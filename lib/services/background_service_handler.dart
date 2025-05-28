// lib/services/background_service_handler.dart
import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart'; // For WidgetsFlutterBinding if service needs it.
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Constants (ensure these are globally unique if needed, or prefix them)
const String SMART_CANE_SERVICE_UUID = "A5A20D8A-E137-4B30-9F30-1A7A91579C9C";
const String BATTERY_CHARACTERISTIC_UUID = "2A19";
const String FALL_CHARACTERISTIC_UUID = "C712A5B2-2C13-4088-8D53-F7E3291B0155";
const String CALIBRATION_CHARACTERISTIC_UUID = "E9A10B6B-8A65-4F56-82C3-6768F0EE38A1";
const String CALIBRATION_STATUS_UUID = "494600C8-1693-4A3B-B380-FF1EC534959E";
// const String SMART_CANE_DEVICE_NAME = "Smart Cane"; // This might vary

const String notificationChannelId = 'smart_cane_foreground_service';
const String notificationChannelName = 'Smart Cane Background Service';
const int notificationId = 888;
const String bgServiceDeviceIdKey = 'bg_service_device_id';
const String bgServiceDeviceNameKey = 'bg_service_device_name_key';

const String bgServiceStopEvent = "stopService";
const String bgServiceSetDeviceEvent = "setDevice";
const String triggerFallAlertUIEvent = "triggerFallAlertUI";
const String backgroundServiceConnectionUpdateEvent = "backgroundConnectionUpdate";
const String resetFallHandlingEvent = "resetFallHandling";
const String requestCalibrationEvent = "requestCalibration";

const String fallPendingAlertKey = 'fall_pending_alert';

BluetoothDevice? _connectedDeviceBg;
StreamSubscription<BluetoothConnectionState>? _connectionStateSubscriptionBg;
StreamSubscription<List<int>>? _fallSubscriptionBg;
StreamSubscription<List<int>>? _batterySubscriptionBg;
StreamSubscription<List<int>>? _calibrationStatusSubscriptionBg;

BluetoothCharacteristic? _fallCharacteristicBg;
BluetoothCharacteristic? _batteryCharacteristicBg;
BluetoothCharacteristic? _calibrationCharacteristicForWriteBg;
BluetoothCharacteristic? _calibrationStatusCharacteristicForNotifyBg;

Timer? _reconnectTimer;
bool _isFallHandlingInProgressBg = false;
String? _targetDeviceIdBg;
String? _targetDeviceNameBg;
bool _isConnectingBg = false;
ServiceInstance? _serviceInstanceBg;
Timer? _fallResetTimerBg;

enum BgCalibrationState { idle, inProgress, success, failed }

BgCalibrationState _bgCalibrationState = BgCalibrationState.idle;

// Helper to find a device in a list by ID
BluetoothDevice? _findDeviceById(List<BluetoothDevice> devices, String id) {
  for (var d in devices) {
    if (d.remoteId.str == id) {
      return d;
    }
  }
  return null;
}


