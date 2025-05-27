// lib/screens/home_screen.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart'; // <-- ADD THIS
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_cane_prototype/main.dart';
import 'package:smart_cane_prototype/services/background_service_handler.dart'; // <-- ADD THIS
import 'package:smart_cane_prototype/services/ble_service.dart';
import 'package:smart_cane_prototype/services/permission_service.dart';
import 'package:smart_cane_prototype/utils/app_theme.dart';
import 'package:smart_cane_prototype/widgets/fall_detection_overlay.dart';

class HomeScreen extends StatefulWidget {
  final bool launchedFromFall;

  const HomeScreen({super.key, this.launchedFromFall = false});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final BleService _bleService = BleService();

  BleConnectionState _uiBleConnectionState = BleConnectionState.disconnected;
  BluetoothDevice? _uiConnectedDevice;
  List<ScanResult> _uiScanResults = [];
  int? _uiBatteryLevel;
  bool _uiFallDetectedState = false;
  CalibrationState _uiCalibrationStatus = CalibrationState.idle;

  String? _backgroundConnectedDeviceId;
  String? _backgroundConnectedDeviceName;
  bool _isBgServiceConnected = false;

  StreamSubscription<BleConnectionState>? _bleConnectionStateSubscription;
  StreamSubscription<List<ScanResult>>? _bleScanResultsSubscription;
  StreamSubscription<int?>? _bleBatteryLevelSubscription;
  StreamSubscription<bool>? _bleFallDetectedSubscription;
  StreamSubscription<BluetoothDevice?>? _bleConnectedDeviceSubscription;
  StreamSubscription<CalibrationState>? _bleCalibrationStatusSubscription;
  StreamSubscription<Map<String, dynamic>>? _backgroundConnectionSubscription;
  StreamSubscription<bool>? _nativeFallSubscriptionHomeScreen;
  StreamSubscription<bool>? _fallAlertSubscriptionHomeScreen;

  bool _isFallOverlayVisible = false;
  bool _isBackgroundServiceRunning = false;
  bool _isBackgroundToggleEnabled = false;
  bool _initialFallCheckDone = false;

