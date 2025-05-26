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
const String backgroundServiceConnectionUpdateEvent =
    "backgroundConnectionUpdate";
const String resetFallHandlingEvent = "resetFallHandling"; // New event to reset the flag


// --- Background State ---
BluetoothDevice? _connectedDeviceBg;
StreamSubscription<BluetoothConnectionState>? _connectionStateSubscriptionBg;
StreamSubscription<List<int>>? _fallSubscriptionBg;
Timer? _reconnectTimer;
bool _isFallHandlingInProgress = false;
String? _targetDeviceId;
bool _isConnecting = false;
ServiceInstance? _serviceInstance;
Timer? _fallResetTimer; // Explicit timer for failsafe reset


@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  _serviceInstance = service;
  print("BG Service: Starting (onStart invoked).");

  service.on(bgServiceStopEvent).listen((event) async {
    print("BG Service: Received stop event.");
    await _disconnectBg();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(bgServiceDeviceIdKey);
    _targetDeviceId = null;
    _isFallHandlingInProgress = false; // Ensure flag is reset on stop
    _fallResetTimer?.cancel(); // Cancel timer on stop
    service.stopSelf();
    print("BG Service: Stopped self.");
  });

  service.on(bgServiceSetDeviceEvent).listen((event) async {
    final deviceId = event?['deviceId'] as String?;
    if (deviceId != null) {
      print("BG Service: Received device ID via event: $deviceId");
      bool needsReconnect = (_targetDeviceId != deviceId ||
          _connectedDeviceBg == null);
      _targetDeviceId = deviceId;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(bgServiceDeviceIdKey, deviceId);

      if (needsReconnect &&
          !_isFallHandlingInProgress) { // Only connect if not handling fall
        await _disconnectBg();
        _connectToTargetDevice();
      } else {
        print(
            "BG Service: Device ID $deviceId already set / connected / handling fall. No action needed.");
      }
    } else {
      print("BG Service: Received null deviceId. Clearing target.");
      await _disconnectBg();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(bgServiceDeviceIdKey);
      _targetDeviceId = null;
      _serviceInstance?.invoke(backgroundServiceConnectionUpdateEvent, {
        'connected': false, 'deviceId': null, 'deviceName': null,
      });
    }
  });

  service.on(resetFallHandlingEvent).listen((event) {
    print("BG Service: Received reset fall handling event from UI.");
    if (_isFallHandlingInProgress) {
      _isFallHandlingInProgress = false;
      _fallResetTimer?.cancel(); // Cancel the failsafe timer
      print("BG Service: Fall handling flag reset by UI.");
      // Check if we need to reconnect now that the fall is handled
      if (_connectedDeviceBg == null && _targetDeviceId != null &&
          !_isConnecting) {
        print("BG Service: Attempting reconnect after UI fall reset.");
        _connectToTargetDevice();
      }
    }
  });

  if (service is AndroidServiceInstance) {
    await service.setAsForegroundService();
    print("BG Service: Set as foreground service.");
  }

  final prefs = await SharedPreferences.getInstance();
  _targetDeviceId = prefs.getString(bgServiceDeviceIdKey);
  if (_targetDeviceId != null) {
    print(
        "BG Service: Found stored device ID: $_targetDeviceId. Attempting connect.");
    _connectToTargetDevice();
  } else {
    print("BG Service: No stored device ID. Waiting for UI event.");
    _serviceInstance?.invoke(backgroundServiceConnectionUpdateEvent, {
      'connected': false, 'deviceId': null, 'deviceName': null,
    });
  }

  Timer.periodic(const Duration(seconds: 35), (timer) async {
    bool isRunning = await FlutterBackgroundService().isRunning();
    if (!isRunning) {
      timer.cancel();
      print("BG Service: Heartbeat - Service stopped.");
      return;
    }
    print(
        "BG Service: Heartbeat - Target: $_targetDeviceId, Connected: ${_connectedDeviceBg
            ?.remoteId
            .str}, Connecting: $_isConnecting, FallHandling: $_isFallHandlingInProgress");
    if (_targetDeviceId != null && _connectedDeviceBg == null &&
        !_isConnecting && !_isFallHandlingInProgress &&
        _reconnectTimer == null) {
      print(
          "BG Service: Heartbeat - Not connected but should be. Attempting reconnect.");
      _connectToTargetDevice();
    }
  });
  print("BG Service: onStart completed.");
}

