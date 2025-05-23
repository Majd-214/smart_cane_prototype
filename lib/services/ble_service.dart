// lib/services/ble_service.dart
import 'dart:async';

import 'package:flutter/services.dart'; // For PlatformChannel
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
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

  CalibrationState _currentInternalCalibrationState = CalibrationState.idle;

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

  // ** MODIFIED: Check permissions, don't request **
  Future<bool> _checkPermissions() async {
    print("BleService: Checking permissions...");
    var locStatus = await Permission.location.status;
    var scanStatus = await Permission.bluetoothScan.status;
    var connectStatus = await Permission.bluetoothConnect.status;

    print("  Location: $locStatus, Scan: $scanStatus, Connect: $connectStatus");

    return locStatus.isGranted && scanStatus.isGranted &&
        connectStatus.isGranted;
  }

  Future<void> initialize() async {
    print("BleService Initializing...");
    _currentInternalCalibrationState = CalibrationState.idle;
    _calibrationStatusController.add(_currentInternalCalibrationState);
    // ** We don't request/check here anymore, just set up listeners **

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
        _currentInternalCalibrationState = CalibrationState.idle;
        _calibrationStatusController.add(_currentInternalCalibrationState);
      }
    }
  }

  Future<void> startScan({Duration timeout = const Duration(seconds: 10)}) async {
    if (FlutterBluePlus.isScanningNow || _currentConnectionState == BleConnectionState.connecting || _currentConnectionState == BleConnectionState.connected || _currentConnectionState == BleConnectionState.disconnecting) {
      print("Already scanning, connecting, connected, or disconnecting. Ignoring start scan request.");
      return;
    }
    _currentInternalCalibrationState = CalibrationState.idle;
    _calibrationStatusController.add(_currentInternalCalibrationState);

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

      // ** MODIFIED PERMISSION CHECK **
      bool hasPermissions = await _checkPermissions();
      if (!hasPermissions) {
        print(
            "Cannot start scan: Essential permissions are missing. Please grant them via UI/Settings.");
        _updateConnectionState(BleConnectionState.noPermissions);
        _updateConnectionState(BleConnectionState
            .scanStopped); // Set to stopped as scan won't start
        return;
      }
      // *******************************

      await FlutterBluePlus.startScan(timeout: timeout);
      print("BLE scan started.");
    } catch (e) {
      print("Error starting scan: $e");
      _updateConnectionState(BleConnectionState.scanStopped);
    }
  }

  // ... (Keep stopScan, connectToDevice, disconnectFromDevice, _clearCharacteristicReferences,
  //      _cancelCharacteristicValueSubscriptions, _discoverServices, _parseBatteryLevel,
  //      _parseFallDetection, _parseCalibrationStatus, readBatteryLevel, _subscribeToCharacteristic,
  //      getCurrentConnectionState, getConnectedDevice, startBleScan, connectToScannedDevice,
  //      disconnectCurrentDevice, resetFallDetectedState, sendCalibrationCommand,
  //      _audioChannel, _setSpeakerphoneOn, makePhoneCall, dispose) ...

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
    _currentInternalCalibrationState = CalibrationState.idle;
    _calibrationStatusController.add(_currentInternalCalibrationState);

    print("Attempting to connect to ${device.platformName}...");
    _updateConnectionState(BleConnectionState.connecting);
    try {
      if (FlutterBluePlus.isScanningNow) {
        await stopScan();
      }
      _connectionStateSubscription?.cancel();
      _connectionStateSubscription = device.connectionState.listen((state) {
        print("Device ${device.platformName} connection state: $state");
        if (state == BluetoothConnectionState.disconnected) {
          _connectedDevice = null;
          _connectedDeviceController.add(null);
          _updateConnectionState(BleConnectionState.disconnected);
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
      await device.connect(
          timeout: const Duration(seconds: 15), autoConnect: false);
    } catch (e) {
      print("Error connecting to device: $e");
      _updateConnectionState(BleConnectionState.disconnected);
      _connectedDevice = null;
      _connectedDeviceController.add(null);
      _clearCharacteristicReferences();
      _connectionStateSubscription?.cancel();
      _cancelCharacteristicValueSubscriptions();
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
    } catch (e) {
      print("Error disconnecting from device: $e");
      _updateConnectionState(BleConnectionState.connected);
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
              if (characteristic.properties.read) readBatteryLevel();
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
            "Warning: Could not find ALL required characteristics on the Smart Cane Service.");
      } else {
        print(
            "All required Smart Cane characteristics found and subscriptions attempted.");
      }
    } catch (e) {
      print("Error discovering services: $e");
      disconnectFromDevice();
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
      print("  Received empty value from Battery Characteristic.");
    }
  }

  void _parseFallDetection(List<int> value) {
    if (value.isNotEmpty) {
      bool fallDetected = value[0] == 1;
      _fallDetectedController.add(fallDetected);
    } else {
      print("  Received empty value from Fall Characteristic.");
    }
  }

  void _parseCalibrationStatus(List<int> value) {
    CalibrationState previousState = _currentInternalCalibrationState;

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
          print("  Received unknown calibration status byte: $statusByte.");
          _currentInternalCalibrationState = CalibrationState.failed;
          break;
      }
      print(
          "  Parsed Calibration Status: $_currentInternalCalibrationState (from byte $statusByte)");
    } else {
      print("  Received empty value from Calibration Status Characteristic.");
      if (previousState != CalibrationState.idle) {
        _currentInternalCalibrationState = CalibrationState.failed;
        print("  Transitioning to FAILED due to empty value when not idle.");
      }
    }
    _calibrationStatusController.add(_currentInternalCalibrationState);
  }

  Future<int?> readBatteryLevel() async {
    if (_batteryCharacteristic != null && _connectedDevice != null &&
        _batteryCharacteristic!.properties.read) {
      print("Reading battery level...");
      try {
        List<int> value = await _batteryCharacteristic!.read();
        _parseBatteryLevel(value);
        if (value.isNotEmpty && value[0] >= 0 && value[0] <= 100)
          return value[0];
      } catch (e) {
        print("Error reading battery level: $e");
      }
    } else {
      print("Cannot read battery level: Not connected/found/readable.");
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
          "Characteristic $charUuid ($logName) does not support notifications.");
      return;
    }

    if (_characteristicValueSubscriptions.containsKey(charUuid)) {
      print("Cancelling existing subscription for $charUuid ($logName)...");
      await _characteristicValueSubscriptions[charUuid]?.cancel();
      _characteristicValueSubscriptions.remove(charUuid);
    }

    print("Subscribing to notifications for $charUuid ($logName)...");
    try {
      bool isNotifying = characteristic.isNotifying;
      if (!isNotifying) {
        await characteristic.setNotifyValue(true);
        print("Set notify value to true for $charUuid ($logName).");
      } else {
        print("Characteristic $charUuid ($logName) is already notifying.");
      }

      _characteristicValueSubscriptions[charUuid] =
          characteristic.onValueReceived.listen(
              dataParser,
              onError: (e) {
                print("Error receiving data from $charUuid ($logName): $e");
                if (charUuid == CALIBRATION_STATUS_UUID.toUpperCase()) {
                  _currentInternalCalibrationState = CalibrationState.failed;
                  _calibrationStatusController.add(
                      _currentInternalCalibrationState);
                }
              },
              onDone: () {
                print("Stream for $charUuid ($logName) is done.");
                _characteristicValueSubscriptions.remove(charUuid);
              },
              cancelOnError: true
          );
      print("Successfully subscribed to $charUuid ($logName).");
    } catch (e, s) {
      print("Error setting up subscription for $charUuid ($logName): $e\n$s");
      if (charUuid == CALIBRATION_STATUS_UUID.toUpperCase()) {
        _currentInternalCalibrationState = CalibrationState.failed;
        _calibrationStatusController.add(_currentInternalCalibrationState);
      }
    }
  }

  BleConnectionState getCurrentConnectionState() => _currentConnectionState;

  BluetoothDevice? getConnectedDevice() => _connectedDevice;

  void startBleScan() => startScan();

  void connectToScannedDevice(BluetoothDevice device) =>
      connectToDevice(device);

  Future<void> disconnectCurrentDevice() async => await disconnectFromDevice();
  void resetFallDetectedState() {
    print("Service: Resetting fall detected state.");
    _fallDetectedController.add(false);
  }

  Future<void> sendCalibrationCommand() async {
    if (_currentConnectionState != BleConnectionState.connected ||
        _calibrationCharacteristic == null ||
        !(_calibrationCharacteristic!.properties.write ||
            _calibrationCharacteristic!.properties.writeWithoutResponse)) {
      print(
          "Cannot send calibration command: Not connected, not found, or not writable.");
      return;
    }

    if (_currentInternalCalibrationState == CalibrationState.inProgress) {
      print("Calibration is already in progress. New command ignored.");
      return;
    }
    _currentInternalCalibrationState = CalibrationState.inProgress;
    _calibrationStatusController.add(_currentInternalCalibrationState);

    print("Sending calibration command (value: [1]) to ESP32...");
    try {
      await _calibrationCharacteristic!.write([1],
          withoutResponse: _calibrationCharacteristic!.properties
              .writeWithoutResponse);
      print("Calibration command successfully sent.");
    } catch (e) {
      print("Error writing calibration command: $e");
      _currentInternalCalibrationState = CalibrationState.failed;
      _calibrationStatusController.add(_currentInternalCalibrationState);
    }
  }

  static const MethodChannel _audioChannel = MethodChannel(
      'com.sept.learning_factory.smart_cane_prototype/audio');

  Future<void> _setSpeakerphoneOn(bool on) async {
    try {
      print("Attempting to set speakerphone: $on");
      await _audioChannel.invokeMethod('setSpeakerphoneOn', {'on': on});
      print("Speakerphone method invoked.");
    } on PlatformException catch (e) {
      print("Failed to set speakerphone: '${e.message}'.");
    }
  }

  Future<void> makePhoneCall(String phoneNumber) async {
    var phonePermissionStatus = await Permission.phone.status;
    if (!phonePermissionStatus.isGranted) {
      if (!await Permission.phone
          .request()
          .isGranted) {
        print("Phone permission denied.");
        await openAppSettings(); // Guide user if denied
        return;
      }
    }

    print("Attempting to directly call: $phoneNumber");
    bool? res = await FlutterPhoneDirectCaller.callNumber(phoneNumber);
    if (res == true) {
      print("Direct call initiated.");
      await Future.delayed(const Duration(seconds: 3));
      await _setSpeakerphoneOn(true);
    } else {
      print("Failed to initiate direct call.");
    }
  }

  void dispose() {
    print("BleService Disposing...");
    _connectionStateSubscription?.cancel();
    _isScanningSubscription?.cancel();
    disconnectFromDevice(); // Attempt clean disconnect
    _cancelCharacteristicValueSubscriptions();
    _connectionStateController.close();
    _scanResultsController.close();
    _batteryLevelController.close();
    _fallDetectedController.close();
    _connectedDeviceController.close();
    _calibrationStatusController.close();
    print("BleService Disposed.");
  }
}