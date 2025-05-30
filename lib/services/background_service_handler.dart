// lib/services/background_service_handler.dart
import 'dart:async';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_cane_prototype/services/ble_service.dart'; // For UUIDs & constants

// --- Constants ---
const String notificationChannelId = 'smart_cane_foreground_service';
const String notificationChannelName = 'Smart Cane Background Service';
const int bg_notificationId = 888; // Renamed to avoid conflict
const String bgServiceDeviceIdKey = 'bg_service_device_id';

// --- Service Events ---
const String bgServiceStopEvent = "stopService";
const String bgServiceSetDeviceEvent = "setDevice";
const String triggerFallAlertUIEvent = "triggerFallAlertUI"; // This event is now key
const String backgroundServiceConnectionUpdateEvent = "backgroundConnectionUpdate";
const String resetFallHandlingEvent = "resetFallHandling"; // UI tells BG to reset its own fall handling state

// --- Background State ---
BluetoothDevice? _connectedDeviceBg;
StreamSubscription<BluetoothConnectionState>? _connectionStateSubscriptionBg;
StreamSubscription<List<int>>? _fallSubscriptionBg;
StreamSubscription<List<int>>? _batterySubscriptionBg;
StreamSubscription<List<int>>? _calibrationStatusSubscriptionBg;
Timer? _reconnectTimer;
bool _isBgFallHandlingInProgress = false; // Renamed to avoid clash with main.dart's global
String? _targetDeviceId;
bool _isConnecting = false;
ServiceInstance? _serviceInstanceBg; // Renamed
Timer? _fallResetTimerBg; // Renamed
bool _isStopping = false;

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  _serviceInstanceBg = service;
  _isStopping = false;
  print("BG Service: Starting (onStart invoked).");

  service.on(bgServiceStopEvent).listen((event) async {
    print("BG Service: Received stop event.");
    _isStopping = true;
    await _disconnectBg(clearTarget: true);
    _targetDeviceId = null;
    _isBgFallHandlingInProgress = false;
    _fallResetTimerBg?.cancel();
    service.stopSelf();
    print("BG Service: Stopped self.");
  });

  service.on(bgServiceSetDeviceEvent).listen((event) async {
    if (_isStopping) return;
    final deviceId = event?['deviceId'] as String?;
    print("BG Service: Received device ID via event: $deviceId");
    if (deviceId != null && deviceId != _targetDeviceId) {
      print("BG Service: New target $deviceId. Resetting connection.");
      _targetDeviceId = deviceId;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(bgServiceDeviceIdKey, deviceId);
      await _disconnectBg(clearTarget: false);
      _connectToTargetDevice();
    } else if (deviceId == null) {
      print(
          "BG Service: Received null deviceId. Clearing target and stopping.");
      await _disconnectBg(clearTarget: true);
      _targetDeviceId = null;
      _isStopping = true;
      service.stopSelf();
    } else
    if (deviceId != null && _connectedDeviceBg == null && !_isConnecting) {
      print(
          "BG Service: Same device ID ($deviceId) but not connected. Trying connect.");
      _connectToTargetDevice();
    }
  });

  service.on(resetFallHandlingEvent).listen((event) {
    print("BG Service: Received reset fall handling event from UI.");
    if (_isBgFallHandlingInProgress) {
      _isBgFallHandlingInProgress = false;
      _fallResetTimerBg?.cancel();
      print("BG Service: Fall handling flag reset by UI.");
      // If disconnected, try to reconnect as fall sequence is over.
      if (_connectedDeviceBg == null && _targetDeviceId != null &&
          !_isConnecting && !_isStopping) {
        print("BG Service: Attempting reconnect after UI fall reset.");
        _connectToTargetDevice();
      }
    }
  });

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
      print("BG Service: Set as foreground.");
    });
    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
      print("BG Service: Set as background.");
    });
  }

  final prefs = await SharedPreferences.getInstance();
  _targetDeviceId = prefs.getString(bgServiceDeviceIdKey);
  print("BG Service: Initial Target Device ID: $_targetDeviceId");

  if (_targetDeviceId != null) {
    _updateNotification(content: 'Connecting to Smart Cane...');
    _connectToTargetDevice();
  } else {
    _isStopping = true;
    service.stopSelf();
    return;
  }

  Timer.periodic(const Duration(seconds: 25), (timer) async {
    if (_isStopping || _serviceInstanceBg == null) {
      timer.cancel();
      return;
    }
    if (_targetDeviceId != null && _connectedDeviceBg == null &&
        !_isConnecting &&
        !_isBgFallHandlingInProgress) { // Check BG fall handling flag
      _connectToTargetDevice();
    }
  });
  print("BG Service: onStart completed.");
}