@pragma('vm:entry-point')
Future<void> onStart(ServiceInstance service) async {
  try {
    DartPluginRegistrant.ensureInitialized();
    print("BG_SERVICE: DartPluginRegistrant.ensureInitialized() SUCCESS");
  } catch (e, s) {
    print(
        "BG_SERVICE: ERROR in DartPluginRegistrant.ensureInitialized(): $e\n$s");
    // If this fails, the isolate is doomed.
  }

  WidgetsFlutterBinding
      .ensureInitialized(); // Usually not needed in background isolate unless using specific UI widgets

  _serviceInstanceBg = service;
  print("BG_SERVICE: Starting (onStart invoked).");

  final prefs = await SharedPreferences.getInstance();
  _targetDeviceIdBg = prefs.getString(bgServiceDeviceIdKey);
  _targetDeviceNameBg = prefs.getString(bgServiceDeviceNameKey);

  if (service is AndroidServiceInstance) {
    await service.setAsForegroundService();
    print("BG_SERVICE: Set as foreground service.");
    if (_targetDeviceIdBg != null) {
      service.setForegroundNotificationInfo(
        title: "Smart Cane Service",
        content: "Monitoring '${_targetDeviceNameBg ?? _targetDeviceIdBg}'",
      );
    } else {
      service.setForegroundNotificationInfo(
        title: "Smart Cane Service",
        content: "No cane selected. Open app to select.",
      );
    }
  }

  service.on(bgServiceStopEvent).listen((event) async {
    print("BG_SERVICE: Received '$bgServiceStopEvent'.");
    await _disconnectBg(clearTargetDevice: true);
    await prefs.remove(bgServiceDeviceIdKey);
    await prefs.remove(bgServiceDeviceNameKey);
    _isFallHandlingInProgressBg = false;
    _fallResetTimerBg?.cancel();
    await service.stopSelf();
    print("BG_SERVICE: Stopped self.");
  });

  service.on(bgServiceSetDeviceEvent).listen((event) async {
    final newDeviceId = event?['deviceId'] as String?;
    final newDeviceName = event?['deviceName'] as String?;

    print(
        "BG_SERVICE: Received '$bgServiceSetDeviceEvent'. Device ID: $newDeviceId, Name: $newDeviceName");

    if (newDeviceId == null) {
      await _disconnectBg(clearTargetDevice: true);
      await prefs.remove(bgServiceDeviceIdKey);
      await prefs.remove(bgServiceDeviceNameKey);
      _updateForegroundNotification("No cane selected. Open app to select.");
      _invokeConnectionUpdate();
    } else if (newDeviceId != _targetDeviceIdBg) {
      await _disconnectBg(clearTargetDevice: false); // Disconnect from old
      _targetDeviceIdBg = newDeviceId;
      _targetDeviceNameBg = newDeviceName ?? "Smart Cane";
      await prefs.setString(bgServiceDeviceIdKey, _targetDeviceIdBg!);
      await prefs.setString(bgServiceDeviceNameKey, _targetDeviceNameBg!);
      _updateForegroundNotification(
          "Attempting to connect to '${_targetDeviceNameBg}'");
      if (!_isFallHandlingInProgressBg) {
        _connectToTargetDevice();
      } else {
        print(
            "BG_SERVICE: Fall handling in progress, will connect after reset.");
      }
    } else {
      print(
          "BG_SERVICE: Target device ID $newDeviceId is already set. Ensuring connection.");
      _updateForegroundNotification(
          "Monitoring '${_targetDeviceNameBg ?? _targetDeviceIdBg}'");
      if (_connectedDeviceBg == null && !_isConnectingBg &&
          !_isFallHandlingInProgressBg) {
        _connectToTargetDevice();
      } else {
        _invokeConnectionUpdate();
      }
    }
  });

  service.on(resetFallHandlingEvent).listen((event) {
    print("BG_SERVICE: Received '$resetFallHandlingEvent' from UI.");
    if (_isFallHandlingInProgressBg) {
      _isFallHandlingInProgressBg = false;
      _fallResetTimerBg?.cancel();
      print("BG_SERVICE: Fall handling flag reset by UI.");
      if (_connectedDeviceBg == null && _targetDeviceIdBg != null &&
          !_isConnectingBg) {
        print("BG_SERVICE: Attempting reconnect after UI fall reset.");
        _connectToTargetDevice();
      }
    }
  });

  service.on(requestCalibrationEvent).listen((event) {
    print("BG_SERVICE: Received '$requestCalibrationEvent'.");
    _sendCalibrationCommandBg();
  });

  if (_targetDeviceIdBg != null) {
    print(
        "BG_SERVICE: Found stored device ID: $_targetDeviceIdBg. Name: $_targetDeviceNameBg. Attempting connect.");
    _connectToTargetDevice();
  } else {
    print("BG_SERVICE: No stored target device. Waiting for UI selection.");
    _invokeConnectionUpdate();
  }

  Timer.periodic(const Duration(seconds: 45), (timer) async {
    // Removed: bool isRunning = await service.isRunning();
    print(
        "BG_SERVICE: Heartbeat - Target: $_targetDeviceIdBg, Name: $_targetDeviceNameBg, Connected: ${_connectedDeviceBg
            ?.remoteId
            .str}, Connecting: $_isConnectingBg, FallHandling: $_isFallHandlingInProgressBg");
    if (_targetDeviceIdBg != null && _connectedDeviceBg == null &&
        !_isConnectingBg && !_isFallHandlingInProgressBg &&
        _reconnectTimer == null) {
      print(
          "BG_SERVICE: Heartbeat - Not connected but should be. Attempting reconnect.");
      _connectToTargetDevice();
    }
  });
  print("BG_SERVICE: onStart completed.");
}