Future<void> _disconnectBg() async {
  print(
    "BG Service: Disconnecting background BLE. Current target: $_targetDeviceId",
  );
  _isConnecting = false;
  _reconnectTimer?.cancel();
  _reconnectTimer = null;

  // Cancel characteristic subscription before disconnecting device
  await _fallSubscriptionBg?.cancel();
  _fallSubscriptionBg = null;

  // Cancel connection state subscription AFTER device disconnect attempt or if it's already null
  StreamSubscription<BluetoothConnectionState>? tempConnectionSub =
      _connectionStateSubscriptionBg;
  _connectionStateSubscriptionBg = null; // Nullify before async gap

  if (_connectedDeviceBg != null) {
    try {
      await _connectedDeviceBg!.disconnect();
      print(
        "BG Service: Disconnected from ${_connectedDeviceBg!.remoteId.str}",
      );
    } catch (e) {
      print("BG Service: Error during explicit disconnect: $e");
    }
  }
  await tempConnectionSub?.cancel(); // Now cancel the subscription
  _connectedDeviceBg = null;

  // Always invoke update after attempts to disconnect
  _serviceInstance?.invoke(backgroundServiceConnectionUpdateEvent, {
    'connected': false,
    'deviceId': _targetDeviceId,
    'deviceName': null,
  });
}

void _scheduleReconnect() {
  if (_isFallHandlingInProgress ||
      _targetDeviceId == null ||
      _serviceInstance == null) {
    print(
      "BG Service: Reconnect skipped (fallInProgress: $_isFallHandlingInProgress, noTarget: ${_targetDeviceId == null}, serviceNull: ${_serviceInstance == null}).",
    );
    return;
  }
  _reconnectTimer?.cancel();
  print(
    "BG Service: Scheduling reconnect in 20 seconds for $_targetDeviceId.",
  ); // Shorter reconnect
  _reconnectTimer = Timer(const Duration(seconds: 20), () {
    _reconnectTimer = null;
    print("BG Service: Reconnect timer fired for $_targetDeviceId.");
    _connectToTargetDevice();
  });
}

BluetoothDevice? _findDeviceInList(List<BluetoothDevice> devices, String id) {
  for (var d in devices) {
    if (d.remoteId.str == id) return d;
  }
  return null;
}

Future<void> _connectToTargetDevice() async {
  if (_serviceInstance == null) {
    print("BG Service: Connect skipped, service instance null.");
    return;
  }
  if (_isConnecting ||
      _connectedDeviceBg != null ||
      _isFallHandlingInProgress ||
      _targetDeviceId == null) {
    print(
      "BG Service: Connect skipped (isConnecting: $_isConnecting, isConnected: ${_connectedDeviceBg != null}, handlingFall: $_isFallHandlingInProgress, noTarget: ${_targetDeviceId == null}).",
    );
    if (_isConnecting && _targetDeviceId != null) {
      print("BG Service: Already attempting to connect to $_targetDeviceId");
    }
    return;
  }
  _isConnecting = true;
  _reconnectTimer?.cancel();
  print("BG Service: Connecting to $_targetDeviceId...");

  try {
    var adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      print("BG Service: Bluetooth is OFF.");
      _isConnecting = false;
      _scheduleReconnect();
      return;
    }

    BluetoothDevice? targetDevice;
    List<BluetoothDevice> bonded = await FlutterBluePlus.bondedDevices;
    targetDevice = _findDeviceInList(bonded, _targetDeviceId!);
    if (targetDevice == null) {
      List<BluetoothDevice> system = await FlutterBluePlus.systemDevices([]);
      targetDevice = _findDeviceInList(system, _targetDeviceId!);
    }
    if (targetDevice == null) {
      print(
        "BG Service: Device not bonded/system for $_targetDeviceId. Starting scan...",
      );
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 7),
        androidScanMode: AndroidScanMode.lowLatency,
      );
      await for (List<ScanResult> results in FlutterBluePlus.scanResults) {
        for (ScanResult r in results) {
          if (r.device.remoteId.str == _targetDeviceId) {
            targetDevice = r.device;
            print("BG Service: Found device $_targetDeviceId via scan.");
            await FlutterBluePlus.stopScan();
            break;
          }
        }
        if (targetDevice != null) break;
      }
      if (!await FlutterBluePlus.isScanningNow && targetDevice == null) {
        // Check if scan ended
        print(
          "BG Service: Scan ended, device $_targetDeviceId not found via scan.",
        );
      }
      await FlutterBluePlus.stopScan(); // Ensure scan is stopped
    }

    if (targetDevice == null) {
      print(
        "BG Service: Device $_targetDeviceId not found. Scheduling reconnect.",
      );
      _isConnecting = false;
      _scheduleReconnect();
      return;
    }

    final deviceToConnect =
        targetDevice; // Use a final variable for safety in listener

    _connectionStateSubscriptionBg = deviceToConnect.connectionState.listen((
      state,
    ) async {
      print(
        "BG Service: Device ${deviceToConnect.remoteId.str} connection state: $state",
      );
      if (state == BluetoothConnectionState.connected) {
        _connectedDeviceBg =
            deviceToConnect; // Assign the successfully connected device
        _isConnecting = false;
        await _discoverServicesBg(deviceToConnect);
        _reconnectTimer?.cancel();
        _reconnectTimer = null;
        // **FIX**: Use deviceToConnect here for accurate name
        _serviceInstance?.invoke(backgroundServiceConnectionUpdateEvent, {
          'connected': true,
          'deviceId': deviceToConnect.remoteId.str,
          'deviceName':
              deviceToConnect.platformName.isNotEmpty
                  ? deviceToConnect.platformName
                  : "Smart Cane",
        });
      } else if (state == BluetoothConnectionState.disconnected) {
        bool wasThisDeviceConnected =
            _connectedDeviceBg?.remoteId.str == deviceToConnect.remoteId.str;
        if (wasThisDeviceConnected) {
          _connectedDeviceBg = null; // Clear if it was this device
        }
        _isConnecting = false;
        await _fallSubscriptionBg?.cancel();
        _fallSubscriptionBg = null;

        if (wasThisDeviceConnected) {
          // Only invoke if it was this device that disconnected
          _serviceInstance?.invoke(backgroundServiceConnectionUpdateEvent, {
            'connected': false,
            'deviceId': deviceToConnect.remoteId.str,
            // Send ID of device that disconnected
            'deviceName': null,
          });
        }
        // Only schedule reconnect if this disconnect pertains to the current target device
        if (_targetDeviceId == deviceToConnect.remoteId.str) {
          _scheduleReconnect();
        }
      }
    });
    await deviceToConnect.connect(
      autoConnect: false,
      timeout: const Duration(seconds: 20),
    );
  } catch (e, s) {
    print(
      "BG Service: Error during connection/scan for $_targetDeviceId: $e\n$s",
    );
    _isConnecting = false;
    _scheduleReconnect();
  }
}