  @override
  void initState() {
    super.initState();
    print("HomeScreen: initState. Props: launchedFromFall=${widget
        .launchedFromFall}");

    _uiBleConnectionState = _bleService.getCurrentConnectionState();
    _uiConnectedDevice = _bleService.getConnectedDevice();

    _fallAlertSubscriptionHomeScreen = onFallAlertTriggered.listen((isFall) {
      if (isFall && mounted && !_isFallOverlayVisible) {
        print("HomeScreen: Fall alert stream received. Showing overlay.");
        _showFallDetectionOverlay();
      }
    });


    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      bool permissionsGranted = await PermissionService.requestAllPermissions(
          context);

      if (!permissionsGranted && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text(
            "Warning: Not all permissions granted. App may not function fully."),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 5),),);
      }

      if (!_initialFallCheckDone) {
        _initialFallCheckDone = true;
        final arguments = ModalRoute
            .of(context)
            ?.settings
            .arguments as Map?;
        bool argumentIndicatesFall = arguments?['fallDetected'] == true;
        print("HomeScreen: PostFrame: launchedFromFall=${widget
            .launchedFromFall}, argumentIndicatesFall=$argumentIndicatesFall, overlayVisible=$_isFallOverlayVisible");
      }

      if (widget.launchedFromFall && !_isFallOverlayVisible) {
        print(
            "HomeScreen: PostFrame: launchedFromFall is true. Showing overlay.");
        _showFallDetectionOverlay();
      }

      _initializeUiBleAndMaybeScan();
      await _syncWithBackgroundServiceState();
    });

    _bleConnectionStateSubscription =
        _bleService.connectionStateStream.listen((state) {
      if (!mounted) return;
      setState(() {
        _uiBleConnectionState = state;
        if (state != BleConnectionState.connected) {
          if (_uiConnectedDevice?.remoteId.str !=
              _backgroundConnectedDeviceId) {
            _uiConnectedDevice = null;
          }
        }
        if (state == BleConnectionState.noPermissions) print(
            "HomeScreen: UI BLE Service reports no permissions.");
        _updateBackgroundToggleAndUiDisplay();
      });
        });

    _bleScanResultsSubscription =
        _bleService.scanResultsStream.listen((results) {
      if (!mounted) return;
      if (_uiBleConnectionState == BleConnectionState.scanning ||
          (_uiBleConnectionState == BleConnectionState.scanStopped &&
              results.isNotEmpty)) {
        setState(() =>
        _uiScanResults =
            results.where((r) => r.device.platformName.isNotEmpty).toList());
      } else if (_uiScanResults.isNotEmpty &&
          _uiBleConnectionState != BleConnectionState.scanning) {
        setState(() => _uiScanResults = []);
      }
        });
    _bleBatteryLevelSubscription =
        _bleService.batteryLevelStream.listen((level) {
          if (mounted) setState(() => _uiBatteryLevel = level);
        });
    _bleFallDetectedSubscription =
        _bleService.fallDetectedStream.listen((detected) {
      if (!mounted) return;
      if (detected == true && !_isFallOverlayVisible) {
        setState(() => _uiFallDetectedState = true);
        _showFallDetectionOverlay();
      } else if (!detected && _uiFallDetectedState) {
        setState(() => _uiFallDetectedState = false);
        if (_isFallOverlayVisible) _dismissFallDetectionOverlay();
      }
        });
    _bleConnectedDeviceSubscription =
        _bleService.connectedDeviceStream.listen((device) {
      if (!mounted) return;
      setState(() {
        _uiConnectedDevice = device;
        if (device == null &&
            _uiBleConnectionState == BleConnectionState.connected) {
          // If UI service explicitly disconnects, update overall state
          _uiBleConnectionState = BleConnectionState.disconnected;
        }
        _updateBackgroundToggleAndUiDisplay();
      });
        });
    _bleCalibrationStatusSubscription =
        _bleService.calibrationStatusStream.listen((status) {
          if (!mounted) return;
          setState(() => _uiCalibrationStatus = status);
          if (status == CalibrationState.success && mounted)
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text("Cane calibrated successfully!"),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 3),));
          else
          if (status == CalibrationState.failed && mounted) ScaffoldMessenger
              .of(context).showSnackBar(const SnackBar(
            content: Text("Cane calibration failed."),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),));
        });

    _backgroundConnectionSubscription =
        onBackgroundConnectionUpdate.listen((update) {
          if (!mounted) return;
          print("HomeScreen: Received background connection update: $update");
          bool bgIsConnected = update['connected'] ?? false;
          String? bgDeviceId = update['deviceId'];
          String? bgDeviceName = update['deviceName'];

          setState(() {
            _isBgServiceConnected = bgIsConnected;
            if (bgIsConnected && bgDeviceId != null) {
              _backgroundConnectedDeviceId = bgDeviceId;
              _backgroundConnectedDeviceName = bgDeviceName;
              // If UI isn't already connected to this device, reflect BG's connection for display
              if (_uiConnectedDevice == null ||
                  _uiConnectedDevice!.remoteId.str != bgDeviceId) {
                _uiBleConnectionState =
                    BleConnectionState.connected; // Show connected state
                // _uiConnectedDevice is not set here directly to avoid conflict with UI's BleService object.
                // Build method will use _backgroundConnectedDeviceName/Id for display if _uiConnectedDevice is null/different.
              }
            } else { // BG is not connected or deviceId is null
              if (_backgroundConnectedDeviceId == bgDeviceId || bgDeviceId ==
                  null) { // If it's the same device disconnecting or a general disconnect
                _backgroundConnectedDeviceId = null;
                _backgroundConnectedDeviceName = null;
                // If the UI wasn't managing its own connection, set its state to disconnected
                if (_uiConnectedDevice == null &&
                    _uiBleConnectionState == BleConnectionState.connected) {
                  _uiBleConnectionState = BleConnectionState.disconnected;
                }
              }
            }
            _updateBackgroundToggleAndUiDisplay();
          });
        });
    print("HomeScreen: initState finished.");
  }

  Future<void> _syncWithBackgroundServiceState() async {
    final service = FlutterBackgroundService();
    bool isBgRunning = await service.isRunning();
    SharedPreferences prefs = await SharedPreferences.getInstance();
    // String? bgStoredTargetDeviceId = prefs.getString(bgServiceDeviceIdKey); // Not directly used for connection status here

    if (mounted) {
      setState(() {
        _isBackgroundServiceRunning = isBgRunning;
      });
      _updateBackgroundToggleAndUiDisplay();
      // If service is running, we could invoke an event to ask for its current connection details
      // e.g., service.invoke("getBackgroundConnectionStatus");
      // And the service would respond with a backgroundConnectionUpdateEvent
      // For now, we rely on the service sending updates on its own connect/disconnect events.
    }
  }

  void _updateBackgroundToggleAndUiDisplay() {
    if (!mounted) return;

    bool canEnableToggle = (_uiConnectedDevice != null &&
        _uiBleConnectionState == BleConnectionState.connected) ||
        (_isBgServiceConnected && _backgroundConnectedDeviceId != null);

    // The toggle should be enabled if there's ANY device context (either UI-managed or BG-managed)
    // that the background service could potentially monitor.
    // More simply: if UI is connected, it can be monitored.
    // If BG is already running and connected, toggle should reflect BG state.
    _isBackgroundToggleEnabled = _uiConnectedDevice != null ||
        (_isBackgroundServiceRunning && _backgroundConnectedDeviceId != null);


    // If UI connects to a device, and BG toggle is intended to be ON, ensure BG service targets this device.
    if (_uiBleConnectionState == BleConnectionState.connected &&
        _uiConnectedDevice != null && _isBackgroundServiceRunning) {
      if (_uiConnectedDevice!.remoteId.str != _backgroundConnectedDeviceId) {
        print("HomeScreen: UI connected to ${_uiConnectedDevice!.remoteId
            .str}, telling BG service to track it.");
        FlutterBackgroundService().invoke(bgServiceSetDeviceEvent,
            {'deviceId': _uiConnectedDevice!.remoteId.str});
      }
    }
    // If the service reports it's connected via background stream, ensure toggle is on
    if (_isBgServiceConnected && _backgroundConnectedDeviceId != null &&
        !_isBackgroundServiceRunning) {
      // setState(() => _isBackgroundServiceRunning = true); // This could cause loop if not careful
    }
  }

  Future<void> _initializeUiBleAndMaybeScan() async {
    await _bleService.initialize();
    if (!mounted) return;
    _updateBackgroundToggleAndUiDisplay();
    BleConnectionState initialStateAfterUiInit = _bleService
        .getCurrentConnectionState();
    if (initialStateAfterUiInit == BleConnectionState.disconnected ||
        initialStateAfterUiInit == BleConnectionState.scanStopped) {
      if (_bleService.getCurrentConnectionState() !=
          BleConnectionState.noPermissions) {
        _bleService.startBleScan();
      }
    }
  }

  void _showFallDetectionOverlay() {
    // Check the gate *first*
    if (!mounted || _isFallOverlayVisible) {
      print(
          "HomeScreen: Overlay show skipped. Mounted: $mounted, Visible: $_isFallOverlayVisible");
      return;
    }

    print("HomeScreen: SHOWING fall detection overlay.");
    // Set the flag *immediately* before pushing
    setState(() {
      _isFallOverlayVisible = true;
      _uiFallDetectedState = true;
    });

    // *** ADD THIS LINE ***
    flutterLocalNotificationsPlugin.cancel(fallNotificationId);
    print("HomeScreen: Cancelled fall notification ($fallNotificationId).");
    // *******************

    SharedPreferences.getInstance().then((prefs) =>
        prefs.remove('fall_pending_alert'));

    Navigator.of(context).push(
      PageRouteBuilder(
          opaque: false,
          pageBuilder: (context, animation, secondaryAnimation) => FallDetectionOverlay(
            initialCountdownSeconds: 30,
            onImOk: () {
              print("HomeScreen: 'I'm OK' tapped.");
              // Directly call the dismiss and reset logic
              _dismissAndResetOverlay();
            },
            onCallEmergency: () {
              print("HomeScreen: 'Call Emergency' tapped.");
              _bleService.makePhoneCall('+19058028483'); // Or your number
              // Directly call the dismiss and reset logic
              _dismissAndResetOverlay();
            },
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) =>
              FadeTransition(opacity: animation, child: child),
          transitionDuration: const Duration(milliseconds: 300)
      ),
    ).then((_) {
      // This .then() block now acts as a GUARANTEED cleanup,
      // especially for back-button presses or unexpected pops.
      print("HomeScreen: Overlay Navigator.push().then() executed.");
      if (mounted && _isFallOverlayVisible) {
        print(
            "HomeScreen: .then() is cleaning up and setting _isFallOverlayVisible = false.");
        // If the overlay is *still* considered visible (meaning _dismissAndResetOverlay didn't run or failed),
        // force a reset here.
        _dismissAndResetOverlay(
            forcePop: false); // Reset state, but don't try to pop again.
      } else if (mounted) {
        print(
            "HomeScreen: .then() executed, but overlay already marked as dismissed.");
      }
    });
  }

  // NEW Centralized Function
  void _dismissAndResetOverlay({bool forcePop = true}) async {
    print("HomeScreen: Dismiss and Reset called. Force Pop: $forcePop");

    // 1. Pop the Navigator (if needed and possible)
    // Only pop if told to and if we believe the overlay is still up.
    if (forcePop && _isFallOverlayVisible && Navigator.canPop(context)) {
      print("HomeScreen: Popping navigator...");
      Navigator.of(context).pop();
      // We expect .then() to run after this, but we'll set state anyway.
    }

    print("HomeScreen: Releasing global fall handling lock.");
    isCurrentlyHandlingFall = false; // <-- Release Lock!

    // 2. Reset the State (ALWAYS)
    // Check if a state change is actually needed before calling setState.
    if (_isFallOverlayVisible || _uiFallDetectedState) {
      print(
          "HomeScreen: Resetting flags _isFallOverlayVisible=false, _uiFallDetectedState=false.");
      if (mounted) {
        setState(() {
          _isFallOverlayVisible = false;
          _uiFallDetectedState = false;
        });
      }
    } else {
      print("HomeScreen: Flags already reset, no state change needed.");
    }


    // 3. Inform Services (ALWAYS)
    _bleService.resetFallDetectedState();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('fall_pending_alert');
      FlutterBackgroundService().invoke(resetFallHandlingEvent);
      print("HomeScreen: Cleared SP flag and invoked resetFallHandlingEvent.");
    } catch (e) {
      print("HomeScreen: Error during service reset: $e");
    }
  }

  void _dismissFallDetectionOverlay() {
    if (_isFallOverlayVisible && mounted && Navigator.canPop(context)) {
      print("HomeScreen: Dismissing overlay programmatically.");
      Navigator.of(context).pop();
    }
  }

  void _handleFallDetectedResetLogic() async {
    // <-- Make async
    print("HomeScreen: Handling Fall Reset Logic.");
    _dismissFallDetectionOverlay(); // Ensure it's dismissed

    if (mounted && _uiFallDetectedState) {
      setState(() => _uiFallDetectedState = false);
    }
    _bleService.resetFallDetectedState();

    // --- ADD/ENSURE THIS ---
    // Clear SharedPreferences flag as a final safety measure
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('fall_pending_alert');
    // Tell the background service the fall is handled
    FlutterBackgroundService().invoke(resetFallHandlingEvent);
    print("HomeScreen: Cleared SP flag and invoked resetFallHandlingEvent.");
    // --------------------
  }

  void _handleConnectDisconnect() {
    BleConnectionState currentState = _bleService.getCurrentConnectionState();
    if (currentState == BleConnectionState.connected)
      _bleService.disconnectCurrentDevice();
    else if (currentState == BleConnectionState.connecting ||
        currentState == BleConnectionState.disconnecting) {
      /*No-op*/
    }
    else if (currentState == BleConnectionState.scanning)
      _bleService.stopScan();
    else
      _bleService.startBleScan();
  }

  void _handleCalibrate() {
    bool canCalibrateNow = (_uiBleConnectionState ==
        BleConnectionState.connected ||
        (_isBgServiceConnected && _backgroundConnectedDeviceId != null)) &&
        _uiCalibrationStatus != CalibrationState.inProgress;
    if (canCalibrateNow) {
      _bleService.sendCalibrationCommand();
    } else if (_uiCalibrationStatus == CalibrationState.inProgress && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Calibration is already in progress..."),
        duration: Duration(seconds: 2),));
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Cane not connected."), duration: Duration(seconds: 2),));
    }
  }

  Future<void> _handleSignOut() async {
    if (_isFallOverlayVisible && mounted && Navigator.canPop(context)) Navigator
        .of(context).pop();
    try {
      if (await FlutterBackgroundService()
          .isRunning()) await _handleBackgroundToggle(false);
      if (_uiBleConnectionState == BleConnectionState.connected ||
          _uiBleConnectionState == BleConnectionState.connecting) {
        await _bleService.disconnectCurrentDevice();
        await Future.delayed(const Duration(milliseconds: 300));
      }
      await GoogleSignIn().signOut();
      if (mounted) Navigator.pushReplacementNamed(context, '/login');
    } catch (error, s) {
      print('HomeScreen: Error signing out: $error\n$s');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error signing out: $error')),);
    }
  }

  Future<void> _checkBackgroundServiceStatus() async {
    final service = FlutterBackgroundService();
    bool isRunning = await service.isRunning();
    if (mounted) {
      setState(() {
        _isBackgroundServiceRunning = isRunning;
      });
      _updateBackgroundToggleAndUiDisplay();
    }
  }

  Future<void> _handleBackgroundToggle(bool value) async {
    final service = FlutterBackgroundService();
    if (value) {
      BluetoothDevice? deviceToMonitor = _uiConnectedDevice;
      // If UI not connected, but BG service was connected to a device, use that one.
      if (deviceToMonitor == null && _isBgServiceConnected &&
          _backgroundConnectedDeviceId != null) {
        // This logic is tricky: if we re-enable monitoring, should it pick up the BG device?
        // For now, require UI to connect first to select a device for BG monitoring.
        print(
            "HomeScreen: Background toggle ON, but no active UI device. BG service will use its last known if any.");
        // We will just ensure the service is running. If it has a stored deviceId, it will attempt to use it.
      }

      if (deviceToMonitor != null) { // Prefer UI connected device if available
        print(
            "HomeScreen: Enabling BG monitoring for UI device ${deviceToMonitor
                .remoteId.str}");
        bool isRunning = await service.isRunning();
        if (!isRunning) {
          try {
            await service.startService();
            await Future.delayed(const Duration(milliseconds: 200));
          }
          catch (e) {
            print("Error starting service: $e");
            return;
          }
        }
        service.invoke(bgServiceSetDeviceEvent,
            {'deviceId': deviceToMonitor.remoteId.str});
        if (mounted) setState(() => _isBackgroundServiceRunning = true);
      } else if (_isBgServiceConnected && _backgroundConnectedDeviceId !=
          null) { // Fallback to BG device if UI not connected
        print(
            "HomeScreen: Enabling BG monitoring for BG device $_backgroundConnectedDeviceId");
        bool isRunning = await service.isRunning();
        if (!isRunning) {
          try {
            await service.startService();
            await Future.delayed(const Duration(milliseconds: 200));
          }
          catch (e) {
            print("Error starting service: $e");
            return;
          }
        }
        service.invoke(bgServiceSetDeviceEvent,
            {'deviceId': _backgroundConnectedDeviceId});
        if (mounted) setState(() => _isBackgroundServiceRunning = true);
      }
      else {
        print(
            "HomeScreen: Cannot start background service, no device context (UI or BG).");
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                "Connect to a cane via UI first or ensure BG service has a target!"),
            backgroundColor: Colors.orange));
        return;
      }
    } else {
      print(
          "HomeScreen: Disabling BG monitoring. Telling service to clear target.");
      service.invoke(
          bgServiceSetDeviceEvent, {'deviceId': null}); // Clear target in BG
      // Optionally fully stop if desired: service.invoke(bgServiceStopEvent);
      if (mounted) setState(() => _isBackgroundServiceRunning = false);
    }
    _updateBackgroundToggleAndUiDisplay();
  }

  @override
  void dispose() {
    print("HomeScreen: dispose called");
    _bleConnectionStateSubscription?.cancel();
    _bleScanResultsSubscription?.cancel();
    _bleBatteryLevelSubscription?.cancel();
    _bleFallDetectedSubscription?.cancel();
    _bleConnectedDeviceSubscription?.cancel();
    _bleCalibrationStatusSubscription?.cancel();
    _backgroundConnectionSubscription?.cancel();
    _nativeFallSubscriptionHomeScreen?.cancel();
    super.dispose();
    print("HomeScreen: dispose finished.");
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final colorScheme = theme.colorScheme;

    // ** CORRECTED: Theme variable definitions moved inside build method **
    final Color primaryThemedColor = colorScheme.primary;
    final Color accentThemedColor = colorScheme.secondary;
    final Color errorThemedColor = colorScheme.error;
    final Color warningThemedColor = AppTheme.warningColor;
    final Color backgroundThemedColor = theme.scaffoldBackgroundColor;
    final Color cardThemedColor = theme.cardColor;
    // final Color primaryTextThemedColor = colorScheme.onBackground; // Defined below
    final Color secondaryTextThemedColor = colorScheme.onBackground.withOpacity(0.7);
    const Color textOnSolidColor = Colors.white;
    final Color onSurfaceThemedColor = colorScheme.onSurface;


    // Determine overall connection state for display
    BleConnectionState displayConnectionState = _uiBleConnectionState;
    if (_isBgServiceConnected &&
        _uiBleConnectionState != BleConnectionState.connected &&
        _uiBleConnectionState != BleConnectionState.connecting) {
      displayConnectionState =
          BleConnectionState.connected; // Show as connected if BG is connected
    }

    String displayDeviceName = "N/A";
    String displayDeviceId = "N/A"; // Not directly used in cards, but available

    if (displayConnectionState == BleConnectionState.connected) {
      if (_uiConnectedDevice !=
          null) { // Prioritize device connected by UI's BleService
        displayDeviceName =
        _uiConnectedDevice!.platformName.isNotEmpty ? _uiConnectedDevice!
            .platformName : "Smart Cane";
        displayDeviceId = _uiConnectedDevice!.remoteId.str;
      } else if (_backgroundConnectedDeviceId !=
          null) { // Fallback to BG service's device info
        displayDeviceName = _backgroundConnectedDeviceName ?? "Smart Cane (BG)";
        displayDeviceId = _backgroundConnectedDeviceId!;
      } else {
        displayDeviceName = "Connected (Detail N/A)";
      }
    }


    Widget mainBodyContent;
    if (displayConnectionState == BleConnectionState.connected) {
      mainBodyContent = Column(
        key: const ValueKey('connected_info'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          Text('Device Information', style: textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold, color: colorScheme.onBackground)),
          const SizedBox(height: 16),
          Card(
            elevation: 2, color: cardThemedColor,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Device Name: $displayDeviceName',
                      style: textTheme.titleMedium?.copyWith(
                          color: onSurfaceThemedColor,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  Text('Device ID: ${(_uiConnectedDevice?.remoteId.str ??
                      _backgroundConnectedDeviceId) ?? "N/A"}',
                      style: textTheme.bodyMedium?.copyWith(
                          color: secondaryTextThemedColor)),
                ],
              ),
            ),
          ),
        ],
      );
    } else if ((_uiBleConnectionState == BleConnectionState.scanning ||
        (_uiBleConnectionState == BleConnectionState.scanStopped &&
            _uiScanResults.isNotEmpty))) {
      mainBodyContent = Column(
        key: const ValueKey('scan_results'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8.0, bottom: 8.0),
            child: Text('Discovered Devices:',
                style: textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onBackground)),
          ),
          Expanded(
            child: _uiScanResults.isEmpty &&
                _uiBleConnectionState == BleConnectionState.scanning
                ? Center(child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                CircularProgressIndicator(),
                SizedBox(height: 10),
                Text("Scanning...")
              ],))
                : _uiScanResults.isEmpty &&
                _uiBleConnectionState == BleConnectionState.scanStopped
                ? Center(child: Text("No devices found.",
                style: textTheme.titleMedium?.copyWith(
                    color: secondaryTextThemedColor)))
                : ListView.builder(
              itemCount: _uiScanResults.length,
              itemBuilder: (context, index) {
                final result = _uiScanResults[index];
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 4.0),
                  elevation: 1.5,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
                    title: Text(
                        result.device.platformName.isNotEmpty ? result.device
                            .platformName : "Unknown Device",
                        style: textTheme.titleMedium?.copyWith(
                            color: colorScheme.onBackground,
                            fontWeight: FontWeight.w500)),
                    subtitle: Text(result.device.remoteId.toString(), style: textTheme.bodySmall?.copyWith(color: secondaryTextThemedColor)),
                    trailing: Text('${result.rssi} dBm', style: textTheme.bodyMedium?.copyWith(color: primaryThemedColor)),
                    onTap: () {
                      _bleService.connectToDevice(result.device);
                    },
                  ),
                );
              },
            ),
          ),
        ],
      );
    } else {
      String placeholderText;
      IconData placeholderIcon = Icons.bluetooth_disabled_rounded;
      bool showProgress = false;
      switch (_uiBleConnectionState) {
        case BleConnectionState.connecting:
          placeholderText = 'Connecting...';
          placeholderIcon = Icons.bluetooth_searching_rounded;
          showProgress = true;
          break;
        case BleConnectionState.disconnecting:
          placeholderText = 'Disconnecting...';
          showProgress = true;
          break;
        case BleConnectionState.bluetoothOff:
          placeholderText = 'Bluetooth is off. Please turn it on.';
          break;
        case BleConnectionState.noPermissions:
          placeholderText = 'Permissions needed. Check settings.';
          placeholderIcon = Icons.gpp_bad_rounded;
          break;
        default:
          placeholderText = 'Cane disconnected. Scan to connect.';
      }
      mainBodyContent = Center(
        key: ValueKey('placeholder_$_uiBleConnectionState'),
        child: Padding(padding: const EdgeInsets.all(32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(placeholderIcon, size: 60, color: secondaryTextThemedColor),
              const SizedBox(height: 20),
              Text(placeholderText, style: textTheme.titleMedium?.copyWith(
                  color: secondaryTextThemedColor, height: 1.4),
                  textAlign: TextAlign.center),
              if(showProgress) ...[
                const SizedBox(height: 20),
                const CircularProgressIndicator()
              ],
            ],
            )
        ),
      );
    }

    bool canCalibrate = (displayConnectionState ==
        BleConnectionState.connected) &&
        _uiCalibrationStatus != CalibrationState.inProgress;
    String calibrateButtonText = "Calibrate Cane";
    IconData calibrateButtonIcon = Icons.settings_input_component_rounded;
    Color calibBtnFgColor = canCalibrate ? primaryThemedColor : theme
        .disabledColor.withOpacity(0.7);
    Color calibBtnBorderColor = canCalibrate ? primaryThemedColor.withOpacity(
        0.7) : theme.disabledColor.withOpacity(0.4);
    switch (_uiCalibrationStatus) {
      case CalibrationState.inProgress:
        calibrateButtonText = "Calibrating...";
        calibrateButtonIcon = Icons.rotate_right_rounded;
        calibBtnFgColor = warningThemedColor;
        calibBtnBorderColor = warningThemedColor;
        break;
      case CalibrationState.success:
        calibrateButtonText = "Calibrated";
        calibrateButtonIcon = Icons.check_circle_rounded;
        calibBtnFgColor = accentThemedColor;
        calibBtnBorderColor = accentThemedColor;
        break;
      case CalibrationState.failed:
        calibrateButtonText = "Calibration Failed";
        calibrateButtonIcon = Icons.error_outline_rounded;
        calibBtnFgColor = errorThemedColor;
        calibBtnBorderColor = errorThemedColor;
        break;
      case CalibrationState.idle:
        if (!canCalibrate) {
          calibrateButtonText = "Calibrate Cane";
          calibrateButtonIcon = Icons.settings_input_component_rounded;
        }
        break;
    }

    return Scaffold(
      backgroundColor: backgroundThemedColor,
      appBar: AppBar(title: const Text('Smart Cane Dashboard'),
        elevation: 1,
        actions: [
          IconButton(icon: const Icon(Icons.logout_rounded),
              tooltip: 'Sign Out',
              onPressed: _handleSignOut)
        ],),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('Status Overview', style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold, color: colorScheme.onBackground)),
            const SizedBox(height: 12),
            StreamBuilder<BleConnectionState>(
              stream: _bleService.connectionStateStream,
              initialData: _uiBleConnectionState,
              builder: (context, snapshot) {
                final currentDisplayState = _isBgServiceConnected &&
                    _uiBleConnectionState != BleConnectionState.connected &&
                    _uiBleConnectionState != BleConnectionState.connecting
                    ? BleConnectionState.connected
                    : (snapshot.data ?? _uiBleConnectionState);
                String statusText;
                IconData statusIcon;
                Color cardBgColor;
                Color cardElColor;
                Widget? trailing;
                String nameForCard = displayDeviceName;

                switch (currentDisplayState) {
                  case BleConnectionState.connected:
                    statusText = "Cane: $nameForCard";
                    statusIcon = Icons.bluetooth_connected_rounded;
                    cardBgColor = accentThemedColor;
                    cardElColor = textOnSolidColor;
                    trailing = Icon(
                        Icons.check_circle_rounded, color: cardElColor,
                        size: 20);
                    break;
                  case BleConnectionState.connecting:
                    statusText = "Connecting...";
                    statusIcon = Icons.bluetooth_searching_rounded;
                    cardBgColor = warningThemedColor;
                    cardElColor = textOnSolidColor;
                    trailing = SizedBox(width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                                cardElColor)));
                    break;
                  case BleConnectionState.disconnected:
                    statusText = "Cane: Disconnected";
                    statusIcon = Icons.bluetooth_disabled_rounded;
                    cardBgColor = cardThemedColor;
                    cardElColor = onSurfaceThemedColor;
                    break;
                  case BleConnectionState.disconnecting:
                    statusText = "Disconnecting...";
                    statusIcon = Icons.bluetooth_disabled_rounded;
                    cardBgColor = warningThemedColor;
                    cardElColor = textOnSolidColor;
                    trailing = SizedBox(width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                                cardElColor)));
                    break;
                  case BleConnectionState.bluetoothOff:
                    statusText = "Bluetooth is Off";
                    statusIcon = Icons.bluetooth_disabled_rounded;
                    cardBgColor = errorThemedColor;
                    cardElColor = textOnSolidColor;
                    break;
                  case BleConnectionState.noPermissions:
                    statusText = "Permissions Required";
                    statusIcon = Icons.gpp_bad_rounded;
                    cardBgColor = errorThemedColor;
                    cardElColor = textOnSolidColor;
                    break;
                  case BleConnectionState.scanning:
                    statusText = "Scanning for Cane...";
                    statusIcon = Icons.search_rounded;
                    cardBgColor = warningThemedColor;
                    cardElColor = textOnSolidColor;
                    trailing = SizedBox(width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                                cardElColor)));
                    break;
                  case BleConnectionState.scanStopped:
                    statusText = "Scan Stopped";
                    statusIcon = Icons.search_off_rounded;
                    cardBgColor = cardThemedColor;
                    cardElColor = onSurfaceThemedColor;
                    break;
                  default:
                    statusText = "Status Unknown";
                    statusIcon = Icons.help_outline_rounded;
                    cardBgColor = Colors.grey.shade700;
                    cardElColor = textOnSolidColor;
                }
                return Card(elevation: 2,
                  color: cardBgColor,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  child: Padding(padding: const EdgeInsets.symmetric(
                      horizontal: 16.0, vertical: 12.0),
                    child: Row(children: [
                      Icon(statusIcon, color: cardElColor, size: 26),
                      const SizedBox(width: 12),
                      Expanded(child: Text(statusText,
                        style: textTheme.titleSmall?.copyWith(
                            color: cardElColor, fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis,)),
                      if (trailing != null) Padding(padding: const EdgeInsets
                          .only(left: 8.0), child: trailing),
                    ]),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            Card(elevation: 2,
              color: cardThemedColor,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              child: Padding(padding: const EdgeInsets.symmetric(
                  horizontal: 16.0, vertical: 12.0),
                child: Row(children: [
                  Icon(
                      (displayConnectionState == BleConnectionState.connected &&
                          _uiBatteryLevel != null) ? (_uiBatteryLevel! > 95
                          ? Icons.battery_full_rounded
                          : _uiBatteryLevel! > 80
                          ? Icons.battery_6_bar_rounded
                          : _uiBatteryLevel! > 65
                          ? Icons.battery_5_bar_rounded
                          : _uiBatteryLevel! > 50
                          ? Icons.battery_4_bar_rounded
                          : _uiBatteryLevel! > 35
                          ? Icons.battery_3_bar_rounded
                          : _uiBatteryLevel! > 20
                          ? Icons.battery_2_bar_rounded
                          : _uiBatteryLevel! > 5
                          ? Icons.battery_1_bar_rounded
                          : Icons.battery_alert_rounded) : Icons
                          .battery_unknown_rounded,
                      color: (displayConnectionState ==
                          BleConnectionState.connected &&
                          _uiBatteryLevel != null) ? (_uiBatteryLevel! > 40
                          ? accentThemedColor
                          : _uiBatteryLevel! > 15
                          ? warningThemedColor
                          : errorThemedColor) : secondaryTextThemedColor,
                      size: 26),
                  const SizedBox(width: 12),
                  Text('Battery: ${(displayConnectionState ==
                      BleConnectionState.connected) ? (_uiBatteryLevel
                      ?.toString() ?? '...') + '%' : 'N/A'}',
                      style: textTheme.titleSmall?.copyWith(
                          color: onSurfaceThemedColor,
                          fontWeight: FontWeight.w500)),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            Card(elevation: 2,
              color: _uiFallDetectedState ? errorThemedColor : cardThemedColor,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              child: Padding(padding: const EdgeInsets.symmetric(
                  horizontal: 16.0, vertical: 12.0),
                child: Row(children: [
                  Icon(_uiFallDetectedState
                      ? Icons.error_rounded
                      : (displayConnectionState == BleConnectionState.connected
                      ? Icons.verified_user_outlined
                      : Icons.shield_outlined), color: _uiFallDetectedState
                      ? textOnSolidColor
                      : (displayConnectionState == BleConnectionState.connected
                      ? accentThemedColor
                      : secondaryTextThemedColor), size: 26,),
                  const SizedBox(width: 12),
                  Expanded(child: Text(_uiFallDetectedState
                      ? 'FALL DETECTED!'
                      : (displayConnectionState == BleConnectionState.connected
                      ? 'Protected'
                      : 'Cane Disconnected'),
                    style: textTheme.titleSmall?.copyWith(
                      color: _uiFallDetectedState
                          ? textOnSolidColor
                          : onSurfaceThemedColor,
                      fontWeight: _uiFallDetectedState
                          ? FontWeight.bold
                          : FontWeight.w500,),)),
                  if (_uiFallDetectedState) TextButton(
                    onPressed: _handleFallDetectedResetLogic,
                    child: Text('RESET', style: textTheme.labelMedium?.copyWith(
                        color: textOnSolidColor, fontWeight: FontWeight.bold)),
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4)),),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            Card(elevation: 2,
              color: cardThemedColor,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              child: SwitchListTile(
                title: Text('Background Fall Detection',
                  style: textTheme.titleSmall?.copyWith(
                      color: onSurfaceThemedColor,
                      fontWeight: FontWeight.w500),),
                subtitle: Text(
                  _isBackgroundServiceRunning ? (_isBgServiceConnected
                      ? 'Active (Cane Connected)'
                      : 'Active (Searching Cane)') : 'Inactive',
                  style: textTheme.bodySmall?.copyWith(
                      color: _isBackgroundServiceRunning
                          ? accentThemedColor
                          : secondaryTextThemedColor),),
                value: _isBackgroundServiceRunning,
                onChanged: _isBackgroundToggleEnabled
                    ? _handleBackgroundToggle
                    : null,
                secondary: Icon(Icons.shield_moon_outlined,
                  color: _isBackgroundToggleEnabled
                      ? (_isBackgroundServiceRunning
                      ? primaryThemedColor
                      : secondaryTextThemedColor)
                      : theme.disabledColor.withOpacity(0.5), size: 28,),
                activeColor: primaryThemedColor,
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              icon: Icon(
                  (_uiBleConnectionState == BleConnectionState.connected &&
                      _uiConnectedDevice != null) ? Icons
                      .bluetooth_disabled_rounded : _uiBleConnectionState ==
                      BleConnectionState.scanning
                      ? Icons.stop_circle_outlined
                      : Icons.bluetooth_searching_rounded,
                  color: textOnSolidColor),
              label: Text(
                  (_uiBleConnectionState == BleConnectionState.connected &&
                      _uiConnectedDevice != null)
                      ? 'Disconnect Cane (UI)'
                      : (_uiBleConnectionState == BleConnectionState.connecting
                      ? 'Connecting...'
                      : (_uiBleConnectionState == BleConnectionState.scanning
                      ? 'Stop Scan'
                      : 'Scan for Cane')),
                  style: textTheme.labelLarge?.copyWith(
                      color: textOnSolidColor)),
              onPressed: (_uiBleConnectionState ==
                  BleConnectionState.connecting ||
                  _uiBleConnectionState == BleConnectionState.disconnecting)
                  ? null
                  : _handleConnectDisconnect,
              style: ElevatedButton.styleFrom(
                backgroundColor: (_uiBleConnectionState ==
                    BleConnectionState.connected && _uiConnectedDevice != null)
                    ? errorThemedColor.withOpacity(0.9)
                    : (_uiBleConnectionState == BleConnectionState.noPermissions
                    ? errorThemedColor
                    : primaryThemedColor),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                textStyle: textTheme.labelLarge,),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (Widget child,
                    Animation<double> animation) =>
                    ScaleTransition(scale: animation, child: child),
                child: _uiCalibrationStatus == CalibrationState.inProgress
                    ? SizedBox(width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation<Color>(
                        calibBtnFgColor),),)
                    : Icon(calibrateButtonIcon,
                    key: ValueKey(calibrateButtonIcon.codePoint),
                    color: calibBtnFgColor),
              ),
              label: Text(calibrateButtonText,
                  style: textTheme.labelLarge?.copyWith(
                      color: calibBtnFgColor)),
              onPressed: canCalibrate ? _handleCalibrate : null,
              style: OutlinedButton.styleFrom(foregroundColor: calibBtnFgColor,
                side: BorderSide(color: calibBtnBorderColor, width: 1.5),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                textStyle: textTheme.labelLarge,),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (widget, animation) =>
                    FadeTransition(opacity: animation,
                      child: SlideTransition(position: Tween<Offset>(
                          begin: const Offset(0.0, 0.03), end: Offset.zero)
                          .animate(animation), child: widget,),),
                child: KeyedSubtree(
                  key: ValueKey<String>(
                      (displayConnectionState == BleConnectionState.connected)
                          ? 'device_info_content_${displayDeviceId}'
                          : ((_uiBleConnectionState ==
                          BleConnectionState.scanning ||
                          (_uiBleConnectionState ==
                              BleConnectionState.scanStopped &&
                              _uiScanResults.isNotEmpty))
                          ? 'scan_results_content'
                          : 'placeholder_content_${_uiBleConnectionState}')),
                  child: mainBodyContent,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}