void _updateForegroundNotification(String content) {
  if (_serviceInstanceBg is AndroidServiceInstance) {
    (_serviceInstanceBg as AndroidServiceInstance)
        .setForegroundNotificationInfo(
      title: "Smart Cane Service",
      content: content,
    );
  }
}

void _invokeConnectionUpdate(
    {int? batteryLevel, BgCalibrationState? calibrationState}) {
  if (_serviceInstanceBg == null) return;
  final currentCalibState = calibrationState ?? _bgCalibrationState;

  _serviceInstanceBg!.invoke(backgroundServiceConnectionUpdateEvent, {
    'connected': _connectedDeviceBg != null,
    'deviceId': _connectedDeviceBg?.remoteId.str ?? _targetDeviceIdBg,
    'deviceName': _connectedDeviceBg?.platformName.isNotEmpty == true
        ? _connectedDeviceBg!.platformName
        : _targetDeviceNameBg,
    'batteryLevel': batteryLevel,
    'isFallHandlingInProgress': _isFallHandlingInProgressBg,
    'calibrationStatus': currentCalibState.name,
  });
  print("BG_SERVICE: Invoked connection update: Conn: ${_connectedDeviceBg !=
      null}, Device: ${_connectedDeviceBg?.remoteId.str ??
      _targetDeviceIdBg}, Name: ${_connectedDeviceBg?.platformName ??
      _targetDeviceNameBg}, Batt: $batteryLevel, Calib: ${currentCalibState
      .name}");
}

Future<void> _disconnectBg({bool clearTargetDevice = false}) async {
  print(
      "BG_SERVICE: Disconnecting background BLE. Current target: $_targetDeviceIdBg. Clear target: $clearTargetDevice");
  _isConnectingBg = false;
  _reconnectTimer?.cancel();
  _reconnectTimer = null;

  await _fallSubscriptionBg?.cancel();
  _fallSubscriptionBg = null;
  await _batterySubscriptionBg?.cancel();
  _batterySubscriptionBg = null;
  await _calibrationStatusSubscriptionBg?.cancel();
  _calibrationStatusSubscriptionBg = null;

  _fallCharacteristicBg = null;
  _batteryCharacteristicBg = null;
  _calibrationCharacteristicForWriteBg = null;
  _calibrationStatusCharacteristicForNotifyBg = null;

  StreamSubscription<
      BluetoothConnectionState>? tempConnectionSub = _connectionStateSubscriptionBg;
  _connectionStateSubscriptionBg = null;

  if (_connectedDeviceBg != null) {
    try {
      print("BG_SERVICE: Attempting to disconnect from ${_connectedDeviceBg!
          .remoteId.str}");
      await _connectedDeviceBg!.disconnect(timeout: 10);
      print(
          "BG_SERVICE: Disconnected from device: ${_connectedDeviceBg!.remoteId
              .str}");
    } catch (e) {
      print(
          "BG_SERVICE: Error during explicit disconnect of ${_connectedDeviceBg
              ?.remoteId.str}: $e");
    }
  } else {
    print(
        "BG_SERVICE: _disconnectBg called, but _connectedDeviceBg was already null.");
  }
  _connectedDeviceBg = null;
  await tempConnectionSub?.cancel();

  if (clearTargetDevice) {
    _targetDeviceIdBg = null;
    _targetDeviceNameBg = null;
    _bgCalibrationState = BgCalibrationState.idle;
  }
  _updateForegroundNotification(
      _targetDeviceIdBg != null ? "Disconnected from '${_targetDeviceNameBg ??
          _targetDeviceIdBg}'. Reconnecting..." : "No cane selected.");
  _invokeConnectionUpdate();
}

