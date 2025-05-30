// lib/services/ble_service.dart
import 'dart:async';

import 'package:flutter/services.dart'; // For PlatformChannel
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_cane_prototype/services/background_service_handler.dart';

// Define the Service and Characteristic UUIDs
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

class BleService {
  static final BleService _instance = BleService._internal();
  factory BleService() {
    return _instance;
  }
  BleService._internal();

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

  CalibrationState _currentInternalCalibrationState = CalibrationState.idle;
  BleConnectionState _currentConnectionState = BleConnectionState.disconnected;
  BluetoothDevice? _connectedDevice;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  Map<String, StreamSubscription<List<int>>> _characteristicValueSubscriptions =
  {};
  StreamSubscription<bool>? _isScanningSubscription;
  StreamSubscription? _adapterStateSubscription; // Added for robustness

  BluetoothCharacteristic? _batteryCharacteristic;
  BluetoothCharacteristic? _fallCharacteristic;
  BluetoothCharacteristic? _calibrationCharacteristic;
  BluetoothCharacteristic? _calibrationStatusCharacteristic;

  bool _isInitializing = false;
  bool _isBgServiceListenerSetup = false;

  Future<bool> _checkPermissions() async {
    print("BleService: Checking permissions...");
    var locStatus = await Permission.location.status;
    var scanStatus = await Permission.bluetoothScan.status;
    var connectStatus = await Permission.bluetoothConnect.status;

    print("  Location: $locStatus, Scan: $scanStatus, Connect: $connectStatus");

    return locStatus.isGranted &&
        scanStatus.isGranted &&
        connectStatus.isGranted;
  }

