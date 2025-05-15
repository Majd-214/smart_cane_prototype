import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

// Define the Service and Characteristic UUIDs
const String SMART_CANE_SERVICE_UUID = "A5A20D8A-E137-4B30-9F30-1A7A91579C9C";
const String BATTERY_CHARACTERISTIC_UUID = "2A19";
const String FALL_CHARACTERISTIC_UUID = "C712A5B2-2C13-4088-8D53-F7E3291B0155";
const String CALIBRATION_CHARACTERISTIC_UUID = "E9A10B6B-8A65-4F56-82C3-6768F0EE38A1";
const String SMART_CANE_DEVICE_NAME = "Smart Cane";

enum BleConnectionState {
  disconnected,
  connecting,
  connected,
  disconnecting,
  bluetoothOff,
  noPermissions,
  unknown,
  scanning,
  scanStopped,
}

class BleService {
  // Singleton pattern
  static final BleService _instance = BleService._internal();
  factory BleService() {
    return _instance;
  }
  BleService._internal();

  // Streams to broadcast BLE state changes
  final _connectionStateController = StreamController<BleConnectionState>.broadcast();
  Stream<BleConnectionState> get connectionStateStream => _connectionStateController.stream;

  final _scanResultsController = StreamController<List<ScanResult>>.broadcast();
  Stream<List<ScanResult>> get scanResultsStream => _scanResultsController.stream;

  final _batteryLevelController = StreamController<int?>.broadcast();
  Stream<int?> get batteryLevelStream => _batteryLevelController.stream;

  final _fallDetectedController = StreamController<bool>.broadcast();
  Stream<bool> get fallDetectedStream => _fallDetectedController.stream;

  final _connectedDeviceController = StreamController<BluetoothDevice?>.broadcast();
  Stream<BluetoothDevice?> get connectedDeviceStream => _connectedDeviceController.stream;


  // Keep track of the current connection state internally
  BleConnectionState _currentConnectionState = BleConnectionState.disconnected;

  // Currently connected device and its subscriptions
  BluetoothDevice? _connectedDevice;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  List<StreamSubscription> _characteristicValueSubscriptions = [];
  StreamSubscription<bool>? _isScanningSubscription;


  // Keep track of discovered characteristics
  BluetoothCharacteristic? _batteryCharacteristic;
  BluetoothCharacteristic? _fallCharacteristic;
  BluetoothCharacteristic? _calibrationCharacteristic;


  // --- Initialization and Permissions ---
  Future<void> initialize() async {
    print("BleService Initializing...");
    await _requestPermissions();

    FlutterBluePlus.adapterState.listen((state) {
      print("BLE Adapter State: $state");
      if (state == BluetoothAdapterState.on) {
        if (_currentConnectionState == BleConnectionState.bluetoothOff || _currentConnectionState == BleConnectionState.unknown) {
          _updateConnectionState(BleConnectionState.disconnected);
        }
      } else if (state == BluetoothAdapterState.off) {
        _updateConnectionState(BleConnectionState.bluetoothOff);
        disconnectFromDevice();
      } else if (state == BluetoothAdapterState.unavailable) {
        _updateConnectionState(BleConnectionState.unknown);
      }
      if (state == BluetoothAdapterState.unauthorized) {
        _updateConnectionState(BleConnectionState.noPermissions);
      }
    });

    FlutterBluePlus.scanResults.listen((results) {
      _scanResultsController.add(results);
    });

    _isScanningSubscription = FlutterBluePlus.isScanning.listen((scanning) {
      print("isScanning state changed: $scanning");
      if (scanning) {
        if (_currentConnectionState == BleConnectionState.disconnected || _currentConnectionState == BleConnectionState.scanStopped) {
          _updateConnectionState(BleConnectionState.scanning);
        }
      } else {
        if (_currentConnectionState == BleConnectionState.scanning) {
          _updateConnectionState(BleConnectionState.scanStopped);
        }
      }
    });

    print("BleService Initialized.");
  }

  void _updateConnectionState(BleConnectionState state) {
    if (_currentConnectionState != state) {
      _currentConnectionState = state;
      _connectionStateController.add(state);
      print("Connection State Updated: $state");
    }
  }


  Future<void> _requestPermissions() async {
    print("Requesting BLE and Location Permissions...");
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
    await Permission.locationWhenInUse.request();
    await Permission.locationAlways.request();
    await Permission.phone.request();
    await Permission.systemAlertWindow.request();
    print("Permission requests finished.");
  }