void _scheduleReconnect() {
  if (_isFallHandlingInProgressBg || _targetDeviceIdBg == null ||
      _serviceInstanceBg == null || _reconnectTimer != null ||
      _isConnectingBg) {
    print(
        "BG_SERVICE: Reconnect skipped (fall: $_isFallHandlingInProgressBg, noTarget: ${_targetDeviceIdBg ==
            null}, serviceNull: ${_serviceInstanceBg ==
            null}, timerExists: ${_reconnectTimer !=
            null}, isConnecting: $_isConnectingBg).");
    return;
  }
  _reconnectTimer?.cancel();
  print(
      "BG_SERVICE: Scheduling reconnect in 15 seconds for '$_targetDeviceNameBg' ($_targetDeviceIdBg).");
  _reconnectTimer = Timer(const Duration(seconds: 15), () {
    _reconnectTimer = null;
    if (!_isFallHandlingInProgressBg && _targetDeviceIdBg != null &&
        _connectedDeviceBg == null && !_isConnectingBg) {
      print(
          "BG_SERVICE: Reconnect timer fired for '$_targetDeviceNameBg'. Attempting connection.");
      _connectToTargetDevice();
    } else {
      print(
          "BG_SERVICE: Reconnect timer fired but conditions not met for reconnect.");
    }
  });
}

