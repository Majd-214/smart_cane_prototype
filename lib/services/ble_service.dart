import 'dart:async';

import 'package:flutter/services.dart'; // For PlatformChannel
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart'; // Import new package
import 'package:permission_handler/permission_handler.dart';

// Define the Service and Characteristic UUIDs
const String SMART_CANE_SERVICE_UUID = "A5A20D8A-E137-4B30-9F30-1A7A91579C9C";
const String BATTERY_CHARACTERISTIC_UUID = "2A19";
const String FALL_CHARACTERISTIC_UUID = "C712A5B2-2C13-4088-8D53-F7E3291B0155";
const String CALIBRATION_CHARACTERISTIC_UUID = "E9A10B6B-8A65-4F56-82C3-6768F0EE38A1";
const String CALIBRATION_STATUS_UUID = "494600C8-1693-4A3B-B380-FF1EC534959E";
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

enum CalibrationState {
  idle,
  inProgress,
  success,
  failed,
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

  final _calibrationStatusController = StreamController<
      CalibrationState>.broadcast();

  Stream<CalibrationState> get calibrationStatusStream =>
      _calibrationStatusController.stream;
  CalibrationState _currentInternalCalibrationState = CalibrationState
      .idle; // Cache the state

  BleConnectionState _currentConnectionState = BleConnectionState.disconnected;
  BluetoothDevice? _connectedDevice;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  Map<String,
      StreamSubscription<List<int>>> _characteristicValueSubscriptions = {};
  StreamSubscription<bool>? _isScanningSubscription;

  BluetoothCharacteristic? _batteryCharacteristic;
  BluetoothCharacteristic? _fallCharacteristic;
  BluetoothCharacteristic? _calibrationCharacteristic;
  BluetoothCharacteristic? _calibrationStatusCharacteristic;

