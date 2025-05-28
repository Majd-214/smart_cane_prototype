// lib/screens/home_screen.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_cane_prototype/main.dart';
import 'package:smart_cane_prototype/services/background_service_handler.dart';
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

  // REMOVED: Background state variables (_backgroundConnectedDeviceId, etc.)
  // We will now rely on BleService and its streams for a unified state.

  StreamSubscription<BleConnectionState>? _bleConnectionStateSubscription;
  StreamSubscription<List<ScanResult>>? _bleScanResultsSubscription;
  StreamSubscription<int?>? _bleBatteryLevelSubscription;
  StreamSubscription<bool>? _bleFallDetectedSubscription;
  StreamSubscription<BluetoothDevice?>? _bleConnectedDeviceSubscription;
  StreamSubscription<CalibrationState>? _bleCalibrationStatusSubscription;

  // REMOVED: _backgroundConnectionSubscription
  StreamSubscription<bool>? _fallAlertSubscriptionHomeScreen;

  bool _isFallOverlayVisible = false;
  bool _initialFallCheckDone = false;
  bool _isConnectingOrDisconnecting = false; // Added to manage button state

  @override
  void initState() {
    super.initState();
    print(
        "HomeScreen: initState. Props: launchedFromFall=${widget
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
        // Only initialize if permissions are granted
        _initializeBleAndSync();
      }

      if (!_initialFallCheckDone) {
        _initialFallCheckDone = true;
        final arguments = ModalRoute
            .of(context)
            ?.settings
            .arguments as Map?;
        bool argumentIndicatesFall = arguments?['fallDetected'] == true;
        print(
            "HomeScreen: PostFrame: launchedFromFall=${widget
                .launchedFromFall}, argumentIndicatesFall=$argumentIndicatesFall, overlayVisible=$_isFallOverlayVisible");
      }

      if (widget.launchedFromFall && !_isFallOverlayVisible) {
        print(
            "HomeScreen: PostFrame: launchedFromFall is true. Showing overlay.");
        _showFallDetectionOverlay();
      }
    });

    // --- Unified BLE State Handling ---
    _bleConnectionStateSubscription =
        _bleService.connectionStateStream.listen((state) {
          if (!mounted) return;
          print("HomeScreen: UI Received BLE State: $state");
          setState(() {
            _uiBleConnectionState = state;
            _isConnectingOrDisconnecting = (state ==
                BleConnectionState.connecting ||
                state == BleConnectionState.disconnecting);
            if (state == BleConnectionState.noPermissions) {
              print("HomeScreen: UI BLE Service reports no permissions.");
              // Optionally show a dialog or message here
            }
          });
        });

    _bleConnectedDeviceSubscription =
        _bleService.connectedDeviceStream.listen((device) {
          if (!mounted) return;
          print("HomeScreen: UI Received Connected Device: ${device?.remoteId
              .str}");
          setState(() {
            _uiConnectedDevice = device;
            // If device becomes null, ensure state reflects disconnected unless it's known to be connecting
            if (device == null &&
                _uiBleConnectionState != BleConnectionState.connecting &&
                _uiBleConnectionState != BleConnectionState.disconnecting &&
                _uiBleConnectionState != BleConnectionState.bluetoothOff &&
                _uiBleConnectionState != BleConnectionState.noPermissions) {
              _uiBleConnectionState = BleConnectionState.disconnected;
            }
          });
        });
    // --- End Unified BLE State Handling ---

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

    _bleCalibrationStatusSubscription =
        _bleService.calibrationStatusStream.listen((status) {
          if (!mounted) return;
          setState(() => _uiCalibrationStatus = status);
          if (status == CalibrationState.success && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text("Cane calibrated successfully!"),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 3),
            ));
          } else if (status == CalibrationState.failed && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text("Cane calibration failed."),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ));
          }
        });

    // REMOVED: _backgroundConnectionSubscription

    print("HomeScreen: initState finished.");
  }

  // NEW: Combined initialization and sync function
  Future<void> _initializeBleAndSync() async {
    print("HomeScreen: Initializing BleService and syncing state...");
    await _bleService
        .initialize(); // BleService now handles checking permissions internally
    if (!mounted) return;

    // Sync UI with the current (potentially background-managed) state
    setState(() {
      _uiBleConnectionState = _bleService.getCurrentConnectionState();
      _uiConnectedDevice = _bleService.getConnectedDevice();
      _isConnectingOrDisconnecting = (_uiBleConnectionState ==
          BleConnectionState.connecting ||
          _uiBleConnectionState == BleConnectionState.disconnecting);
    });

    // If already connected (maybe from background), no need to scan
    if (_uiBleConnectionState == BleConnectionState.connected) {
      print(
          "HomeScreen: Already connected to ${_uiConnectedDevice?.remoteId
              .str}. Not scanning.");
      return;
    }

    // If disconnected, try to get latched device and connect, else scan.
    String? latchedDeviceId = await _bleService.getLatchedDeviceId();
    if (latchedDeviceId != null) {
      print(
          "HomeScreen: Found latched device $latchedDeviceId. Attempting reconnect.");
      await _bleService.connectToLatchedDevice();
    } else if (_uiBleConnectionState == BleConnectionState.disconnected ||
        _uiBleConnectionState == BleConnectionState.scanStopped) {
      print("HomeScreen: No latched device. Starting scan.");
      _bleService.startBleScan();
    }
  }

  // REMOVED: _syncWithBackgroundServiceState()
  // REMOVED: _updateBackgroundToggleAndUiDisplay()
  // REMOVED: _initializeUiBleAndMaybeScan() - merged into _initializeBleAndSync

  void _showFallDetectionOverlay() {
    if (!mounted || _isFallOverlayVisible) {
      print(
          "HomeScreen: Overlay show skipped. Mounted: $mounted, Visible: $_isFallOverlayVisible");
      return;
    }
    print("HomeScreen: SHOWING fall detection overlay.");
    setState(() {
      _isFallOverlayVisible = true;
      _uiFallDetectedState = true;
    });
    flutterLocalNotificationsPlugin.cancel(fallNotificationId);
    print("HomeScreen: Cancelled fall notification ($fallNotificationId).");
    SharedPreferences.getInstance()
        .then((prefs) => prefs.remove('fall_pending_alert'));

    Navigator.of(context).push(
      PageRouteBuilder(
          opaque: false,
          pageBuilder: (context, animation, secondaryAnimation) =>
              FallDetectionOverlay(
                initialCountdownSeconds: 30,
                onImOk: () {
                  print("HomeScreen: 'I'm OK' tapped.");
                  _dismissAndResetOverlay();
                },
                onCallEmergency: () {
                  print("HomeScreen: 'Call Emergency' tapped.");
                  _bleService.makePhoneCall('+19058028483');
                  _dismissAndResetOverlay();
                },
              ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) =>
              FadeTransition(opacity: animation, child: child),
          transitionDuration: const Duration(milliseconds: 300)),
    ).then((_) {
      print("HomeScreen: Overlay Navigator.push().then() executed.");
      if (mounted && _isFallOverlayVisible) {
        print(
            "HomeScreen: .then() is cleaning up and setting _isFallOverlayVisible = false.");
        _dismissAndResetOverlay(forcePop: false);
      } else if (mounted) {
        print(
            "HomeScreen: .then() executed, but overlay already marked as dismissed.");
      }
    });
  }

  void _dismissAndResetOverlay({bool forcePop = true}) async {
    print("HomeScreen: Dismiss and Reset called. Force Pop: $forcePop");
    if (forcePop && _isFallOverlayVisible && Navigator.canPop(context)) {
      print("HomeScreen: Popping navigator...");
      Navigator.of(context).pop();
    }
    print("HomeScreen: Releasing global fall handling lock.");
    isCurrentlyHandlingFall = false;
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
    print("HomeScreen: Handling Fall Reset Logic.");
    _dismissFallDetectionOverlay();
    if (mounted && _uiFallDetectedState) {
      setState(() => _uiFallDetectedState = false);
    }
    _bleService.resetFallDetectedState();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('fall_pending_alert');
    FlutterBackgroundService().invoke(resetFallHandlingEvent);
    print("HomeScreen: Cleared SP flag and invoked resetFallHandlingEvent.");
  }

  // --- REVISED: Connection/Disconnection Logic ---
  Future<void> _handleConnectDisconnect() async {
    if (_isConnectingOrDisconnecting) return; // Prevent multiple clicks

    setState(() => _isConnectingOrDisconnecting = true); // Set flag

    try {
      if (_uiBleConnectionState == BleConnectionState.connected) {
        print("HomeScreen: User initiated disconnect.");
        await _bleService
            .disconnectCurrentDevice(); // BleService now handles service stop
      } else if (_uiBleConnectionState == BleConnectionState.scanning) {
        print("HomeScreen: User stopped scan.");
        await _bleService.stopScan();
      } else {
        print("HomeScreen: User initiated scan/connect.");
        bool permissionsGranted =
        await PermissionService.requestAllPermissions(context);
        if (permissionsGranted) {
          _bleService.startBleScan();
        } else {
          print("HomeScreen: Permissions not granted, cannot scan.");
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                "Permissions are required to scan for Bluetooth devices."),
            backgroundColor: Colors.red,
          ));
        }
      }
    } catch (e) {
      print("HomeScreen: Error in _handleConnectDisconnect: $e");
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("An error occurred: $e"),
        backgroundColor: Colors.red,
      ));
    } finally {
      // The stream listener will update _isConnectingOrDisconnecting
      // based on the actual state changes. We might remove the 'finally'
      // part if the streams handle it reliably.
      if (mounted) {
        // Let the stream update the state naturally, avoid setting false here.
      }
    }
  }

  Future<void> _handleDeviceSelection(BluetoothDevice device) async {
    if (_isConnectingOrDisconnecting) return;
    setState(() => _isConnectingOrDisconnecting = true);
    print("HomeScreen: User selected device ${device.remoteId
        .str}. Connecting...");
    await _bleService.connectToDevice(
        device); // BleService now handles service start
    // State will be updated via streams.
  }

  // --- End REVISED ---


  void _handleCalibrate() {
    bool canCalibrateNow = (_uiBleConnectionState ==
        BleConnectionState.connected) &&
        _uiCalibrationStatus != CalibrationState.inProgress;
    if (canCalibrateNow) {
      _bleService.sendCalibrationCommand();
    } else if (_uiCalibrationStatus == CalibrationState.inProgress && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Calibration is already in progress..."),
        duration: Duration(seconds: 2),
      ));
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Cane not connected."),
        duration: Duration(seconds: 2),
      ));
    }
  }

  Future<void> _handleSignOut() async {
    if (_isFallOverlayVisible && mounted && Navigator.canPop(context)) {
      Navigator.of(context).pop();
    }
    try {
      // Ensure disconnection happens first
      if (_uiBleConnectionState == BleConnectionState.connected ||
          _uiBleConnectionState == BleConnectionState.connecting) {
        await _bleService.disconnectCurrentDevice();
        await Future.delayed(const Duration(milliseconds: 500)); // Give time
      }
      // Ensure service is stopped (disconnect should handle this, but double-check)
      if (await FlutterBackgroundService().isRunning()) {
        FlutterBackgroundService().invoke(bgServiceStopEvent);
      }
      // Clear latched device
      await _bleService.clearLatchedDeviceId();

      await GoogleSignIn().signOut();
      if (mounted) Navigator.pushReplacementNamed(context, '/login');
    } catch (error, s) {
      print('HomeScreen: Error signing out: $error\n$s');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error signing out: $error')),
        );
      }
    }
  }


  // REMOVED: _checkBackgroundServiceStatus()
  // REMOVED: _handleBackgroundToggle()

  @override
  void dispose() {
    print("HomeScreen: dispose called");
    _bleConnectionStateSubscription?.cancel();
    _bleScanResultsSubscription?.cancel();
    _bleBatteryLevelSubscription?.cancel();
    _bleFallDetectedSubscription?.cancel();
    _bleConnectedDeviceSubscription?.cancel();
    _bleCalibrationStatusSubscription?.cancel();
    _fallAlertSubscriptionHomeScreen?.cancel();
    // No need to explicitly call _bleService.dispose() if it's a singleton
    // unless you have specific app exit logic.
    super.dispose();
    print("HomeScreen: dispose finished.");
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final colorScheme = theme.colorScheme;

    final Color primaryThemedColor = colorScheme.primary;
    final Color accentThemedColor = colorScheme.secondary;
    final Color errorThemedColor = colorScheme.error;
    final Color warningThemedColor = AppTheme.warningColor;
    final Color backgroundThemedColor = theme.scaffoldBackgroundColor;
    final Color cardThemedColor = theme.cardColor;
    final Color secondaryTextThemedColor =
    colorScheme.onBackground.withOpacity(0.7);
    const Color textOnSolidColor = Colors.white;
    final Color onSurfaceThemedColor = colorScheme.onSurface;

    // --- REVISED: Display Logic ---
    BleConnectionState displayConnectionState = _uiBleConnectionState;
    String displayDeviceName = "N/A";

    if (displayConnectionState == BleConnectionState.connected &&
        _uiConnectedDevice != null) {
      displayDeviceName = _uiConnectedDevice!.platformName.isNotEmpty
          ? _uiConnectedDevice!.platformName
          : "Smart Cane";
    }
    // --- End REVISED ---

    Widget mainBodyContent;
    if (displayConnectionState == BleConnectionState.connected &&
        _uiConnectedDevice != null) {
      mainBodyContent = Column(
        key: const ValueKey('connected_info'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          Text('Device Information',
              style: textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onBackground)),
          const SizedBox(height: 16),
          Card(
            elevation: 2,
            color: cardThemedColor,
            shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
                  Text('Device ID: ${_uiConnectedDevice!.remoteId.str}',
                      style: textTheme.bodyMedium
                          ?.copyWith(color: secondaryTextThemedColor)),
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
                ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    CircularProgressIndicator(),
                    SizedBox(height: 10),
                    Text("Scanning...")
                  ],
                ))
                : _uiScanResults.isEmpty &&
                _uiBleConnectionState == BleConnectionState.scanStopped
                ? Center(
                child: Text("No devices found.",
                    style: textTheme.titleMedium
                        ?.copyWith(color: secondaryTextThemedColor)))
                : ListView.builder(
              itemCount: _uiScanResults.length,
              itemBuilder: (context, index) {
                final result = _uiScanResults[index];
                return Card(
                  margin:
                  const EdgeInsets.symmetric(vertical: 4.0),
                  elevation: 1.5,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                        vertical: 8.0, horizontal: 16.0),
                    title: Text(
                        result.device.platformName.isNotEmpty
                            ? result.device.platformName
                            : "Unknown Device",
                        style: textTheme.titleMedium?.copyWith(
                            color: colorScheme.onBackground,
                            fontWeight: FontWeight.w500)),
                    subtitle: Text(result.device.remoteId.toString(),
                        style: textTheme.bodySmall
                            ?.copyWith(color: secondaryTextThemedColor)),
                    trailing: Text('${result.rssi} dBm',
                        style: textTheme.bodyMedium
                            ?.copyWith(color: primaryThemedColor)),
                    onTap: () =>
                        _handleDeviceSelection(
                            result.device), // Use new handler
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
          placeholderText = 'Permissions needed. Check settings or tap Scan.';
          placeholderIcon = Icons.gpp_bad_rounded;
          break;
        default:
          placeholderText = 'Cane disconnected. Scan to connect.';
      }
      mainBodyContent = Center(
        key: ValueKey('placeholder_$_uiBleConnectionState'),
        child: Padding(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                    placeholderIcon, size: 60, color: secondaryTextThemedColor),
                const SizedBox(height: 20),
                Text(placeholderText,
                    style: textTheme.titleMedium?.copyWith(
                        color: secondaryTextThemedColor, height: 1.4),
                    textAlign: TextAlign.center),
                if (showProgress) ...[
                  const SizedBox(height: 20),
                  const CircularProgressIndicator()
                ],
                if (_uiBleConnectionState ==
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

    bool canCalibrate = (_uiBleConnectionState ==
        BleConnectionState.connected) &&
        _uiCalibrationStatus != CalibrationState.inProgress;
    String calibrateButtonText = "Calibrate Cane";
    IconData calibrateButtonIcon = Icons.settings_input_component_rounded;
    Color calibBtnFgColor =
    canCalibrate ? primaryThemedColor : theme.disabledColor.withOpacity(0.7);
    Color calibBtnBorderColor = canCalibrate
        ? primaryThemedColor.withOpacity(0.7)
        : theme.disabledColor.withOpacity(0.4);
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
      appBar: AppBar(
        title: const Text('Smart Cane Dashboard'),
        elevation: 1,
        actions: [
          IconButton(
              icon: const Icon(Icons.logout_rounded),
              tooltip: 'Sign Out',
              onPressed: _handleSignOut)
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('Status Overview',
                style: textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onBackground)),
            const SizedBox(height: 12),
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
                    trailing = Icon(Icons.check_circle_rounded,
                        color: cardElColor, size: 20);
                    break;
                  case BleConnectionState.connecting:
                    statusText = "Connecting...";
                    statusIcon = Icons.bluetooth_searching_rounded;
                    cardBgColor = warningThemedColor;
                    cardElColor = textOnSolidColor;
                    trailing = SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor:
                            AlwaysStoppedAnimation<Color>(cardElColor)));
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
                    trailing = SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor:
                            AlwaysStoppedAnimation<Color>(cardElColor)));
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
                    trailing = SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor:
                            AlwaysStoppedAnimation<Color>(cardElColor)));
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
                      Expanded(
                          child: Text(statusText,
                              style: textTheme.titleSmall?.copyWith(
                                  color: cardElColor,
                                  fontWeight: FontWeight.w500),
                              overflow: TextOverflow.ellipsis)),
                      if (trailing != null)
                        Padding(
                            padding: const EdgeInsets.only(left: 8.0),
                            child: trailing),
                    ]),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
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
                          ? (_uiBatteryLevel! > 95
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
                          ? Icons
                          .battery_2_bar_rounded
                          : _uiBatteryLevel! > 5
                          ? Icons
                          .battery_1_bar_rounded
                          : Icons
                          .battery_alert_rounded)
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
                  Text(
                      'Battery: ${(displayConnectionState ==
                          BleConnectionState.connected) ? (_uiBatteryLevel
                          ?.toString() ?? '...') + '%' : 'N/A'}',
                      style: textTheme.titleSmall?.copyWith(
                          color: onSurfaceThemedColor,
                          fontWeight: FontWeight.w500)),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            Card(
              elevation: 2,
              color: _uiFallDetectedState ? errorThemedColor : cardThemedColor,
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
                        BleConnectionState.connected
                        ? Icons.verified_user_outlined
                        : Icons.shield_outlined),
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
                  if (_uiFallDetectedState)
                    TextButton(
                      onPressed: _handleFallDetectedResetLogic,
                      child: Text('RESET',
                          style: textTheme.labelMedium?.copyWith(
                              color: textOnSolidColor,
                              fontWeight: FontWeight.bold)),
                      style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4)),
                    ),
                ]),
              ),
            ),
            // REMOVED: Background SwitchListTile
            const SizedBox(height: 20),
            ElevatedButton.icon(
              icon: Icon(
                  (_uiBleConnectionState == BleConnectionState.connected)
                      ? Icons.bluetooth_disabled_rounded
                      : _uiBleConnectionState == BleConnectionState.scanning
                      ? Icons.stop_circle_outlined
                      : Icons.bluetooth_searching_rounded,
                  color: textOnSolidColor),
              label: Text(
                  (_uiBleConnectionState == BleConnectionState.connected)
                      ? 'Disconnect Cane'
                      : (_uiBleConnectionState == BleConnectionState.connecting
                      ? 'Connecting...'
                      : (_uiBleConnectionState ==
                      BleConnectionState.disconnecting
                      ? 'Disconnecting...'
                      : (_uiBleConnectionState == BleConnectionState.scanning
                      ? 'Stop Scan'
                      : 'Scan for Cane'))),
                  style: textTheme.labelLarge
                      ?.copyWith(color: textOnSolidColor)),
              onPressed: _isConnectingOrDisconnecting
                  ? null // Disable button during transitions
                  : _handleConnectDisconnect, // Use revised handler
              style: ElevatedButton.styleFrom(
                backgroundColor:
                (_uiBleConnectionState == BleConnectionState.connected)
                    ? errorThemedColor.withOpacity(0.9)
                    : (_uiBleConnectionState ==
                    BleConnectionState.noPermissions
                    ? errorThemedColor
                    : primaryThemedColor),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                textStyle: textTheme.labelLarge,
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
                    ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor:
                    AlwaysStoppedAnimation<Color>(calibBtnFgColor),
                  ),
                )
                    : Icon(calibrateButtonIcon,
                    key: ValueKey(calibrateButtonIcon.codePoint),
                    color: calibBtnFgColor),
              ),
              label: Text(calibrateButtonText,
                  style:
                  textTheme.labelLarge?.copyWith(color: calibBtnFgColor)),
              onPressed: canCalibrate ? _handleCalibrate : null,
              style: OutlinedButton.styleFrom(
                foregroundColor: calibBtnFgColor,
                side: BorderSide(color: calibBtnBorderColor, width: 1.5),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                textStyle: textTheme.labelLarge,
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
                  key: ValueKey<String>((displayConnectionState ==
                      BleConnectionState.connected &&
                      _uiConnectedDevice != null)
                      ? 'device_info_content_${_uiConnectedDevice?.remoteId
                      .str}'
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