// lib/screens/home_screen.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp; // Aliased
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_cane_prototype/main.dart'; // For stream controllers, global fall lock, configureBackgroundService, and constants
import 'package:smart_cane_prototype/services/background_service_handler.dart' as bgs; // Aliased
import 'package:smart_cane_prototype/services/ble_service.dart'; // UI's BleService for scanning
import 'package:smart_cane_prototype/services/permission_service.dart';
import 'package:smart_cane_prototype/utils/app_theme.dart';
import 'package:smart_cane_prototype/widgets/fall_detection_overlay.dart';

class HomeScreen extends StatefulWidget {
  final bool launchedFromFall;
  const HomeScreen({super.key, this.launchedFromFall = false});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum HomeScreenCaneStatus {
  initializing,
  noPermissions,
  disconnected,
  scanning,
  connectingToLatch,
  latchedAndConnecting,
  latchedAndConnected,
}

class _HomeScreenState extends State<HomeScreen> {
  final BleService _uiBleService = BleService(); // For UI-initiated scans and connections
  final _backgroundService = FlutterBackgroundService();

  HomeScreenCaneStatus _currentCaneStatus = HomeScreenCaneStatus.initializing;
  String? _latchedDeviceId;
  String? _latchedDeviceName;
  int? _currentBatteryLevel;
  bool _isFallCurrentlyDetectedByBg = false;
  bgs.BgCalibrationState _currentCalibrationStatus = bgs.BgCalibrationState
      .idle;

  List<fbp.ScanResult> _uiScanResults = [];
  bool _isUiScanning = false; // Specifically for when UI initiates a scan

  StreamSubscription<bool>? _fallAlertStreamSubscriptionHomeScreen;
  StreamSubscription<
      Map<String, dynamic>>? _backgroundConnectionUpdateSubscription;
  StreamSubscription<BleConnectionState>? _uiBleConnectionStateSubscription;
  StreamSubscription<List<fbp.ScanResult>>? _uiBleScanResultsSubscription;

  bool _isFallOverlayVisible = false;
  bool _initialFallCheckDone = false;
  bool _permissionsGranted = false;