void _updateNotification(
    {required String content, String title = 'Smart Cane Service'}) {
  final service = _serviceInstanceBg;
  if (service is AndroidServiceInstance) {
    service.setForegroundNotificationInfo(
      title: title,
      content: content,
    );
  }
}

Future<void> _disconnectBg({bool clearTarget = false}) async {
  print("BG Service: Disconnecting background BLE. Clear Target: $clearTarget");
  _isConnecting = false;
  _reconnectTimer?.cancel();
  _reconnectTimer = null;

  await _fallSubscriptionBg?.cancel();
  _fallSubscriptionBg = null;
  await _batterySubscriptionBg?.cancel();
  _batterySubscriptionBg = null;
  await _calibrationStatusSubscriptionBg?.cancel();
  _calibrationStatusSubscriptionBg = null;

  StreamSubscription<
      BluetoothConnectionState>? tempConnectionSub = _connectionStateSubscriptionBg;
  _connectionStateSubscriptionBg = null; // Nullify before await

  if (_connectedDeviceBg != null) {
    try {
      await _connectedDeviceBg!.disconnect();
    } catch (e) {
      /* Silent disconnect error */
    }
  }
  await tempConnectionSub?.cancel(); // Cancel after disconnect attempt
  _connectedDeviceBg = null;

  if (clearTarget) {
    _targetDeviceId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(bgServiceDeviceIdKey);
  }

  _serviceInstanceBg?.invoke(backgroundServiceConnectionUpdateEvent, {
    'connected': false, 'deviceId': _targetDeviceId, 'deviceName': null,
  });
  _updateNotification(content: 'Disconnected. Waiting...');
}

void _scheduleReconnect() {
  if (_isBgFallHandlingInProgress || _targetDeviceId == null ||
      _serviceInstanceBg == null || _isConnecting || _isStopping) {
    return;
  }
  _reconnectTimer?.cancel();
  _reconnectTimer = Timer(const Duration(seconds: 15), () {
    _reconnectTimer = null;
    if (_isStopping || _isConnecting || _connectedDeviceBg != null) return;
    _connectToTargetDevice();
  });
}

BluetoothDevice? _findDeviceInList(List<BluetoothDevice> devices, String id) {
  try {
    return devices.firstWhere((d) => d.remoteId.str == id);
  } catch (e) {
    return null;
  }
}

