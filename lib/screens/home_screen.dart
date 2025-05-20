import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:smart_cane_prototype/services/ble_service.dart'; // Ensure this path is correct
import 'package:smart_cane_prototype/utils/app_theme.dart';    // Ensure this path is correct
import 'package:smart_cane_prototype/widgets/fall_detection_overlay.dart'; // Ensure this path is correct

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
  CalibrationState _calibrationProcessState = CalibrationState.idle; // Initial state

  StreamSubscription<BleConnectionState>? _connectionStateSubscription;
  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;
  StreamSubscription<int?>? _batteryLevelSubscription;
  StreamSubscription<bool>? _fallDetectedSubscription;
  StreamSubscription<BluetoothDevice?>? _connectedDeviceSubscription;
  StreamSubscription<CalibrationState>? _calibrationStatusSubscription;

  bool _isFallOverlayVisible = false;

  @override
  void initState() {
    super.initState();
    print("HomeScreen: initState");

    _connectionStateSubscription = _bleService.connectionStateStream.listen((state) {
      if (!mounted) return;
      print("HomeScreen: Received connection state: $state");
      setState(() {
        _currentConnectionState = state;
        if (state != BleConnectionState.scanning && state != BleConnectionState.scanStopped) {
          if (_scanResults.isNotEmpty && state != BleConnectionState.scanStopped) _scanResults = [];
        }
        if (state == BleConnectionState.disconnected ||
            state == BleConnectionState.bluetoothOff ||
            state == BleConnectionState.noPermissions ||
            state == BleConnectionState.unknown) {
          _currentBatteryLevel = null;
          _currentConnectedDevice = null;
          _calibrationProcessState = CalibrationState.idle;
        }
        if (state == BleConnectionState.connected && _currentConnectedDevice != null) {
          if(_scanResults.isNotEmpty) _scanResults = [];
        }
      });
    }, onError: (e, s) => print("HomeScreen: Error in connectionStateStream: $e\n$s"));

    _scanResultsSubscription = _bleService.scanResultsStream.listen((results) {
      if (!mounted) return;
      if (_currentConnectionState == BleConnectionState.scanning || _currentConnectionState == BleConnectionState.scanStopped) {
        setState(() {
          _scanResults = results.where((result) => result.device.platformName.isNotEmpty).toList();
        });
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
      if (device == null) {
        _currentBatteryLevel = null;
        _calibrationProcessState = CalibrationState.idle;
      }
    }, onError: (e, s) => print("HomeScreen: Error in connectedDeviceStream: $e\n$s"));

    _calibrationStatusSubscription = _bleService.calibrationStatusStream.listen((status) {
      if (!mounted) return;
      print("HomeScreen DEBUG: Received calibration status via stream: $status");
      setState(() {
        _calibrationProcessState = status;
      });
      if (status == CalibrationState.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: const Text("Calibration Successful!"), backgroundColor: Theme.of(context).colorScheme.secondary),
        );
      } else if (status == CalibrationState.failed) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: const Text("Calibration Failed."), backgroundColor: Theme.of(context).colorScheme.error),
        );
      }
    }, onError: (e,s) => print("HomeScreen DEBUG ERROR: Error in _calibrationStatusStream: $e\n$s"));
    print("HomeScreen DEBUG: Subscribed to _bleService.calibrationStatusStream in initState.");

    _initializeBleAndMaybeScan();
    print("HomeScreen: initState finished synchronous part.");
  }

  Future<void> _initializeBleAndMaybeScan() async {
    print("HomeScreen: Initializing BleService...");
    await _bleService.initialize();
    if (!mounted) return;
    print("HomeScreen: BleService initialize call completed.");
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    BleConnectionState initialStateAfterInit = _bleService.getCurrentConnectionState();
    print("HomeScreen: State after BleService init and delay: $initialStateAfterInit");
    if (_currentConnectionState != initialStateAfterInit) {
      setState(() { _currentConnectionState = initialStateAfterInit; });
    }
    if (initialStateAfterInit == BleConnectionState.disconnected) {
      print("HomeScreen: State is disconnected after init. Attempting initial scan.");
      _bleService.startScan();
    } else if (initialStateAfterInit == BleConnectionState.noPermissions) {
      print("HomeScreen: BleService reports no permissions after init. Scan not started.");
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
          opaque: false,
          pageBuilder: (context, animation, secondaryAnimation) => FallDetectionOverlay(
            initialCountdownSeconds: 30,
            onImOk: () {
              print("HomeScreen: 'I'm OK' pressed from overlay.");
              if(Navigator.canPop(context)) Navigator.of(context).pop();
              _handleFallDetectedResetLogic();
            },
            onCallEmergency: () {
              print("HomeScreen: 'Call Emergency' pressed from overlay.");
              if(Navigator.canPop(context)) Navigator.of(context).pop();
              _performEmergencyCallAndActions();
              _handleFallDetectedResetLogic();
            },
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
          transitionDuration: const Duration(milliseconds: 300)
      ),
    ).then((_) {
      print("HomeScreen: Fall detection overlay was popped or dismissed.");
      if (mounted) {
        final bool wasFallActiveBeforePop = _currentFallDetectedUiState;
        if (_isFallOverlayVisible) {
          setState(() => _isFallOverlayVisible = false);
        }
        if (wasFallActiveBeforePop) {
          print("HomeScreen: Overlay dismissed while fall was UI-active. Resetting state.");
          _handleFallDetectedResetLogic();
        }
      }
    });
  }

  void _dismissFallDetectionOverlay() {
    if (_isFallOverlayVisible && mounted && Navigator.canPop(context)) {
      print("HomeScreen: Dismissing fall detection overlay programmatically.");
      Navigator.of(context).pop();
    }
  }

  void _performEmergencyCallAndActions() {
    _bleService.makePhoneCall('+19058028483');
  }

  void _handleFallDetectedResetLogic() {
    print("HomeScreen: Executing fall detected reset logic.");
    if (mounted) {
      setState(() {
        _currentFallDetectedUiState = false;
      });
    }
    _bleService.resetFallDetectedStateLocally();
  }

  void _handleConnectDisconnect() {
    BleConnectionState serviceState = _bleService.getCurrentConnectionState();
    print("HomeScreen: _handleConnectDisconnect called. Current BLE Service State: $serviceState");
    if (serviceState == BleConnectionState.connected) {
      _bleService.disconnectFromDevice();
    } else if (serviceState == BleConnectionState.connecting || serviceState == BleConnectionState.disconnecting) {
      print("HomeScreen: Button pressed while connecting/disconnecting. No action.");
    } else if (serviceState == BleConnectionState.scanning) {
      _bleService.stopScan();
    } else {
      _bleService.startScan();
    }
  }

  // --- MODIFIED _handleCalibrate ---
  void _handleCalibrate() {
    if (_bleService.getCurrentConnectionState() == BleConnectionState.connected) {
      print("HomeScreen: Calibrate button pressed.");
      if (mounted) {
        // **CRITICAL: Set state to idle *before* sending the command.**
        // This ensures the UI resets if the user clicks "Calibrate" again while
        // a previous (e.g., failed) state is showing. The UI will then wait for
        // the "inProgress" (2) notification from the ESP32.
        setState(() {
          _calibrationProcessState = CalibrationState.idle;
        });
      }
      // Now send the command. BleService will handle emitting .failed if the send itself fails.
      // Otherwise, we wait for the ESP32 to send status 2 (inProgress).
      _bleService.sendCalibrationCommand();
    } else {
      print("HomeScreen: Cannot calibrate, not connected.");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Cane not connected. Cannot calibrate."), duration: Duration(seconds: 2))
        );
      }
    }
  }
  // --- END OF MODIFIED _handleCalibrate ---

  Future<void> _handleSignOut() async {
    if (_isFallOverlayVisible && mounted && Navigator.canPop(context)) {
      Navigator.of(context).pop();
      setState(() => _isFallOverlayVisible = false);
    }
    try {
      print("HomeScreen: Signing out.");
      if (_bleService.getCurrentConnectionState() == BleConnectionState.connected ||
          _bleService.getCurrentConnectionState() == BleConnectionState.connecting) {
        await _bleService.disconnectFromDevice();
        await Future.delayed(const Duration(milliseconds: 300));
      }
      await GoogleSignIn().signOut();
      if (mounted) Navigator.pushReplacementNamed(context, '/login');
    } catch (error) {
      print('HomeScreen: Error signing out: $error');
      if(mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error signing out: $error'), backgroundColor: Theme.of(context).colorScheme.error),
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
    _calibrationStatusSubscription?.cancel();
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
    final Color primaryTextThemedColor = colorScheme.onBackground;
    final Color secondaryTextThemedColor = colorScheme.onBackground.withOpacity(0.7);
    const Color textOnSolidColor = Colors.white;
    final Color onSurfaceThemedColor = colorScheme.onSurface;

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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
          if (_scanResults.isEmpty && _currentConnectionState == BleConnectionState.scanStopped)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20.0),
              child: Center(child: Text("No Smart Canes found nearby.", style: textTheme.titleMedium?.copyWith(color: secondaryTextThemedColor))),
            )
          else if (_scanResults.isEmpty && _currentConnectionState == BleConnectionState.scanning)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20.0),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            Expanded(
              child: ListView.builder(
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
        case BleConnectionState.bluetoothOff:
          placeholderText = 'Bluetooth is turned off. Please turn Bluetooth on to connect.';
          break;
        case BleConnectionState.noPermissions:
          placeholderText = 'Permissions are needed. Please grant them in app settings.';
          placeholderIcon = Icons.gpp_bad_rounded;
          break;
        case BleConnectionState.unknown:
          placeholderText = 'Bluetooth status is unknown. Check settings.';
          placeholderIcon = Icons.help_outline_rounded;
          break;
        default:
          placeholderText = 'Your Smart Cane is disconnected. Tap "Scan" to connect.';
      }
      mainBodyContent = Center(
        key: ValueKey('placeholder_$_currentConnectionState'),
        child: Padding(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(placeholderIcon, size: 60, color: secondaryTextThemedColor),
                const SizedBox(height: 20),
                Text(placeholderText, style: textTheme.titleMedium?.copyWith(color: secondaryTextThemedColor, height: 1.4), textAlign: TextAlign.center),
                if(showProgress) const Padding(padding: EdgeInsets.only(top: 20.0), child: CircularProgressIndicator()),
              ],
            )
        ),
      );
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
            Column(
              children: [
                StreamBuilder<BleConnectionState>(
                  stream: _bleService.connectionStateStream,
                  initialData: _currentConnectionState,
                  builder: (context, snapshot) {
                    final state = snapshot.data ?? _currentConnectionState;
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
                      default:
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
                Card(
                  elevation: 2, color: cardThemedColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
                        'Battery: ${_currentConnectionState == BleConnectionState.connected && _currentBatteryLevel != null ? ("${_currentBatteryLevel!}%") : 'N/A'}',
                        style: textTheme.titleSmall?.copyWith(color: onSurfaceThemedColor, fontWeight: FontWeight.w500),
                      ),
                    ]),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  elevation: 2, color: _currentFallDetectedUiState ? errorThemedColor : cardThemedColor,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                    child: Row(children: [
                      Icon(
                        _currentFallDetectedUiState ? Icons.error_rounded :
                        (_currentConnectionState == BleConnectionState.connected ? Icons.verified_user_outlined : Icons.shield_outlined),
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
            const SizedBox(height: 20),
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
                textStyle: textTheme.labelLarge,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (Widget child, Animation<double> animation) {
                  return ScaleTransition(scale: animation, child: child);
                },
                child: switch (_calibrationProcessState) {
                  CalibrationState.inProgress => SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      key: const ValueKey('cal_progress'),
                      color: _currentConnectionState == BleConnectionState.connected ? primaryThemedColor : theme.disabledColor.withOpacity(0.6),
                    ),
                  ),
                  CalibrationState.success => Icon(Icons.check_circle_rounded, key: const ValueKey('cal_success'), color: accentThemedColor),
                  CalibrationState.failed => Icon(Icons.error_outline_rounded, key: const ValueKey('cal_fail'), color: errorThemedColor),
                  CalibrationState.idle || _ => Icon(Icons.settings_input_component_rounded,  key: const ValueKey('cal_default'), color: _currentConnectionState == BleConnectionState.connected ? primaryThemedColor : theme.disabledColor.withOpacity(0.6)),
                },
              ),
              label: Text(
                  switch (_calibrationProcessState) {
                    CalibrationState.inProgress => 'Calibrating...',
                    CalibrationState.success    => 'Cane Calibrated!',
                    CalibrationState.failed     => 'Calibration Failed',
                    CalibrationState.idle || _  => 'Calibrate Cane',
                  },
                  style: textTheme.labelLarge
              ),
              onPressed: (_currentConnectionState == BleConnectionState.connected && _calibrationProcessState != CalibrationState.inProgress)
                  ? _handleCalibrate
                  : null,
              style: OutlinedButton.styleFrom(
                foregroundColor: switch (_calibrationProcessState) {
                  CalibrationState.inProgress => primaryThemedColor,
                  CalibrationState.success    => accentThemedColor,
                  CalibrationState.failed     => errorThemedColor,
                  CalibrationState.idle || _  => _currentConnectionState == BleConnectionState.connected ? primaryThemedColor : theme.disabledColor.withOpacity(0.7),
                },
                side: BorderSide(
                    color: switch (_calibrationProcessState) {
                      CalibrationState.inProgress => primaryThemedColor.withOpacity(0.7),
                      CalibrationState.success    => accentThemedColor,
                      CalibrationState.failed     => errorThemedColor,
                      CalibrationState.idle || _  => _currentConnectionState == BleConnectionState.connected ? primaryThemedColor.withOpacity(0.7) : theme.disabledColor.withOpacity(0.4),
                    },
                    width: 1.5
                ),
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
                child: KeyedSubtree(
                  key: ValueKey<String>(
                      _currentConnectionState == BleConnectionState.connected && _currentConnectedDevice != null ? 'device_info_content' :
                      ((_currentConnectionState == BleConnectionState.scanning || (_currentConnectionState == BleConnectionState.scanStopped && _scanResults.isNotEmpty)) ? 'scan_results_content' : 'placeholder_content_${_currentConnectionState.name}')
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