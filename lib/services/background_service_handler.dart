// lib/services/background_service_handler.dart
import 'dart:async';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_cane_prototype/services/ble_service.dart'; // For UUIDs & constants

// --- Constants ---
const String notificationChannelId = 'smart_cane_foreground_service';
const String notificationChannelName = 'Smart Cane Background Service';
const int notificationId = 888;
const String bgServiceDeviceIdKey = 'bg_service_device_id';

// --- Service Events ---
const String bgServiceStopEvent = "stopService";
const String bgServiceSetDeviceEvent = "setDevice";
const String triggerFallAlertUIEvent = "triggerFallAlertUI";
const String backgroundServiceConnectionUpdateEvent = "backgroundConnectionUpdate";
const String resetFallHandlingEvent = "resetFallHandling";

// --- Background State ---
BluetoothDevice? _connectedDeviceBg;
StreamSubscription<BluetoothConnectionState>? _connectionStateSubscriptionBg;
StreamSubscription<List<int>>? _fallSubscriptionBg;
StreamSubscription<List<int>>? _batterySubscriptionBg; // Added for battery
StreamSubscription<
    List<int>>? _calibrationStatusSubscriptionBg; // Added for calibration
Timer? _reconnectTimer;
bool _isFallHandlingInProgress = false;
String? _targetDeviceId;
bool _isConnecting = false;
ServiceInstance? _serviceInstance;
Timer? _fallResetTimer;
bool _isStopping = false; // Flag to prevent reconnect during stop

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  // DartPluginRegistrant.ensureInitialized(); // Crucial for background isolates
  _serviceInstance = service;
  _isStopping = false;
  print("BG Service: Starting (onStart invoked).");

  service.on(bgServiceStopEvent).listen((event) async {
    print("BG Service: Received stop event.");
    _isStopping = true; // Set stopping flag
    await _disconnectBg(clearTarget: true); // Disconnect and clear target
    _targetDeviceId = null;
    _isFallHandlingInProgress = false;
    _fallResetTimer?.cancel();
    service.stopSelf();
    print("BG Service: Stopped self.");
  });

  service.on(bgServiceSetDeviceEvent).listen((event) async {
    if (_isStopping) return; // Ignore if stopping
    final deviceId = event?['deviceId'] as String?;
    print("BG Service: Received device ID via event: $deviceId");
    if (deviceId != null && deviceId != _targetDeviceId) {
      print("BG Service: New target $deviceId. Resetting connection.");
      _targetDeviceId = deviceId;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(bgServiceDeviceIdKey, deviceId);
      await _disconnectBg(clearTarget: false); // Disconnect but keep new target
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
    } else {
      print(
          "BG Service: Device ID $deviceId already set/connected. No action.");
    }
  });

  service.on(resetFallHandlingEvent).listen((event) {
    print("BG Service: Received reset fall handling event from UI.");
    if (_isFallHandlingInProgress) {
      _isFallHandlingInProgress = false;
      _fallResetTimer?.cancel();
      print("BG Service: Fall handling flag reset by UI.");
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

  // --- Initial Setup ---
  final prefs = await SharedPreferences.getInstance();
  _targetDeviceId = prefs.getString(bgServiceDeviceIdKey);
  print("BG Service: Initial Target Device ID: $_targetDeviceId");

  if (_targetDeviceId != null) {
    print("BG Service: Found stored device ID. Attempting connect.");
    _updateNotification(content: 'Connecting to Smart Cane...');
    _connectToTargetDevice();
  } else {
    print("BG Service: No stored device ID. Stopping self.");
    _isStopping = true;
    service.stopSelf();
    return; // Exit if no target
  }

  // --- Heartbeat / Reconnect Timer ---
  Timer.periodic(
      const Duration(seconds: 25), (timer) async { // Slightly shorter
    if (_isStopping || _serviceInstance == null) {
      timer.cancel();
      print("BG Service: Heartbeat - Service stopped or instance null.");
      return;
    }
    print(
        "BG Service: Heartbeat - Target: $_targetDeviceId, Connected: ${_connectedDeviceBg
            ?.remoteId
            .str}, Connecting: $_isConnecting, FallHandling: $_isFallHandlingInProgress");
    if (_targetDeviceId != null && _connectedDeviceBg == null &&
        !_isConnecting && !_isFallHandlingInProgress) {
      print("BG Service: Heartbeat - Not connected. Attempting reconnect.");
      _connectToTargetDevice();
    }
  });
  print("BG Service: onStart completed.");
}


void _updateNotification(
    {required String content, String title = 'Smart Cane Service'}) {
  final service = _serviceInstance; // Use a local variable for null-safety
  // Check if the service is not null AND it's an AndroidServiceInstance
  if (service is AndroidServiceInstance) {
    // If it is, cast it and call the method
    service.setForegroundNotificationInfo(
      title: title,
      content: content,
    );
  } else {
    // Optional: Log if not Android or service is null
    print(
        "BG Service: Cannot update notification (Not Android or service is null).");
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
  _connectionStateSubscriptionBg = null;

  if (_connectedDeviceBg != null) {
    try {
      await _connectedDeviceBg!.disconnect();
      print(
          "BG Service: Disconnected from ${_connectedDeviceBg!.remoteId.str}");
    } catch (e) {
      print("BG Service: Error during disconnect: $e");
    }
  }
  await tempConnectionSub?.cancel();
  _connectedDeviceBg = null;

  if (clearTarget) {
    _targetDeviceId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(bgServiceDeviceIdKey);
  }

  _serviceInstance?.invoke(backgroundServiceConnectionUpdateEvent, {
    'connected': false, 'deviceId': _targetDeviceId, 'deviceName': null,
  });
  _updateNotification(content: 'Disconnected. Waiting...');
}

void _scheduleReconnect() {
  if (_isFallHandlingInProgress || _targetDeviceId == null ||
      _serviceInstance == null || _isConnecting || _isStopping) {
    print(
        "BG Service: Reconnect skipped (fall/noTarget/noService/connecting/stopping).");
    return;
  }
  _reconnectTimer?.cancel();
  print("BG Service: Scheduling reconnect in 15 seconds for $_targetDeviceId.");
  _reconnectTimer = Timer(const Duration(seconds: 15), () { // Shorter duration
    _reconnectTimer = null;
    if (_isStopping || _isConnecting || _connectedDeviceBg != null) {
      print("BG Service: Reconnect timer fired, but state changed. Aborting.");
      return;
    }
    print("BG Service: Reconnect timer fired for $_targetDeviceId.");
    _connectToTargetDevice();
  });
}

BluetoothDevice? _findDeviceInList(List<BluetoothDevice> devices, String id) {
  try {
    return devices.firstWhere((d) => d.remoteId.str == id);
  } catch (e) {
    return null; // Not found
  }
}

Future<void> _connectToTargetDevice() async {
  if (_serviceInstance == null || _isConnecting || _connectedDeviceBg != null ||
      _isFallHandlingInProgress || _targetDeviceId == null || _isStopping) {
    print("BG Service: Connect skipped (state check failed).");
    return;
  }
  _isConnecting = true;
  _reconnectTimer?.cancel();
  _updateNotification(content: 'Connecting to $_targetDeviceId...');
  print("BG Service: Connecting to $_targetDeviceId...");

  try {
    var adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      print("BG Service: Bluetooth is OFF.");
      _isConnecting = false;
      _updateNotification(content: 'Bluetooth is off. Waiting...');
      _scheduleReconnect();
      return;
    }

    BluetoothDevice? targetDevice;
    List<BluetoothDevice> system = await FlutterBluePlus.systemDevices([]);
    targetDevice = _findDeviceInList(system, _targetDeviceId!);

    if (targetDevice == null) {
      print("BG Service: $_targetDeviceId not in system list. Scanning...");
      _updateNotification(content: 'Scanning for $_targetDeviceId...');
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 10), // Increased scan time
        androidScanMode: AndroidScanMode.lowLatency,
      );
      // Wait for scan results
      await for (List<ScanResult> results in FlutterBluePlus.scanResults) {
        for (ScanResult r in results) {
          if (r.device.remoteId.str == _targetDeviceId) {
            targetDevice = r.device;
            print("BG Service: Found $_targetDeviceId via scan.");
            await FlutterBluePlus.stopScan();
            break;
          }
        }
        if (targetDevice != null) break;
      }
      await FlutterBluePlus.stopScan(); // Ensure stopped
    }


    if (targetDevice == null) {
      print(
          "BG Service: Device $_targetDeviceId not found. Scheduling reconnect.");
      _updateNotification(content: 'Cane not found. Retrying soon...');
      _isConnecting = false;
      _scheduleReconnect();
      return;
    }

    final deviceToConnect = targetDevice;

    _connectionStateSubscriptionBg?.cancel(); // Cancel previous if any
    _connectionStateSubscriptionBg =
        deviceToConnect.connectionState.listen((state) async {
          if (_isStopping) return; // Ignore if stopping

          print("BG Service: ${deviceToConnect.remoteId.str} state: $state");

      if (state == BluetoothConnectionState.connected) {
        _connectedDeviceBg = deviceToConnect;
        _isConnecting = false;
        _reconnectTimer?.cancel();
        _reconnectTimer = null;
        String name = deviceToConnect.platformName.isNotEmpty ? deviceToConnect
            .platformName : "Smart Cane";
        print(
            "BG Service: Connected to $name (${deviceToConnect.remoteId.str})");
        _updateNotification(content: 'Connected to $name.');
        _serviceInstance?.invoke(backgroundServiceConnectionUpdateEvent, {
          'connected': true,
          'deviceId': deviceToConnect.remoteId.str,
          'deviceName': name,
        });
        await _discoverServicesBg(deviceToConnect);
      } else if (state == BluetoothConnectionState.disconnected) {
        print("BG Service: Disconnected from ${deviceToConnect.remoteId.str}.");
        _connectedDeviceBg = null;
        _isConnecting = false;
        await _fallSubscriptionBg?.cancel();
        _fallSubscriptionBg = null;
        await _batterySubscriptionBg?.cancel();
        _batterySubscriptionBg = null;
        await _calibrationStatusSubscriptionBg?.cancel();
        _calibrationStatusSubscriptionBg = null;

        _serviceInstance?.invoke(backgroundServiceConnectionUpdateEvent, {
          'connected': false,
          'deviceId': deviceToConnect.remoteId.str,
          'deviceName': null,
        });
        _updateNotification(content: 'Disconnected. Reconnecting...');
        if (!_isStopping) _scheduleReconnect(); // Only reconnect if not stopping
      }
    });

    await deviceToConnect.connect(
      autoConnect: false, // Important: We manage reconnects
      timeout: const Duration(seconds: 25), // Longer timeout
    );

  } catch (e, s) {
    print("BG Service: Error during connection/scan: $e\n$s");
    _isConnecting = false;
    _updateNotification(content: 'Connection error. Retrying...');
    _scheduleReconnect();
  }
}