Future<void> _connectToTargetDevice() async {
  if (_serviceInstanceBg == null || _targetDeviceIdBg == null ||
      _isConnectingBg || _connectedDeviceBg != null ||
      _isFallHandlingInProgressBg) {
    print("BG_SERVICE: Connect skipped (serviceNull: ${_serviceInstanceBg ==
        null}, noTarget: ${_targetDeviceIdBg ==
        null}, connecting: $_isConnectingBg, connected: ${_connectedDeviceBg !=
        null}, fallHandling: $_isFallHandlingInProgressBg).");
    _invokeConnectionUpdate();
    return;
  }

  _isConnectingBg = true;
  _reconnectTimer?.cancel();
  _reconnectTimer = null;
  _bgCalibrationState = BgCalibrationState.idle;

  print(
      "BG_SERVICE: Connecting to '$_targetDeviceNameBg' ($_targetDeviceIdBg)...");
  _updateForegroundNotification(
      "Connecting to '${_targetDeviceNameBg ?? _targetDeviceIdBg}'...");
  _invokeConnectionUpdate();

  try {
    var adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      print("BG_SERVICE: Bluetooth is OFF ($adapterState). Cannot connect.");
      _isConnectingBg = false;
      _updateForegroundNotification(
          "Bluetooth is off. Turn on Bluetooth to connect.");
      _invokeConnectionUpdate();
      _scheduleReconnect();
      return;
    }

    BluetoothDevice? targetDevice;
    try {
      // Try to get the device directly if already known to the system/bonded
      List<BluetoothDevice> knownDevices = await FlutterBluePlus.systemDevices(
          []); // Includes bonded
      targetDevice = _findDeviceById(knownDevices, _targetDeviceIdBg!);
    } catch (e) {
      print("BG_SERVICE: Error fetching system/bonded devices: $e");
    }


    if (targetDevice == null) {
      print(
          "BG_SERVICE: Device '$_targetDeviceNameBg' not in system/bonded list. Starting scan...");
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 7),
        androidScanMode: AndroidScanMode.lowLatency,
      );
      // Using await for is fine for listening to a stream for a short duration like a scan
      await for (List<ScanResult> results in FlutterBluePlus.scanResults) {
        for (ScanResult r in results) {
          if (r.device.remoteId.str == _targetDeviceIdBg) {
            targetDevice = r.device;
            print("BG_SERVICE: Found device '$_targetDeviceNameBg' via scan.");
            break; // Found device
          }
        }
        if (targetDevice != null) break; // Exit stream loop
      }
      // Ensure scan is stopped
      if (await FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
        print("BG_SERVICE: Scan stopped.");
      }
    } else {
      print(
          "BG_SERVICE: Found device '$_targetDeviceNameBg' in system/bonded devices list.");
    }


    if (targetDevice == null) {
      print(
          "BG_SERVICE: Device '$_targetDeviceNameBg' ($_targetDeviceIdBg) not found. Scheduling reconnect.");
      _isConnectingBg = false;
      _updateForegroundNotification(
          "Could not find '${_targetDeviceNameBg}'. Will retry.");
      _invokeConnectionUpdate();
      _scheduleReconnect();
      return;
    }

    final deviceToConnect = targetDevice;

    _connectionStateSubscriptionBg?.cancel();
    _connectionStateSubscriptionBg = deviceToConnect.connectionState.listen(
            (state) async {
          print("BG_SERVICE: Device '${deviceToConnect
              .platformName}' ($_targetDeviceIdBg) connection state: $state");
          if (state == BluetoothConnectionState.connected) {
            _connectedDeviceBg = deviceToConnect;
            _isConnectingBg = false;
            _targetDeviceNameBg =
            deviceToConnect.platformName.isNotEmpty ? deviceToConnect
                .platformName : _targetDeviceNameBg;
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString(bgServiceDeviceNameKey, _targetDeviceNameBg!);

            _updateForegroundNotification(
                "Connected to '${_targetDeviceNameBg}'");
            _reconnectTimer?.cancel();
            _reconnectTimer = null;
            await _discoverServicesBg(deviceToConnect);
          } else if (state == BluetoothConnectionState.disconnected) {
            bool wasThisDeviceConnected = _connectedDeviceBg?.remoteId.str ==
                deviceToConnect.remoteId.str;
            _isConnectingBg = false;

            if (wasThisDeviceConnected) {
              print("BG_SERVICE: Device '$_targetDeviceNameBg' disconnected.");
              _connectedDeviceBg = null;
              await _fallSubscriptionBg?.cancel();
              _fallSubscriptionBg = null;
              await _batterySubscriptionBg?.cancel();
              _batterySubscriptionBg = null;
              await _calibrationStatusSubscriptionBg?.cancel();
              _calibrationStatusSubscriptionBg = null;
              _fallCharacteristicBg = null;
              _batteryCharacteristicBg = null;
              _calibrationCharacteristicForWriteBg = null;
              _calibrationStatusCharacteristicForNotifyBg = null;
              _bgCalibrationState = BgCalibrationState.idle;
              _updateForegroundNotification(
                  "Disconnected from '${_targetDeviceNameBg}'. Retrying...");
            }
            _invokeConnectionUpdate();
            if (_targetDeviceIdBg == deviceToConnect.remoteId.str &&
                !_isFallHandlingInProgressBg) {
              _scheduleReconnect();
            }
          }
        },
        onError: (error) {
          print(
              "BG_SERVICE: Connection state listener error for '$_targetDeviceNameBg': $error");
          _isConnectingBg = false;
          _invokeConnectionUpdate();
          _scheduleReconnect();
        }
    );

    await deviceToConnect.connect(
      autoConnect: false,
      timeout: const Duration(seconds: 20),
    );
  } catch (e, s) {
    print(
        "BG_SERVICE: Error during connection/scan for '$_targetDeviceNameBg' ($_targetDeviceIdBg): $e\n$s");
    _isConnectingBg = false;
    _updateForegroundNotification(
        "Error connecting to '${_targetDeviceNameBg}'. Retrying.");
    _invokeConnectionUpdate();
    _scheduleReconnect();
  }
}

