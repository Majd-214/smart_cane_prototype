import 'package:flutter/material.dart';
import 'package:smart_cane_prototype/utils/app_theme.dart';
import 'package:google_sign_in/google_sign_in.dart';

// Import BleService and CalibrationState enum
import 'package:smart_cane_prototype/services/ble_service.dart';
import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:smart_cane_prototype/widgets/fall_detection_overlay.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final BleService _bleService = BleService(); // Use the singleton instance

  BleConnectionState _currentConnectionState = BleConnectionState.disconnected;
  List<ScanResult> _scanResults = [];
  int? _currentBatteryLevel;
  bool _currentFallDetectedUiState = false;
  BluetoothDevice? _currentConnectedDevice;

  // Remove _calibrationSuccess and _calibrationTimer
  // bool _calibrationSuccess = false;
  // Timer? _calibrationTimer;

  // New state variable for calibration status
  CalibrationState _currentCalibrationStatus = CalibrationState.idle; // <<< NEW

  StreamSubscription<BleConnectionState>? _connectionStateSubscription;
  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;
  StreamSubscription<int?>? _batteryLevelSubscription;
  StreamSubscription<bool>? _fallDetectedSubscription;
  StreamSubscription<BluetoothDevice?>? _connectedDeviceSubscription;

  // New subscription for calibration status
  StreamSubscription<
      CalibrationState>? _calibrationStatusSubscription; // <<< NEW

  bool _isFallOverlayVisible = false;

  @override
  void initState() {
    super.initState();
    print("HomeScreen: initState");

    // Initialize _currentConnectionState from the service if already initialized
    _currentConnectionState = _bleService.getCurrentConnectionState();


    _connectionStateSubscription = _bleService.connectionStateStream.listen((state) {
      if (!mounted) return;
      print("HomeScreen: Received connection state: $state");
      setState(() {
        _currentConnectionState = state;
        if (state != BleConnectionState.scanning && state != BleConnectionState.scanStopped && _scanResults.isNotEmpty) {
          _scanResults = [];
        }
        if (state == BleConnectionState.disconnected ||
            state == BleConnectionState.bluetoothOff ||
            state == BleConnectionState.noPermissions ||
            state == BleConnectionState.unknown ||
            state == BleConnectionState.scanStopped) {
          _currentBatteryLevel = null;
          // _currentCalibrationStatus = CalibrationState.idle; // Also handled by service stream
        }
        if (state == BleConnectionState.noPermissions) {
          print("HomeScreen: No BLE permissions. UI should reflect this.");
        }
      });
    }, onError: (e, s) => print("HomeScreen: Error in connectionStateStream: $e\n$s"));

    _scanResultsSubscription = _bleService.scanResultsStream.listen((results) {
      if (!mounted) return;
      if (_currentConnectionState == BleConnectionState.scanning ||
          (_currentConnectionState == BleConnectionState.scanStopped &&
              results.isNotEmpty)) {
        setState(() {
          _scanResults = results.where((result) => result.device.platformName.isNotEmpty).toList();
        });
      } else if (_scanResults.isNotEmpty &&
          _currentConnectionState != BleConnectionState.scanning) {
        // Clear results if not scanning and not just stopped with results
        setState(() => _scanResults = []);
      }
    }, onError: (e, s) => print("HomeScreen: Error in scanResultsStream: $e\n$s"));

    _batteryLevelSubscription = _bleService.batteryLevelStream.listen((level) {
      if (!mounted) return;
      setState(() => _currentBatteryLevel = level);
    }, onError: (e, s) => print("HomeScreen: Error in batteryLevelStream: $e\n$s"));

    _fallDetectedSubscription = _bleService.fallDetectedStream.listen((detected) {
      if (!mounted) return;
      print("HomeScreen: Fall detected stream update: $detected. Overlay visible: $_isFallOverlayVisible. UI Fall State: $_currentFallDetectedUiState");
      if (detected == true) {
        if (!_isFallOverlayVisible) { // Only show if not already visible
          setState(() => _currentFallDetectedUiState = true);
          _showFallDetectionOverlay();
        }
      } else { // Fall reset either by ESP32 or app
        // if (_currentFallDetectedUiState || _isFallOverlayVisible) {
        //   _dismissFallDetectionOverlay(); // Dismiss if it was programmatically shown
        //   setState(() => _currentFallDetectedUiState = false);
        // }
        // Let the overlay handle its own dismissal for 'I'm OK' or 'Call'
        // Only reset UI state if fall is truly no longer active
        if (_currentFallDetectedUiState) {
          setState(() => _currentFallDetectedUiState = false);
        }
        if (_isFallOverlayVisible) { // If overlay is somehow still up after fall cleared, dismiss
          _dismissFallDetectionOverlay();
        }
      }
    }, onError: (e, s) => print("HomeScreen: Error in fallDetectedStream: $e\n$s"));

    _connectedDeviceSubscription = _bleService.connectedDeviceStream.listen((device) {
      if (!mounted) return;
      setState(() =>
      _currentConnectedDevice = device ?? _bleService.getConnectedDevice());
    }, onError: (e, s) => print("HomeScreen: Error in connectedDeviceStream: $e\n$s"));

    // Subscribe to calibration status stream <<< NEW
    _calibrationStatusSubscription =
        _bleService.calibrationStatusStream.listen((status) {
          if (!mounted) return;
          print("HomeScreen: Received calibration status: $status");
          setState(() {
            _currentCalibrationStatus = status;
          });
          // Optionally show a SnackBar for success/failure if not relying purely on button state
          if (status == CalibrationState.success) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Cane calibrated successfully!"),
                  backgroundColor: Colors.green,
                  duration: Duration(seconds: 3)),
            );
          } else if (status == CalibrationState.failed) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text("Cane calibration failed. Please try again."),
                  backgroundColor: Colors.red,
                  duration: Duration(seconds: 3)),
            );
          }
        }, onError: (e, s) =>
            print("HomeScreen: Error in calibrationStatusStream: $e\n$s"));


    _initializeBleAndMaybeScan();
    print("HomeScreen: initState finished synchronous part.");
  }

  Future<void> _initializeBleAndMaybeScan() async {
    print("HomeScreen: Initializing BleService...");
    await _bleService
        .initialize(); // Service's initialize handles its own permission requests
    if (!mounted) return;
    print("HomeScreen: BleService initialize call completed.");

    await Future.delayed(
        const Duration(milliseconds: 300)); // Give a moment for state to settle
    if (!mounted) return;

    BleConnectionState initialStateAfterInit = _bleService.getCurrentConnectionState();
    print("HomeScreen: State after BleService init and delay: $initialStateAfterInit");

    if (_currentConnectionState != initialStateAfterInit) {
      setState(() { _currentConnectionState = initialStateAfterInit; });
    }

    if (initialStateAfterInit == BleConnectionState.disconnected) {
      print("HomeScreen: State is disconnected after init. Attempting initial scan.");
      _bleService
          .startBleScan(); // startBleScan in service now handles its permissions
    } else if (initialStateAfterInit == BleConnectionState.noPermissions) {
      print("HomeScreen: BleService reports no permissions after init. Scan not started. UI should guide user.");
      // UI will reflect this via the connection state listener.
    }
    else {
      print("HomeScreen: Not starting initial scan. Current state after init: $initialStateAfterInit");
    }
  }

  void _showFallDetectionOverlay() {
    if (!mounted || _isFallOverlayVisible) return;
    print("HomeScreen: Attempting to show fall detection overlay.");
    setState(() => _isFallOverlayVisible = true);

    Navigator.of(context).push(
      PageRouteBuilder(
          opaque: false,
          pageBuilder: (context, animation, secondaryAnimation) => FallDetectionOverlay(
            initialCountdownSeconds: 30, // Or from config
            onImOk: () {
              print("HomeScreen: 'I'm OK' pressed.");
              if (Navigator.canPop(context)) Navigator
                  .of(context)
                  .pop(); // Pop overlay
              // _isFallOverlayVisible = false; // Handled in .then()
              _handleFallDetectedResetLogic(); // Reset fall state in BLE service and UI
            },
            onCallEmergency: () {
              print("HomeScreen: 'Call Emergency' pressed.");
              if (Navigator.canPop(context)) Navigator
                  .of(context)
                  .pop(); // Pop overlay
              // _isFallOverlayVisible = false; // Handled in .then()
              _bleService.makePhoneCall(
                  '+19058028483'); // Test number, replace with actual
              _handleFallDetectedResetLogic(); // Reset fall state
            },
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
          transitionDuration: const Duration(milliseconds: 300)
      ),
    ).then((
        _) { // Called when the overlay is popped (either by its buttons or back button)
      print("HomeScreen: Fall detection overlay was popped.");
      if (mounted) {
        // Ensure _isFallOverlayVisible is reset
        if (_isFallOverlayVisible) {
          setState(() => _isFallOverlayVisible = false);
        }
        // If the overlay was dismissed (e.g., by back button) AND the fall was still active,
        // ensure we reset the underlying fall state.
        if (_currentFallDetectedUiState) {
          print(
              "HomeScreen: Overlay popped (e.g. back button) while fall was active. Resetting fall state.");
          _handleFallDetectedResetLogic();
        }
      }
    });
  }

  void _dismissFallDetectionOverlay() {
    // This is called if the fall is reset from elsewhere (e.g. ESP32 sends 'not fallen' signal)
    if (_isFallOverlayVisible && mounted && Navigator.canPop(context)) {
      print(
          "HomeScreen: Dismissing fall detection overlay programmatically because fall state cleared.");
      Navigator.of(context).pop();
      // _isFallOverlayVisible is set to false in the .then() of push()
    }
  }

  void _handleFallDetectedResetLogic() {
    print("HomeScreen: Executing fall detected reset logic.");
    if (mounted) {
      // Reset UI state if it's still showing fall
      if (_currentFallDetectedUiState) {
        setState(() => _currentFallDetectedUiState = false);
      }
      // If the overlay is still technically visible according to our flag,
      // and can be popped, pop it. (Though usually handled by overlay's own buttons or .then())
      // if (_isFallOverlayVisible && Navigator.canPop(context)) {
      //   Navigator.of(context).pop();
      // }
    }
    _bleService
        .resetFallDetectedState(); // Tell the service to reset its internal state and notify ESP32 if needed
  }


  void _handleConnectDisconnect() {
    BleConnectionState currentState = _bleService.getCurrentConnectionState();
    print("HomeScreen: _handleConnectDisconnect called. Current BLE Service State: $currentState");

    if (currentState == BleConnectionState.connected) {
      print("HomeScreen: Disconnect button pressed.");
      _bleService.disconnectCurrentDevice();
    } else if (currentState == BleConnectionState.connecting || currentState == BleConnectionState.disconnecting) {
      print("HomeScreen: Button pressed while connecting/disconnecting. No action taken.");
    } else if (currentState == BleConnectionState.scanning) {
      print("HomeScreen: Stop Scan button pressed.");
      _bleService.stopScan();
    }
    else {
      print("HomeScreen: Scan button pressed. Current state: $currentState");
      _bleService.startBleScan();
    }
  }

  void _handleCalibrate() {
    // Check connection and if calibration is already in progress
    if (_bleService.getCurrentConnectionState() ==
        BleConnectionState.connected &&
        _currentCalibrationStatus != CalibrationState.inProgress) {
      print(
          "HomeScreen: Calibrate button pressed. Current status: $_currentCalibrationStatus");
      _bleService.sendCalibrationCommand();
      // UI will update based on the _calibrationStatusStream
    } else if (_currentCalibrationStatus == CalibrationState.inProgress) {
      print("HomeScreen: Calibration already in progress.");
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Calibration is already in progress..."),
              duration: Duration(seconds: 2))
      );
    }
    else {
      print(
          "HomeScreen: Cannot calibrate, not connected or calibration ongoing.");
      if(mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text("Cane not connected or calibration ongoing."),
                duration: Duration(seconds: 2))
        );
      }
    }
  }

  Future<void> _handleSignOut() async {
    if (_isFallOverlayVisible && mounted && Navigator.canPop(context)) {
      Navigator.of(context).pop();
      setState(() => _isFallOverlayVisible = false);
    }
    try {
      print("HomeScreen: Signing out.");
      if (_bleService.getCurrentConnectionState() == BleConnectionState.connected ||
          _bleService.getCurrentConnectionState() == BleConnectionState.connecting) {
        await _bleService.disconnectCurrentDevice();
        await Future.delayed(const Duration(milliseconds: 300));
      }
      await GoogleSignIn().signOut();
      print("HomeScreen: Google sign out successful.");
      if (mounted) Navigator.pushReplacementNamed(context, '/login');
    } catch (error) {
      print('HomeScreen: Error signing out: $error');
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
    _connectionStateSubscription?.cancel();
    _scanResultsSubscription?.cancel();
    _batteryLevelSubscription?.cancel();
    _fallDetectedSubscription?.cancel();
    _connectedDeviceSubscription?.cancel();
    _calibrationStatusSubscription?.cancel(); // <<< NEW
    // _calibrationTimer?.cancel(); // Removed

    // BleService is a singleton, so it's generally not disposed here
    // unless this is the absolute last screen that uses it.
    // _bleService.dispose();

    super.dispose();
    print("HomeScreen: dispose finished.");
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final colorScheme = theme.colorScheme;

    final Color primaryThemedColor = colorScheme.primary;
    final Color accentThemedColor = colorScheme.secondary; // Often green
    final Color errorThemedColor = colorScheme.error; // Often red
    final Color warningThemedColor = AppTheme
        .warningColor; // Specific yellow from AppTheme
    final Color backgroundThemedColor = theme.scaffoldBackgroundColor;
    final Color cardThemedColor = theme.cardColor;
    final Color primaryTextThemedColor = colorScheme.onBackground;
    final Color secondaryTextThemedColor = colorScheme.onBackground.withOpacity(0.7);
    const Color textOnSolidColor = Colors.white;
    final Color onSurfaceThemedColor = colorScheme.onSurface;


    Widget mainBodyContent;
    // ... (mainBodyContent logic remains largely the same, showing scan results or device info) ...
    // (Ensure it's wrapped in KeyedSubtree or similar if AnimatedSwitcher transitions are problematic)
    if (_currentConnectionState == BleConnectionState.connected && _currentConnectedDevice != null) {
      mainBodyContent = Column(
        key: const ValueKey('connected_info'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          Text('Device Information', style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, color: primaryTextThemedColor)),
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
                  Text('Device Name: ${_currentConnectedDevice!.platformName
                      .isNotEmpty
                      ? _currentConnectedDevice!.platformName
                      : "N/A"}', style: textTheme.titleMedium?.copyWith(
                      color: onSurfaceThemedColor,
                      fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  Text('Device ID: ${_currentConnectedDevice!.remoteId.toString()}', style: textTheme.bodyMedium?.copyWith(color: secondaryTextThemedColor)),
                ],
              ),
            ),
          ),
        ],
      );
    } else if ((_currentConnectionState == BleConnectionState.scanning || (_currentConnectionState == BleConnectionState.scanStopped && _scanResults.isNotEmpty)) ) {
      mainBodyContent = Column(
        key: const ValueKey('scan_results'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8.0, bottom: 8.0),
            child: Text('Discovered Devices:',
                style: textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: primaryTextThemedColor)),
          ),
          Expanded(
            child: _scanResults.isEmpty &&
                _currentConnectionState == BleConnectionState.scanning
                ? Center(child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 10),
                Text("Scanning...")
              ],))
                : _scanResults.isEmpty &&
                _currentConnectionState == BleConnectionState.scanStopped
                ? Center(child: Text("No devices found.",
                style: textTheme.titleMedium?.copyWith(
                    color: secondaryTextThemedColor)))
                : ListView.builder(
              itemCount: _scanResults.length,
              itemBuilder: (context, index) {
                final result = _scanResults[index];
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 4.0),
                  elevation: 1.5,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
                    title: Text(result.device.platformName.isNotEmpty ? result.device.platformName : "Unknown Device", style: textTheme.titleMedium?.copyWith(color: primaryTextThemedColor, fontWeight: FontWeight.w500)),
                    subtitle: Text(result.device.remoteId.toString(), style: textTheme.bodySmall?.copyWith(color: secondaryTextThemedColor)),
                    trailing: Text('${result.rssi} dBm', style: textTheme.bodyMedium?.copyWith(color: primaryThemedColor)),
                    onTap: () {
                      print("HomeScreen: Tapped on device: ${result.device.platformName}");
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

      switch(_currentConnectionState) {
        case BleConnectionState.connecting:
          placeholderText = 'Connecting to your Smart Cane...';
          placeholderIcon = Icons.bluetooth_searching_rounded;
          showProgress = true;
          break;
        case BleConnectionState.disconnecting:
          placeholderText = 'Disconnecting from Smart Cane...';
          showProgress = true;
          break;
      // Scanning and ScanStopped without results cases are handled by the above block.
      // This 'else' will primarily hit for disconnected, bluetoothOff, noPermissions, unknown
        case BleConnectionState.bluetoothOff:
          placeholderText =
          'Bluetooth is turned off. Please turn Bluetooth on to connect to your Smart Cane.';
          break;
        case BleConnectionState.noPermissions:
          placeholderText =
          'Bluetooth or Location permissions are needed. Please grant them in app settings and try again.';
          placeholderIcon = Icons.gpp_bad_rounded;
          break;
        case BleConnectionState.unknown:
          placeholderText =
          'Bluetooth status is unknown. Please check your Bluetooth settings.';
          placeholderIcon = Icons.help_outline_rounded;
          break;
        default: // disconnected, or scanStopped with no results (though latter should be caught by previous if)
          placeholderText = 'Your Smart Cane is disconnected. Tap "Scan for Cane" to find and connect your device.';
      }
      mainBodyContent = Center(
        key: ValueKey('placeholder_$_currentConnectionState'),
        child: Padding(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                    placeholderIcon, size: 60, color: secondaryTextThemedColor),
                const SizedBox(height: 20),
                Text(placeholderText, style: textTheme.titleMedium?.copyWith(color: secondaryTextThemedColor, height: 1.4), textAlign: TextAlign.center),
                if(showProgress) ...[
                  const SizedBox(height: 20),
                  const CircularProgressIndicator()
                ],
              ],
            )
        ),
      );
    }


    // --- Calibration Button Logic --- <<< MODIFIED
    String calibrateButtonText = "Calibrate Cane";
    IconData calibrateButtonIcon = Icons.settings_input_component_rounded;
    Color calibrateButtonForegroundColor = _currentConnectionState ==
        BleConnectionState.connected ? primaryThemedColor : theme.disabledColor
        .withOpacity(0.7);
    Color calibrateButtonBorderColor = _currentConnectionState ==
        BleConnectionState.connected
        ? primaryThemedColor.withOpacity(0.7)
        : theme.disabledColor.withOpacity(0.4);
    VoidCallback? calibrateOnPressed = (_currentConnectionState ==
        BleConnectionState.connected &&
        _currentCalibrationStatus != CalibrationState.inProgress)
        ? _handleCalibrate
        : null;

    switch (_currentCalibrationStatus) {
      case CalibrationState.inProgress:
        calibrateButtonText = "Calibrating...";
        calibrateButtonIcon =
            Icons.rotate_right_rounded; // Or a CircularProgressIndicator
        calibrateButtonForegroundColor = warningThemedColor;
        calibrateButtonBorderColor = warningThemedColor;
        calibrateOnPressed = null; // Disable while in progress
        break;
      case CalibrationState.success:
        calibrateButtonText = "Calibrated";
        calibrateButtonIcon = Icons.check_circle_rounded;
        calibrateButtonForegroundColor = accentThemedColor; // Green for success
        calibrateButtonBorderColor = accentThemedColor;
        // Keep onPressed active to allow re-calibration if desired, or set to null for a period.
        break;
      case CalibrationState.failed:
        calibrateButtonText = "Calibration Failed";
        calibrateButtonIcon = Icons.error_outline_rounded;
        calibrateButtonForegroundColor = errorThemedColor; // Red for failure
        calibrateButtonBorderColor = errorThemedColor;
        break;
      case CalibrationState.idle:
      // Default values assigned above are for idle state when connected
        break;
    }
    if (_currentConnectionState != BleConnectionState.connected) {
      calibrateButtonText = "Calibrate Cane";
      calibrateButtonIcon = Icons.settings_input_component_rounded;
      calibrateButtonForegroundColor = theme.disabledColor.withOpacity(0.7);
      calibrateButtonBorderColor = theme.disabledColor.withOpacity(0.4);
      calibrateOnPressed = null;
    }


    return Scaffold(
      backgroundColor: backgroundThemedColor,
      appBar: AppBar(
        title: const Text('Smart Cane Dashboard'),
        elevation: 1,
        actions: [ IconButton(icon: const Icon(Icons.logout_rounded), tooltip: 'Sign Out', onPressed: _handleSignOut) ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('Status Overview', style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold, color: primaryTextThemedColor)),
            const SizedBox(height: 12),
            // Status Cards Area
            // ... (Connectivity Status Card - no major changes needed here for calibration status, it's separate)
            StreamBuilder<BleConnectionState>(
              stream: _bleService.connectionStateStream,
              initialData: _currentConnectionState,
              builder: (context, snapshot) {
                final state = snapshot.data ?? _currentConnectionState;
                String statusText;
                IconData statusIcon;
                Color cardBackgroundColor;
                Color cardElementColor;
                Widget? trailingWidget;

                switch (state) {
                  case BleConnectionState.connected:
                    statusText =
                    "Connected: ${_currentConnectedDevice?.platformName
                        .isNotEmpty ?? false ? _currentConnectedDevice!
                        .platformName : 'Smart Cane'}";
                    statusIcon = Icons.bluetooth_connected_rounded;
                    cardBackgroundColor = accentThemedColor;
                    cardElementColor = textOnSolidColor;
                    trailingWidget = Icon(
                        Icons.check_circle_rounded, color: cardElementColor,
                        size: 20);
                    break;
                  case BleConnectionState.connecting:
                    statusText = "Connecting...";
                    statusIcon = Icons.bluetooth_searching_rounded;
                    cardBackgroundColor = warningThemedColor;
                    cardElementColor = textOnSolidColor;
                    trailingWidget = SizedBox(width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                                cardElementColor)));
                    break;
                  case BleConnectionState.disconnected:
                    statusText = "Disconnected";
                    statusIcon = Icons.bluetooth_disabled_rounded;
                    cardBackgroundColor = cardThemedColor;
                    cardElementColor = onSurfaceThemedColor;
                    break;
                  case BleConnectionState.disconnecting:
                    statusText = "Disconnecting...";
                    statusIcon = Icons.bluetooth_disabled_rounded;
                    cardBackgroundColor = warningThemedColor;
                    cardElementColor = textOnSolidColor;
                    trailingWidget = SizedBox(width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                                cardElementColor)));
                    break;
                  case BleConnectionState.bluetoothOff:
                    statusText = "Bluetooth is Off";
                    statusIcon = Icons.bluetooth_disabled_rounded;
                    cardBackgroundColor = errorThemedColor;
                    cardElementColor = textOnSolidColor;
                    break;
                  case BleConnectionState.noPermissions:
                    statusText = "Permissions Required";
                    statusIcon = Icons.gpp_bad_rounded;
                    cardBackgroundColor = errorThemedColor;
                    cardElementColor = textOnSolidColor;
                    break;
                  case BleConnectionState.scanning:
                    statusText = "Scanning...";
                    statusIcon = Icons.search_rounded;
                    cardBackgroundColor = warningThemedColor;
                    cardElementColor = textOnSolidColor;
                    trailingWidget = SizedBox(width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                                cardElementColor)));
                    break;
                  case BleConnectionState.scanStopped:
                    statusText = "Scan Stopped";
                    statusIcon = Icons.search_off_rounded;
                    cardBackgroundColor = cardThemedColor;
                    cardElementColor = onSurfaceThemedColor;
                    break;
                  default: // unknown
                    statusText = "Status Unknown";
                    statusIcon = Icons.help_outline_rounded;
                    cardBackgroundColor = Colors.grey.shade700;
                    cardElementColor = textOnSolidColor;
                }
                return Card(
                  elevation: 2,
                  color: cardBackgroundColor,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  child: Padding(padding: const EdgeInsets.symmetric(
                      horizontal: 16.0, vertical: 12.0),
                    child: Row(children: [
                      Icon(statusIcon, color: cardElementColor, size: 26),
                      const SizedBox(width: 12),
                      Expanded(child: Text(statusText,
                        style: textTheme.titleSmall?.copyWith(
                            color: cardElementColor,
                            fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis,)),
                      if (trailingWidget != null) Padding(
                          padding: const EdgeInsets.only(left: 8.0),
                          child: trailingWidget),
                    ]),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            // ... (Battery Level Card - no changes) ...
            Card(elevation: 2,
              color: cardThemedColor,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              child: Padding(padding: const EdgeInsets.symmetric(
                  horizontal: 16.0, vertical: 12.0),
                child: Row(children: [
                  Icon(
                      _currentConnectionState == BleConnectionState.connected &&
                          _currentBatteryLevel != null
                          ? (_currentBatteryLevel! > 95 ? Icons
                          .battery_full_rounded :
                      _currentBatteryLevel! > 80 ? Icons.battery_6_bar_rounded :
                      _currentBatteryLevel! > 65 ? Icons.battery_5_bar_rounded :
                      _currentBatteryLevel! > 50 ? Icons.battery_4_bar_rounded :
                      _currentBatteryLevel! > 35 ? Icons.battery_3_bar_rounded :
                      _currentBatteryLevel! > 20 ? Icons.battery_2_bar_rounded :
                      _currentBatteryLevel! > 5
                          ? Icons.battery_1_bar_rounded
                          : Icons.battery_alert_rounded)
                          : Icons.battery_unknown_rounded,
                      color: _currentConnectionState ==
                          BleConnectionState.connected &&
                          _currentBatteryLevel != null
                          ? (_currentBatteryLevel! > 40
                          ? accentThemedColor
                          : _currentBatteryLevel! > 15
                          ? warningThemedColor
                          : errorThemedColor)
                          : secondaryTextThemedColor,
                      size: 26),
                  const SizedBox(width: 12),
                  Text(
                    'Battery: ${_currentConnectionState ==
                        BleConnectionState.connected ? (_currentBatteryLevel
                        ?.toString() ?? '...') + '%' : 'N/A'}',
                    style: textTheme.titleSmall?.copyWith(
                        color: onSurfaceThemedColor,
                        fontWeight: FontWeight.w500),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            // ... (Fall Detection Card - no changes) ...
            Card(
              elevation: 2,
              color: _currentFallDetectedUiState
                  ? errorThemedColor
                  : cardThemedColor,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              child: Padding(padding: const EdgeInsets.symmetric(
                  horizontal: 16.0, vertical: 12.0),
                child: Row(children: [
                  Icon(
                    _currentFallDetectedUiState ? Icons.error_rounded :
                    (_currentConnectionState == BleConnectionState.connected
                        ? Icons.verified_user_outlined
                        : Icons.shield_outlined),
                    color: _currentFallDetectedUiState ? textOnSolidColor :
                    (_currentConnectionState == BleConnectionState.connected
                        ? accentThemedColor
                        : secondaryTextThemedColor),
                    size: 26,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(
                    _currentFallDetectedUiState ? 'FALL DETECTED!' :
                    (_currentConnectionState == BleConnectionState.connected
                        ? 'Protected'
                        : 'Cane Disconnected'),
                    style: textTheme.titleSmall?.copyWith(
                      color: _currentFallDetectedUiState
                          ? textOnSolidColor
                          : onSurfaceThemedColor,
                      fontWeight: _currentFallDetectedUiState
                          ? FontWeight.bold
                          : FontWeight.w500,
                    ),
                  )),
                  if (_currentFallDetectedUiState)
                    TextButton(
                      onPressed: _handleFallDetectedResetLogic,
                      // This calls service's reset
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
            // Action Buttons
            ElevatedButton.icon(
              icon: Icon(
                  _currentConnectionState == BleConnectionState.connected ? Icons.bluetooth_disabled_rounded
                      : _currentConnectionState == BleConnectionState.scanning ? Icons.stop_circle_outlined
                      : Icons.bluetooth_searching_rounded,
                  color: textOnSolidColor), // Icon color consistent
              label: Text(
                  _currentConnectionState == BleConnectionState.connected ? 'Disconnect Cane'
                      : (_currentConnectionState == BleConnectionState.connecting ? 'Connecting...'
                      : (_currentConnectionState == BleConnectionState.scanning ? 'Stop Scan'
                      : 'Scan for Cane')),
                  style: textTheme.labelLarge?.copyWith(
                      color: textOnSolidColor) // Text color consistent
              ),
              onPressed: (_currentConnectionState == BleConnectionState.connecting || _currentConnectionState == BleConnectionState.disconnecting)
                  ? null : _handleConnectDisconnect,
              style: ElevatedButton.styleFrom(
                backgroundColor: _currentConnectionState == BleConnectionState.connected ? errorThemedColor.withOpacity(0.9) :
                (_currentConnectionState == BleConnectionState.noPermissions ? errorThemedColor : primaryThemedColor),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                textStyle: textTheme.labelLarge,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon( // <<< MODIFIED CALIBRATION BUTTON
              icon: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (Widget child, Animation<double> animation) {
                  return ScaleTransition(scale: animation, child: child);
                },
                child: _currentCalibrationStatus == CalibrationState.inProgress
                    ? SizedBox( // Show progress indicator when calibrating
                  width: 20, height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation<Color>(
                        calibrateButtonForegroundColor),
                  ),
                )
                    : Icon(calibrateButtonIcon,
                    key: ValueKey(calibrateButtonIcon.codePoint),
                    color: calibrateButtonForegroundColor),
              ),
              label: Text(calibrateButtonText,
                  style: textTheme.labelLarge?.copyWith(
                      color: calibrateButtonForegroundColor)),
              onPressed: calibrateOnPressed,
              style: OutlinedButton.styleFrom(
                foregroundColor: calibrateButtonForegroundColor,
                // Handled by text and icon color above
                side: BorderSide(color: calibrateButtonBorderColor, width: 1.5),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                textStyle: textTheme.labelLarge,
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (widget, animation) {
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(begin: const Offset(0.0, 0.03), end: Offset.zero).animate(animation),
                      child: widget,
                    ),
                  );
                },
                child: KeyedSubtree( // Using KeyedSubtree as before
                  key: ValueKey<String>(
                      _currentConnectionState == BleConnectionState.connected ? 'device_info_content' :
                      ((_currentConnectionState ==
                          BleConnectionState.scanning ||
                          (_currentConnectionState ==
                              BleConnectionState.scanStopped &&
                              _scanResults.isNotEmpty))
                          ? 'scan_results_content'
                          : 'placeholder_content_${_currentConnectionState}')
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