  Future<void> initialize() async {
    print("BleService Initializing...");
    _currentInternalCalibrationState =
        CalibrationState.idle; // Initialize cache
    _calibrationStatusController.add(
        _currentInternalCalibrationState); // Notify initial state
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
      if (state == BleConnectionState.disconnected ||
          state == BleConnectionState.bluetoothOff ||
          state == BleConnectionState.noPermissions) {
        _currentInternalCalibrationState = CalibrationState.idle; // Reset cache
        _calibrationStatusController.add(
            _currentInternalCalibrationState); // Notify reset
        // Subscription cancellation is handled by disconnectFromDevice or its cascade
      }
    }
  }

  Future<void> _requestPermissions() async {
    print("Requesting BLE and Location Permissions...");
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
    await Permission.locationWhenInUse.request();
    print("Permission requests finished.");
  }

  Future<void> startScan({Duration timeout = const Duration(seconds: 10)}) async {
    if (FlutterBluePlus.isScanningNow || _currentConnectionState == BleConnectionState.connecting || _currentConnectionState == BleConnectionState.connected || _currentConnectionState == BleConnectionState.disconnecting) {
      print("Already scanning, connecting, connected, or disconnecting. Ignoring start scan request.");
      return;
    }
    _currentInternalCalibrationState =
        CalibrationState.idle; // Reset on new scan
    _calibrationStatusController.add(_currentInternalCalibrationState);

    print("Starting BLE scan...");
    _scanResultsController.add([]); // Clear previous results
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
        await _requestPermissions(); // Try requesting again
        final newLocationStatus = await Permission.locationWhenInUse.status;
        final newBluetoothScanStatus = await Permission.bluetoothScan.status;
        if (!newLocationStatus.isGranted || !newBluetoothScanStatus.isGranted) {
          _updateConnectionState(
              BleConnectionState.scanStopped); // Still no permissions
          return;
        }
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
      } finally {
        if (_currentConnectionState == BleConnectionState.scanning) {
          _updateConnectionState(BleConnectionState.scanStopped);
        }
      }
    } else {
      print("No active BLE scan to stop.");
      if (_currentConnectionState == BleConnectionState.scanning) {
        _updateConnectionState(BleConnectionState.scanStopped);
      }
    }
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    if (_currentConnectionState == BleConnectionState.connecting || _currentConnectionState == BleConnectionState.connected || _currentConnectionState == BleConnectionState.disconnecting) {
      print("Already in connection process or connected. Ignoring connect request.");
      return;
    }
    _currentInternalCalibrationState =
        CalibrationState.idle; // Reset on new connection attempt
    _calibrationStatusController.add(_currentInternalCalibrationState);

    print("Attempting to connect to ${device.platformName}...");
    _updateConnectionState(BleConnectionState.connecting);
    try {
      if (FlutterBluePlus.isScanningNow) {
        await stopScan();
      }
      _connectionStateSubscription
          ?.cancel(); // Cancel previous device's state subscription
      _connectionStateSubscription = device.connectionState.listen((state) {
        print("Device ${device.platformName} connection state: $state");
        if (state == BluetoothConnectionState.disconnected) {
          _connectedDevice = null;
          _connectedDeviceController.add(null);
          _updateConnectionState(BleConnectionState
              .disconnected); // This will reset calibration state via its notifier
          _clearCharacteristicReferences();
          _cancelCharacteristicValueSubscriptions(); // Ensure subs are cancelled on disconnect
        } else if (state == BluetoothConnectionState.connected) {
          _updateConnectionState(BleConnectionState.connected);
          print("Successfully connected to ${device.platformName}");
          _connectedDevice = device;
          _connectedDeviceController.add(device);
          _discoverServices(device);
        }
      });
      await device.connect(
          timeout: const Duration(seconds: 15), autoConnect: false);
    } catch (e) {
      print("Error connecting to device: $e");
      _updateConnectionState(BleConnectionState.disconnected);
      _connectedDevice = null;
      _connectedDeviceController.add(null);
      _clearCharacteristicReferences();
      _connectionStateSubscription
          ?.cancel(); // Cancel the new subscription attempt if it failed
      _cancelCharacteristicValueSubscriptions(); // Also cancel if connection fails
    }
  }

  Future<void> disconnectFromDevice() async {
    if (_currentConnectionState == BleConnectionState.disconnected || _connectedDevice == null || _currentConnectionState == BleConnectionState.disconnecting) {
      print("Not connected, device is null, or already disconnecting. Ignoring disconnect request.");
      if (_currentConnectionState != BleConnectionState.disconnected &&
          _currentConnectionState != BleConnectionState.scanStopped &&
          _currentConnectionState != BleConnectionState.scanning) {
        _updateConnectionState(BleConnectionState.disconnected);
      }
      return;
    }
    print("Attempting to disconnect from ${_connectedDevice!.platformName}...");
    _updateConnectionState(BleConnectionState.disconnecting);
    try {
      await _connectedDevice!.disconnect();
      // State update to 'disconnected' handled by connectionState listener,
      // which will then call _cancelCharacteristicValueSubscriptions & reset calibration state.
    } catch (e) {
      print("Error disconnecting from device: $e");
      _updateConnectionState(BleConnectionState
          .connected); // Revert to connected if disconnect failed
      _connectedDeviceController.add(_connectedDevice);
    }
  }

  void _clearCharacteristicReferences() {
    _batteryCharacteristic = null;
    _fallCharacteristic = null;
    _calibrationCharacteristic = null;
    _calibrationStatusCharacteristic = null;
    print("Characteristic references cleared.");
  }

  void _cancelCharacteristicValueSubscriptions() {
    print("Cancelling ${_characteristicValueSubscriptions
        .length} characteristic value subscriptions...");
    _characteristicValueSubscriptions.forEach((uuid, sub) {
      sub.cancel();
      print("  Cancelled subscription for UUID: $uuid");
    });
    _characteristicValueSubscriptions.clear();
    print("All characteristic value subscriptions cancelled and cleared.");
  }

  Future<void> _discoverServices(BluetoothDevice device) async {
    print("Discovering services for ${device.platformName}...");
    // Clearing refs and subs is vital before re-discovering
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
            String charUuid = characteristic.uuid.str.toUpperCase();
            if (charUuid == BATTERY_CHARACTERISTIC_UUID.toUpperCase()) {
              _batteryCharacteristic = characteristic;
              print("      Found Battery Characteristic.");
              if (characteristic.properties
                  .notify) await _subscribeToCharacteristic(
                  characteristic, _parseBatteryLevel, "Battery");
              if (characteristic.properties
                  .read) readBatteryLevel(); // Initial read
            } else if (charUuid == FALL_CHARACTERISTIC_UUID.toUpperCase()) {
              _fallCharacteristic = characteristic;
              print("      Found Fall Characteristic.");
              if (characteristic.properties
                  .notify) await _subscribeToCharacteristic(
                  characteristic, _parseFallDetection, "Fall");
            } else
            if (charUuid == CALIBRATION_CHARACTERISTIC_UUID.toUpperCase()) {
              _calibrationCharacteristic = characteristic;
              print("      Found Calibration Command Characteristic.");
            } else if (charUuid == CALIBRATION_STATUS_UUID.toUpperCase()) {
              _calibrationStatusCharacteristic = characteristic;
              print("      Found Calibration Status Characteristic.");
              if (characteristic.properties
                  .notify) await _subscribeToCharacteristic(
                  characteristic, _parseCalibrationStatus, "CalibrationStatus");
            }
          }
        }
      }
      if (!smartCaneServiceFound) {
        print("Error: Smart Cane Service not found on the device.");
        disconnectFromDevice();
      } else
      if (_batteryCharacteristic == null || _fallCharacteristic == null ||
          _calibrationCharacteristic == null ||
          _calibrationStatusCharacteristic == null) {
        print(
            "Warning: Could not find ALL required characteristics on the Smart Cane Service. Some features might not work.");
      } else {
        print(
            "All required Smart Cane characteristics found and subscriptions attempted.");
      }
    } catch (e) {
      print("Error discovering services: $e");
      disconnectFromDevice(); // Disconnect if service discovery fails catastrophically
    }
  }

  void _parseBatteryLevel(List<int> value) {
    if (value.isNotEmpty) {
      int batteryLevel = value[0];
      if (batteryLevel >= 0 && batteryLevel <= 100) {
        _batteryLevelController.add(batteryLevel);
      } else {
        print("  Received unexpected battery value: ${value[0]}");
      }
    } else {
      // Don't add to controller if empty, could be an issue with peripheral or connection
      print(
          "  Received empty value from Battery Characteristic. No update to battery level.");
    }
  }

  void _parseFallDetection(List<int> value) {
    if (value.isNotEmpty) {
      bool fallDetected = value[0] == 1;
      _fallDetectedController.add(fallDetected);
    } else {
      print(
          "  Received empty value from Fall Characteristic. No update to fall status.");
    }
  }

  void _parseCalibrationStatus(List<int> value) {
    CalibrationState previousState = _currentInternalCalibrationState; // Use cached state

    if (value.isNotEmpty) {
      int statusByte = value[0];
      switch (statusByte) {
        case 0:
          _currentInternalCalibrationState = CalibrationState.failed;
          break;
        case 1:
          _currentInternalCalibrationState = CalibrationState.success;
          break;
        case 2:
          _currentInternalCalibrationState = CalibrationState.inProgress;
          break;
        default:
          print(
              "  Received unknown calibration status byte: $statusByte. Treating as FAILED.");
          _currentInternalCalibrationState = CalibrationState.failed;
          break;
      }
      print(
          "  Parsed Calibration Status: $_currentInternalCalibrationState (from byte $statusByte)");
    } else {
      // This case should ideally not be hit if onValueReceived only fires on actual data.
      // If it does, it means the peripheral sent an empty notification, which is odd for this characteristic.
      print(
          "  Received empty value from Calibration Status Characteristic. Current internal state: $previousState");
      if (previousState != CalibrationState.idle) {
        // If we were inProgress or success and suddenly get empty, that's a failure.
        _currentInternalCalibrationState = CalibrationState.failed;
        print("  Transitioning to FAILED due to empty value when not idle.");
      }
      // If previousState was idle, _currentInternalCalibrationState remains idle (no change on empty if idle).
    }
    // Only notify listeners if the state actually changed, or if it's a specific update we always want to pass.
    // For calibration, any explicit status from ESP32 is usually important.
    _calibrationStatusController.add(_currentInternalCalibrationState);
  }

  Future<int?> readBatteryLevel() async {
    if (_batteryCharacteristic != null && _connectedDevice != null &&
        _batteryCharacteristic!.properties.read) {
      print("Reading battery level...");
      try {
        List<int> value = await _batteryCharacteristic!.read();
        _parseBatteryLevel(value); // Use the parser to update the stream
        if (value.isNotEmpty && value[0] >= 0 && value[0] <= 100)
          return value[0];
      } catch (e) {
        print("Error reading battery level: $e");
      }
    } else {
      print("Cannot read battery level: Not connected, characteristic not found, or does not support reading.");
    }
    return null;
  }

  Future<void> _subscribeToCharacteristic(
      BluetoothCharacteristic characteristic,
      Function(List<int>) dataParser,
      String logName) async {
    final String charUuid = characteristic.uuid.str.toUpperCase();

    if (!characteristic.properties.notify &&
        !characteristic.properties.indicate) {
      print(
          "Characteristic $charUuid ($logName) does not support notifications or indications.");
      return;
    }

    if (_characteristicValueSubscriptions.containsKey(charUuid)) {
      print("Cancelling existing subscription for $charUuid ($logName)...");
      await _characteristicValueSubscriptions[charUuid]?.cancel();
      _characteristicValueSubscriptions.remove(charUuid);
    }

    print(
        "Subscribing to notifications for $charUuid ($logName) using onValueReceived...");
    try {
      bool isNotifying = characteristic.isNotifying;
      if (!isNotifying) {
        await characteristic.setNotifyValue(true);
        print("Set notify value to true for $charUuid ($logName).");
      } else {
        print(
            "Characteristic $charUuid ($logName) is already notifying (isNotifying was true).");
      }

      _characteristicValueSubscriptions[charUuid] =
          characteristic.onValueReceived.listen(
              dataParser,
          onError: (e) {
            print("Error receiving data from $charUuid ($logName): $e");
            if (charUuid == CALIBRATION_STATUS_UUID.toUpperCase()) {
              _currentInternalCalibrationState =
                  CalibrationState.failed; // Update cache
              _calibrationStatusController.add(
                  _currentInternalCalibrationState); // Notify
            }
          },
          onDone: () {
            print("Stream for $charUuid ($logName) is done.");
            _characteristicValueSubscriptions.remove(charUuid);
            // If it's calibration status and it's done, maybe revert to idle if not success/fail?
            // Or assume disconnect is imminent. For now, just remove.
          },
              cancelOnError: true // Automatically cancel subscription on error
      );
      print("Successfully subscribed to $charUuid ($logName).");
    } catch (e, s) {
      print("Error setting up subscription for $charUuid ($logName): $e\n$s");
      if (charUuid == CALIBRATION_STATUS_UUID.toUpperCase()) {
        _currentInternalCalibrationState =
            CalibrationState.failed; // Update cache
        _calibrationStatusController.add(
            _currentInternalCalibrationState); // Notify
      }
    }
  }

  BleConnectionState getCurrentConnectionState() {
    return _currentConnectionState;
  }

  BluetoothDevice? getConnectedDevice() {
    return _connectedDevice;
  }

  void startBleScan() {
    startScan();
  }

  void connectToScannedDevice(BluetoothDevice device) {
    connectToDevice(device);
  }

  Future<void> disconnectCurrentDevice() async {
    await disconnectFromDevice();
  }

  void resetFallDetectedState() {
    print("Service: Resetting fall detected state.");
    _fallDetectedController.add(false); // Emit false to update UI
    // TODO: Implement sending a reset command to the ESP32 if needed/possible
  }

  Future<void> sendCalibrationCommand() async {
    if (_currentConnectionState != BleConnectionState.connected ||
        _calibrationCharacteristic == null) {
      print(
          "Cannot send calibration command: Not connected or calibration characteristic not found.");
      // UI should prevent this, but if called, don't change cal state unless it's an error condition for an *attempt*
      return;
    }
    if (!(_calibrationCharacteristic!.properties.write ||
        _calibrationCharacteristic!.properties.writeWithoutResponse)) {
      print("Cannot send calibration command: Characteristic is not writable.");
      return;
    }

    // Set internal state to inProgress and notify listeners
    // Only transition to inProgress if we are starting fresh (idle) or after a conclusive end (success/failed)
    if (_currentInternalCalibrationState == CalibrationState.idle ||
        _currentInternalCalibrationState == CalibrationState.success ||
        _currentInternalCalibrationState == CalibrationState.failed) {
      _currentInternalCalibrationState = CalibrationState.inProgress;
      _calibrationStatusController.add(_currentInternalCalibrationState);
    } else
    if (_currentInternalCalibrationState == CalibrationState.inProgress) {
      print("Calibration is already in progress. New command ignored.");
      return; // Don't send if already processing
    }

    print("Sending calibration command (value: [1]) to ESP32...");
    try {
      await _calibrationCharacteristic!.write([1],
          withoutResponse: _calibrationCharacteristic!.properties
              .writeWithoutResponse);
      print("Calibration command successfully sent to ESP32's queue.");
      // Now we wait for the ESP32 to send notifications on the CALIBRATION_STATUS_UUID
      // The ESP32 itself should send an "inProgress" (2) notification first.
    } catch (e) {
      print("Error writing calibration command to ESP32: $e");
      _currentInternalCalibrationState =
          CalibrationState.failed; // Update cache
      _calibrationStatusController.add(
          _currentInternalCalibrationState); // Notify
    }
  }

  // Platform Channel for audio services (speakerphone)
  static const MethodChannel _audioChannel = MethodChannel(
      'com.sept.learning_factory.smart_cane_prototype/audio');

  Future<void> _setSpeakerphoneOn(bool on) async {
    try {
      print("Attempting to set speakerphone: $on");
      await _audioChannel.invokeMethod('setSpeakerphoneOn', {'on': on});
      print("Speakerphone method invoked successfully.");
    } on PlatformException catch (e) {
      print("Failed to set speakerphone status: '${e.message}'.");
    }
  }

  Future<void> makePhoneCall(String phoneNumber) async {
    // Request Phone Permission
    var phonePermissionStatus = await Permission.phone.status;
    if (phonePermissionStatus.isDenied) {
      if (await Permission.phone
          .request()
          .isGranted) {
        print("Phone permission granted.");
      } else {
        print("Phone permission denied by user.");
        // Handle permission denial (e.g., show a message to the user)
        return;
      }
    } else if (phonePermissionStatus.isPermanentlyDenied) {
      print("Phone permission permanently denied. Opening app settings.");
      await openAppSettings();
      return;
    }

    if (!await Permission.phone.isGranted) {
      print("Phone permission is still not granted after request.");
      return;
    }

    // New way (direct calling)
    print("Attempting to directly call: $phoneNumber");
    bool? res = await FlutterPhoneDirectCaller.callNumber(phoneNumber);
    if (res == true) {
      print("Direct call initiated to $phoneNumber.");
      // Add a short delay to allow the call to establish before turning on speakerphone
      await Future.delayed(
          const Duration(seconds: 3)); // Adjust delay as needed
      await _setSpeakerphoneOn(true);
    } else {
      print("Failed to initiate direct call to $phoneNumber.");
      // Optionally, fall back to url_launcher or show an error
    }
  }

  void dispose() {
    print("BleService Disposing...");
    _connectionStateSubscription?.cancel();
    _isScanningSubscription?.cancel();

    if (_connectedDevice != null &&
        (_currentConnectionState == BleConnectionState.connected ||
            _currentConnectionState == BleConnectionState.connecting ||
            _currentConnectionState == BleConnectionState
                .disconnecting)) { // Also if in process of disconnecting
      print(
          "Dispose: Attempting to ensure disconnection from ${_connectedDevice!
              .platformName}");
      disconnectFromDevice(); // This handles cancelling subscriptions if it leads to a disconnected state.
    } else {
      // If not connected or trying to connect/disconnect, ensure subs are cleared manually
      _cancelCharacteristicValueSubscriptions();
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