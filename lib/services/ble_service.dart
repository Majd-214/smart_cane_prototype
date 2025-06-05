// lib/services/ble_service.dart
import 'dart:async';

import 'package:flutter/services.dart'; // For PlatformChannel
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
// import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart'; // No longer needed for calling
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_cane_prototype/services/background_service_handler.dart';

// ... (Keep your existing UUIDs and enums)
const String SMART_CANE_SERVICE_UUID = "A5A20D8A-E137-4B30-9F30-1A7A91579C9C";
const String BATTERY_CHARACTERISTIC_UUID = "2A19";
const String FALL_CHARACTERISTIC_UUID = "C712A5B2-2C13-4088-8D53-F7E3291B0155";
const String CALIBRATION_CHARACTERISTIC_UUID =
    "E9A10B6B-8A65-4F56-82C3-6768F0EE38A1";
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
// ...

class BleService {
  static final BleService _instance = BleService._internal();
  factory BleService() {
    return _instance;
  }
  BleService._internal();

  // ... (Keep your existing controllers and stream getters)
  final _connectionStateController =
  StreamController<BleConnectionState>.broadcast();

  Stream<BleConnectionState> get connectionStateStream =>
      _connectionStateController.stream;

  final _scanResultsController = StreamController<List<ScanResult>>.broadcast();

  Stream<List<ScanResult>> get scanResultsStream =>
      _scanResultsController.stream;

  final _batteryLevelController = StreamController<int?>.broadcast();
  Stream<int?> get batteryLevelStream => _batteryLevelController.stream;

  final _fallDetectedController = StreamController<bool>.broadcast();
  Stream<bool> get fallDetectedStream => _fallDetectedController.stream;

  final _connectedDeviceController =
  StreamController<BluetoothDevice?>.broadcast();

  Stream<BluetoothDevice?> get connectedDeviceStream =>
      _connectedDeviceController.stream;

  final _calibrationStatusController =
  StreamController<CalibrationState>.broadcast();
  Stream<CalibrationState> get calibrationStatusStream =>
      _calibrationStatusController.stream;


  // MethodChannel for the new native call method
  static const MethodChannel _callChannel =
  MethodChannel(
      'com.sept.learning_factory.smart_cane_prototype/call'); // New channel

  // Existing audio channel if still needed for other purposes, or you can remove if not
  static const MethodChannel _audioChannel =
  MethodChannel('com.sept.learning_factory.smart_cane_prototype/audio');


  // ... (Rest of your BleService properties and methods like initialize, connect, disconnect, etc.)
  // Ensure they are up-to-date with your latest working versions for BLE logic.
  // The following are stubs for brevity but should be your actual implementations.

  CalibrationState _currentInternalCalibrationState = CalibrationState.idle;
  BleConnectionState _currentConnectionState = BleConnectionState.disconnected;
  BluetoothDevice? _connectedDevice;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  Map<String, StreamSubscription<List<int>>> _characteristicValueSubscriptions =
  {};
  StreamSubscription<bool>? _isScanningSubscription;
  StreamSubscription? _adapterStateSubscription;

  BluetoothCharacteristic? _batteryCharacteristic;
  BluetoothCharacteristic? _fallCharacteristic;
  BluetoothCharacteristic? _calibrationCharacteristic;
  BluetoothCharacteristic? _calibrationStatusCharacteristic;

  bool _isInitializing = false;
  bool _isBgServiceListenerSetup = false;
  String? _targetDeviceId;


  Future<bool> _checkPermissions() async {
    var locStatus = await Permission.location.status;
    var scanStatus = await Permission.bluetoothScan.status;
    var connectStatus = await Permission.bluetoothConnect.status;
    // Phone permission will be checked before calling makePhoneCall
    return locStatus.isGranted &&
        scanStatus.isGranted &&
        connectStatus.isGranted;
  }