  @override
  void initState() {
    super.initState();
    print("HomeScreen: initState. Props: launchedFromFall=${widget
        .launchedFromFall}");

    _fallAlertStreamSubscriptionHomeScreen =
        onFallAlertTriggered.listen((isFall) {
          if (isFall && mounted && !_isFallOverlayVisible &&
              _permissionsGranted) {
            print(
                "HomeScreen: Global Fall alert stream received. Showing overlay.");
        _showFallDetectionOverlay();
      }
    });

    _backgroundConnectionUpdateSubscription =
        onBackgroundConnectionUpdate.listen((update) {
      if (!mounted) return;
      print("HomeScreen: Received background connection update: $update");
      bool bgIsConnected = update['connected'] ?? false;
      String? bgDeviceId = update['deviceId'];
      String? bgDeviceName = update['deviceName'];
      int? bgBatteryLevel = update['batteryLevel'];
      bool bgIsFallHandling = update['isFallHandlingInProgress'] ?? false;
      String bgCalibStatusString = update['calibrationStatus'] ?? 'idle';
      bgs.BgCalibrationState bgCalibState = bgs.BgCalibrationState.values
          .firstWhere(
              (e) => e.name == bgCalibStatusString,
          orElse: () => bgs.BgCalibrationState.idle);

      HomeScreenCaneStatus newStatus = _currentCaneStatus;
      if (!_permissionsGranted) {
        newStatus = HomeScreenCaneStatus.noPermissions;
      } else if (bgDeviceId == null) {
        newStatus =
        _isUiScanning ? HomeScreenCaneStatus.scanning : HomeScreenCaneStatus
            .disconnected;
      } else {
        if (bgIsConnected) {
          newStatus = HomeScreenCaneStatus.latchedAndConnected;
        } else {
          // If UI just told BG to latch, it's "connectingToLatch"
          // otherwise, BG is attempting connection on its own ("latchedAndConnecting")
          newStatus =
          (_currentCaneStatus == HomeScreenCaneStatus.connectingToLatch &&
              _latchedDeviceId == bgDeviceId)
              ? HomeScreenCaneStatus.connectingToLatch
              : HomeScreenCaneStatus.latchedAndConnecting;
        }
      }
      print(
          "HomeScreen setState from BG Update: New Cane Status = $newStatus, Old Status: $_currentCaneStatus, LatchedDevice: $bgDeviceId, Name: $bgDeviceName, BGConnected: $bgIsConnected");

      setState(() {
        _latchedDeviceId = bgDeviceId;
        _latchedDeviceName =
            bgDeviceName ?? (bgDeviceId != null ? "Smart Cane" : null);
        _currentBatteryLevel = bgBatteryLevel;
        _isFallCurrentlyDetectedByBg = bgIsFallHandling;
        _currentCalibrationStatus = bgCalibState;
        _currentCaneStatus = newStatus;

        if (_isFallCurrentlyDetectedByBg && !_isFallOverlayVisible &&
            _permissionsGranted) {
          print(
              "HomeScreen: Background reports fall handling, showing overlay via update.");
          _showFallDetectionOverlay();
        }
      });
    });

    _uiBleScanResultsSubscription =
        _uiBleService.scanResultsStream.listen((results) {
          if (!mounted || !_isUiScanning) return;
      setState(() {
        _uiScanResults = results.where((r) =>
        r.device.platformName.isNotEmpty ||
            r.advertisementData.advName.isNotEmpty).toList();
      });
        });

    _uiBleConnectionStateSubscription =
        _uiBleService.connectionStateStream.listen((state) {
          if (!mounted || !_isUiScanning) return;

          if (state == BleConnectionState.connected &&
              _currentCaneStatus == HomeScreenCaneStatus.scanning) {
            print(
                "HomeScreen (UI_BLE_Stream): UI service connected to device during scan, prompting to latch.");
            fbp.BluetoothDevice? connectedUiDevice = _uiBleService
                .getConnectedDevice();
            if (connectedUiDevice != null) {
              _confirmAndLatchDevice(connectedUiDevice);
            } else {
              print(
                  "HomeScreen (UI_BLE_Stream): UI service connected but device is null. Resetting scan state.");
              if (mounted) {
                setState(() {
                  _isUiScanning = false;
                  _currentCaneStatus = HomeScreenCaneStatus.disconnected;
                });
              }
            }
          } else if ((state == BleConnectionState.disconnected ||
              state.toString() == 'BleConnectionState.failed') &&
              _isUiScanning) { // Temporary: check string if enum has issues
            print(
                "HomeScreen (UI_BLE_Stream): UI service connection failed or disconnected during scan. Ending UI scan. State: $state");
            if (mounted) {
              setState(() {
                _isUiScanning = false;
                _currentCaneStatus = HomeScreenCaneStatus.disconnected;
              });
            }
          }
        });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _checkPermissionsAndInitialize();

      if (!_initialFallCheckDone) {
        _initialFallCheckDone = true;
        print(
            "HomeScreen: PostFrame (after permissions): launchedFromFall=${widget
                .launchedFromFall}, overlayVisible=$_isFallOverlayVisible");
      }
      if (widget.launchedFromFall && !_isFallOverlayVisible &&
          _permissionsGranted) {
        print(
            "HomeScreen: PostFrame: launchedFromFall is true and permissions granted. Showing overlay.");
        _showFallDetectionOverlay();
      }
    });
    print(
        "HomeScreen: initState finished (async post frame callback scheduled).");
  }

  Future<void> _checkPermissionsAndInitialize() async {
    print("HomeScreen: Requesting permissions...");
    bool granted = await PermissionService.requestAllPermissions(context);
    if (!mounted) return;

    setState(() {
      _permissionsGranted = granted;
      if (!granted) {
        _currentCaneStatus = HomeScreenCaneStatus.noPermissions;
      } else {
        _currentCaneStatus = HomeScreenCaneStatus
            .initializing; // Or disconnected if no latched device
      }
    });

    if (granted) {
      print("HomeScreen: All essential permissions granted.");
      // configureBackgroundService is called in main.dart now.
      // We need to ensure it IS configured before trying to start/use it.
      // For now, assuming it's configured by main().

      print("HomeScreen: Initializing UI BLE Service...");
      await _uiBleService.initialize();

      print(
          "HomeScreen: Loading latched device (if any) and ensuring service state...");
      await _loadLatchedDeviceAndEnsureServiceState();
    } else {
      print(
          "HomeScreen: Not all permissions granted. App functionality may be limited.");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              "Critical permissions missing. App needs them to function. Please grant in settings and restart."),
          backgroundColor: Colors.red, duration: Duration(seconds: 7),
        ));
      }
    }
  }

  Future<void> _loadLatchedDeviceAndEnsureServiceState() async {
    if (!_permissionsGranted) {
      print(
          "HomeScreen: Skipping load latched device, permissions not granted.");
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final deviceId = prefs.getString(bgs.bgServiceDeviceIdKey);
    final deviceName = prefs.getString(bgs.bgServiceDeviceNameKey);

    if (deviceId != null) {
      print(
          "HomeScreen: Found stored latched device: ID $deviceId, Name $deviceName.");
      if (mounted) {
        setState(() {
          _latchedDeviceId = deviceId;
          _latchedDeviceName = deviceName ?? "Smart Cane";
          _currentCaneStatus = HomeScreenCaneStatus.latchedAndConnecting;
        });
      }
      bool serviceIsRunning = await _backgroundService.isRunning();
      if (!serviceIsRunning) {
        print(
            "HomeScreen: Starting background service because a device was latched.");
        try {
          await _backgroundService.startService();
          await Future.delayed(const Duration(milliseconds: 200));
        } catch (e) {
          print(
              "HomeScreen: Error starting background service for latched device: $e");
          return;
        }
      }
      print(
          "HomeScreen: Telling background service to latch onto stored device: $deviceId");
      _backgroundService.invoke(bgs.bgServiceSetDeviceEvent,
          {'deviceId': deviceId, 'deviceName': deviceName});
    } else {
      print("HomeScreen: No latched device found in Prefs.");
      if (mounted) {
        setState(() {
          _currentCaneStatus = HomeScreenCaneStatus.disconnected;
        });
      }
    }
  }

  void _showFallDetectionOverlay() {
    if (!mounted || _isFallOverlayVisible) {
      print(
          "HomeScreen: Overlay show skipped. Mounted: $mounted, Visible: $_isFallOverlayVisible");
      return;
    }
    print("HomeScreen: SHOWING fall detection overlay.");
    setState(() {
      _isFallOverlayVisible = true;
      _isFallCurrentlyDetectedByBg = true;
    });

    flutterLocalNotificationsPlugin.cancel(fallNotificationId);
    print("HomeScreen: Cancelled fall notification ($fallNotificationId).");

    SharedPreferences.getInstance().then((prefs) =>
        prefs.remove(bgs.fallPendingAlertKey));

    Navigator.of(context).push(
      PageRouteBuilder(
          opaque: false,
          pageBuilder: (context, animation, secondaryAnimation) => FallDetectionOverlay(
            initialCountdownSeconds: 30,
            onImOk: () {
              print("HomeScreen: 'I'm OK' tapped from overlay.");
              _dismissAndResetOverlay();
            },
            onCallEmergency: () {
              print("HomeScreen: 'Call Emergency' tapped from overlay.");
              _uiBleService.makePhoneCall('+19058028483');
              _dismissAndResetOverlay();
            },
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) =>
              FadeTransition(opacity: animation, child: child),
          transitionDuration: const Duration(milliseconds: 300)
      ),
    ).then((_) {
      print(
          "HomeScreen: Overlay Navigator.push().then() executed (overlay popped).");
      if (mounted) {
        if (_isFallOverlayVisible || _isFallCurrentlyDetectedByBg) {
          print(
              "HomeScreen: .then() calling _dismissAndResetOverlay (forcePop: false) as a failsafe.");
          _dismissAndResetOverlay(forcePop: false);
        }
      }
    });
  }

  void _dismissAndResetOverlay({bool forcePop = true}) async {
    print(
        "HomeScreen: Dismiss and Reset called. Force Pop: $forcePop, Current Overlay Visible: $_isFallOverlayVisible");

    if (forcePop && _isFallOverlayVisible && Navigator.canPop(context)) {
      print("HomeScreen: Popping navigator...");
      Navigator.of(context).pop();
    }

    print(
        "HomeScreen: Releasing global fall handling lock (isCurrentlyHandlingFall = false).");
    isCurrentlyHandlingFall = false;

    if (mounted) {
      if (_isFallOverlayVisible || _isFallCurrentlyDetectedByBg) {
        setState(() {
          _isFallOverlayVisible = false;
          _isFallCurrentlyDetectedByBg = false;
        });
      }
    }

    _backgroundService.invoke(bgs.resetFallHandlingEvent);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(bgs.fallPendingAlertKey);
      print("HomeScreen: Cleared '${bgs.fallPendingAlertKey}' and invoked '${bgs
          .resetFallHandlingEvent}'.");
    } catch (e) {
      print("HomeScreen: Error during SharedPreferences clear in reset: $e");
    }
  }

  Future<void> _manageCaneSelection() async {
    if (!_permissionsGranted) {
      print(
          "HomeScreen: Permissions not granted. Cannot manage cane selection.");
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Permissions are required to scan for canes.")));
      await _checkPermissionsAndInitialize();
      return;
    }

    if (_latchedDeviceId != null) {
      print(
          "HomeScreen: Disconnecting/Unlatching from device: $_latchedDeviceId. Stopping service.");
      _backgroundService.invoke(
          bgs.bgServiceSetDeviceEvent, {'deviceId': null});
      if (await _backgroundService.isRunning()) {
        _backgroundService.invoke(bgs.bgServiceStopEvent);
        print("HomeScreen: Background service stop invoked.");
      }
      if (mounted) {
        setState(() {
          _currentCaneStatus = HomeScreenCaneStatus.disconnected;
          _latchedDeviceId = null;
          _latchedDeviceName = null;
          _currentBatteryLevel = null;
          _currentCalibrationStatus = bgs.BgCalibrationState.idle;
          _isUiScanning = false;
          _uiScanResults = [];
        });
      }
    } else {
      print("HomeScreen: Starting UI scan for cane selection.");
      if (!await _backgroundService.isRunning()) {
        print("HomeScreen: Starting background service before scan.");
        try {
          await _backgroundService.startService();
          await Future.delayed(const Duration(milliseconds: 200));
        } catch (e) {
          print("HomeScreen: Error starting background service for scan: $e");
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text("Error starting monitoring service: $e")));
          return;
        }
      }
      await _uiBleService.initialize(); // Ensure UI BLE service is ready
      if (mounted) {
        setState(() {
          _isUiScanning = true;
          _currentCaneStatus = HomeScreenCaneStatus.scanning;
          _uiScanResults = [];
        });
      }
      await _uiBleService
          .startScan(); // Removed 'await' as startScan itself is likely not returning a future that needs awaiting here for UI update
    }
  }

  Future<void> _confirmAndLatchDevice(fbp.BluetoothDevice device) async {
    if (!mounted) return;
    if (_isUiScanning) {
      await _uiBleService.stopScan(); // This is Future<void>
      if (mounted) setState(() => _isUiScanning = false);
    }

    final deviceName = device.platformName.isNotEmpty
        ? device.platformName
        : (device.advName.isNotEmpty ? device.advName : device.remoteId.str);
    bool? confirm = await showDialog<bool>(
        context: context,
        builder: (context) =>
            AlertDialog(
              title: const Text("Confirm Smart Cane"),
              content: Text(
                  "Set '$deviceName' as your Smart Cane for monitoring?"),
              actions: [
                TextButton(onPressed: () => Navigator.of(context).pop(false),
                    child: const Text("Cancel")),
                TextButton(onPressed: () => Navigator.of(context).pop(true),
                    child: const Text("Confirm")),
              ],
            ));

    if (confirm == true) {
      print("HomeScreen: User confirmed. Latching to device: ${device.remoteId
          .str}, Name: $deviceName");
      if (mounted) {
        setState(() {
          _currentCaneStatus = HomeScreenCaneStatus.connectingToLatch;
        });
      }

      bool serviceWasRunning = await _backgroundService.isRunning();
      if (!serviceWasRunning) {
        print("HomeScreen: User confirmed latch, starting BG service first.");
        try {
          await _backgroundService.startService();
          await Future.delayed(const Duration(milliseconds: 200));
        } catch (e) {
          print("HomeScreen: Error starting BG service during latch: $e");
          if (mounted) setState(() =>
          _currentCaneStatus = HomeScreenCaneStatus.disconnected);
          return;
        }
      }
      _backgroundService.invoke(bgs.bgServiceSetDeviceEvent,
          { // Ensure await if invoke is async and matters for sequence
            'deviceId': device.remoteId.str,
            'deviceName': deviceName,
          });

      final uiConnectedDevice = _uiBleService.getConnectedDevice();
      if (uiConnectedDevice?.remoteId.str == device.remoteId.str) {
        print(
            "HomeScreen: Disconnecting UI's temporary connection to let BG take over.");
        await _uiBleService.disconnectCurrentDevice();
      }
    } else {
      print("HomeScreen: User cancelled latching.");
      final uiConnectedDevice = _uiBleService.getConnectedDevice();
      if (uiConnectedDevice?.remoteId.str == device.remoteId.str) {
        await _uiBleService.disconnectCurrentDevice();
      }
      if (mounted &&
          _currentCaneStatus != HomeScreenCaneStatus.latchedAndConnected &&
          _currentCaneStatus != HomeScreenCaneStatus.latchedAndConnecting) {
        setState(() => _currentCaneStatus = HomeScreenCaneStatus.disconnected);
      }
    }
  }

  void _handleCalibrate() {
    if (!_permissionsGranted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Permissions required for calibration.")));
      return;
    }
    if (_currentCaneStatus == HomeScreenCaneStatus.latchedAndConnected) {
      if (_currentCalibrationStatus == bgs.BgCalibrationState.inProgress) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("Calibration is already in progress...")));
        return;
      }
      print("HomeScreen: Requesting calibration from background service.");
      _backgroundService.invoke(bgs.requestCalibrationEvent);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Cane not connected. Cannot calibrate.")));
    }
  }

  Future<void> _handleSignOut() async {
    if (_isFallOverlayVisible && mounted) {
      _dismissAndResetOverlay(forcePop: true);
      await Future.delayed(const Duration(milliseconds: 300));
    }
    try {
      print(
          "HomeScreen: Signing out. Telling BG service to unlatch and stop if running.");
      if (await _backgroundService.isRunning()) {
        _backgroundService.invoke(
            bgs.bgServiceSetDeviceEvent, {'deviceId': null});
        _backgroundService.invoke(bgs.bgServiceStopEvent);
      }
      await GoogleSignIn().signOut();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(bgs.bgServiceDeviceIdKey);
      await prefs.remove(bgs.bgServiceDeviceNameKey);
      await prefs.remove(bgs.fallPendingAlertKey);
      await prefs.remove(fallHandledKey);

      if (mounted) {
        Navigator.pushNamedAndRemoveUntil(
            context, '/login', (Route<dynamic> route) => false);
      }
    } catch (error, s) {
      print('HomeScreen: Error signing out: $error\n$s');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error signing out: $error')));
    }
  }

  @override
  void dispose() {
    print("HomeScreen: dispose called");
    _fallAlertStreamSubscriptionHomeScreen?.cancel();
    _backgroundConnectionUpdateSubscription?.cancel();
    _uiBleScanResultsSubscription?.cancel();
    _uiBleConnectionStateSubscription?.cancel();
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
    final Color onSurfaceThemedColor = colorScheme.onSurface;
    final Color secondaryTextThemedColor = colorScheme.onSurface.withOpacity(
        0.7);

    String statusText = "Initializing...";
    IconData statusIcon = Icons.hourglass_empty_rounded;
    Color cardBgColor = theme.cardColor;
    Color cardElColor = onSurfaceThemedColor;
    Widget? trailing;
    String caneNameForDisplay = _latchedDeviceName ??
        (_latchedDeviceId != null ? "Smart Cane" : "N/A");

    if (!_permissionsGranted &&
        _currentCaneStatus == HomeScreenCaneStatus.noPermissions) {
      statusText = "Permissions Required";
      statusIcon = Icons.gpp_bad_rounded;
      cardBgColor = errorThemedColor;
      cardElColor = Colors.white;
    } else {
      switch (_currentCaneStatus) {
        case HomeScreenCaneStatus.initializing:
          statusText = "Initializing App...";
          statusIcon = Icons.settings_applications_rounded;
          trailing = const SizedBox(width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2));
          break;
        case HomeScreenCaneStatus.disconnected:
          statusText = _latchedDeviceId == null
              ? "No Cane Selected"
              : "Cane: $caneNameForDisplay (Disconnected)";
          statusIcon = Icons.bluetooth_disabled_rounded;
          cardBgColor = theme.cardColor; // Use theme.cardColor
          cardElColor = onSurfaceThemedColor;
          break;
        case HomeScreenCaneStatus.scanning:
          statusText = "Scanning for Canes...";
          statusIcon = Icons.search_rounded;
          cardBgColor = warningThemedColor;
          cardElColor = Colors.white;
          trailing = const SizedBox(width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white)));
          break;
        case HomeScreenCaneStatus.connectingToLatch:
          statusText = "Setting up '${_latchedDeviceName ?? "New Cane"}'...";
          statusIcon = Icons.bluetooth_searching_rounded;
          cardBgColor = warningThemedColor;
          cardElColor = Colors.white;
          trailing = const SizedBox(width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white)));
          break;
        case HomeScreenCaneStatus.latchedAndConnecting:
          statusText = "Connecting to: $caneNameForDisplay";
          statusIcon = Icons.bluetooth_searching_rounded;
          cardBgColor = warningThemedColor;
          cardElColor = Colors.white;
          trailing = const SizedBox(width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white)));
          break;
        case HomeScreenCaneStatus.latchedAndConnected:
          statusText = "Cane: $caneNameForDisplay (Connected)";
          statusIcon = Icons.bluetooth_connected_rounded;
          cardBgColor = accentThemedColor;
          cardElColor = Colors.white;
          trailing =
          const Icon(Icons.check_circle_rounded, color: Colors.white, size: 20);
          break;
        case HomeScreenCaneStatus.noPermissions:
          statusText = "Permissions Required for BLE";
          statusIcon = Icons.gpp_bad_rounded;
          cardBgColor = errorThemedColor;
          cardElColor = Colors.white;
          break;
      }
    }

    String mainButtonText = _permissionsGranted
        ? "Scan & Select Cane"
        : "Grant Permissions";
    IconData mainButtonIcon = _permissionsGranted ? Icons
        .bluetooth_searching_rounded : Icons.shield_outlined;
    VoidCallback? mainButtonAction = _checkPermissionsAndInitialize; // Default to permission check / re-check

    if (_permissionsGranted) { // Only evaluate these if permissions are granted
      mainButtonAction =
          _manageCaneSelection; // Default action if permissions are fine
      if (_latchedDeviceId != null) {
        mainButtonText = "Disconnect from $caneNameForDisplay";
        mainButtonIcon = Icons.bluetooth_disabled_rounded;
      } else if (_currentCaneStatus == HomeScreenCaneStatus.scanning) {
        mainButtonText = "Stop Scan";
        mainButtonIcon = Icons.stop_circle_outlined;
        mainButtonAction = () async {
          await _uiBleService.stopScan();
          if (mounted) setState(() {
            _isUiScanning = false;
            _currentCaneStatus = HomeScreenCaneStatus.disconnected;
          });
        };
      } else if (_currentCaneStatus == HomeScreenCaneStatus.connectingToLatch ||
          _currentCaneStatus == HomeScreenCaneStatus.latchedAndConnecting) {
        mainButtonText =
        _currentCaneStatus == HomeScreenCaneStatus.connectingToLatch
            ? "Setting up..."
            : "Connecting...";
        mainButtonAction = null;
      } else {
        mainButtonText =
        "Scan & Select Cane"; // Default if disconnected and not scanning
        mainButtonIcon = Icons.bluetooth_searching_rounded;
      }
    }


    Widget mainBodyContent;
    if (!_permissionsGranted &&
        _currentCaneStatus == HomeScreenCaneStatus.noPermissions) {
      mainBodyContent = Center(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.gpp_bad_outlined, size: 60, color: errorThemedColor),
                const SizedBox(height: 20),
                Text("Permissions Required",
                    style: textTheme.headlineSmall?.copyWith(
                        color: errorThemedColor)),
                const SizedBox(height: 10),
                Text(
                    "This app needs Bluetooth, Location, and Notification permissions to find and connect to your Smart Cane, and to alert you. Please grant them to continue.",
                    textAlign: TextAlign.center, style: textTheme.bodyLarge),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  icon: const Icon(Icons.shield_outlined, color: Colors.white),
                  label: const Text("Grant Permissions",
                      style: TextStyle(color: Colors.white)),
                  onPressed: _checkPermissionsAndInitialize,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: primaryThemedColor),
                )
              ],
            ),
          )
      );
    } else
    if (_currentCaneStatus == HomeScreenCaneStatus.scanning && _isUiScanning) {
      mainBodyContent = Column(
        key: const ValueKey('scan_results_active_scan'),
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
            child: _uiScanResults.isEmpty
                ? const Center(child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 10),
                Text("Scanning...")
              ],))
                : ListView.builder(
              itemCount: _uiScanResults.length,
              itemBuilder: (context, index) {
                final result = _uiScanResults[index];
                final deviceName = result.device.platformName.isNotEmpty
                    ? result.device.platformName
                    : (result.advertisementData.advName.isNotEmpty ? result
                    .advertisementData.advName : "Unknown Device");
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 4.0),
                  child: ListTile(
                    title: Text(deviceName,
                        style: textTheme.titleMedium?.copyWith(
                            color: onSurfaceThemedColor,
                            fontWeight: FontWeight.w500)),
                    subtitle: Text(result.device.remoteId.toString(), style: textTheme.bodySmall?.copyWith(color: secondaryTextThemedColor)),
                    trailing: Text('${result.rssi} dBm', style: textTheme.bodyMedium?.copyWith(color: primaryThemedColor)),
                    onTap: () => _confirmAndLatchDevice(result.device),
                  ),
                );
              },
            ),
          ),
        ],
      );
    } else if (_currentCaneStatus == HomeScreenCaneStatus.latchedAndConnected ||
        _currentCaneStatus == HomeScreenCaneStatus.latchedAndConnecting ||
        _currentCaneStatus == HomeScreenCaneStatus.connectingToLatch) {
      mainBodyContent = Column(
        key: ValueKey('latched_device_info_$_latchedDeviceId'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          Text('Device Information', style: textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold, color: colorScheme.onBackground)),
          const SizedBox(height: 16),
          Card(
            color: theme.cardColor,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Name: $caneNameForDisplay',
                      style: textTheme.titleMedium?.copyWith(
                          color: onSurfaceThemedColor,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  Text('ID: ${_latchedDeviceId ?? "N/A"}',
                      style: textTheme.bodyMedium?.copyWith(
                          color: secondaryTextThemedColor)),
                  const SizedBox(height: 8),
                  Text('Status: ${_currentCaneStatus.name
                      .replaceAllMapped(
                      RegExp(r'([A-Z])'), (match) => ' ${match.group(0)}')
                      .trim()
                      .replaceAllMapped(RegExp(r'^L'), (match) => 'L')}',
                      // Attempt to format enum name nicely
                      style: textTheme.bodyMedium?.copyWith(
                          color: secondaryTextThemedColor)),
                ],
              ),
            ),
          ),
        ],
      );
    } else { // Disconnected or Initializing (after permissions)
      mainBodyContent = Center(
        key: const ValueKey('placeholder_disconnected_or_initializing'),
        child: Padding(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_currentCaneStatus ==
                    HomeScreenCaneStatus.initializing) ...[
                  const CircularProgressIndicator(),
                  const SizedBox(height: 20),
                  Text("Initializing...",
                      style: textTheme.titleMedium?.copyWith(
                          color: secondaryTextThemedColor)),
                ] else
                  ... [
                    Icon(Icons.bluetooth_disabled_outlined, size: 60,
                        color: secondaryTextThemedColor),
                    const SizedBox(height: 20),
                    Text(_latchedDeviceId == null &&
                        _currentCaneStatus == HomeScreenCaneStatus.disconnected
                        ? "No Smart Cane selected."
                        : (_currentCaneStatus ==
                        HomeScreenCaneStatus.disconnected
                        ? "'${_latchedDeviceName ??
                        "Your cane"}' is disconnected."
                        : "Ready to Scan."),
                        style: textTheme.titleMedium?.copyWith(
                            color: secondaryTextThemedColor, height: 1.4),
                        textAlign: TextAlign.center),
                    const SizedBox(height: 10),
                    if (_latchedDeviceId == null &&
                        _currentCaneStatus == HomeScreenCaneStatus.disconnected)
                      Text("Use the button below to scan and select your cane.",
                          style: textTheme.bodyMedium?.copyWith(
                              color: secondaryTextThemedColor),
                          textAlign: TextAlign.center),
                  ]
              ],
            )),
      );
    }

    bool canCalibrate = _permissionsGranted &&
        _currentCaneStatus == HomeScreenCaneStatus.latchedAndConnected &&
        _currentCalibrationStatus != bgs.BgCalibrationState.inProgress;
    String calibrateButtonText = "Calibrate Cane";
    IconData calibrateButtonIcon = Icons.settings_input_component_rounded;
    Color calibBtnFgColor = canCalibrate ? primaryThemedColor : theme
        .disabledColor.withOpacity(0.7);
    Color calibBtnBorderColor = canCalibrate ? primaryThemedColor.withOpacity(
        0.7) : theme.disabledColor.withOpacity(0.4);

    switch (_currentCalibrationStatus) {
      case bgs.BgCalibrationState.inProgress:
        calibrateButtonText = "Calibrating...";
        calibrateButtonIcon = Icons.rotate_right_rounded;
        calibBtnFgColor = warningThemedColor;
        calibBtnBorderColor = warningThemedColor;
        break;
      case bgs.BgCalibrationState.success:
        calibrateButtonText = "Calibrated Successfully";
        calibrateButtonIcon = Icons.check_circle_rounded;
        calibBtnFgColor = accentThemedColor;
        calibBtnBorderColor = accentThemedColor;
        break;
      case bgs.BgCalibrationState.failed:
        calibrateButtonText = "Calibration Failed";
        calibrateButtonIcon = Icons.error_outline_rounded;
        calibBtnFgColor = errorThemedColor;
        calibBtnBorderColor = errorThemedColor;
        break;
      case bgs.BgCalibrationState.idle:
        break;
    }

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Smart Cane Dashboard'),
        elevation: 1,
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
                fontWeight: FontWeight.bold, color: colorScheme.onBackground)),
            const SizedBox(height: 12),
            Card(
              elevation: 2, color: cardBgColor,
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
                    overflow: TextOverflow.ellipsis,)),
                  if (trailing != null) Padding(
                      padding: const EdgeInsets.only(left: 8.0),
                      child: trailing),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            Card(
              elevation: 2, color: theme.cardColor,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16.0, vertical: 12.0),
                child: Row(children: [
                  Icon(
                      (_currentCaneStatus ==
                          HomeScreenCaneStatus.latchedAndConnected &&
                          _currentBatteryLevel != null)
                          ? (_currentBatteryLevel! > 95 ? Icons
                          .battery_full_rounded
                          : _currentBatteryLevel! > 80 ? Icons
                          .battery_6_bar_rounded
                          : _currentBatteryLevel! > 65 ? Icons
                          .battery_5_bar_rounded
                          : _currentBatteryLevel! > 50 ? Icons
                          .battery_4_bar_rounded
                          : _currentBatteryLevel! > 35 ? Icons
                          .battery_3_bar_rounded
                          : _currentBatteryLevel! > 20 ? Icons
                          .battery_2_bar_rounded
                          : _currentBatteryLevel! > 5 ? Icons
                          .battery_1_bar_rounded
                          : Icons.battery_alert_rounded)
                          : Icons.battery_unknown_rounded,
                      color: (_currentCaneStatus ==
                          HomeScreenCaneStatus.latchedAndConnected &&
                          _currentBatteryLevel != null)
                          ? (_currentBatteryLevel! > 40 ? accentThemedColor
                          : _currentBatteryLevel! > 15 ? warningThemedColor
                          : errorThemedColor)
                          : secondaryTextThemedColor,
                      size: 26),
                  const SizedBox(width: 12),
                  Text('Battery: ${(_currentCaneStatus ==
                      HomeScreenCaneStatus.latchedAndConnected &&
                      _currentBatteryLevel != null)
                      ? '$_currentBatteryLevel%'
                      : 'N/A'}',
                      style: textTheme.titleSmall?.copyWith(
                          color: onSurfaceThemedColor,
                          fontWeight: FontWeight.w500)),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            Card(
              elevation: 2,
              color: _isFallCurrentlyDetectedByBg ? errorThemedColor : theme
                  .cardColor,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16.0, vertical: 12.0),
                child: Row(children: [
                  Icon(_isFallCurrentlyDetectedByBg ? Icons.error_rounded
                      : (_currentCaneStatus ==
                      HomeScreenCaneStatus.latchedAndConnected ? Icons
                      .verified_user_outlined : Icons.shield_outlined),
                    color: _isFallCurrentlyDetectedByBg ? Colors.white
                        : (_currentCaneStatus ==
                        HomeScreenCaneStatus.latchedAndConnected
                        ? accentThemedColor
                        : secondaryTextThemedColor),
                    size: 26,),
                  const SizedBox(width: 12),
                  Expanded(child: Text(
                    _isFallCurrentlyDetectedByBg ? 'FALL DETECTED!'
                        : (_currentCaneStatus ==
                        HomeScreenCaneStatus.latchedAndConnected
                        ? 'Protected & Monitored'
                        : 'Not Monitored'),
                    style: textTheme.titleSmall?.copyWith(
                      color: _isFallCurrentlyDetectedByBg
                          ? Colors.white
                          : onSurfaceThemedColor,
                      fontWeight: _isFallCurrentlyDetectedByBg
                          ? FontWeight.bold
                          : FontWeight.w500,),
                  )),
                  if (_isFallCurrentlyDetectedByBg)
                    TextButton(
                      onPressed: () => _dismissAndResetOverlay(forcePop: true),
                      child: Text('RESET',
                          style: textTheme.labelMedium?.copyWith(color: Colors
                              .white, fontWeight: FontWeight.bold)),
                    ),
                ]),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              icon: Icon(mainButtonIcon, color: Colors.white),
              label: Text(mainButtonText,
                  style: textTheme.labelLarge?.copyWith(color: Colors.white)),
              onPressed: mainButtonAction,
              style: ElevatedButton.styleFrom(
                backgroundColor: (_latchedDeviceId != null &&
                    _currentCaneStatus != HomeScreenCaneStatus.disconnected &&
                    _permissionsGranted)
                    ? errorThemedColor.withOpacity(0.9)
                    : primaryThemedColor,
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
                child: _currentCalibrationStatus ==
                    bgs.BgCalibrationState.inProgress
                    ? SizedBox(width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation<Color>(
                          calibBtnFgColor),))
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
                child: KeyedSubtree(
                  key: ValueKey<HomeScreenCaneStatus>(_currentCaneStatus),
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