  Future<void> initialize() async {
    if (_isInitializing || _adapterStateSubscription != null) {
      print("BleService: Already initialized or initializing.");
      return;
    }
    _isInitializing = true;
    print("BleService Initializing...");

    _currentInternalCalibrationState = CalibrationState.idle;
    _calibrationStatusController.add(_currentInternalCalibrationState);

    // Setup listener for background service updates if not already done
    _setupBackgroundServiceListener();

    _adapterStateSubscription = FlutterBluePlus.adapterState.listen((state) {
      print("BLE Adapter State: $state");
      if (state == BluetoothAdapterState.on) {
        if (_currentConnectionState == BleConnectionState.bluetoothOff ||
            _currentConnectionState == BleConnectionState.unknown) {
          _updateConnectionState(BleConnectionState.disconnected);
          // When BT turns on, check if we should be connected (latched device)
          _tryAutoConnectIfLatched();
        }
      } else if (state == BluetoothAdapterState.off) {
        _updateConnectionState(BleConnectionState.bluetoothOff);
        disconnectCurrentDevice(
            initiatedByUser: false); // Disconnect but don't clear latch
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

    // Check initial state
    final initialState = await FlutterBluePlus.adapterState.first;
    if (initialState == BluetoothAdapterState.on) {
      await _tryAutoConnectIfLatched();
    } else if (initialState == BluetoothAdapterState.off) {
      _updateConnectionState(BleConnectionState.bluetoothOff);
    } else if (initialState == BluetoothAdapterState.unauthorized) {
      _updateConnectionState(BleConnectionState.noPermissions);
    }


    _isInitializing = false;
    print("BleService Initialized.");
  }

  void _setupBackgroundServiceListener() {
    if (_isBgServiceListenerSetup) return;
    _isBgServiceListenerSetup = true;

    FlutterBackgroundService()
        .on(backgroundServiceConnectionUpdateEvent)
        .listen((event) {
      if (event == null) return;
      print("BleService: Received BG Service Update: $event");
      bool bgConnected = event['connected'] ?? false;
      String? bgDeviceId = event['deviceId'];
      String? bgDeviceName = event['deviceName'];

      // If BG says it's connected, and UI thinks it's not, update UI state
      if (bgConnected &&
          _currentConnectionState != BleConnectionState.connected &&
          bgDeviceId != null) {
        print("BleService: BG is connected, UI is not. Syncing UI.");
        // We need a device object. If we don't have it, we might need a way
        // to get it or show a "connected" state without full details.
        // For now, let's just update the state if we *don't* have a device yet.
        if (_connectedDevice == null) {
          _updateConnectionState(BleConnectionState.connected);
          // We can't fully set _connectedDevice without its object,
          // but we know *something* is connected. HomeScreen can show this.
          // We might need to ask BG for the device object or re-fetch.
          // OR, BleService can try to find the device by ID.
          _findAndSetDeviceById(bgDeviceId);
        }
      }
      // If BG says it's disconnected, and UI thinks it *is* connected, update UI.
      else if (!bgConnected &&
          _currentConnectionState == BleConnectionState.connected) {
        print("BleService: BG disconnected, UI connected. Syncing UI.");
        _updateConnectionState(BleConnectionState.disconnected);
        _connectedDevice = null;
        _connectedDeviceController.add(null);
      }
    });
  }

  Future<void> _findAndSetDeviceById(String deviceId) async {
    try {
      List<BluetoothDevice> system = await FlutterBluePlus.systemDevices([]);
      for (var d in system) {
        if (d.remoteId.str == deviceId) {
          _connectedDevice = d;
          _connectedDeviceController.add(d);
          _updateConnectionState(BleConnectionState.connected);
          print("BleService: Found system device $deviceId, updated UI.");
          // Since we found it, ensure we are subscribed (or re-subscribe)
          _discoverServices(d);
          return;
        }
      }
      print(
          "BleService: Could not find system device $deviceId to fully sync UI.");
    } catch (e) {
      print("BleService: Error finding system device $deviceId: $e");
    }
  }


  void _updateConnectionState(BleConnectionState state) {
    if (_currentConnectionState != state) {
      _currentConnectionState = state;
      _connectionStateController.add(state);
      print("BleService: Connection State Updated: $state");
      if (state == BleConnectionState.disconnected ||
          state == BleConnectionState.bluetoothOff ||
          state == BleConnectionState.noPermissions) {
        _currentInternalCalibrationState = CalibrationState.idle;
        _calibrationStatusController.add(_currentInternalCalibrationState);
        _batteryLevelController.add(null); // Clear battery on disconnect
      }
    }
  }

  Future<void> startBleScan(
      {Duration timeout = const Duration(seconds: 10)}) async {
    if (FlutterBluePlus.isScanningNow ||
        _currentConnectionState == BleConnectionState.connecting ||
        _currentConnectionState == BleConnectionState.connected ||
        _currentConnectionState == BleConnectionState.disconnecting) {
      print(
          "Already scanning, connecting, connected, or disconnecting. Ignoring start scan request.");
      return;
    }
    _currentInternalCalibrationState = CalibrationState.idle;
    _calibrationStatusController.add(_currentInternalCalibrationState);

    print("Starting BLE scan...");
    _scanResultsController.add([]);

    bool hasPermissions = await _checkPermissions();
    if (!hasPermissions) {
      print(
          "Cannot start scan: Essential permissions are missing.");
      _updateConnectionState(BleConnectionState.noPermissions);
      return;
    }

    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      print("Cannot start scan: Bluetooth adapter is ${adapterState.name}.");
      if (adapterState == BluetoothAdapterState.off) {
        _updateConnectionState(BleConnectionState.bluetoothOff);
      }
      return;
    }

    _updateConnectionState(BleConnectionState.scanning);
    try {
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
    if (_currentConnectionState == BleConnectionState.connecting ||
        _currentConnectionState == BleConnectionState.connected ||
        _currentConnectionState == BleConnectionState.disconnecting) {
      print(
          "Already in connection process or connected. Ignoring connect request.");
      return;
    }
    _currentInternalCalibrationState = CalibrationState.idle;
    _calibrationStatusController.add(_currentInternalCalibrationState);

    print("Attempting to connect to ${device.remoteId.str}...");
    _updateConnectionState(BleConnectionState.connecting);
    try {
      if (FlutterBluePlus.isScanningNow) {
        await stopScan();
      }
      _connectionStateSubscription?.cancel();
      _connectionStateSubscription = device.connectionState.listen((state) {
        print("Device ${device.remoteId.str} connection state: $state");
        if (state == BluetoothConnectionState.disconnected) {
          // Only update UI if we *thought* we were connected to *this* device
          if (_connectedDevice?.remoteId == device.remoteId) {
            _handleDisconnectionLogic(device.remoteId.str);
          } else {
            print("BleService: Received disconnect for ${device.remoteId
                .str}, but wasn't primary. State: $_currentConnectionState");
            // If we get a disconnect while trying to connect, set back to disconnected
            if (_currentConnectionState == BleConnectionState.connecting) {
              _updateConnectionState(BleConnectionState.disconnected);
            }
          }
        } else if (state == BluetoothConnectionState.connected) {
          _updateConnectionState(BleConnectionState.connected);
          print("Successfully connected to ${device.remoteId.str}");
          _connectedDevice = device;
          _connectedDeviceController.add(device);
          _discoverServices(device);
          // --- Latch and Start BG Service ---
          _latchDeviceAndStartService(device);
          // ----------------------------------
        }
      });
      await device.connect(
          timeout: const Duration(seconds: 20),
          autoConnect: false); // Increased timeout
    } catch (e, s) {
      print("Error connecting to device ${device.remoteId.str}: $e\n$s");
      _updateConnectionState(BleConnectionState.disconnected);
      _connectedDevice = null;
      _connectedDeviceController.add(null);
      _clearCharacteristicReferences();
      _connectionStateSubscription?.cancel();
      _cancelCharacteristicValueSubscriptions();
    }
  }

  // --- NEW: Latch and start BG service ---
  Future<void> _latchDeviceAndStartService(BluetoothDevice device) async {
    print("BleService: Latching device ${device.remoteId
        .str} and starting BG service.");
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(bgServiceDeviceIdKey, device.remoteId.str);
    _targetDeviceId = device.remoteId.str; // Update internal tracker

    final service = FlutterBackgroundService();
    bool isRunning = await service.isRunning();
    if (!isRunning) {
      try {
        await service.startService();
        await Future.delayed(
            const Duration(milliseconds: 200)); // Give it a moment
      } catch (e) {
        print("BleService: Error starting service: $e");
        return;
      }
    }
    // Tell the service (even if already running) which device to use
    service.invoke(bgServiceSetDeviceEvent, {'deviceId': device.remoteId.str});
  }

  // --- END NEW ---

  // --- NEW: Unlatch and stop BG service ---
  Future<void> _unlatchDeviceAndStopService() async {
    print("BleService: Unlatching device and stopping BG service.");
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(bgServiceDeviceIdKey);
    _targetDeviceId = null; // Update internal tracker

    final service = FlutterBackgroundService();
    bool isRunning = await service.isRunning();
    if (isRunning) {
      service.invoke(bgServiceStopEvent); // Tell service to stop cleanly
    }
  }

  // --- END NEW ---


  // --- REVISED: Disconnect ---
  Future<void> disconnectCurrentDevice({bool initiatedByUser = true}) async {
    if (_connectedDevice == null &&
        _currentConnectionState == BleConnectionState.disconnected) {
      print("BleService: Already disconnected. Ignoring disconnect request.");
      // If user initiated and we are *sure* we are disconnected, also ensure service is stopped.
      if (initiatedByUser) await _unlatchDeviceAndStopService();
      return;
    }

    BluetoothDevice? deviceToDisconnect = _connectedDevice;
    String? deviceId = deviceToDisconnect?.remoteId.str;
    print("BleService: Attempting to disconnect from ${deviceId ??
        'current device'}... User: $initiatedByUser");
    _updateConnectionState(BleConnectionState.disconnecting);

    // If the user *explicitly* disconnects, we unlatch and stop the service.
    if (initiatedByUser) {
      await _unlatchDeviceAndStopService();
    }

    try {
      if (deviceToDisconnect != null) {
        await deviceToDisconnect.disconnect();
        print("BleService: Disconnect command sent to ${deviceId}.");
        // The connectionState listener will handle the transition to disconnected.
      } else {
        print(
            "BleService: No device object to disconnect, forcing state to disconnected.");
        _handleDisconnectionLogic(null); // Force cleanup if no device object
      }
    } catch (e) {
      print("BleService: Error during disconnect: $e. Forcing state.");
      _handleDisconnectionLogic(deviceId); // Force cleanup on error
    }

    // Don't set state to disconnected here; let the listener do it.
    // If the listener doesn't fire, we might need a timeout.
  }

  void _handleDisconnectionLogic(String? disconnectedId) {
    print("BleService: Handling disconnection logic for ${disconnectedId ??
        'unknown'}.");
    // Only update UI if the disconnected device matches the one we thought was connected
    if (_connectedDevice != null && (disconnectedId == null ||
        _connectedDevice!.remoteId.str == disconnectedId)) {
      _connectedDevice = null;
      _connectedDeviceController.add(null);
      _updateConnectionState(BleConnectionState.disconnected);
      _clearCharacteristicReferences();
      _cancelCharacteristicValueSubscriptions();
      _connectionStateSubscription?.cancel();
      _connectionStateSubscription = null;
      print("BleService: Cleaned up resources for ${disconnectedId}.");
    } else if (_currentConnectionState != BleConnectionState.disconnected) {
      // If we didn't think we were connected, or it was a different device,
      // still ensure the state is set correctly.
      _updateConnectionState(BleConnectionState.disconnected);
      _connectedDevice = null;
      _connectedDeviceController.add(null);
    }
  }

  // --- END REVISED ---

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
    print("Discovering services for ${device.remoteId.str}...");
    _clearCharacteristicReferences();
    _cancelCharacteristicValueSubscriptions();
    try {
      List<BluetoothService> services = await device.discoverServices(
          timeout: 20); // Longer timeout
      print("Discovered ${services.length} services.");
      bool smartCaneServiceFound = false;
      for (BluetoothService service in services) {
        if (service.uuid.str.toUpperCase() == SMART_CANE_SERVICE_UUID.toUpperCase()) {
          smartCaneServiceFound = true;
          print("    Found Smart Cane Service!");
          for (BluetoothCharacteristic characteristic in service.characteristics) {
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
        print("Error: Smart Cane Service not found. Disconnecting.");
        disconnectCurrentDevice();
      } else {
        print("Service discovery completed.");
      }
    } catch (e, s) {
      print("Error discovering services: $e\n$s");
      // Don't disconnect here - the connection might still be valid,
      // and the BG service might retry. Only disconnect if *critical* service is missing.
    }
  }

  void _parseBatteryLevel(List<int> value) {
    if (value.isNotEmpty) {
      int batteryLevel = value[0];
      _batteryLevelController.add(batteryLevel);
    }
  }

  void _parseFallDetection(List<int> value) {
    if (value.isNotEmpty) {
      bool fallDetected = value[0] == 1;
      _fallDetectedController.add(fallDetected);
    }
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
    if (_batteryCharacteristic != null && _connectedDevice != null &&
        _batteryCharacteristic!.properties.read) {
      try {
        List<int> value = await _batteryCharacteristic!.read();
        _parseBatteryLevel(value);
        return value.isNotEmpty ? value[0] : null;
      } catch (e) {
        print("Error reading battery level: $e");
      }
    }
    return null;
  }

  Future<void> _subscribeToCharacteristic(
      BluetoothCharacteristic characteristic,
      Function(List<int>) dataParser, String logName) async {
    final String charUuid = characteristic.uuid.str.toUpperCase();
    if (!characteristic.properties.notify &&
        !characteristic.properties.indicate) {
      print(
          "Characteristic $charUuid ($logName) does not support notifications.");
      return;
    }

    // Check if already subscribed (important to avoid multiple subscriptions)
    if (_characteristicValueSubscriptions.containsKey(charUuid)) {
      print("Already subscribed to $charUuid ($logName).");
      return;
    }

    print("Subscribing to $charUuid ($logName)...");
    try {
      await characteristic.setNotifyValue(true);
      _characteristicValueSubscriptions[charUuid] =
          characteristic.onValueReceived.listen(
              dataParser,
              onError: (e) {
                print("Error receiving from $charUuid ($logName): $e");
                _characteristicValueSubscriptions.remove(charUuid);
                // Consider attempting re-subscription or handling error.
              },
              onDone: () {
                print("Stream for $charUuid ($logName) done.");
                _characteristicValueSubscriptions.remove(charUuid);
              },
              cancelOnError: true
          );
      print("Successfully subscribed to $charUuid ($logName).");
    } catch (e, s) {
      print("Error subscribing to $charUuid ($logName): $e\n$s");
    }
  }


  BleConnectionState getCurrentConnectionState() => _currentConnectionState;
  BluetoothDevice? getConnectedDevice() => _connectedDevice;

  void connectToScannedDevice(BluetoothDevice device) =>
      connectToDevice(device);

  void resetFallDetectedState() {
    print("Service: Resetting fall detected state.");
    _fallDetectedController.add(false);
  }

  Future<void> sendCalibrationCommand() async {
    if (_currentConnectionState != BleConnectionState.connected ||
        _calibrationCharacteristic == null ||
        !(_calibrationCharacteristic!.properties.write ||
            _calibrationCharacteristic!.properties.writeWithoutResponse)) {
      print("Cannot send calibration command: Not connected/found/writable.");
      return;
    }
    if (_currentInternalCalibrationState == CalibrationState.inProgress) {
      print("Calibration already in progress. Ignoring.");
      return;
    }
    _currentInternalCalibrationState = CalibrationState.inProgress;
    _calibrationStatusController.add(_currentInternalCalibrationState);
    print("Sending calibration command (value: [1])...");
    try {
      await _calibrationCharacteristic!.write([1],
          withoutResponse: _calibrationCharacteristic!.properties
              .writeWithoutResponse);
      print("Calibration command sent.");
    } catch (e) {
      print("Error writing calibration command: $e");
      _currentInternalCalibrationState = CalibrationState.failed;
      _calibrationStatusController.add(_currentInternalCalibrationState);
    }
  }


  static const MethodChannel _audioChannel =
  MethodChannel('com.sept.learning_factory.smart_cane_prototype/audio');

  Future<void> _setSpeakerphoneOn(bool on) async {
    try {
      await _audioChannel.invokeMethod('setSpeakerphoneOn', {'on': on});
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
        await openAppSettings();
        return;
      }
    }
    bool? res = await FlutterPhoneDirectCaller.callNumber(phoneNumber);
    if (res == true) {
      await Future.delayed(const Duration(seconds: 4));
      await _setSpeakerphoneOn(true);
    } else {
      print("Failed to initiate direct call.");
    }
  }

  // --- NEW: Latch helpers ---
  Future<String?> getLatchedDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(bgServiceDeviceIdKey);
  }

  Future<void> clearLatchedDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(bgServiceDeviceIdKey);
    _targetDeviceId = null;
  }

  // --- END NEW ---

  // --- NEW: Try Auto Connect ---
  String? _targetDeviceId; // Keep track internally
  Future<void> _tryAutoConnectIfLatched() async {
    _targetDeviceId = await getLatchedDeviceId();
    if (_targetDeviceId != null &&
        _currentConnectionState == BleConnectionState.disconnected) {
      print(
          "BleService: Found latched device $_targetDeviceId and BT is ON. Attempting auto-connect via BG Service.");
      // Instead of connecting directly, ensure the BG service is running and let IT handle it.
      final service = FlutterBackgroundService();
      bool isRunning = await service.isRunning();
      if (!isRunning) {
        print(
            "BleService: BG service wasn't running, starting it for latched device.");
        await service.startService();
        await Future.delayed(const Duration(milliseconds: 200));
        service.invoke(bgServiceSetDeviceEvent, {'deviceId': _targetDeviceId});
      } else {
        print(
            "BleService: BG service is running, ensuring it targets $_targetDeviceId.");
        service.invoke(bgServiceSetDeviceEvent, {'deviceId': _targetDeviceId});
      }
      // Update UI to show 'Connecting' as BG service takes over.
      _updateConnectionState(BleConnectionState.connecting);
    }
  }

  Future<void> connectToLatchedDevice() async {
    _targetDeviceId = await getLatchedDeviceId();
    if (_targetDeviceId != null) {
      // This method is now simpler: it just tells the BG service to do its job.
      _tryAutoConnectIfLatched();
    }
  }

  // --- END NEW ---


  void dispose() {
    print("BleService Disposing...");
    _connectionStateSubscription?.cancel();
    _isScanningSubscription?.cancel();
    _adapterStateSubscription?.cancel();
    disconnectCurrentDevice(initiatedByUser: false);
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