Future<void> _connectToTargetDevice() async {
  if (_serviceInstanceBg == null || _isConnecting ||
      _connectedDeviceBg != null ||
      _isBgFallHandlingInProgress || _targetDeviceId == null || _isStopping) {
    return;
  }
  _isConnecting = true;
  _reconnectTimer?.cancel();
  _updateNotification(content: 'Connecting to $_targetDeviceId...');

  try {
    var adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      _isConnecting = false;
      _updateNotification(content: 'Bluetooth is off. Waiting...');
      _scheduleReconnect();
      return;
    }

    BluetoothDevice? targetDevice;
    // Check connected devices first
    List<BluetoothDevice> connected = await FlutterBluePlus.connectedDevices;
    targetDevice = _findDeviceInList(connected, _targetDeviceId!);

    if (targetDevice == null) {
      List<BluetoothDevice> system = await FlutterBluePlus.systemDevices([]);
      targetDevice = _findDeviceInList(system, _targetDeviceId!);
    }


    if (targetDevice == null) {
      _updateNotification(content: 'Scanning for $_targetDeviceId...');
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 10),
        androidScanMode: AndroidScanMode.lowLatency,
      );
      await for (List<ScanResult> results in FlutterBluePlus.scanResults) {
        for (ScanResult r in results) {
          if (r.device.remoteId.str == _targetDeviceId) {
            targetDevice = r.device;
            await FlutterBluePlus.stopScan();
            break;
          }
        }
        if (targetDevice != null) break;
      }
      await FlutterBluePlus.stopScan();
    }

    if (targetDevice == null) {
      _updateNotification(content: 'Cane not found. Retrying soon...');
      _isConnecting = false;
      _scheduleReconnect();
      return;
    }

    final deviceToConnect = targetDevice;
    _connectionStateSubscriptionBg?.cancel();
    _connectionStateSubscriptionBg =
        deviceToConnect.connectionState.listen((state) async {
          if (_isStopping) return;
      if (state == BluetoothConnectionState.connected) {
        _connectedDeviceBg = deviceToConnect;
        _isConnecting = false;
        _reconnectTimer?.cancel();
        _reconnectTimer = null;
        String name = deviceToConnect.platformName.isNotEmpty ? deviceToConnect
            .platformName : "Smart Cane";
        _updateNotification(content: 'Connected to $name.');
        _serviceInstanceBg?.invoke(backgroundServiceConnectionUpdateEvent, {
          'connected': true,
          'deviceId': deviceToConnect.remoteId.str,
          'deviceName': name,
        });
        await _discoverServicesBg(deviceToConnect);
      } else if (state == BluetoothConnectionState.disconnected) {
        // Only handle if this was the device we were connected to, or trying to connect to
        if (_connectedDeviceBg?.remoteId == deviceToConnect.remoteId ||
            _targetDeviceId == deviceToConnect.remoteId.str) {
          _connectedDeviceBg = null;
          _isConnecting = false; // Ensure this is reset
          await _fallSubscriptionBg?.cancel();
          _fallSubscriptionBg = null;
          await _batterySubscriptionBg?.cancel();
          _batterySubscriptionBg = null;
          await _calibrationStatusSubscriptionBg?.cancel();
          _calibrationStatusSubscriptionBg = null;
          _serviceInstanceBg?.invoke(backgroundServiceConnectionUpdateEvent, {
            'connected': false,
            'deviceId': deviceToConnect.remoteId.str,
            'deviceName': null,
          });
          _updateNotification(content: 'Disconnected. Reconnecting...');
          if (!_isStopping) _scheduleReconnect();
        }
      }
    });

    await deviceToConnect.connect(
      autoConnect: false, // We manage reconnects
      timeout: const Duration(seconds: 25),
    );
  } catch (e) {
    _isConnecting = false;
    _updateNotification(content: 'Connection error. Retrying...');
    if (!_isStopping) _scheduleReconnect();
  }
}

Future<void> _discoverServicesBg(BluetoothDevice device) async {
  if (_serviceInstanceBg == null || _isStopping) return;
  try {
    List<BluetoothService> services = await device.discoverServices(
        timeout: 20);
    for (BluetoothService s in services) {
      if (s.uuid.str.toUpperCase() == SMART_CANE_SERVICE_UUID.toUpperCase()) {
        for (BluetoothCharacteristic c in s.characteristics) {
          String charUuid = c.uuid.str.toUpperCase();
          if (charUuid == FALL_CHARACTERISTIC_UUID.toUpperCase() &&
              c.properties.notify) {
            await _subscribeBg(c, _handleFallDetectionBg);
          } else if (charUuid == BATTERY_CHARACTERISTIC_UUID.toUpperCase() &&
              c.properties.notify) {
            await _subscribeBg(c, _handleBatteryLevelBg);
          } else if (charUuid == CALIBRATION_STATUS_UUID.toUpperCase() &&
              c.properties.notify) {
            await _subscribeBg(c, _handleCalibrationStatusBg);
          }
        }
        return;
      }
    }
    await _disconnectBg(); // Disconnect if service not found
  } catch (e) {
    await _disconnectBg();
  }
}

