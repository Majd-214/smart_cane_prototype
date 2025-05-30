// lib/screens/home_screen.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_cane_prototype/main.dart'; // For onFallAlertTriggered, confirmFallHandledByOverlay, DEFAULT_FALL_COUNTDOWN_SECONDS
import 'package:smart_cane_prototype/services/background_service_handler.dart'; // For bgServiceStopEvent
import 'package:smart_cane_prototype/services/ble_service.dart';
import 'package:smart_cane_prototype/services/permission_service.dart';
import 'package:smart_cane_prototype/utils/app_theme.dart';
import 'package:smart_cane_prototype/widgets/fall_detection_overlay.dart';


class HomeScreen extends StatefulWidget {
  final bool launchedFromFall;
  final int resumeCountdownSeconds; // New parameter

  const HomeScreen({
    super.key,
    this.launchedFromFall = false,
    this.resumeCountdownSeconds = DEFAULT_FALL_COUNTDOWN_SECONDS, // Use default from main.dart
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final BleService _bleService = BleService();

  BleConnectionState _uiBleConnectionState = BleConnectionState.disconnected;
  BluetoothDevice? _uiConnectedDevice;
  List<ScanResult> _uiScanResults = [];
  int? _uiBatteryLevel;
  bool _uiFallDetectedState = false; // Represents if overlay *should* be visible
  CalibrationState _uiCalibrationStatus = CalibrationState.idle;

  StreamSubscription<BleConnectionState>? _bleConnectionStateSubscription;
  StreamSubscription<List<ScanResult>>? _bleScanResultsSubscription;
  StreamSubscription<int?>? _bleBatteryLevelSubscription;
  StreamSubscription<
      bool>? _bleFallDetectedSubscription; // From BleService (raw fall event)
  StreamSubscription<BluetoothDevice?>? _bleConnectedDeviceSubscription;
  StreamSubscription<CalibrationState>? _bleCalibrationStatusSubscription;

  StreamSubscription<
      bool>? _mainFallAlertSubscription; // From main.dart global stream

  bool _isFallOverlayActuallyVisible = false; // Tracks if Navigator.push for overlay happened
  bool _initialFallCheckDone = false;
  bool _isConnectingOrDisconnecting = false;

  @override
  void initState() {
    super.initState();
    print(
        "HomeScreen: initState. Props: launchedFromFall=${widget
            .launchedFromFall}, resumeCountdown=${widget
            .resumeCountdownSeconds}");

    _uiBleConnectionState = _bleService.getCurrentConnectionState();
    _uiConnectedDevice = _bleService.getConnectedDevice();

    // This subscription is primarily for foreground fall detections or when main.dart signals
    // that an overlay should be shown (e.g., after interactive notification tap).
    _mainFallAlertSubscription = onFallAlertTriggered.listen((isFallSignal) {
      if (isFallSignal && mounted && !_isFallOverlayActuallyVisible) {
        print(
            "HomeScreen: Main fall alert stream received (isFallSignal=true). Showing overlay.");
        _showFallDetectionOverlay(
            initialSeconds: currentNotificationCountdownSeconds); // Use seconds from main.dart if available
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      bool permissionsGranted =
      await PermissionService.requestAllPermissions(context);

      if (!permissionsGranted && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              "Warning: Not all permissions granted. App may not function fully."),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 5),
        ));
      } else {
        _initializeBleAndSync();
      }

      if (!_initialFallCheckDone) {
        _initialFallCheckDone = true;
        final arguments = ModalRoute
            .of(context)
            ?.settings
            .arguments as Map?;
        bool argumentIndicatesFall = arguments?['fallDetected'] == true;
        int argumentResumeSeconds = arguments?['resumeCountdownSeconds'] as int? ??
            widget.resumeCountdownSeconds;

        print("HomeScreen: PostFrame: launchedFromFall(widget)=${widget
            .launchedFromFall}, argumentIndicatesFall=$argumentIndicatesFall, overlayVisible=$_isFallOverlayActuallyVisible, resumeSecs=$argumentResumeSeconds");

        if ((widget.launchedFromFall || argumentIndicatesFall) &&
            !_isFallOverlayActuallyVisible) {
          print(
              "HomeScreen PostFrame: Fall launch detected. Showing overlay with ${argumentResumeSeconds}s.");
          _showFallDetectionOverlay(initialSeconds: argumentResumeSeconds);
        }
      }
    });