  // --- Scanning ---
  Future<void> startScan({Duration timeout = const Duration(seconds: 10)}) async {
    if (FlutterBluePlus.isScanningNow || _currentConnectionState == BleConnectionState.connecting || _currentConnectionState == BleConnectionState.connected || _currentConnectionState == BleConnectionState.disconnecting) {
      print("Already scanning, connecting, connected, or disconnecting. Ignoring start scan request.");
      return;
    }

    print("Starting BLE scan...");
    _scanResultsController.add([]);
    _updateConnectionState(BleConnectionState.scanning);
    try {
      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        print("Cannot start scan: Bluetooth adapter is ${adapterState.name}.");
        if (adapterState == BluetoothAdapterState.off) _updateConnectionState(BleConnectionState.bluetoothOff);
        if (adapterState == BluetoothAdapterState.unauthorized) _updateConnectionState(BleConnectionState.noPermissions);
        _updateConnectionState(BleConnectionState.scanStopped);
        return;
      }

      final locationStatus = await Permission.locationWhenInUse.status;
      final bluetoothScanStatus = await Permission.bluetoothScan.status;
      if (!locationStatus.isGranted || !bluetoothScanStatus.isGranted) {
        print("Cannot start scan: Missing Location or Bluetooth Scan permissions.");
        _updateConnectionState(BleConnectionState.noPermissions);
        await _requestPermissions();
        _updateConnectionState(BleConnectionState.scanStopped);
        return;
      }

      await FlutterBluePlus.startScan(timeout: timeout);
      print("BLE scan started.");
    } catch (e) {
      print("Error starting scan: $e");
      _updateConnectionState(BleConnectionState.scanStopped);
    }
  }

  Future<void> stopScan() async {
    if (FlutterBluePlus.isScanningNow) {
      print("Stopping BLE scan...");
      try {
        await FlutterBluePlus.stopScan();
        print("BLE scan stopped.");
      } catch (e) {
        print("Error stopping scan: $e");
        _updateConnectionState(BleConnectionState.scanStopped);
      }
    } else {
      print("No active BLE scan to stop.");
      _updateConnectionState(BleConnectionState.scanStopped);
    }
  }

  // --- Connection ---
  Future<void> connectToDevice(BluetoothDevice device) async {
    if (_currentConnectionState == BleConnectionState.connecting || _currentConnectionState == BleConnectionState.connected || _currentConnectionState == BleConnectionState.disconnecting) {
      print("Already in connection process or connected. Ignoring connect request.");
      return;
    }

    print("Attempting to connect to ${device.platformName}...");
    _updateConnectionState(BleConnectionState.connecting);

    try {
      await stopScan();

      _connectionStateSubscription?.cancel();
      _connectionStateSubscription = device.connectionState.listen((state) {
        print("Device ${device.platformName} connection state: $state");
        if (state == BluetoothConnectionState.disconnected) {
          _connectedDevice = null;
          _connectedDeviceController.add(null);
          _updateConnectionState(BleConnectionState.disconnected);
          print("Disconnected from ${device.platformName}");
          _clearCharacteristicReferences();
          _cancelCharacteristicValueSubscriptions();

        } else if (state == BluetoothConnectionState.connected) {
          _updateConnectionState(BleConnectionState.connected);
          print("Successfully connected to ${device.platformName}");
          _connectedDevice = device;
          _connectedDeviceController.add(device);
          _discoverServices(device);
        }
      });

      await device.connect(timeout: const Duration(seconds: 15));
      // State update to 'connected' is handled by the listener.

    } catch (e) {
      print("Error connecting to device: $e");
      _updateConnectionState(BleConnectionState.disconnected);
      _connectedDevice = null;
      _connectedDeviceController.add(null);
      _clearCharacteristicReferences();
      _connectionStateSubscription?.cancel();
    }
  }

  Future<void> disconnectFromDevice() async {
    if (_currentConnectionState == BleConnectionState.disconnected || _connectedDevice == null || _currentConnectionState == BleConnectionState.disconnecting) {
      print("Not connected, device is null, or already disconnecting. Ignoring disconnect request.");
      if (_currentConnectionState != BleConnectionState.disconnected && _currentConnectionState != BleConnectionState.scanStopped && _currentConnectionState != BleConnectionState.scanning) {
        _updateConnectionState(BleConnectionState.disconnected);
      }
      return;
    }

    print("Attempting to disconnect from ${_connectedDevice!.platformName}...");
    _updateConnectionState(BleConnectionState.disconnecting);

    try {
      _cancelCharacteristicValueSubscriptions();
      _clearCharacteristicReferences();
      // Don't cancel the connectionStateSubscription here. Let it receive the disconnected event.

      _connectedDeviceController.add(null);

      await _connectedDevice!.disconnect();
      // State update to 'disconnected' is handled by the connectionState listener

    } catch (e) {
      print("Error disconnecting from device: $e");
      _updateConnectionState(BleConnectionState.connected);
      _connectedDeviceController.add(_connectedDevice);
    } finally {
      // Ensure device reference is cleared regardless of success or failure
      _connectedDevice = null;
      // Add a small delay before broadcasting null in finally to allow listener to fire first
      Future.delayed(const Duration(milliseconds: 100), () {
        // Only broadcast null if we haven't transitioned to disconnected already
        if (_currentConnectionState != BleConnectionState.disconnected) {
          _connectedDeviceController.add(null);
          _updateConnectionState(BleConnectionState.disconnected); // Ensure state is disconnected
        }
      });
    }
  }

  void _clearCharacteristicReferences() {
    _batteryCharacteristic = null;
    _fallCharacteristic = null;
    _calibrationCharacteristic = null;
    print("Characteristic references cleared.");
  }

  void _cancelCharacteristicValueSubscriptions() {
    for (var sub in _characteristicValueSubscriptions) {
      sub.cancel();
    }
    _characteristicValueSubscriptions.clear();
    print("Characteristic value subscriptions cancelled.");
  }


  // --- Service and Characteristic Discovery ---
  Future<void> _discoverServices(BluetoothDevice device) async {
    print("Discovering services for ${device.platformName}...");
    _clearCharacteristicReferences();
    _cancelCharacteristicValueSubscriptions();

    try {
      List<BluetoothService> services = await device.discoverServices();
      print("Discovered ${services.length} services.");

      bool smartCaneServiceFound = false;

      for (BluetoothService service in services) {
        print("  Service UUID: ${service.uuid.str.toUpperCase()}");
        if (service.uuid.str.toUpperCase() == SMART_CANE_SERVICE_UUID.toUpperCase()) {
          smartCaneServiceFound = true;
          print("    Found Smart Cane Service!");
          for (BluetoothCharacteristic characteristic in service.characteristics) {
            print("    Characteristic UUID: ${characteristic.uuid.str.toUpperCase()}");
            if (characteristic.uuid.str.toUpperCase() == BATTERY_CHARACTERISTIC_UUID.toUpperCase()) {
              _batteryCharacteristic = characteristic;
              print("      Found Battery Characteristic.");
              if (characteristic.properties.notify) {
                _subscribeToCharacteristic(characteristic, _batteryLevelController);
              } else {
                print("Warning: Battery characteristic does not support notifications.");
              }
              if (characteristic.properties.read) {
                readBatteryLevel();
              }
            } else if (characteristic.uuid.str.toUpperCase() == FALL_CHARACTERISTIC_UUID.toUpperCase()) {
              _fallCharacteristic = characteristic;
              print("      Found Fall Characteristic.");
              if (characteristic.properties.notify) {
                _subscribeToCharacteristic(characteristic, _fallDetectedController);
              } else {
                print("Warning: Fall characteristic does not support notifications.");
              }
            } else if (characteristic.uuid.str.toUpperCase() == CALIBRATION_CHARACTERISTIC_UUID.toUpperCase()) {
              _calibrationCharacteristic = characteristic;
              print("      Found Calibration Characteristic.");
              if (!characteristic.properties.write && !characteristic.properties.writeWithoutResponse) {
                print("Warning: Calibration characteristic does not support writing.");
              }
            }
          }
        }
      }

      if (!smartCaneServiceFound) {
        print("Error: Smart Cane Service not found on the device.");
        disconnectFromDevice();
      } else if (_batteryCharacteristic == null || _fallCharacteristic == null || _calibrationCharacteristic == null) {
        print("Warning: Could not find all required characteristics on the Smart Cane Service. Proceeding with available characteristics.");
      } else {
        print("All required Smart Cane characteristics found.");
      }


    } catch (e) {
      print("Error discovering services: $e");
      disconnectFromDevice();
    }
  }


  // --- Reading and Writing ---
  Future<int?> readBatteryLevel() async {
    if (_batteryCharacteristic != null && _connectedDevice != null && _batteryCharacteristic!.properties.read) {
      print("Reading battery level...");
      try {
        List<int> value = await _batteryCharacteristic!.read();
        if (value.isNotEmpty) {
          int batteryLevel = value[0];
          if (batteryLevel >= 0 && batteryLevel <= 100) {
            print("  Read Battery Level: $batteryLevel%");
            _batteryLevelController.add(batteryLevel);
            return batteryLevel;
          } else {
            print("  Received unexpected battery value: ${value[0]}");
          }
        } else {
          print("  Received empty value from Battery Characteristic.");
        }
      } catch (e) {
        print("Error reading battery level: $e");
      }
    } else {
      print("Cannot read battery level: Not connected, characteristic not found, or does not support reading.");
    }
    return null;
  }


  // --- Notifications (Subscriptions) ---
  void _subscribeToCharacteristic(BluetoothCharacteristic characteristic, StreamController controller) {
    print("Subscribing to notifications for ${characteristic.uuid.str.toUpperCase()}...");
    try {
      characteristic.setNotifyValue(true).catchError((e) {
        print("Error setting notify value for ${characteristic.uuid.str.toUpperCase()}: $e");
      });

      final subscription = characteristic.value.listen((value) {
        if (characteristic.uuid.str.toUpperCase() == BATTERY_CHARACTERISTIC_UUID.toUpperCase()) {
          if (value.isNotEmpty) {
            int batteryLevel = value[0];
            if (batteryLevel >= 0 && batteryLevel <= 100) {
              print("  Parsed Battery Level: $batteryLevel%");
              controller.add(batteryLevel);
            } else {
              print("  Received unexpected battery value: ${value[0]}");
            }
          } else {
            print("  Received empty value from Battery Characteristic.");
          }
        } else if (characteristic.uuid.str.toUpperCase() == FALL_CHARACTERISTIC_UUID.toUpperCase()) {
          if (value.isNotEmpty) {
            bool fallDetected = value[0] == 1;
            print("  Parsed Fall Detected: $fallDetected");
            controller.add(fallDetected);

            if (fallDetected) {
              print("FALL EVENT DETECTED! Triggering overlay logic.");
            }
          } else {
            print("  Received empty value from Fall Characteristic.");
          }
        }
      },
          onError: (e) {
            print("Error receiving data from ${characteristic.uuid.str.toUpperCase()}: $e");
          },
          onDone: () {
            print("Stream for ${characteristic.uuid.str.toUpperCase()} is done.");
          }
      );

      _characteristicValueSubscriptions.add(subscription);
    } catch (e) {
      print("Error setting up subscription for ${characteristic.uuid.str.toUpperCase()}: $e");
    }
  }

  // --- Public Methods to interact with the Service ---
  BleConnectionState getCurrentConnectionState() {
    return _currentConnectionState;
  }

  void startBleScan() {
    startScan();
  }

  void connectToScannedDevice(BluetoothDevice device) {
    connectToDevice(device);
  }

  void disconnectCurrentDevice() {
    disconnectFromDevice();
  }

  void resetFallDetectedState() {
    print("Service: Resetting fall detected state.");
    _fallDetectedController.add(false); // Emit false to update UI
    // TODO: Implement sending a reset command to the ESP32 if needed/possible
  }


  Future<void> sendCalibrationCommand() async {
    if (_calibrationCharacteristic != null && _connectedDevice != null && (_calibrationCharacteristic!.properties.write || _calibrationCharacteristic!.properties.writeWithoutResponse)) {
      print("Sending calibration command...");
      try {
        await _calibrationCharacteristic!.write([1], withoutResponse: _calibrationCharacteristic!.properties.writeWithoutResponse);
        print("Calibration command sent.");
      } catch (e) {
        print("Error sending calibration command: $e");
      }
    } else {
      print("Cannot send calibration command: Not connected or calibration characteristic not found or does not support writing.");
    }
  }

  Future<void> makePhoneCall(String phoneNumber) async {
    final Uri launchUri = Uri(
      scheme: 'tel',
      path: phoneNumber,
    );
    try {
      await launchUrl(launchUri);
      print("Attempting to call: $phoneNumber");
    } catch (e) {
      print("Error launching phone call: $e");
    }
  }

  void dispose() {
    print("BleService Disposing...");
    _cancelCharacteristicValueSubscriptions();
    _connectionStateSubscription?.cancel();
    _isScanningSubscription?.cancel();
    disconnectFromDevice();
    _connectionStateController.close();
    _scanResultsController.close();
    _batteryLevelController.close();
    _fallDetectedController.close();
    _connectedDeviceController.close();
    print("BleService Disposed.");
  }
}