Future<void> _discoverServicesBg(BluetoothDevice device) async {
  if (_serviceInstance == null) {
    print("BG Service: Discover skipped, service instance null.");
    return;
  }
  print("BG Service: Discovering services for ${device.remoteId.str}");
  try {
    List<BluetoothService> services = await device.discoverServices(
      timeout: 15,
    ); // Added timeout
    for (BluetoothService s in services) {
      if (s.uuid.str.toUpperCase() == SMART_CANE_SERVICE_UUID.toUpperCase()) {
        for (BluetoothCharacteristic c in s.characteristics) {
          if (c.uuid.str.toUpperCase() ==
              FALL_CHARACTERISTIC_UUID.toUpperCase()) {
            print(
              "BG Service: Found Fall Characteristic for ${device.remoteId.str}. Subscribing...",
            );
            if (!c.isNotifying)
              await c.setNotifyValue(true); // Ensure notify is true
            _fallSubscriptionBg = c.onValueReceived.listen((value) {
              _handleFallDetection(value, _serviceInstance!);
            });
            return;
          }
        }
      }
    }
    print(
      "BG Service: Fall characteristic not found for ${device.remoteId.str}. Disconnecting.",
    );
    await _disconnectBg();
  } catch (e, s) {
    print(
      "BG Service: Error discovering services for ${device.remoteId.str}: $e\n$s",
    );
    await _disconnectBg();
  }
}

void _handleFallDetection(List<int> value, ServiceInstance service) async {
  // <-- Make async
  if (value.isNotEmpty && value[0] == 1 && !_isFallHandlingInProgress) {
    _isFallHandlingInProgress = true;
    print(
        "BG Service: !!! FALL DETECTED on $_targetDeviceId !!! Invoking UI event & setting flag.");

    // --- ADD THIS ---
    // Set a flag in SharedPreferences so the app knows it needs to show the overlay on launch
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('fall_pending_alert', true); // THIS IS CRUCIAL
    // --------------

    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    service.invoke(
        triggerFallAlertUIEvent); // This will trigger the notification in main.dart

    _fallResetTimer?.cancel();
    _fallResetTimer = Timer(const Duration(seconds: 90), () {
      if (_isFallHandlingInProgress) {
        print("BG Service: Failsafe timer - Resetting fall handling flag.");
        _isFallHandlingInProgress = false;
        // Also clear the SharedPreferences flag as a failsafe
        prefs.remove('fall_pending_alert');
        if (_connectedDeviceBg == null && _targetDeviceId != null &&
            !_isConnecting) {
          print("BG Service: Attempting reconnect after failsafe timer.");
          _connectToTargetDevice();
        }
      }
    });
  }
}