    _bleConnectionStateSubscription =
        _bleService.connectionStateStream.listen((state) {
          if (!mounted) return;
          setState(() {
            _uiBleConnectionState = state;
            _isConnectingOrDisconnecting =
            (state == BleConnectionState.connecting ||
                state == BleConnectionState.disconnecting);
            if (state == BleConnectionState.disconnected &&
                _isFallOverlayActuallyVisible) {
              // If disconnected while overlay is up, this is a problem.
              // Overlay should probably have a "connection lost" state or auto-OK.
              // For now, let overlay manage itself.
            }
          });
        });

    _bleConnectedDeviceSubscription =
        _bleService.connectedDeviceStream.listen((device) {
          if (!mounted) return;
          setState(() => _uiConnectedDevice = device);
        });

    _bleScanResultsSubscription =
        _bleService.scanResultsStream.listen((results) {
          if (!mounted) return;
          if (_uiBleConnectionState == BleConnectionState.scanning ||
              (_uiBleConnectionState == BleConnectionState.scanStopped &&
                  results.isNotEmpty)) {
            setState(() =>
            _uiScanResults =
                results
                    .where((r) => r.device.platformName.isNotEmpty)
                    .toList());
          } else if (_uiScanResults.isNotEmpty &&
              _uiBleConnectionState != BleConnectionState.scanning) {
            setState(() => _uiScanResults = []);
          }
        });

    _bleBatteryLevelSubscription =
        _bleService.batteryLevelStream.listen((level) {
          if (mounted) setState(() => _uiBatteryLevel = level);
        });

    // This subscription is for the *raw* fall detection event from the BLE service.
    // It primarily sets the _uiFallDetectedState which can be used for UI cues
    // *before* the full overlay is triggered by the main.dart logic (via onFallAlertTriggered).
    _bleFallDetectedSubscription =
        _bleService.fallDetectedStream.listen((detected) {
          if (!mounted) return;
          print(
              "HomeScreen: BLE Fall Detected Stream: $detected. OverlayVisible: $_isFallOverlayActuallyVisible");
          if (detected &&
              !_isFallOverlayActuallyVisible) { // Only set true if overlay isn't already up
            setState(() => _uiFallDetectedState = true);
            // The actual showing of overlay is handled by main.dart's logic which considers foreground/background
            // and then signals via onFallAlertTriggered if appropriate for HomeScreen.
          } else if (!detected &&
              _uiFallDetectedState) { // If BLE service says fall is reset
            setState(() => _uiFallDetectedState = false);
            if (_isFallOverlayActuallyVisible) _dismissFallDetectionOverlayLocally(); // Dismiss if it was visible
          }
        });