Future<void> _discoverServicesBg(BluetoothDevice device) async {
  if (_serviceInstance == null || _isStopping) return;
  print("BG Service: Discovering services for ${device.remoteId.str}");
  try {
    List<BluetoothService> services = await device.discoverServices(
        timeout: 20);
    for (BluetoothService s in services) {
      if (s.uuid.str.toUpperCase() == SMART_CANE_SERVICE_UUID.toUpperCase()) {
        print("BG Service: Found Smart Cane Service.");
        for (BluetoothCharacteristic c in s.characteristics) {
          String charUuid = c.uuid.str.toUpperCase();
          if (charUuid == FALL_CHARACTERISTIC_UUID.toUpperCase() &&
              c.properties.notify) {
            print("BG Service: Found Fall Characteristic. Subscribing...");
            await _subscribeBg(c, _handleFallDetection);
          } else if (charUuid == BATTERY_CHARACTERISTIC_UUID.toUpperCase() &&
              c.properties.notify) {
            print("BG Service: Found Battery Characteristic. Subscribing...");
            await _subscribeBg(c, _handleBatteryLevel); // Subscribe to battery
          } else if (charUuid == CALIBRATION_STATUS_UUID.toUpperCase() &&
              c.properties.notify) {
            print("BG Service: Found Calibration Status. Subscribing...");
            await _subscribeBg(
                c, _handleCalibrationStatus); // Subscribe to calibration
          }
        }
        return; // Exit after finding the service
      }
    }
    print("BG Service: Smart Cane Service not found. Disconnecting.");
    await _disconnectBg();
  } catch (e, s) {
    print("BG Service: Error discovering services: $e\n$s");
    await _disconnectBg(); // Disconnect on error
  }
}

