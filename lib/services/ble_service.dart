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
const String CALIBRATION_STATUS_UUID = "494600C8-1693-4A3B-B380-FF1EC534959E";

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

enum CalibrationState {
  idle,
  inProgress,
  success,
  failed
}

class BleService {
  static final BleService _instance = BleService._internal();
  factory BleService() {
    return _instance;
  }
  BleService._internal();

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

  final _calibrationStatusController = StreamController<CalibrationState>.broadcast();
  Stream<CalibrationState> get calibrationStatusStream => _calibrationStatusController.stream;

  BleConnectionState _currentConnectionState = BleConnectionState.disconnected;
  BluetoothDevice? _connectedDevice;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  List<StreamSubscription<List<int>>> _characteristicValueSubscriptions = []; // Corrected type
  StreamSubscription<bool>? _isScanningSubscription;

  BluetoothCharacteristic? _batteryCharacteristic;
  BluetoothCharacteristic? _fallCharacteristic;
  BluetoothCharacteristic? _calibrationCharacteristic;
  BluetoothCharacteristic? _calibrationStatusCharacteristic; // CLASS MEMBER DECLARED HERE

  Future<void> initialize() async {
    print("BleService Initializing...");
    await _requestPermissions();

    FlutterBluePlus.adapterState.listen((state) {
      print("BleService: BLE Adapter State: $state");
      if (state == BluetoothAdapterState.on) {
        if (_currentConnectionState == BleConnectionState.bluetoothOff || _currentConnectionState == BleConnectionState.unknown) {
          _updateConnectionState(BleConnectionState.disconnected);
        }
      } else if (state == BluetoothAdapterState.off) {
        _updateConnectionState(BleConnectionState.bluetoothOff);
        disconnectFromDevice(); // Attempt to clean up if BT is turned off
      } else if (state == BluetoothAdapterState.unavailable) {
        _updateConnectionState(BleConnectionState.unknown);
      } else if (state == BluetoothAdapterState.unauthorized) {
        _updateConnectionState(BleConnectionState.noPermissions);
      }
    });

    FlutterBluePlus.scanResults.listen((results) {
      _scanResultsController.add(results);
    });

    _isScanningSubscription = FlutterBluePlus.isScanning.listen((scanning) {
      print("BleService: isScanning state changed: $scanning");
      if (scanning) {
        if (_currentConnectionState == BleConnectionState.disconnected || _currentConnectionState == BleConnectionState.scanStopped || _currentConnectionState == BleConnectionState.unknown) {
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
      print("BleService: Connection State Updated: $state");
    }
  }

  Future<void> _requestPermissions() async {
    print("BleService: Requesting BLE and Location Permissions...");
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse, // Essential for BLE scanning on many Android versions
      // Permission.locationAlways, // Only if background location is strictly needed by a feature
      Permission.phone,            // For making calls
      // Permission.systemAlertWindow, // If you plan to draw overlays from background
    ].request();
    statuses.forEach((permission, status) {
      print("BleService: Permission ${permission.toString()} status: ${status.toString()}");
    });
    print("BleService: Permission requests finished.");
  }

  Future<void> startScan({Duration timeout = const Duration(seconds: 10)}) async {
    if (FlutterBluePlus.isScanningNow) {
      print("BleService: Already scanning. Ignoring start scan request.");
      return;
    }
    if (_currentConnectionState == BleConnectionState.connecting || _currentConnectionState == BleConnectionState.connected) {
      print("BleService: Already connecting or connected. Scan not initiated.");
      return;
    }


    print("BleService: Starting BLE scan...");
    _scanResultsController.add([]); // Clear previous results

    // Check adapter state
    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      print("BleService: Cannot start scan: Bluetooth adapter is ${adapterState.name}.");
      _updateConnectionState(adapterState == BluetoothAdapterState.off
          ? BleConnectionState.bluetoothOff
          : BleConnectionState.unknown);
      return;
    }

    // Check permissions
    if (!await Permission.bluetoothScan.isGranted ||
        !await Permission.bluetoothConnect.isGranted ||
        !await Permission.locationWhenInUse.isGranted) { // Or locationAlways if that's your target
      print("BleService: Cannot start scan: Missing required Bluetooth or Location permissions.");
      _updateConnectionState(BleConnectionState.noPermissions);
      await _requestPermissions(); // Try requesting again
      return;
    }
    _updateConnectionState(BleConnectionState.scanning);
    try {
      await FlutterBluePlus.startScan(timeout: timeout);
      print("BleService: BLE scan started.");
    } catch (e) {
      print("BleService: Error starting scan: $e");
      _updateConnectionState(BleConnectionState.scanStopped); // Or unknown/error
    }
  }

  Future<void> stopScan() async {
    if (FlutterBluePlus.isScanningNow) {
      print("BleService: Stopping BLE scan...");
      try {
        await FlutterBluePlus.stopScan();
        print("BleService: BLE scan stopped.");
        // State update to scanStopped is handled by the isScanning listener
      } catch (e) {
        print("BleService: Error stopping scan: $e");
        _updateConnectionState(BleConnectionState.scanStopped); // Or unknown/error
      }
    } else {
      print("BleService: No active BLE scan to stop.");
      if (_currentConnectionState == BleConnectionState.scanning) {
        _updateConnectionState(BleConnectionState.scanStopped);
      }
    }
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    if (_currentConnectionState == BleConnectionState.connected && _connectedDevice?.remoteId == device.remoteId) {
      print("BleService: Already connected to ${device.platformName}. Ignoring connect request.");
      return;
    }
    if (_currentConnectionState == BleConnectionState.connecting) {
      print("BleService: Already attempting to connect. Ignoring connect request.");
      return;
    }

    print("BleService: Attempting to connect to ${device.platformName} (${device.remoteId})...");
    _updateConnectionState(BleConnectionState.connecting);

    try {
      if (FlutterBluePlus.isScanningNow) {
        await stopScan();
      }

      _connectionStateSubscription?.cancel(); // Cancel any previous device's connection state sub
      _connectionStateSubscription = device.connectionState.listen(
              (BluetoothConnectionState state) {
            print("BleService: Device ${device.platformName} connection state changed: $state");
            if (state == BluetoothConnectionState.disconnected) {
              if (_connectedDevice?.remoteId == device.remoteId || _connectedDevice == null) {
                _clearCharacteristicReferencesAndSubscriptions();
                _connectedDevice = null;
                _connectedDeviceController.add(null);
                _updateConnectionState(BleConnectionState.disconnected);
                print("BleService: Disconnected from ${device.platformName}");
              }
            } else if (state == BluetoothConnectionState.connected) {
              _connectedDevice = device;
              _connectedDeviceController.add(device);
              _updateConnectionState(BleConnectionState.connected);
              print("BleService: Successfully connected to ${device.platformName}");
              _discoverServices(device);
            }
          },
          onError: (error) {
            print("BleService: Error in device connection state stream for ${device.platformName}: $error");
            _updateConnectionState(BleConnectionState.disconnected);
          }
      );

      await device.connect(timeout: const Duration(seconds: 15), autoConnect: false);
      // Connection state listener will handle transition to 'connected' and service discovery
    } catch (e) {
      print("BleService: Error connecting to device ${device.platformName}: $e");
      _connectionStateSubscription?.cancel(); // Clean up listener on error
      _updateConnectionState(BleConnectionState.disconnected); // Or a specific error state
    }
  }

  Future<void> disconnectFromDevice() async {
    if (_connectedDevice == null) {
      print("BleService: Not connected to any device. Ignoring disconnect request.");
      if (_currentConnectionState != BleConnectionState.disconnected && _currentConnectionState != BleConnectionState.scanStopped) {
        _updateConnectionState(BleConnectionState.disconnected);
      }
      return;
    }
    if (_currentConnectionState == BleConnectionState.disconnecting) {
      print("BleService: Already disconnecting. Ignoring disconnect request.");
      return;
    }


    print("BleService: Attempting to disconnect from ${_connectedDevice!.platformName}...");
    _updateConnectionState(BleConnectionState.disconnecting);

    try {
      await _connectedDevice!.disconnect();
      // The device.connectionState listener should handle the state update to disconnected
      print("BleService: Disconnect command sent to ${_connectedDevice!.platformName}.");
    } catch (e) {
      print("BleService: Error disconnecting from device: $e");
      // If disconnect fails, force state back to connected to allow retry, or to disconnected if appropriate
      if (_connectedDevice != null && _connectedDevice!.isConnected) {
        _updateConnectionState(BleConnectionState.connected); // Still connected
      } else {
        _clearCharacteristicReferencesAndSubscriptions();
        _connectedDevice = null;
        _connectedDeviceController.add(null);
        _updateConnectionState(BleConnectionState.disconnected);
      }
    }
  }

  void _clearCharacteristicReferencesAndSubscriptions() {
    _batteryCharacteristic = null;
    _fallCharacteristic = null;
    _calibrationCharacteristic = null;
    _calibrationStatusCharacteristic = null; // CLEAR THIS TOO
    print("BleService: Characteristic references cleared.");

    for (var sub in _characteristicValueSubscriptions) {
      sub.cancel();
    }
    _characteristicValueSubscriptions.clear();
    print("BleService: Characteristic value subscriptions cancelled.");
  }

  Future<void> _discoverServices(BluetoothDevice device) async {
    print("BleService: Discovering services for ${device.platformName}...");
    // Clear old ones before rediscovering, especially if reconnecting without full disconnect
    _clearCharacteristicReferencesAndSubscriptions();


    List<BluetoothService> services;
    try {
      services = await device.discoverServices();
      print("BleService: Discovered ${services.length} services for ${device.platformName}.");
    } catch (e) {
      print("BleService: Error discovering services for ${device.platformName}: $e");
      // Consider disconnecting or setting an error state
      disconnectFromDevice();
      return;
    }

    bool smartCaneServiceFound = false;
    for (BluetoothService service in services) {
      // print("BleService DEBUG: Service UUID: ${service.uuid.str.toUpperCase()}");
      if (service.uuid.str.toUpperCase() == SMART_CANE_SERVICE_UUID.toUpperCase()) {
        smartCaneServiceFound = true;
        print("BleService: Found Smart Cane Service! (${service.uuid.str})");
        for (BluetoothCharacteristic characteristic in service.characteristics) {
          final charUuidUpper = characteristic.uuid.str.toUpperCase();
          print("BleService:  Characteristic UUID: $charUuidUpper (Notify: ${characteristic.properties.notify})");

          if (charUuidUpper == BATTERY_CHARACTERISTIC_UUID) {
            _batteryCharacteristic = characteristic;
            print("BleService:   Found Battery Characteristic.");
            if (characteristic.properties.read) await readBatteryLevel(); // Initial read
            if (characteristic.properties.notify) await _subscribeToChar(characteristic, _batteryLevelController);
          } else if (charUuidUpper == FALL_CHARACTERISTIC_UUID) {
            _fallCharacteristic = characteristic;
            print("BleService:   Found Fall Characteristic.");
            if (characteristic.properties.notify) await _subscribeToChar(characteristic, _fallDetectedController);
          } else if (charUuidUpper == CALIBRATION_CHARACTERISTIC_UUID) {
            _calibrationCharacteristic = characteristic;
            print("BleService:   Found Calibration Command Characteristic. Write: ${characteristic.properties.write}, WriteNoResponse: ${characteristic.properties.writeWithoutResponse}");
          } else if (charUuidUpper == CALIBRATION_STATUS_UUID) {
            _calibrationStatusCharacteristic = characteristic; // ASSIGN CLASS MEMBER
            print("BleService:   Found Calibration Status Characteristic.");
            if (characteristic.properties.notify) {
              print("BleService DEBUG: Calibration Status Characteristic SUPPORTS notify. Attempting to subscribe...");
              await _subscribeToChar(characteristic, _calibrationStatusController);
            } else {
              print("BleService DEBUG ERROR: Calibration Status characteristic DOES NOT support notifications!");
            }
          }
        }
      }
    }

    if (!smartCaneServiceFound) {
      print("BleService ERROR: Smart Cane Service not found on ${device.platformName}. Disconnecting.");
      disconnectFromDevice();
    } else if (_batteryCharacteristic == null || _fallCharacteristic == null || _calibrationCharacteristic == null || _calibrationStatusCharacteristic == null) {
      print("BleService WARNING: Not all required Smart Cane characteristics were found. Some features may not work.");
      // Decide if this is a critical failure worthy of disconnect
    } else {
      print("BleService: All required Smart Cane characteristics identified.");
      _calibrationStatusController.add(CalibrationState.idle); // Set initial state after successful discovery
    }
  }

  Future<int?> readBatteryLevel() async {
    if (_batteryCharacteristic == null || !_connectedDeviceAndCharProps(_batteryCharacteristic!, read: true)) {
      print("BleService: Cannot read battery: Characteristic not available or doesn't support read.");
      return null;
    }
    print("BleService: Reading battery level...");
    try {
      List<int> value = await _batteryCharacteristic!.read();
      if (value.isNotEmpty) {
        int batteryLevel = value[0];
        if (batteryLevel >= 0 && batteryLevel <= 100) {
          print("BleService: Read Battery Level: $batteryLevel%");
          _batteryLevelController.add(batteryLevel);
          return batteryLevel;
        } else {
          print("BleService: Received unexpected battery value: ${value[0]}");
        }
      } else {
        print("BleService: Received empty value from Battery Characteristic read.");
      }
    } catch (e) {
      print("BleService: Error reading battery level: $e");
    }
    return null;
  }

  // Subscribe to Characteristics:
  Future<void> _subscribeToChar(BluetoothCharacteristic characteristic, StreamController controller) async {
    if (!_connectedDeviceAndCharProps(characteristic, notify: true)) {
      print("BleService: Cannot subscribe to ${characteristic.uuid.str}: Device not connected or char does not support notify.");
      // If it's the calibration status controller, emit idle or failed as it won't work
      if (controller == _calibrationStatusController) {
        _calibrationStatusController.add(CalibrationState.idle); // Or failed
      }
      return;
    }

    final charUuidUpper = characteristic.uuid.str.toUpperCase();
    print("BleService DEBUG: Attempting to setNotifyValue(true) for UUID: $charUuidUpper");

    try {
      await characteristic.setNotifyValue(true);
      print("BleService DEBUG: Successfully called setNotifyValue(true) for UUID: $charUuidUpper");

      final StreamSubscription<List<int>> subscription = characteristic.value.listen(
              (value) {
            // General log for any notification
            // print("BleService DEBUG: NOTIFICATION RECEIVED for $charUuidUpper! Raw data: $value");

            if (charUuidUpper == BATTERY_CHARACTERISTIC_UUID) {
              if (value.isNotEmpty) {
                // ... battery logic ...
                (controller as StreamController<int?>).add(value[0]);
              } else {
                print("BleService: Received empty notification from Battery Characteristic.");
              }
            } else if (charUuidUpper == FALL_CHARACTERISTIC_UUID) {
              if (value.isNotEmpty) {
                // ... fall logic ...
                (controller as StreamController<bool>).add(value[0] == 1);
              } else {
                print("BleService: Received empty notification from Fall Characteristic.");
              }
            } else if (charUuidUpper == CALIBRATION_STATUS_UUID) {
              // Specific logging for calibration status
              print("BleService DEBUG: CALIBRATION STATUS NOTIFICATION for $charUuidUpper. Raw data: $value");
              if (value.isNotEmpty) {
                CalibrationState calibState;
                print("BleService DEBUG: Parsing value[0]: ${value[0]} for $charUuidUpper (Calibration Status)");
                switch (value[0]) {
                  case 0: calibState = CalibrationState.failed; break;
                  case 1: calibState = CalibrationState.success; break;
                  case 2: calibState = CalibrationState.inProgress; break;
                  default:
                    print("BleService WARNING: Received UNKNOWN calibration status data value: ${value[0]} for $charUuidUpper. Setting to idle.");
                    calibState = CalibrationState.idle;
                    break;
                }
                print("BleService DEBUG: Parsed Calibration Status: $calibState for $charUuidUpper");
                (controller as StreamController<CalibrationState>).add(calibState);
              } else {
                // IGNORE EMPTY PACKETS for calibration status state updates.
                // The 'idle' state is set by _discoverServices. This empty packet should not change it to 'failed'.
                print("BleService DEBUG: Calibration Status NOTIFICATION was EMPTY for $charUuidUpper. IGNORING for state update.");
              }
            }
          },
          onError: (error) {
            print("BleService DEBUG ERROR: Error in characteristic value stream for $charUuidUpper: $error");
            if (controller == _calibrationStatusController) {
              (controller as StreamController<CalibrationState>).add(CalibrationState.failed); // Stream error could mean failure
            }
          },
          onDone: () {
            print("BleService DEBUG: Characteristic value stream DONE for $charUuidUpper.");
            if (controller == _calibrationStatusController) {
              (controller as StreamController<CalibrationState>).add(CalibrationState.idle); // Stream closed, go to idle
            }
          }
      );
      _characteristicValueSubscriptions.add(subscription);
      print("BleService DEBUG: Added subscription to _characteristicValueSubscriptions for $charUuidUpper");
    } catch (e) {
      print("BleService DEBUG ERROR: Failed to setNotifyValue or listen for $charUuidUpper: $e");
      if (controller == _calibrationStatusController) {
        (controller as StreamController<CalibrationState>).add(CalibrationState.failed); // If cannot subscribe, it's a failure for this feature
      }
    }
  }

  bool _connectedDeviceAndCharProps(BluetoothCharacteristic char, {bool read = false, bool write = false, bool notify = false}) {
    if (_connectedDevice == null || !_connectedDevice!.isConnected) return false;
    if (read && !char.properties.read) return false;
    if (write && !(char.properties.write || char.properties.writeWithoutResponse)) return false;
    if (notify && !(char.properties.notify || char.properties.indicate)) return false;
    return true;
  }


  BleConnectionState getCurrentConnectionState() {
    return _currentConnectionState;
  }

  Future<void> sendCalibrationCommand() async {
    if (_calibrationCharacteristic == null || !_connectedDeviceAndCharProps(_calibrationCharacteristic!, write: true)) {
      print("BleService: Cannot send calibration command: Not connected, characteristic not found, or does not support writing.");
      return;
    }
    print("BleService: Sending calibration command ([1])...");
    try {
      // Determine if writeWithoutResponse is preferred or available
      bool withoutResponse = _calibrationCharacteristic!.properties.writeWithoutResponse;
      await _calibrationCharacteristic!.write([1], withoutResponse: withoutResponse);
      print("BleService: Calibration command sent.");
      // No longer setting _calibrationStatusController to inProgress here,
      // as the ESP32 will send a notification for that.
    } catch (e) {
      print("BleService: Error sending calibration command: $e");
      _calibrationStatusController.add(CalibrationState.failed); // Notify UI of failure to send
    }
  }

  Future<void> makePhoneCall(String phoneNumber) async {
    final Uri launchUri = Uri(scheme: 'tel', path: phoneNumber);
    try {
      if (await canLaunchUrl(launchUri)) {
        await launchUrl(launchUri);
        print("BleService: Attempting to open dialer for: $phoneNumber");
      } else {
        print("BleService: Could not launch dialer for $phoneNumber");
      }
    } catch (e) {
      print("BleService: Error launching phone call: $e");
    }
  }

  void resetFallDetectedStateLocally() {
    print("BleService: Resetting fall detected state locally in app.");
    _fallDetectedController.add(false);
  }

  void dispose() {
    print("BleService Disposing...");
    _connectionStateSubscription?.cancel();
    _isScanningSubscription?.cancel();
    _clearCharacteristicReferencesAndSubscriptions(); // Cancels char value subs

    // Attempt to disconnect if connected
    if (_connectedDevice != null && _connectedDevice!.isConnected) {
      print("BleService: Disconnecting from device during dispose...");
      _connectedDevice!.disconnect().catchError((e) {
        print("BleService: Error during disconnect in dispose: $e");
      });
    }

    _connectionStateController.close();
    _scanResultsController.close();
    _batteryLevelController.close();
    _fallDetectedController.close();
    _connectedDeviceController.close();
    _calibrationStatusController.close();
    print("BleService Disposed.");
  }
}