    _bleCalibrationStatusSubscription =
        _bleService.calibrationStatusStream.listen((status) {
          if (!mounted) return;
          setState(() => _uiCalibrationStatus = status);
          if (status == CalibrationState.success && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text("Cane calibrated successfully!"),
              backgroundColor: Colors.green,
            ));
          } else if (status == CalibrationState.failed && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text("Cane calibration failed."),
              backgroundColor: Colors.red,
            ));
          }
        });
  }

  Future<void> _initializeBleAndSync() async {
    await _bleService.initialize();
    if (!mounted) return;
    setState(() {
      _uiBleConnectionState = _bleService.getCurrentConnectionState();
      _uiConnectedDevice = _bleService.getConnectedDevice();
      _isConnectingOrDisconnecting =
      (_uiBleConnectionState == BleConnectionState.connecting ||
          _uiBleConnectionState == BleConnectionState.disconnecting);
    });

    if (_uiBleConnectionState == BleConnectionState.connected) return;

    String? latchedDeviceId = await _bleService.getLatchedDeviceId();
    if (latchedDeviceId != null) {
      await _bleService.connectToLatchedDevice();
    } else if (_uiBleConnectionState == BleConnectionState.disconnected ||
        _uiBleConnectionState == BleConnectionState.scanStopped) {
      _bleService.startBleScan();
    }
  }

  void _showFallDetectionOverlay({required int initialSeconds}) {
    if (!mounted || _isFallOverlayActuallyVisible) {
      print(
          "HomeScreen: Overlay show skipped. Mounted: $mounted, Visible: $_isFallOverlayActuallyVisible");
      return;
    }
    print(
        "HomeScreen: SHOWING fall detection overlay with initial seconds: $initialSeconds");
    setState(() {
      _isFallOverlayActuallyVisible = true;
      _uiFallDetectedState = true; // Ensure this is true when overlay is shown
    });

    // Cancel any general fall notifications from main.dart that might have been for full-screen intent
    flutterLocalNotificationsPlugin.cancel(
        INTERACTIVE_FALL_NOTIFICATION_ID); // Also cancel interactive one if it was somehow still there

    SharedPreferences.getInstance().then((prefs) =>
        prefs.remove('fall_pending_alert'));

    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (context, animation, secondaryAnimation) =>
            FallDetectionOverlay(
              initialCountdownSeconds: initialSeconds,
              // Pass the initial seconds
              onImOk: () {
                print("HomeScreen: Overlay 'I'm OK' tapped.");
                _dismissAndResetOverlayLogically(isOk: true);
              },
              onCallEmergency: () {
                print("HomeScreen: Overlay 'Call Emergency' tapped.");
                _bleService.makePhoneCall(
                    '+19058028483'); // Replace with actual number
                _dismissAndResetOverlayLogically(isOk: false);
              },
            ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    ).then((_) { // This .then() executes when the overlay is popped.
      print(
          "HomeScreen: Overlay Navigator.push().then() executed (overlay popped).");
      // This is a crucial point to ensure state is reset if overlay is dismissed by back button or programmatically
      if (mounted && _isFallOverlayActuallyVisible) {
        print(
            "HomeScreen: Overlay was popped, but _isFallOverlayActuallyVisible is still true. Force resetting state.");
        _dismissAndResetOverlayLogically(isOk: true,
            calledFromPop: true); // Assume 'OK' if popped without action
      }
    });
  }

  // Call this when overlay actions (I'm OK, Call Emergency) are taken OR when overlay is popped.
  void _dismissAndResetOverlayLogically(
      {required bool isOk, bool calledFromPop = false}) {
    print(
        "HomeScreen: Dismiss and Reset Logically. Is OK: $isOk, Called from Pop: $calledFromPop. OverlayVisible: $_isFallOverlayActuallyVisible");

    if (mounted && _isFallOverlayActuallyVisible) {
      if (Navigator.canPop(context) &&
          !calledFromPop) { // Avoid double pop if already popped
        Navigator.of(context).pop();
      }
      setState(() {
        _isFallOverlayActuallyVisible = false;
        // _uiFallDetectedState will be reset by bleService.resetFallDetectedState() via its stream
      });
    }

    // This tells main.dart that the fall sequence initiated by it (if any) is now fully handled by the overlay.
    confirmFallHandledByOverlay();

    _bleService
        .resetFallDetectedState(); // Tell BLE service to reset its internal fall state
    FlutterBackgroundService().invoke(
        resetFallHandlingEvent); // Tell BG service too

    SharedPreferences.getInstance().then((prefs) {
      prefs.remove('fall_pending_alert');
    });
  }

  // Used if BLE service resets fall state (e.g. cane sends "false alarm" signal)
  void _dismissFallDetectionOverlayLocally() {
    if (_isFallOverlayActuallyVisible && mounted) {
      print(
          "HomeScreen: Dismissing overlay programmatically (e.g. BLE reset fall).");
      if (Navigator.canPop(context)) {
        Navigator.of(context).pop();
      }
      setState(() => _isFallOverlayActuallyVisible = false);
      // Global fall handling state should also be reset if this happens.
      confirmFallHandledByOverlay();
    }
  }


  void _handleFallDetectedResetButton() {
    print("HomeScreen: Handling Fall Reset Button (from status card).");
    // This button is only visible if _uiFallDetectedState is true but overlay might not be.
    // This implies a reset is needed.
    _bleService
        .resetFallDetectedState(); // This will flow through streams and update UI
    if (_isFallOverlayActuallyVisible) {
      _dismissFallDetectionOverlayLocally();
    }
    // Also ensure main.dart's controller knows
    confirmFallHandledByOverlay();
  }


  Future<void> _handleConnectDisconnect() async {
    if (_isConnectingOrDisconnecting) return;
    setState(() => _isConnectingOrDisconnecting = true);

    try {
      if (_uiBleConnectionState == BleConnectionState.connected) {
        await _bleService.disconnectCurrentDevice();
      } else if (_uiBleConnectionState == BleConnectionState.scanning) {
        await _bleService.stopScan();
      } else {
        bool permissionsGranted = await PermissionService.requestAllPermissions(
            context);
        if (permissionsGranted) {
          _bleService.startBleScan();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("Permissions are required to scan."),
            backgroundColor: Colors.red,
          ));
          if (mounted) setState(() =>
          _isConnectingOrDisconnecting = false); // Reset if no permission
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("An error occurred: $e"), backgroundColor: Colors.red,
        ));
        setState(() => _isConnectingOrDisconnecting = false); // Reset on error
      }
    }
    // _isConnectingOrDisconnecting will be updated by the stream listener
  }

  Future<void> _handleDeviceSelection(BluetoothDevice device) async {
    if (_isConnectingOrDisconnecting) return;
    setState(() => _isConnectingOrDisconnecting = true);
    await _bleService.connectToDevice(device);
  }

  void _handleCalibrate() {
    bool canCalibrateNow = (_uiBleConnectionState ==
        BleConnectionState.connected) &&
        _uiCalibrationStatus != CalibrationState.inProgress;
    if (canCalibrateNow) {
      _bleService.sendCalibrationCommand();
    } else if (_uiCalibrationStatus == CalibrationState.inProgress && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Calibration is already in progress..."),
      ));
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Cane not connected."),
      ));
    }
  }

  Future<void> _handleSignOut() async {
    if (_isFallOverlayActuallyVisible && mounted && Navigator.canPop(context)) {
      _dismissAndResetOverlayLogically(
          isOk: true, calledFromPop: true); // Treat as OK if signing out
    }
    try {
      if (_uiBleConnectionState == BleConnectionState.connected ||
          _uiBleConnectionState == BleConnectionState.connecting) {
        await _bleService.disconnectCurrentDevice();
        await Future.delayed(const Duration(milliseconds: 500));
      }
      if (await FlutterBackgroundService().isRunning()) {
        FlutterBackgroundService().invoke(bgServiceStopEvent);
      }
      await _bleService.clearLatchedDeviceId();
      await GoogleSignIn().signOut();
      if (mounted) Navigator.pushReplacementNamed(context, '/login');
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error signing out: $error')),
        );
      }
    }
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
    _mainFallAlertSubscription?.cancel();
    // If overlay might be visible during dispose (e.g. quick navigation away), ensure it's cleaned up.
    if (_isFallOverlayActuallyVisible) {
      // This is a bit tricky as context might not be valid for Navigator.pop.
      // The overlay itself should handle its own cleanup as much as possible.
      // Setting the flag false is the main thing.
      _isFallOverlayActuallyVisible = false;
      confirmFallHandledByOverlay(); // ensure main.dart knows
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ... existing build method ...
    // Key change: The "Fall Detected" card should use _uiFallDetectedState for its appearance.
    // The "RESET" button on that card should call _handleFallDetectedResetButton().

    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final colorScheme = theme.colorScheme;

    // Determine colors based on theme
    final Color primaryThemedColor = colorScheme.primary;
    final Color accentThemedColor = colorScheme.secondary; // Often green
    final Color errorThemedColor = colorScheme.error; // Often red
    final Color warningThemedColor = AppTheme
        .warningColor; // Often yellow/orange
    final Color cardThemedColor = theme.cardColor;
    final Color onSurfaceThemedColor = colorScheme.onSurface;
    final Color secondaryTextThemedColor = colorScheme.onSurface.withOpacity(
        0.7);
    const Color textOnSolidColor = Colors.white;


    BleConnectionState displayConnectionState = _uiBleConnectionState;
    String displayDeviceName = _uiConnectedDevice?.platformName.isNotEmpty ==
        true
        ? _uiConnectedDevice!.platformName
        : "Smart Cane";

    Widget mainBodyContent;
    if (displayConnectionState == BleConnectionState.connected &&
        _uiConnectedDevice != null) {
      mainBodyContent = Column(
        key: const ValueKey('connected_info'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          Text('Device Information', style: textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold)),
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
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  Text('Device ID: ${_uiConnectedDevice!.remoteId.str}',
                      style: textTheme.bodyMedium?.copyWith(
                          color: secondaryTextThemedColor)),
                ],
              ),
            ),
          ),
        ],
      );
    } else if ((displayConnectionState == BleConnectionState.scanning ||
        (displayConnectionState == BleConnectionState.scanStopped &&
            _uiScanResults.isNotEmpty))) {
      mainBodyContent = Column(
        key: const ValueKey('scan_results'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8.0, bottom: 8.0),
            child: Text('Discovered Devices:',
                style: textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: _uiScanResults.isEmpty &&
                displayConnectionState == BleConnectionState.scanning
                ? const Center(child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 10),
                  Text("Scanning...")
                ]))
                : _uiScanResults.isEmpty &&
                displayConnectionState == BleConnectionState.scanStopped
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
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                        vertical: 8.0, horizontal: 16.0),
                    title: Text(
                        result.device.platformName.isNotEmpty ? result.device
                            .platformName : "Unknown Device",
                        style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w500)),
                    subtitle: Text(result.device.remoteId.toString(),
                        style: textTheme.bodySmall?.copyWith(
                            color: secondaryTextThemedColor)),
                    trailing: Text('${result.rssi} dBm',
                        style: textTheme.bodyMedium?.copyWith(
                            color: primaryThemedColor)),
                    onTap: () => _handleDeviceSelection(result.device),
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
      switch (displayConnectionState) {
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
          placeholderText = 'Permissions needed. Check settings or tap Scan.';
          placeholderIcon = Icons.gpp_bad_rounded;
          break;
        default:
          placeholderText = 'Cane disconnected. Scan to connect.';
      }
      mainBodyContent = Center(
        key: ValueKey('placeholder_$displayConnectionState'),
        child: Padding(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                    placeholderIcon, size: 60, color: secondaryTextThemedColor),
                const SizedBox(height: 20),
                Text(placeholderText, style: textTheme.titleMedium?.copyWith(
                    color: secondaryTextThemedColor, height: 1.4),
                    textAlign: TextAlign.center),
                if (showProgress) ...[
                  const SizedBox(height: 20),
                  const CircularProgressIndicator()
                ],
                if (displayConnectionState ==
                    BleConnectionState.noPermissions) ...[
                  const SizedBox(height: 20),
                  ElevatedButton(onPressed: () =>
                      PermissionService.requestAllPermissions(context),
                      child: const Text("Request Permissions"))
                ]
              ],
            )),
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
        break;
    }

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Smart Cane Dashboard'), elevation: 1,
        actions: [
          IconButton(icon: const Icon(Icons.logout_rounded),
              tooltip: 'Sign Out',
              onPressed: _handleSignOut)
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('Status Overview', style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            // Connection Status Card
            StreamBuilder<BleConnectionState>(
              stream: _bleService.connectionStateStream,
              initialData: _uiBleConnectionState,
              builder: (context, snapshot) {
                final currentDisplayState = snapshot.data ??
                    _uiBleConnectionState;
                String statusText;
                IconData statusIcon;
                Color cardBgColor;
                Color cardElColor;
                Widget? trailing;
                String nameForCard = (_uiConnectedDevice?.platformName
                    .isNotEmpty ?? false)
                    ? _uiConnectedDevice!.platformName
                    : "Smart Cane";

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
                return Card(
                  elevation: 2,
                  color: cardBgColor,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16.0, vertical: 12.0),
                    child: Row(children: [
                      Icon(statusIcon, color: cardElColor, size: 26),
                      const SizedBox(width: 12),
                      Expanded(child: Text(statusText,
                          style: textTheme.titleSmall?.copyWith(
                              color: cardElColor, fontWeight: FontWeight.w500),
                          overflow: TextOverflow.ellipsis)),
                      if (trailing != null) Padding(padding: const EdgeInsets
                          .only(left: 8.0), child: trailing),
                    ]),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            // Battery Status Card
            Card(
              elevation: 2,
              color: cardThemedColor,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16.0, vertical: 12.0),
                child: Row(children: [
                  Icon(
                      (displayConnectionState == BleConnectionState.connected &&
                          _uiBatteryLevel != null)
                          ? (_uiBatteryLevel! > 95 ? Icons.battery_full_rounded
                          : _uiBatteryLevel! > 80 ? Icons.battery_6_bar_rounded
                          : _uiBatteryLevel! > 65 ? Icons.battery_5_bar_rounded
                          : _uiBatteryLevel! > 50 ? Icons.battery_4_bar_rounded
                          : _uiBatteryLevel! > 35 ? Icons.battery_3_bar_rounded
                          : _uiBatteryLevel! > 20 ? Icons.battery_2_bar_rounded
                          : _uiBatteryLevel! > 5 ? Icons.battery_1_bar_rounded
                          : Icons.battery_alert_rounded)
                          : Icons.battery_unknown_rounded,
                      color: (displayConnectionState ==
                          BleConnectionState.connected &&
                          _uiBatteryLevel != null)
                          ? (_uiBatteryLevel! > 40
                          ? accentThemedColor
                          : _uiBatteryLevel! > 15
                          ? warningThemedColor
                          : errorThemedColor)
                          : secondaryTextThemedColor,
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
            // Fall Detection Status Card
            Card(
              elevation: 2,
              color: _uiFallDetectedState ? errorThemedColor : cardThemedColor,
              // Use _uiFallDetectedState
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16.0, vertical: 12.0),
                child: Row(children: [
                  Icon(
                    _uiFallDetectedState
                        ? Icons.error_rounded
                        : (displayConnectionState ==
                        BleConnectionState.connected ? Icons
                        .verified_user_outlined : Icons.shield_outlined),
                    color: _uiFallDetectedState
                        ? textOnSolidColor
                        : (displayConnectionState ==
                        BleConnectionState.connected
                        ? accentThemedColor
                        : secondaryTextThemedColor),
                    size: 26,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                      child: Text(
                        _uiFallDetectedState
                            ? 'FALL DETECTED!'
                            : (displayConnectionState ==
                            BleConnectionState.connected
                            ? 'Protected'
                            : 'Cane Disconnected'),
                        style: textTheme.titleSmall?.copyWith(
                          color: _uiFallDetectedState
                              ? textOnSolidColor
                              : onSurfaceThemedColor,
                          fontWeight: _uiFallDetectedState
                              ? FontWeight.bold
                              : FontWeight.w500,
                        ),
                      )),
                  if (_uiFallDetectedState) // Show reset only if a fall is flagged
                    TextButton(
                      onPressed: _handleFallDetectedResetButton,
                      // Use new handler
                      child: Text('RESET',
                          style: textTheme.labelMedium?.copyWith(
                              color: textOnSolidColor, fontWeight: FontWeight
                              .bold)),
                      style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4)),
                    ),
                ]),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              icon: Icon(
                  (displayConnectionState == BleConnectionState.connected)
                      ? Icons.bluetooth_disabled_rounded
                      : displayConnectionState == BleConnectionState.scanning
                      ? Icons.stop_circle_outlined
                      : Icons.bluetooth_searching_rounded,
                  color: textOnSolidColor),
              label: Text(
                  (displayConnectionState == BleConnectionState.connected)
                      ? 'Disconnect Cane'
                      : (displayConnectionState == BleConnectionState.connecting
                      ? 'Connecting...'
                      : (displayConnectionState ==
                      BleConnectionState.disconnecting ? 'Disconnecting...'
                      : (displayConnectionState == BleConnectionState.scanning
                      ? 'Stop Scan'
                      : 'Scan for Cane'))),
                  style: textTheme.labelLarge?.copyWith(
                      color: textOnSolidColor)),
              onPressed: _isConnectingOrDisconnecting
                  ? null
                  : _handleConnectDisconnect,
              style: ElevatedButton.styleFrom(
                backgroundColor: (displayConnectionState ==
                    BleConnectionState.connected) ? errorThemedColor
                    .withOpacity(0.9)
                    : (displayConnectionState ==
                    BleConnectionState.noPermissions
                    ? errorThemedColor
                    : primaryThemedColor),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
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
                            calibBtnFgColor)))
                    : Icon(calibrateButtonIcon,
                    key: ValueKey(calibrateButtonIcon.codePoint),
                    color: calibBtnFgColor),
              ),
              label: Text(calibrateButtonText,
                  style: textTheme.labelLarge?.copyWith(
                      color: calibBtnFgColor)),
              onPressed: canCalibrate ? _handleCalibrate : null,
              style: OutlinedButton.styleFrom(
                foregroundColor: calibBtnFgColor,
                side: BorderSide(color: calibBtnBorderColor, width: 1.5),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (widget, animation) =>
                    FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                            begin: const Offset(0.0, 0.03), end: Offset.zero)
                            .animate(animation),
                        child: widget,
                      ),
                    ),
                child: KeyedSubtree(
                  key: ValueKey<String>(
                      (displayConnectionState == BleConnectionState.connected &&
                          _uiConnectedDevice != null)
                          ? 'device_info_${_uiConnectedDevice?.remoteId.str}'
                          : ((displayConnectionState ==
                          BleConnectionState.scanning ||
                          (displayConnectionState ==
                              BleConnectionState.scanStopped &&
                              _uiScanResults.isNotEmpty)) ? 'scan_results'
                          : 'placeholder_$displayConnectionState')
                  ),
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