Future<void> _subscribeBg(BluetoothCharacteristic c,
    Function(List<int>) handler) async {
  StreamSubscription<List<int>>? subscription;
  // Store subscriptions based on UUID to avoid duplicates and manage them
  if (c.uuid.str.toUpperCase() == FALL_CHARACTERISTIC_UUID.toUpperCase()) {
    subscription = _fallSubscriptionBg;
  } else
  if (c.uuid.str.toUpperCase() == BATTERY_CHARACTERISTIC_UUID.toUpperCase()) {
    subscription = _batterySubscriptionBg;
  } else
  if (c.uuid.str.toUpperCase() == CALIBRATION_STATUS_UUID.toUpperCase()) {
    subscription = _calibrationStatusSubscriptionBg;
  }

  await subscription?.cancel(); // Cancel any existing before re-subscribing
  try {
    if (!c.isNotifying) await c.setNotifyValue(true);
    subscription = c.onValueReceived.listen(handler, onError: (e) {
      print("BG Service: Error on ${c.uuid}: $e");
      // Consider handling errors, maybe trigger reconnect.
    });
    print("BG Service: Subscribed to ${c.uuid.str}");

    // Update the state variables with the new subscription
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
    print("BG Service: Failed to subscribe to ${c.uuid}: $e");
  }
}