  Future<void> initialize() async {
    if (_isInitializing || _adapterStateSubscription != null) return;
    _isInitializing = true;
    _currentInternalCalibrationState = CalibrationState.idle;
    _calibrationStatusController.add(_currentInternalCalibrationState);
    _setupBackgroundServiceListener();
    _adapterStateSubscription = FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.on) {
        if (_currentConnectionState == BleConnectionState.bluetoothOff ||
            _currentConnectionState == BleConnectionState.unknown) {
          _updateConnectionState(BleConnectionState.disconnected);
          _tryAutoConnectIfLatched();
        }
      } else if (state == BluetoothAdapterState.off) {
        _updateConnectionState(BleConnectionState.bluetoothOff);
        disconnectCurrentDevice(initiatedByUser: false);
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
      if (scanning) {
        if (_currentConnectionState == BleConnectionState.disconnected ||
            _currentConnectionState == BleConnectionState.scanStopped) {
          _updateConnectionState(BleConnectionState.scanning);
        }
      } else {
        if (_currentConnectionState == BleConnectionState.scanning) {
          _updateConnectionState(BleConnectionState.scanStopped);
        }
      }
    });
    final initialState = await FlutterBluePlus.adapterState.first;
    if (initialState == BluetoothAdapterState.on) {
      await _tryAutoConnectIfLatched();
    } else if (initialState == BluetoothAdapterState.off) {
      _updateConnectionState(BleConnectionState.bluetoothOff);
    } else if (initialState == BluetoothAdapterState.unauthorized) {
      _updateConnectionState(BleConnectionState.noPermissions);
    }
    _isInitializing = false;
  }

  void _setupBackgroundServiceListener() {
    if (_isBgServiceListenerSetup) return;
    _isBgServiceListenerSetup = true;
    FlutterBackgroundService()
        .on(backgroundServiceConnectionUpdateEvent)
        .listen((event) {
      if (event == null) return;
      bool bgConnected = event['connected'] ?? false;
      String? bgDeviceId = event['deviceId'];
      if (bgConnected &&
          _currentConnectionState != BleConnectionState.connected &&
          bgDeviceId != null) {
        if (_connectedDevice == null) {
          _updateConnectionState(BleConnectionState.connected);
          _findAndSetDeviceById(bgDeviceId);
        }
      } else if (!bgConnected &&
          _currentConnectionState == BleConnectionState.connected) {
        _updateConnectionState(BleConnectionState.disconnected);
        _connectedDevice = null;
        _connectedDeviceController.add(null);
      }
    });
  }

  Future<void> _findAndSetDeviceById(String deviceId) async {
    try {
      List<BluetoothDevice> system = await FlutterBluePlus.systemDevices(
          []); // Simpler way to get system devices
      for (var d in system) {
        if (d.remoteId.str == deviceId) {
          _connectedDevice = d;
          _connectedDeviceController.add(d);
          _updateConnectionState(BleConnectionState.connected);
          await _discoverServices(d); // discover services after finding
          return;
        }
      }
    } catch (e) {
      // log error
    }
  }

  void _updateConnectionState(BleConnectionState state) {
    if (_currentConnectionState != state) {
      _currentConnectionState = state;
      _connectionStateController.add(state);
      if (state == BleConnectionState.disconnected ||
          state == BleConnectionState.bluetoothOff ||
          state == BleConnectionState.noPermissions) {
        _currentInternalCalibrationState = CalibrationState.idle;
        _calibrationStatusController.add(_currentInternalCalibrationState);
        _batteryLevelController.add(null);
      }
    }
  }

  Future<void> startBleScan(
      {Duration timeout = const Duration(seconds: 10)}) async {
    if (FlutterBluePlus.isScanningNow ||
        _currentConnectionState == BleConnectionState.connecting ||
        _currentConnectionState == BleConnectionState.connected ||
        _currentConnectionState == BleConnectionState.disconnecting) return;
    _currentInternalCalibrationState = CalibrationState.idle;
    _calibrationStatusController.add(_currentInternalCalibrationState);
    _scanResultsController.add([]);
    if (!await _checkPermissions()) {
      _updateConnectionState(BleConnectionState.noPermissions);
      return;
    }
    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      if (adapterState == BluetoothAdapterState.off) {
        _updateConnectionState(BleConnectionState.bluetoothOff);
      }
      return;
    }
    _updateConnectionState(BleConnectionState.scanning);
    try {
      await FlutterBluePlus.startScan(timeout: timeout);
    } catch (e) {
      _updateConnectionState(BleConnectionState.scanStopped);
    }
  }

  Future<void> stopScan() async {
    if (FlutterBluePlus.isScanningNow) {
      try {
        await FlutterBluePlus.stopScan();
      } catch (e) {
        /* log error */
      }
      finally {
        if (_currentConnectionState == BleConnectionState.scanning) {
          _updateConnectionState(BleConnectionState.scanStopped);
        }
      }
    } else {
      if (_currentConnectionState == BleConnectionState.scanning) {
        _updateConnectionState(BleConnectionState.scanStopped);
      }
    }
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    if (_currentConnectionState == BleConnectionState.connecting ||
        _currentConnectionState == BleConnectionState.connected ||
        _currentConnectionState == BleConnectionState.disconnecting) return;
    _currentInternalCalibrationState = CalibrationState.idle;
    _calibrationStatusController.add(_currentInternalCalibrationState);
    _updateConnectionState(BleConnectionState.connecting);
    try {
      if (FlutterBluePlus.isScanningNow) await stopScan();
      _connectionStateSubscription?.cancel();
      _connectionStateSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          if (_connectedDevice?.remoteId == device.remoteId ||
              _currentConnectionState == BleConnectionState.connecting) {
            _handleDisconnectionLogic(device.remoteId.str);
          }
        } else if (state == BluetoothConnectionState.connected) {
          _updateConnectionState(BleConnectionState.connected);
          _connectedDevice = device;
          _connectedDeviceController.add(device);
          _discoverServices(device);
          _latchDeviceAndStartService(device);
        }
      });
      await device.connect(
          timeout: const Duration(seconds: 20), autoConnect: false);
    } catch (e) {
      _updateConnectionState(BleConnectionState.disconnected);
      _connectedDevice = null;
      _connectedDeviceController.add(null);
      _clearCharacteristicReferences();
      _connectionStateSubscription?.cancel();
      _cancelCharacteristicValueSubscriptions();
    }
  }

  Future<void> _latchDeviceAndStartService(BluetoothDevice device) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(bgServiceDeviceIdKey, device.remoteId.str);
    _targetDeviceId = device.remoteId.str;
    final service = FlutterBackgroundService();
    bool isRunning = await service.isRunning();
    if (!isRunning) {
      try {
        await service.startService();
        await Future.delayed(const Duration(milliseconds: 200));
      } catch (e) {
        return;
      }
    }
    service.invoke(bgServiceSetDeviceEvent, {'deviceId': device.remoteId.str});
  }

  Future<void> _unlatchDeviceAndStopService() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(bgServiceDeviceIdKey);
    _targetDeviceId = null;
    final service = FlutterBackgroundService();
    if (await service.isRunning()) {
      service.invoke(bgServiceStopEvent);
    }
  }

  Future<void> disconnectCurrentDevice({bool initiatedByUser = true}) async {
    if (_connectedDevice == null &&
        _currentConnectionState == BleConnectionState.disconnected) {
      if (initiatedByUser) await _unlatchDeviceAndStopService();
      return;
    }
    BluetoothDevice? deviceToDisconnect = _connectedDevice;
    String? deviceId = deviceToDisconnect?.remoteId.str;
    _updateConnectionState(BleConnectionState.disconnecting);
    if (initiatedByUser) {
      await _unlatchDeviceAndStopService();
    }
    try {
      if (deviceToDisconnect != null) {
        await deviceToDisconnect.disconnect();
      } else {
        _handleDisconnectionLogic(null);
      }
    } catch (e) {
      _handleDisconnectionLogic(deviceId);
    }
  }

  void _handleDisconnectionLogic(String? disconnectedId) {
    if (_connectedDevice != null && (disconnectedId == null ||
        _connectedDevice!.remoteId.str == disconnectedId)) {
      _connectedDevice = null;
      _connectedDeviceController.add(null);
      _updateConnectionState(BleConnectionState.disconnected);
      _clearCharacteristicReferences();
      _cancelCharacteristicValueSubscriptions();
      _connectionStateSubscription?.cancel();
      _connectionStateSubscription = null;
    } else if (_currentConnectionState != BleConnectionState.disconnected) {
      _updateConnectionState(BleConnectionState.disconnected);
      _connectedDevice = null;
      _connectedDeviceController.add(null);
    }
  }

  void _clearCharacteristicReferences() {
    _batteryCharacteristic = null;
    _fallCharacteristic = null;
    _calibrationCharacteristic = null;
    _calibrationStatusCharacteristic = null;
  }

  void _cancelCharacteristicValueSubscriptions() {
    _characteristicValueSubscriptions.forEach((uuid, sub) => sub.cancel());
    _characteristicValueSubscriptions.clear();
  }

  Future<void> _discoverServices(BluetoothDevice device) async {
    _clearCharacteristicReferences();
    _cancelCharacteristicValueSubscriptions();
    try {
      List<BluetoothService> services = await device.discoverServices(
          timeout: 20);
      bool smartCaneServiceFound = false;
      for (BluetoothService service in services) {
        if (service.uuid.str.toUpperCase() == SMART_CANE_SERVICE_UUID.toUpperCase()) {
          smartCaneServiceFound = true;
          for (BluetoothCharacteristic characteristic in service.characteristics) {
            String charUuid = characteristic.uuid.str.toUpperCase();
            if (charUuid == BATTERY_CHARACTERISTIC_UUID.toUpperCase()) {
              _batteryCharacteristic = characteristic;
              if (characteristic.properties
                  .notify) await _subscribeToCharacteristic(
                  characteristic, _parseBatteryLevel, "Battery");
              if (characteristic.properties
                  .read) await readBatteryLevel(); // made awaitable
            } else if (charUuid == FALL_CHARACTERISTIC_UUID.toUpperCase()) {
              _fallCharacteristic = characteristic;
              if (characteristic.properties
                  .notify) await _subscribeToCharacteristic(
                  characteristic, _parseFallDetection, "Fall");
            } else
            if (charUuid == CALIBRATION_CHARACTERISTIC_UUID.toUpperCase()) {
              _calibrationCharacteristic = characteristic;
            } else if (charUuid == CALIBRATION_STATUS_UUID.toUpperCase()) {
              _calibrationStatusCharacteristic = characteristic;
              if (characteristic.properties
                  .notify) await _subscribeToCharacteristic(
                  characteristic, _parseCalibrationStatus, "CalibrationStatus");
            }
          }
        }
      }
      if (!smartCaneServiceFound) disconnectCurrentDevice();
    } catch (e) {
      /* log error */
    }
  }

  void _parseBatteryLevel(List<int> value) {
    if (value.isNotEmpty) _batteryLevelController.add(value[0]);
  }

  void _parseFallDetection(List<int> value) {
    if (value.isNotEmpty) _fallDetectedController.add(value[0] == 1);
  }

  void _parseCalibrationStatus(List<int> value) {
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
          _currentInternalCalibrationState = CalibrationState.failed;
          break;
      }
      _calibrationStatusController.add(_currentInternalCalibrationState);
    }
  }

  Future<int?> readBatteryLevel() async {
    if (_batteryCharacteristic?.properties.read ?? false) {
      try {
        List<int> value = await _batteryCharacteristic!.read();
        _parseBatteryLevel(value);
        return value.isNotEmpty ? value[0] : null;
      } catch (e) {
        /* log error */
      }
    }
    return null;
  }

  Future<void> _subscribeToCharacteristic(
      BluetoothCharacteristic characteristic, Function(List<int>) dataParser,
      String logName) async {
    final String charUuid = characteristic.uuid.str.toUpperCase();
    if (!characteristic.properties.notify &&
        !characteristic.properties.indicate) return;
    if (_characteristicValueSubscriptions.containsKey(charUuid)) return;
    try {
      await characteristic.setNotifyValue(true);
      _characteristicValueSubscriptions[charUuid] =
          characteristic.onValueReceived.listen(
              dataParser,
              onError: (e) =>
                  _characteristicValueSubscriptions.remove(charUuid),
              onDone: () => _characteristicValueSubscriptions.remove(charUuid),
              cancelOnError: true
          );
    } catch (e) {
      /* log error */
    }
  }

  BleConnectionState getCurrentConnectionState() => _currentConnectionState;
  BluetoothDevice? getConnectedDevice() => _connectedDevice;

  void connectToScannedDevice(BluetoothDevice device) =>
      connectToDevice(device);

  void resetFallDetectedState() {
    _fallDetectedController.add(false);
  }

  Future<void> sendCalibrationCommand() async {
    if (_currentConnectionState != BleConnectionState.connected ||
        _calibrationCharacteristic == null ||
        !(_calibrationCharacteristic!.properties.write ||
            _calibrationCharacteristic!.properties.writeWithoutResponse)) {
      return;
    }
    if (_currentInternalCalibrationState == CalibrationState.inProgress) return;
    _currentInternalCalibrationState = CalibrationState.inProgress;
    _calibrationStatusController.add(_currentInternalCalibrationState);
    try {
      await _calibrationCharacteristic!.write([1],
          withoutResponse: _calibrationCharacteristic!.properties
              .writeWithoutResponse);
    } catch (e) {
      _currentInternalCalibrationState = CalibrationState.failed;
      _calibrationStatusController.add(_currentInternalCalibrationState);
    }
  }
  Future<void> makePhoneCall(String phoneNumber) async {
    var phonePermissionStatus = await Permission.phone.status;
    if (!phonePermissionStatus.isGranted) {
      if (!await Permission.phone
          .request()
          .isGranted) {
        print("Phone permission denied.");
        // Optionally, guide user to settings:
        // await openAppSettings();
        return;
      }
    }

    print("Attempting to make phone call to $phoneNumber via native method.");
    try {
      // Call the new native method
      final bool? speakerphoneActivated = await _callChannel.invokeMethod(
          'initiateEmergencyCallAndSpeaker', {'phoneNumber': phoneNumber});

      if (speakerphoneActivated == true) {
        print(
            "Native method reported call initiated and speakerphone activated successfully.");
      } else {
        print(
            "Native method reported call initiated but speakerphone activation might have failed or was not confirmed.");
      }
    } on PlatformException catch (e) {
      print("Failed to initiate call/speakerphone via MethodChannel: '${e
          .message}'. Details: ${e.details}");
    } catch (e) {
      print("An unexpected error occurred in makePhoneCall: $e");
    }
  }

  // Remove _setSpeakerphoneOn(bool on) as it's now part of the native call.
  // If you still need a separate speakerphone toggle for other reasons,
  // you can keep the _audioChannel and call setSpeakerphoneNative from MainActivity.

  Future<String?> getLatchedDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(bgServiceDeviceIdKey);
  }

  Future<void> clearLatchedDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(bgServiceDeviceIdKey);
    _targetDeviceId = null;
  }

  Future<void> _tryAutoConnectIfLatched() async {
    _targetDeviceId = await getLatchedDeviceId();
    if (_targetDeviceId != null &&
        _currentConnectionState == BleConnectionState.disconnected) {
      final service = FlutterBackgroundService();
      bool isRunning = await service.isRunning();
      if (!isRunning) {
        await service.startService();
        await Future.delayed(const Duration(milliseconds: 200));
      }
      service.invoke(bgServiceSetDeviceEvent, {'deviceId': _targetDeviceId});
      _updateConnectionState(BleConnectionState.connecting);
    }
  }

  Future<void> connectToLatchedDevice() async {
    _targetDeviceId = await getLatchedDeviceId();
    if (_targetDeviceId != null) {
      _tryAutoConnectIfLatched();
    }
  }

  void dispose() {
    _connectionStateSubscription?.cancel();
    _isScanningSubscription?.cancel();
    _adapterStateSubscription?.cancel();
    disconnectCurrentDevice(
        initiatedByUser: false); // Ensure this doesn't try to stop service if not user initiated
    _cancelCharacteristicValueSubscriptions();
    _connectionStateController.close();
    _scanResultsController.close();
    _batteryLevelController.close();
    _fallDetectedController.close();
    _connectedDeviceController.close();
    _calibrationStatusController.close();
  }
}