Future<void> _subscribeBg(BluetoothCharacteristic c,
    Function(List<int>) handler) async {
  StreamSubscription<List<int>>? subscription;
  if (c.uuid.str.toUpperCase() == FALL_CHARACTERISTIC_UUID.toUpperCase()) {
    subscription = _fallSubscriptionBg;
  } else
  if (c.uuid.str.toUpperCase() == BATTERY_CHARACTERISTIC_UUID.toUpperCase()) {
    subscription = _batterySubscriptionBg;
  } else
  if (c.uuid.str.toUpperCase() == CALIBRATION_STATUS_UUID.toUpperCase()) {
    subscription = _calibrationStatusSubscriptionBg;
  }

  await subscription?.cancel();
  try {
    if (!c.isNotifying) await c.setNotifyValue(true); // Ensure CCCD is written
    subscription = c.onValueReceived.listen(handler, onError: (e) {
      // If subscription fails, consider it a disconnect and try to reconnect
      _disconnectBg(); // This will trigger a reconnect if appropriate
    });

    if (c.uuid.str.toUpperCase() == FALL_CHARACTERISTIC_UUID.toUpperCase()) {
      _fallSubscriptionBg = subscription;
    } else
    if (c.uuid.str.toUpperCase() == BATTERY_CHARACTERISTIC_UUID.toUpperCase()) {
      _batterySubscriptionBg = subscription;
    } else
    if (c.uuid.str.toUpperCase() == CALIBRATION_STATUS_UUID.toUpperCase()) {
      _calibrationStatusSubscriptionBg = subscription;
    }
  } catch (e) {
    /* Failed to subscribe */
  }
}

void _handleFallDetectionBg(List<int> value) async {
  if (value.isNotEmpty && value[0] == 1 && !_isBgFallHandlingInProgress) {
    _isBgFallHandlingInProgress = true; // Set BG service's own flag
    print(
        "BG Service: !!! FALL DETECTED !!! Invoking UI trigger & Setting SP flag.");
    final prefs = await SharedPreferences.getInstance();
    // Set a flag that main.dart can check if it was launched due to this
    await prefs.setBool('fall_pending_alert', true);
    _reconnectTimer?.cancel();
    _reconnectTimer = null; // Stop trying to reconnect during fall

    _serviceInstanceBg?.invoke(triggerFallAlertUIEvent); // Signal main.dart

    _fallResetTimerBg?.cancel();
    _fallResetTimerBg =
        Timer(const Duration(seconds: 90), () async { // Failsafe timer
          if (_isBgFallHandlingInProgress) {
            print(
                "BG Service: Failsafe timer - Resetting BG fall handling flag.");
            _isBgFallHandlingInProgress = false;
            await prefs.remove('fall_pending_alert');
            // If still disconnected and not stopping, attempt reconnect
        if (_connectedDeviceBg == null && _targetDeviceId != null &&
            !_isConnecting && !_isStopping) {
          _connectToTargetDevice();
        }
      }
    });
  }
}

void _handleBatteryLevelBg(List<int> value) {
  if (value.isNotEmpty) {
    int level = value[0];
    // Update notification if battery is low
    if (level < 20 && _connectedDeviceBg != null) {
      String name = _connectedDeviceBg!.platformName.isNotEmpty
          ? _connectedDeviceBg!.platformName
          : "Smart Cane";
      _updateNotification(content: 'Connected to $name. LOW BATTERY: $level%');
    } else if (_connectedDeviceBg != null) {
      String name = _connectedDeviceBg!.platformName.isNotEmpty
          ? _connectedDeviceBg!.platformName
          : "Smart Cane";
      _updateNotification(content: 'Connected to $name.');
    }
  }
}

void _handleCalibrationStatusBg(List<int> value) {
  // Background service doesn't need to act on calibration status directly,
  // but good to log or handle if there's a BG specific need.
  if (value.isNotEmpty) {
    print("BG Service: Received Calibration Status from BLE: ${value[0]}");
  }
}