void _handleFallDetection(List<int> value) async {
  if (value.isNotEmpty && value[0] == 1 && !_isFallHandlingInProgress) {
    _isFallHandlingInProgress = true;
    print("BG Service: !!! FALL DETECTED !!! Invoking UI & Setting flag.");
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('fall_pending_alert', true);
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _serviceInstance?.invoke(triggerFallAlertUIEvent);

    _fallResetTimer?.cancel();
    _fallResetTimer = Timer(const Duration(seconds: 90), () {
      if (_isFallHandlingInProgress) {
        print("BG Service: Failsafe timer - Resetting fall handling.");
        _isFallHandlingInProgress = false;
        prefs.remove('fall_pending_alert');
        if (_connectedDeviceBg == null && _targetDeviceId != null &&
            !_isConnecting && !_isStopping) {
          _connectToTargetDevice();
        }
      }
    });
  }
}

void _handleBatteryLevel(List<int> value) {
  if (value.isNotEmpty) {
    int level = value[0];
    print("BG Service: Received Battery Level: $level%");
    // You could potentially invoke an event to the UI if needed,
    // but BleService also listens, so it might be redundant unless
    // you want BG-specific logic.
    // For now, just update the notification if low.
    if (level < 20) {
      _updateNotification(content: 'Connected. LOW BATTERY: $level%');
    }
  }
}

void _handleCalibrationStatus(List<int> value) {
  if (value.isNotEmpty) {
    print("BG Service: Received Calibration Status: ${value[0]}");
    // Handle calibration status updates if needed in the background.
  }
}