Future<void> _discoverServicesBg(BluetoothDevice device) async {
  if (_serviceInstanceBg == null) return;
  print("BG_SERVICE: Discovering services for '${device.platformName}' (${device
      .remoteId.str})...");
  List<BluetoothService> services;
  try {
    services = await device.discoverServices(timeout: 15);
  } catch (e) {
    print("BG_SERVICE: Error discovering services for ${device.remoteId
        .str}: $e. Disconnecting.");
    await _disconnectBg();
    return;
  }

  bool foundSmartCaneService = false;
  _fallCharacteristicBg = null;
  _batteryCharacteristicBg = null; // Reset before discovery
  _calibrationCharacteristicForWriteBg = null;
  _calibrationStatusCharacteristicForNotifyBg = null;

  for (BluetoothService s in services) {
    if (s.uuid.str.toUpperCase() == SMART_CANE_SERVICE_UUID.toUpperCase()) {
      foundSmartCaneService = true;
      print("BG_SERVICE: Found Smart Cane Service for ${device.remoteId.str}.");
      for (BluetoothCharacteristic c in s.characteristics) {
        String charUuidUpper = c.uuid.str.toUpperCase();
        if (charUuidUpper == FALL_CHARACTERISTIC_UUID.toUpperCase()) {
          _fallCharacteristicBg = c;
          print("BG_SERVICE: Found Fall Characteristic. Subscribing...");
          await _fallSubscriptionBg?.cancel();
          if (c.properties.notify || c.properties.indicate) {
            if (!c.isNotifying) await c.setNotifyValue(
                true); // Ensure this completes
            _fallSubscriptionBg = c.onValueReceived.listen(
                    (value) =>
                    _handleFallDetectionBg(value, _serviceInstanceBg!),
                onError: (e) =>
                    print("BG_SERVICE: Fall Characteristic listener error: $e")
            );
          } else {
            print(
                "BG_SERVICE: Fall characteristic does not support notify/indicate.");
          }
        } else if (charUuidUpper == BATTERY_CHARACTERISTIC_UUID.toUpperCase()) {
          _batteryCharacteristicBg = c;
          print(
              "BG_SERVICE: Found Battery Characteristic. Subscribing & Reading...");
          await _batterySubscriptionBg?.cancel();
          if (c.properties.read) {
            try {
              List<int> val = await c.read();
              _handleBatteryLevelBg(val);
            } catch (e) {
              print("BG_SERVICE: Error reading initial battery: $e");
            }
          }
          if (c.properties.notify || c.properties.indicate) {
            if (!c.isNotifying) await c.setNotifyValue(true);
            _batterySubscriptionBg = c.onValueReceived.listen(
                _handleBatteryLevelBg,
                onError: (e) =>
                    print(
                        "BG_SERVICE: Battery Characteristic listener error: $e")
            );
          } else {
            print(
                "BG_SERVICE: Battery characteristic does not support notify/indicate for updates.");
          }
        } else
        if (charUuidUpper == CALIBRATION_CHARACTERISTIC_UUID.toUpperCase()) {
          _calibrationCharacteristicForWriteBg = c;
          print("BG_SERVICE: Found Calibration Write Characteristic.");
        } else if (charUuidUpper == CALIBRATION_STATUS_UUID.toUpperCase()) {
          _calibrationStatusCharacteristicForNotifyBg = c;
          print(
              "BG_SERVICE: Found Calibration Status Characteristic. Subscribing...");
          await _calibrationStatusSubscriptionBg?.cancel();
          if (c.properties.notify || c.properties.indicate) {
            if (!c.isNotifying) await c.setNotifyValue(true);
            _calibrationStatusSubscriptionBg = c.onValueReceived.listen(
                _handleCalibrationStatusBg,
                onError: (e) =>
                    print("BG_SERVICE: Calibration Status listener error: $e")
            );
          } else {
            print(
                "BG_SERVICE: Calibration status characteristic does not support notify/indicate.");
          }
        }
      }
    }
  }

  if (!foundSmartCaneService) {
    print("BG_SERVICE: Smart Cane Service NOT FOUND for ${device.remoteId
        .str}. Disconnecting.");
    await _disconnectBg();
  } else if (_fallCharacteristicBg == null) {
    print(
        "BG_SERVICE: CRITICAL - Fall characteristic not found. Disconnecting.");
    await _disconnectBg();
  }
  else {
    print(
        "BG_SERVICE: Service discovery and characteristic setup complete for ${device
            .remoteId.str}.");
  }
  _invokeConnectionUpdate();
}

