import 'package:flutter/material.dart';
import 'package:smart_cane_prototype/utils/app_theme.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:smart_cane_prototype/services/ble_service.dart';
import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:smart_cane_prototype/widgets/fall_detection_overlay.dart'; // Import overlay

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final BleService _bleService = BleService();

  BleConnectionState _currentConnectionState = BleConnectionState.disconnected;
  List<ScanResult> _scanResults = [];
  int? _currentBatteryLevel;
  bool _currentFallDetectedUiState = false;
  BluetoothDevice? _currentConnectedDevice;
  bool _calibrationSuccess = false;
  Timer? _calibrationTimer;

  // Ensure StreamSubscription types are specific if possible, or use `StreamSubscription<dynamic>`
  StreamSubscription<BleConnectionState>? _connectionStateSubscription;
  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;
  StreamSubscription<int?>? _batteryLevelSubscription;
  StreamSubscription<bool>? _fallDetectedSubscription;
  StreamSubscription<BluetoothDevice?>? _connectedDeviceSubscription;

  bool _isFallOverlayVisible = false;

  @override
  void initState() {
    super.initState();
    print("HomeScreen: initState");

    // Subscribe to streams FIRST
    _connectionStateSubscription = _bleService.connectionStateStream.listen((state) {
      if (!mounted) return;
      print("HomeScreen: Received connection state: $state");
      setState(() {
        _currentConnectionState = state;
        if (state != BleConnectionState.scanning && state != BleConnectionState.scanStopped && _scanResults.isNotEmpty) {
          _scanResults = [];
          print("HomeScreen: Scan results cleared as state is $state");
        }
        if (state == BleConnectionState.disconnected ||
            state == BleConnectionState.bluetoothOff ||
            state == BleConnectionState.noPermissions ||
            state == BleConnectionState.unknown ||
            state == BleConnectionState.scanStopped) {
          _currentBatteryLevel = null;
          if (state == BleConnectionState.noPermissions){
            print("HomeScreen: No BLE permissions. UI should reflect this.");
          }
        }
      });
    }, onError: (e, s) => print("HomeScreen: Error in connectionStateStream: $e\n$s"));

    _scanResultsSubscription = _bleService.scanResultsStream.listen((results) {
      if (!mounted) return;
      if (_currentConnectionState == BleConnectionState.scanning || _currentConnectionState == BleConnectionState.scanStopped) {
        setState(() {
          _scanResults = results.where((result) => result.device.platformName.isNotEmpty).toList();
        });
      } else if (_scanResults.isNotEmpty) {
        setState(() => _scanResults = []);
        print("HomeScreen: Scan results cleared as state is $_currentConnectionState");
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
        if (!_isFallOverlayVisible) {
          setState(() => _currentFallDetectedUiState = true);
          _showFallDetectionOverlay();
        }
      } else {
        if (_currentFallDetectedUiState || _isFallOverlayVisible) {
          _dismissFallDetectionOverlay();
          setState(() => _currentFallDetectedUiState = false);
        }
      }
    }, onError: (e, s) => print("HomeScreen: Error in fallDetectedStream: $e\n$s"));

    _connectedDeviceSubscription = _bleService.connectedDeviceStream.listen((device) {
      if (!mounted) return;
      setState(() => _currentConnectedDevice = device);
    }, onError: (e, s) => print("HomeScreen: Error in connectedDeviceStream: $e\n$s"));

    _initializeBleAndMaybeScan();
    print("HomeScreen: initState finished synchronous part.");
  }

  Future<void> _initializeBleAndMaybeScan() async {
    print("HomeScreen: Initializing BleService...");
    // The reverted BleService.initialize() is Future<void> and calls its own _requestPermissions
    await _bleService.initialize();
    if (!mounted) return;

    print("HomeScreen: BleService initialize call completed.");

    // Give a moment for BleService's internal state (especially after permission requests) to settle
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;

    BleConnectionState initialStateAfterInit = _bleService.getCurrentConnectionState();
    print("HomeScreen: State after BleService init and delay: $initialStateAfterInit");

    // Sync HomeScreen's state with BleService's state if it changed during init
    if (_currentConnectionState != initialStateAfterInit) {
      setState(() { _currentConnectionState = initialStateAfterInit; });
    }

    if (initialStateAfterInit == BleConnectionState.disconnected) {
      print("HomeScreen: State is disconnected after init. Attempting initial scan.");
      // The reverted BleService's startScan() should internally handle permission checks again if needed.
      _bleService.startBleScan();
    } else if (initialStateAfterInit == BleConnectionState.noPermissions) {
      print("HomeScreen: BleService reports no permissions after init. Scan not started. UI should guide user.");
    } else {
      print("HomeScreen: Not starting initial scan. Current state after init: $initialStateAfterInit");
    }
  }

  void _showFallDetectionOverlay() {
    if (!mounted || _isFallOverlayVisible) return;
    print("HomeScreen: Attempting to show fall detection overlay.");
    setState(() => _isFallOverlayVisible = true);

    Navigator.of(context).push(
      PageRouteBuilder(
          opaque: false, // Ensure overlay can be see-through if designed that way
          pageBuilder: (context, animation, secondaryAnimation) => FallDetectionOverlay(
            // Assuming FallDetectionOverlay uses its own default or you provide one
            initialCountdownSeconds: 30,
            onImOk: () {
              print("HomeScreen: 'I'm OK' pressed.");
              if(Navigator.canPop(context)) Navigator.of(context).pop();
              _handleFallDetectedResetLogic();
            },
            onCallEmergency: () {
              print("HomeScreen: 'Call Emergency' pressed.");
              if(Navigator.canPop(context)) Navigator.of(context).pop();
              _bleService.makePhoneCall('+19058028483'); // Test number
              _handleFallDetectedResetLogic();
            },
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            // Example: Fade transition for the overlay
            return FadeTransition(opacity: animation, child: child);
          },
          transitionDuration: const Duration(milliseconds: 300) // Shorter transition
      ),
    ).then((_) {
      print("HomeScreen: Fall detection overlay was popped.");
      if (mounted) {
        // Ensure _isFallOverlayVisible is reset even if popped via back button
        if (_isFallOverlayVisible) { // Only if it was truly visible by our flag
          setState(() => _isFallOverlayVisible = false);
        }
        // If overlay was dismissed by other means (e.g. back button) and fall was active
        if (_currentFallDetectedUiState) {
          print("HomeScreen: Overlay popped via back button while fall was active. Resetting fall state.");
          _handleFallDetectedResetLogic();
        }
      }
    });
  }

  void _dismissFallDetectionOverlay() {
    if (_isFallOverlayVisible && mounted && Navigator.canPop(context)) {
      print("HomeScreen: Dismissing fall detection overlay programmatically.");
      Navigator.of(context).pop();
      // _isFallOverlayVisible is set to false in the .then() of push()
    }
  }

  void _handleFallDetectedResetLogic() {
    print("HomeScreen: Executing fall detected reset logic.");
    if (mounted) {
      // Check if overlay is still somehow visible and try to dismiss it again, just in case
      // This can happen if reset is called from multiple places or due to race conditions
      if (_isFallOverlayVisible && Navigator.canPop(context)) {
        // Don't pop here if this method is called from the overlay's own buttons' pop action
        // The primary role here is to reset the *state*.
      }
      setState(() {
        _currentFallDetectedUiState = false;
        // _isFallOverlayVisible = false; // This should be set when the overlay is actually popped
      });
    }
    _bleService.resetFallDetectedState();
  }


  void _handleConnectDisconnect() {
    // Get the absolute current state from the service before deciding action
    BleConnectionState currentState = _bleService.getCurrentConnectionState();
    print("HomeScreen: _handleConnectDisconnect called. Current BLE Service State: $currentState");

    if (currentState == BleConnectionState.connected) {
      print("HomeScreen: Disconnect button pressed.");
      _bleService.disconnectCurrentDevice(); // Use public method from reverted service
    } else if (currentState == BleConnectionState.connecting || currentState == BleConnectionState.disconnecting) {
      print("HomeScreen: Button pressed while connecting/disconnecting. No action taken.");
      // Optionally, implement a cancel connection attempt here if desired
    } else if (currentState == BleConnectionState.scanning) {
      print("HomeScreen: Stop Scan button pressed.");
      _bleService.stopScan(); // Use public method from reverted service
    }
    else { // Disconnected, scanStopped, noPermissions, bluetoothOff, unknown
      print("HomeScreen: Scan button pressed. Current state: $currentState");
      // The startBleScan() in the reverted BleService internally calls _requestPermissions if needed.
      _bleService.startBleScan(); // Use public method from reverted service
    }
  }

  void _handleCalibrate() {
    if (_bleService.getCurrentConnectionState() == BleConnectionState.connected) {
      print("HomeScreen: Calibrate button pressed.");
      _bleService.sendCalibrationCommand();
      if(mounted) {
        setState(() => _calibrationSuccess = true);
        _calibrationTimer?.cancel();
        _calibrationTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) setState(() => _calibrationSuccess = false);
        });
      }
    } else {
      print("HomeScreen: Cannot calibrate, not connected.");
      if(mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Cane not connected. Cannot calibrate."), duration: Duration(seconds: 2))
        );
      }
    }
  }

  Future<void> _handleSignOut() async {
    if (_isFallOverlayVisible && mounted && Navigator.canPop(context)) {
      Navigator.of(context).pop(); // Dismiss overlay first
      setState(() => _isFallOverlayVisible = false);
    }
    try {
      print("HomeScreen: Signing out.");
      // Disconnect before signing out from Google to ensure BLE cleanup
      if (_bleService.getCurrentConnectionState() == BleConnectionState.connected ||
          _bleService.getCurrentConnectionState() == BleConnectionState.connecting) {
        await _bleService.disconnectCurrentDevice(); // Ensure it's awaited if disconnect is async
        // Add a small delay to allow disconnect to propagate
        await Future.delayed(const Duration(milliseconds: 300));
      }
      await GoogleSignIn().signOut();
      print("HomeScreen: Google sign out successful.");
      if (mounted) Navigator.pushReplacementNamed(context, '/login');
    } catch (error) {
      print('HomeScreen: Error signing out: $error');
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
    _calibrationTimer?.cancel();

    // It's generally good practice for a service not to be "disposed" by one screen
    // if it's a true singleton intended to live longer or be used by other parts.
    // However, if BleService is only used by HomeScreen, then calling _bleService.dispose() here might be okay.
    // The reverted BleService's dispose() method calls disconnectFromDevice() itself.
    // For now, let's assume the BleService manages its own lifecycle or is disposed at a higher app level if needed.
    // If not, and it needs explicit cleanup tied to HomeScreen:
    // _bleService.dispose();

    super.dispose();
    print("HomeScreen: dispose finished.");
  }

  // --- BUILD METHOD ---
  // (Pasted from your provided code, ensure it uses the state variables correctly)
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final colorScheme = theme.colorScheme;

    // Determine colors based on the current theme's color scheme and text theme
    final Color primaryThemedColor = colorScheme.primary;
    final Color accentThemedColor = colorScheme.secondary;
    final Color errorThemedColor = colorScheme.error;
    // Warning color might not be in colorScheme, use AppTheme directly if needed
    final Color warningThemedColor = AppTheme.warningColor;
    final Color backgroundThemedColor = theme.scaffoldBackgroundColor;
    final Color cardThemedColor = theme.cardColor;
    final Color primaryTextThemedColor = colorScheme.onBackground;
    final Color secondaryTextThemedColor = colorScheme.onBackground.withOpacity(0.7);
    const Color textOnSolidColor = Colors.white; // For text on solid colored buttons/cards
    final Color onSurfaceThemedColor = colorScheme.onSurface; // For text on cards/surfaces


    bool showStatusCards = _currentConnectionState != BleConnectionState.disconnected || _scanResults.isNotEmpty;
    // More nuanced: show if not disconnected AND not just idly scanStopped without results
    // Or simply show always and let cards reflect state.
    // Let's try: show if not (disconnected AND no scan results AND not scanning)
    showStatusCards = !(_currentConnectionState == BleConnectionState.disconnected && _scanResults.isEmpty && _currentConnectionState != BleConnectionState.scanning);


    Widget mainBodyContent;
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), // Softer radius
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Device Name: ${_currentConnectedDevice!.platformName}', style: textTheme.titleMedium?.copyWith(color: onSurfaceThemedColor, fontWeight: FontWeight.w500)),
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
          Text('Discovered Devices:', style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, color: primaryTextThemedColor)),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: _scanResults.length,
              itemBuilder: (context, index) {
                final result = _scanResults[index];
                return Card( // Wrap ListTile in a Card for better spacing/visuals
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
                      // Stop scan is called within connectToDevice in the reverted BleService
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
      switch(_currentConnectionState) {
        case BleConnectionState.connecting: placeholderText = 'Connecting to your Smart Cane...'; break;
        case BleConnectionState.disconnecting: placeholderText = 'Disconnecting from Smart Cane...'; break;
        case BleConnectionState.scanning: placeholderText = 'Searching for your Smart Cane...'; break;
        case BleConnectionState.scanStopped:
          placeholderText = _scanResults.isEmpty ? 'Scan finished. No Smart Canes found nearby. Try scanning again.' : 'Scan stopped. Tap a device to connect.';
          break;
        case BleConnectionState.bluetoothOff: placeholderText = 'Bluetooth is turned off. Please turn Bluetooth on to connect to your Smart Cane.'; break;
        case BleConnectionState.noPermissions: placeholderText = 'Permissions for Bluetooth or Location are needed. Please grant them in app settings and try again.'; break;
        case BleConnectionState.unknown: placeholderText = 'Bluetooth status is unknown. Please check your Bluetooth settings.'; break;
        default: // disconnected
          placeholderText = 'Your Smart Cane is disconnected. Tap "Scan for Cane" to find and connect your device.';
      }
      mainBodyContent = Center(
        key: ValueKey('placeholder_$_currentConnectionState'), // Unique key for AnimatedSwitcher
        child: Padding(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.bluetooth_disabled, size: 60, color: secondaryTextThemedColor),
                const SizedBox(height: 20),
                Text(placeholderText, style: textTheme.titleMedium?.copyWith(color: secondaryTextThemedColor, height: 1.4), textAlign: TextAlign.center),
              ],
            )
        ),
      );
    }

    return Scaffold(
      backgroundColor: backgroundThemedColor,
      appBar: AppBar(
        title: const Text('Smart Cane Dashboard'),
        elevation: 1, // Subtle shadow
        actions: [ IconButton(icon: const Icon(Icons.logout_rounded), tooltip: 'Sign Out', onPressed: _handleSignOut) ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0), // Consistent padding
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, // Make buttons stretch
          children: <Widget>[
            Text('Status Overview', style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold, color: primaryTextThemedColor)),
            const SizedBox(height: 12),
            // Status Cards Area
            AnimatedOpacity( // Keep this general opacity for the whole status section
              opacity: 1.0, // Always show status cards, their content will reflect state
              duration: const Duration(milliseconds: 300),
              child: Column(
                children: [
                  // Connectivity Status Card
                  StreamBuilder<BleConnectionState>(
                    stream: _bleService.connectionStateStream,
                    initialData: _currentConnectionState, // Use current state as initial
                    builder: (context, snapshot) {
                      final state = snapshot.data ?? _currentConnectionState; // Use latest state
                      String statusText; IconData statusIcon; Color cardBackgroundColor; Color cardElementColor; Widget? trailingWidget;

                      switch (state) {
                        case BleConnectionState.connected:
                          statusText = "Connected: ${_currentConnectedDevice?.platformName ?? 'Smart Cane'}";
                          statusIcon = Icons.bluetooth_connected_rounded; cardBackgroundColor = accentThemedColor; cardElementColor = textOnSolidColor;
                          trailingWidget = Icon(Icons.check_circle_rounded, color: cardElementColor, size: 20); break;
                        case BleConnectionState.connecting:
                          statusText = "Connecting..."; statusIcon = Icons.bluetooth_searching_rounded; cardBackgroundColor = warningThemedColor; cardElementColor = textOnSolidColor;
                          trailingWidget = SizedBox(width:18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: cardElementColor)); break;
                        case BleConnectionState.disconnected:
                          statusText = "Disconnected"; statusIcon = Icons.bluetooth_disabled_rounded; cardBackgroundColor = cardThemedColor; cardElementColor = onSurfaceThemedColor; break;
                        case BleConnectionState.disconnecting:
                          statusText = "Disconnecting..."; statusIcon = Icons.bluetooth_disabled_rounded; cardBackgroundColor = warningThemedColor; cardElementColor = textOnSolidColor;
                          trailingWidget = SizedBox(width:18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: cardElementColor)); break;
                        case BleConnectionState.bluetoothOff:
                          statusText = "Bluetooth is Off"; statusIcon = Icons.bluetooth_disabled_rounded; cardBackgroundColor = errorThemedColor; cardElementColor = textOnSolidColor; break;
                        case BleConnectionState.noPermissions:
                          statusText = "Permissions Required"; statusIcon = Icons.gpp_bad_rounded; cardBackgroundColor = errorThemedColor; cardElementColor = textOnSolidColor; break;
                        case BleConnectionState.scanning:
                          statusText = "Scanning..."; statusIcon = Icons.search_rounded; cardBackgroundColor = warningThemedColor; cardElementColor = textOnSolidColor;
                          trailingWidget = SizedBox(width:18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: cardElementColor)); break;
                        case BleConnectionState.scanStopped:
                          statusText = "Scan Stopped"; statusIcon = Icons.search_off_rounded; cardBackgroundColor = cardThemedColor; cardElementColor = onSurfaceThemedColor; break;
                        default: // unknown
                          statusText = "Status Unknown"; statusIcon = Icons.help_outline_rounded; cardBackgroundColor = Colors.grey.shade700; cardElementColor = textOnSolidColor;
                      }
                      return Card(
                        elevation: 2, color: cardBackgroundColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                          child: Row(children: [
                            Icon(statusIcon, color: cardElementColor, size: 26), const SizedBox(width: 12),
                            Expanded(child: Text(statusText, style: textTheme.titleSmall?.copyWith(color: cardElementColor, fontWeight: FontWeight.w500))),
                            if (trailingWidget != null) trailingWidget,
                          ]),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  // Battery Level Card
                  Card(elevation: 2, color: cardThemedColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                      child: Row(children: [
                        Icon(
                            _currentConnectionState == BleConnectionState.connected && _currentBatteryLevel != null
                                ? (_currentBatteryLevel! > 95 ? Icons.battery_full_rounded :
                            _currentBatteryLevel! > 80 ? Icons.battery_6_bar_rounded :
                            _currentBatteryLevel! > 65 ? Icons.battery_5_bar_rounded :
                            _currentBatteryLevel! > 50 ? Icons.battery_4_bar_rounded :
                            _currentBatteryLevel! > 35 ? Icons.battery_3_bar_rounded :
                            _currentBatteryLevel! > 20 ? Icons.battery_2_bar_rounded :
                            _currentBatteryLevel! > 5  ? Icons.battery_1_bar_rounded : Icons.battery_alert_rounded)
                                : Icons.battery_unknown_rounded,
                            color: _currentConnectionState == BleConnectionState.connected && _currentBatteryLevel != null
                                ? (_currentBatteryLevel! > 40 ? accentThemedColor : _currentBatteryLevel! > 15 ? warningThemedColor : errorThemedColor)
                                : secondaryTextThemedColor,
                            size: 26),
                        const SizedBox(width: 12),
                        Text(
                          'Battery: ${_currentConnectionState == BleConnectionState.connected ? (_currentBatteryLevel?.toString() ?? '...') + '%' : 'N/A'}',
                          style: textTheme.titleSmall?.copyWith(color: onSurfaceThemedColor, fontWeight: FontWeight.w500),
                        ),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Fall Detection Card
                  Card(
                    elevation: 2, color: _currentFallDetectedUiState ? errorThemedColor : cardThemedColor,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                      child: Row(children: [
                        Icon(
                          _currentFallDetectedUiState ? Icons.error_rounded :
                          (_currentConnectionState == BleConnectionState.connected ? Icons.verified_user_outlined : Icons.shield_outlined), // Custom icons
                          color: _currentFallDetectedUiState ? textOnSolidColor :
                          (_currentConnectionState == BleConnectionState.connected ? accentThemedColor : secondaryTextThemedColor),
                          size: 26,
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: Text(
                          _currentFallDetectedUiState ? 'FALL DETECTED!' :
                          (_currentConnectionState == BleConnectionState.connected ? 'Protected' : 'Cane Disconnected'),
                          style: textTheme.titleSmall?.copyWith(
                            color: _currentFallDetectedUiState ? textOnSolidColor : onSurfaceThemedColor,
                            fontWeight: _currentFallDetectedUiState ? FontWeight.bold : FontWeight.w500,
                          ),
                        )),
                        if (_currentFallDetectedUiState)
                          TextButton(
                            onPressed: _handleFallDetectedResetLogic,
                            child: Text('RESET', style: textTheme.labelMedium?.copyWith(color: textOnSolidColor, fontWeight: FontWeight.bold)),
                            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
                          ),
                      ]),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20), // Spacing before buttons
            // Action Buttons
            ElevatedButton.icon(
              icon: Icon(
                  _currentConnectionState == BleConnectionState.connected ? Icons.bluetooth_disabled_rounded
                      : _currentConnectionState == BleConnectionState.scanning ? Icons.stop_circle_outlined
                      : Icons.bluetooth_searching_rounded,
                  color: textOnSolidColor),
              label: Text(
                  _currentConnectionState == BleConnectionState.connected ? 'Disconnect Cane'
                      : (_currentConnectionState == BleConnectionState.connecting ? 'Connecting...'
                      : (_currentConnectionState == BleConnectionState.scanning ? 'Stop Scan'
                      : 'Scan for Cane')), style: textTheme.labelLarge?.copyWith(color: textOnSolidColor)),
              onPressed: (_currentConnectionState == BleConnectionState.connecting || _currentConnectionState == BleConnectionState.disconnecting)
                  ? null : _handleConnectDisconnect,
              style: ElevatedButton.styleFrom(
                backgroundColor: _currentConnectionState == BleConnectionState.connected ? errorThemedColor.withOpacity(0.9) :
                (_currentConnectionState == BleConnectionState.noPermissions ? errorThemedColor : primaryThemedColor),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                textStyle: textTheme.labelLarge, // Ensure this is applied
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder: (Widget child, Animation<double> animation) {
                    return ScaleTransition(scale: animation, child: child);
                  },
                  child: _calibrationSuccess
                      ? Icon(Icons.check_circle_rounded, key: const ValueKey('cal_success'), color: accentThemedColor)
                      : Icon(Icons.settings_input_component_rounded,  key: const ValueKey('cal_default'), color: _currentConnectionState == BleConnectionState.connected ? primaryThemedColor : theme.disabledColor.withOpacity(0.6))
              ), // Changed icon
              label: Text(_calibrationSuccess ? 'Cane Calibrated!' : 'Calibrate Cane', style: textTheme.labelLarge),
              onPressed: (_currentConnectionState == BleConnectionState.connected && !_calibrationSuccess) ? _handleCalibrate : null,
              style: OutlinedButton.styleFrom(
                foregroundColor: _calibrationSuccess ? accentThemedColor : (_currentConnectionState == BleConnectionState.connected ? primaryThemedColor : theme.disabledColor.withOpacity(0.7)),
                side: BorderSide(color: _calibrationSuccess ? accentThemedColor : (_currentConnectionState == BleConnectionState.connected ? primaryThemedColor.withOpacity(0.7) : theme.disabledColor.withOpacity(0.4)), width: 1.5),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                textStyle: textTheme.labelLarge, // Ensure this is applied
              ),
            ),
            const SizedBox(height: 16), // Spacing before main content area
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (widget, animation) {
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition( // Add slight slide for content change
                      position: Tween<Offset>(begin: const Offset(0.0, 0.03), end: Offset.zero).animate(animation),
                      child: widget,
                    ),
                  );
                },
                child: KeyedSubtree(
                  key: ValueKey<String>(
                      _currentConnectionState == BleConnectionState.connected ? 'device_info_content' :
                      ((_currentConnectionState == BleConnectionState.scanning || _currentConnectionState == BleConnectionState.scanStopped) && _scanResults.isNotEmpty ? 'scan_results_content' : 'placeholder_content_${_currentConnectionState}')
                  ), // More descriptive keys
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