void _handleFallDetectionBg(List<int> value, ServiceInstance service) async {
  if (value.isNotEmpty && value[0] == 1 && !_isFallHandlingInProgressBg) {
    _isFallHandlingInProgressBg = true;
    print(
        "BG_SERVICE: !!! FALL DETECTED on '$_targetDeviceNameBg' ($_targetDeviceIdBg) !!! Invoking UI event & setting '$fallPendingAlertKey'.");

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(fallPendingAlertKey, true);

    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    service.invoke(triggerFallAlertUIEvent);
    _invokeConnectionUpdate();

    _fallResetTimerBg?.cancel();
    _fallResetTimerBg = Timer(const Duration(seconds: 90), () async {
      if (_isFallHandlingInProgressBg) {
        print("BG_SERVICE: Failsafe timer - Resetting fall handling flag.");
        _isFallHandlingInProgressBg = false;
        await prefs.remove(fallPendingAlertKey);
        _invokeConnectionUpdate();
        if (_connectedDeviceBg == null && _targetDeviceIdBg != null &&
            !_isConnectingBg) {
          print("BG_SERVICE: Attempting reconnect after failsafe timer.");
          _connectToTargetDevice();
        }
      }
    });
  } else if (value.isNotEmpty && value[0] == 0 && _isFallHandlingInProgressBg) {
    print("BG_SERVICE: Fall cancelled signal received from device.");
    _isFallHandlingInProgressBg = false;
    _fallResetTimerBg?.cancel();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(fallPendingAlertKey);
    _invokeConnectionUpdate();
  }
}

void _handleBatteryLevelBg(List<int> value) {
  if (value.isNotEmpty) {
    int batteryLevel = value[0];
    if (batteryLevel >= 0 && batteryLevel <= 100) {
      // print("BG_SERVICE: Battery level update: $batteryLevel%"); // Can be noisy
      _invokeConnectionUpdate(batteryLevel: batteryLevel);
    } else {
      print("BG_SERVICE: Received invalid battery level: $batteryLevel");
    }
  }
}

void _handleCalibrationStatusBg(List<int> value) {
  BgCalibrationState newCalibState = _bgCalibrationState;
  if (value.isNotEmpty) {
    int statusByte = value[0];
    switch (statusByte) {
      case 0:
        newCalibState = BgCalibrationState.failed;
        break;
      case 1:
        newCalibState = BgCalibrationState.success;
        break;
      case 2:
        newCalibState = BgCalibrationState.inProgress;
        break;
      default:
        newCalibState = BgCalibrationState.failed;
        break;
    }
  } else {
    if (_bgCalibrationState == BgCalibrationState.inProgress)
      newCalibState = BgCalibrationState.failed;
  }
  if (_bgCalibrationState != newCalibState) {
    _bgCalibrationState = newCalibState;
    print("BG_SERVICE: Parsed Calibration Status: $_bgCalibrationState");
    _invokeConnectionUpdate(calibrationState: _bgCalibrationState);
    if (_bgCalibrationState == BgCalibrationState.success ||
        _bgCalibrationState == BgCalibrationState.failed) {
      Future.delayed(const Duration(seconds: 5), () {
        if (_bgCalibrationState != BgCalibrationState.inProgress) {
          _bgCalibrationState = BgCalibrationState.idle;
          _invokeConnectionUpdate(calibrationState: _bgCalibrationState);
        }
      });
    }
  }
}

Future<void> _sendCalibrationCommandBg() async {
  if (_connectedDeviceBg == null ||
      _calibrationCharacteristicForWriteBg == null) {
    print(
        "BG_SERVICE: Cannot send calibration. Not connected or char not found.");
    _bgCalibrationState = BgCalibrationState.failed;
    _invokeConnectionUpdate(calibrationState: _bgCalibrationState);
    return;
  }
  if (_bgCalibrationState == BgCalibrationState.inProgress) {
    print("BG_SERVICE: Calibration already in progress.");
    return;
  }
  print("BG_SERVICE: Sending calibration command (value: [1]) to ESP32...");
  _bgCalibrationState = BgCalibrationState.inProgress;
  _invokeConnectionUpdate(calibrationState: _bgCalibrationState);
  try {
    await _calibrationCharacteristicForWriteBg!.write([1],
        withoutResponse: _calibrationCharacteristicForWriteBg!.properties
            .writeWithoutResponse, timeout: 5);
    print("BG_SERVICE: Calibration command sent successfully.");
  } catch (e) {
    print("BG_SERVICE: Error writing calibration command: $e");
    _bgCalibrationState = BgCalibrationState.failed;
    _invokeConnectionUpdate(calibrationState: _bgCalibrationState);
  }
}