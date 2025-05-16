import 'package:flutter/material.dart';
// Keep AppTheme import if you need specific colors like warningColor that
// are not standard in ColorScheme.
import 'package:smart_cane_prototype/utils/app_theme.dart';
import 'package:google_sign_in/google_sign_in.dart'; // Keep for sign out
import 'package:smart_cane_prototype/services/ble_service.dart';
import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
// Removed the import for fall_detection_overlay.dart as we are not there yet.
// import 'package:smart_cane_prototype/widgets/fall_detection_overlay.dart';

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
  bool _currentFallDetected = false; // State variable for UI display
  BluetoothDevice? _currentConnectedDevice;
  bool _calibrationSuccess = false; // State to show calibration success feedback
  Timer? _calibrationTimer; // Timer for the calibration feedback duration

  StreamSubscription<BleConnectionState>? _connectionStateSubscription;
  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;
  StreamSubscription<int?>? _batteryLevelSubscription;
  StreamSubscription<bool?>? _fallDetectedSubscription;
  StreamSubscription<BluetoothDevice?>? _connectedDeviceSubscription;

  // Removed OverlayEntry variable and overlay-related methods/logic


  @override
  void initState() {
    super.initState();
    print("HomeScreen initState");

    _bleService.initialize();

    _connectionStateSubscription = _bleService.connectionStateStream.listen((state) {
      print("HomeScreen received connection state: $state");
      setState(() {
        _currentConnectionState = state;

        if (state != BleConnectionState.scanning && state != BleConnectionState.scanStopped && _scanResults.isNotEmpty) {
          _scanResults = [];
          print("Scan results cleared.");
        }

        if (state == BleConnectionState.disconnected ||
            state == BleConnectionState.bluetoothOff ||
            state == BleConnectionState.noPermissions ||
            state == BleConnectionState.unknown ||
            state == BleConnectionState.scanStopped) {
          _currentBatteryLevel = null;
          // Keep _currentFallDetected state for UI until reset button is pressed
          // _currentFallDetected = false; // Do not reset UI state automatically here
          print("Battery status reset.");
        }
      });
    });

    _scanResultsSubscription = _bleService.scanResultsStream.listen((results) {
      setState(() {
        if (_currentConnectionState == BleConnectionState.scanning || _currentConnectionState == BleConnectionState.scanStopped) {
          _scanResults = results.where((result) => result.device.platformName.isNotEmpty).toList();
          print("Scan results updated: ${_scanResults.length} non-empty names.");
        } else {
          _scanResults = [];
          print("Scan results cleared because state is not scanning/scanStopped.");
        }
      });
    });

    _batteryLevelSubscription = _bleService.batteryLevelStream.listen((level) {
      print("HomeScreen received battery level: $level");
      setState(() {
        _currentBatteryLevel = level;
      });
    });

    // Listen for fall detection events and update the UI state
    _fallDetectedSubscription = _bleService.fallDetectedStream.listen((bool? detected) {
      print("HomeScreen received fall detected: $detected");
      // Update the UI state variable when a fall is detected
      if (detected == true) {
        setState(() {
          _currentFallDetected = true;
        });
        print("Fall detected in HomeScreen! UI state updated.");
        // Note: The overlay logic will be added later, triggered by this state change.
      } else if (detected == false && _currentFallDetected) {
        // If cane sends 'false' notification while fall is active in UI state, reset the UI state.
        setState(() {
          _currentFallDetected = false;
        });
        _bleService.resetFallDetectedState(); // Reset service state as well if cane signals reset
      } else if (detected == null) {
        print("HomeScreen received null fall detected state from stream.");
        setState(() {
          _currentFallDetected = false; // Assume no fall on null
        });
      }
    });


    _connectedDeviceSubscription = _bleService.connectedDeviceStream.listen((device) {
      print("HomeScreen received connected device: ${device?.platformName}");
      setState(() {
        _currentConnectedDevice = device;
      });
    });


    // Start a scan when the screen loads if not connected
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_bleService.getCurrentConnectionState() == BleConnectionState.disconnected) {
        print("HomeScreen: Starting initial scan.");
        _bleService.startBleScan();
      } else {
        print("HomeScreen: Not starting initial scan, state is ${_bleService.getCurrentConnectionState()}.");
      }
    });
    print("HomeScreen initState finished.");
  }

  @override
  void dispose() {
    print("HomeScreen dispose");
    _connectionStateSubscription?.cancel();
    _scanResultsSubscription?.cancel();
    _batteryLevelSubscription?.cancel();
    _fallDetectedSubscription?.cancel();
    _connectedDeviceSubscription?.cancel();

    _calibrationTimer?.cancel(); // Cancel the calibration timer

    // Removed overlay removal logic

    _bleService.disconnectCurrentDevice(); // Disconnect from BLE on screen dispose

    super.dispose();
    print("HomeScreen dispose finished.");
  }

  // Removed _showFallDetectionOverlay and _hideFallDetectionOverlay methods


  // --- Button Actions ---
  void _handleConnectDisconnect() {
    if (_currentConnectionState == BleConnectionState.connected || _currentConnectionState == BleConnectionState.connecting || _currentConnectionState == BleConnectionState.disconnecting) {
      print("HomeScreen: Tapped Disconnect/Connecting button.");
      _bleService.disconnectCurrentDevice();
    } else if (_currentConnectionState == BleConnectionState.disconnected || _currentConnectionState == BleConnectionState.scanStopped || _currentConnectionState == BleConnectionState.noPermissions || _currentConnectionState == BleConnectionState.bluetoothOff || _currentConnectionState == BleConnectionState.unknown || _currentConnectionState == BleConnectionState.scanning) {
      print("HomeScreen: Tapped Scan/Connect button.");
      if (_currentConnectionState == BleConnectionState.scanning) {
        _bleService.stopScan();
      } else {
        _bleService.startBleScan();
      }
    }
  }

  void _handleCalibrate() {
    if (_currentConnectionState == BleConnectionState.connected) {
      print("HomeScreen: Tapped Calibrate button.");
      _bleService.sendCalibrationCommand();

      // --- Add Calibration Success Feedback Logic ---
      setState(() {
        _calibrationSuccess = true; // Show success feedback
      });
      _calibrationTimer?.cancel(); // Cancel any existing timer
      _calibrationTimer = Timer(const Duration(seconds: 5), () {
        setState(() {
          _calibrationSuccess = false; // Hide success feedback after 5 seconds
        });
      });
      // --- End of Calibration Success Feedback Logic ---

    } else {
      print("HomeScreen: Cannot calibrate: Not connected to the cane.");
    }
  }

  void _handleFallDetectedReset() {
    print("HomeScreen: Fall Detected Reset requested from UI.");
    setState(() {
      _currentFallDetected = false; // Reset UI state immediately
    });
    _bleService.resetFallDetectedState(); // Notify the service/ESP32 to clear its state
  }


  Future<void> _handleSignOut() async {
    try {
      print("HomeScreen: Attempting sign out.");
      await GoogleSignIn().signOut(); // Use the actual Google Sign-In sign out
      print('Signed out');
      _bleService.disconnectCurrentDevice(); // Ensure disconnect on sign out
      if (mounted) {
        Navigator.pushReplacementNamed(context, '/login');
      }
    } catch (error) {
      print('Error signing out: $error');
    }
  }


  @override
  Widget build(BuildContext context) {
    // Access the current theme based on device settings
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final colorScheme = theme.colorScheme;

    // Determine colors based on the current theme's color scheme and text theme
    final Color primaryThemedColor = colorScheme.primary;
    final Color accentThemedColor = colorScheme.secondary;
    final Color errorThemedColor = colorScheme.error;
    // Warning color might not be in colorScheme, use AppTheme directly if needed
    final Color warningThemedColor = AppTheme.warningColor; // Using static constant for this specific color
    final Color backgroundThemedColor = theme.scaffoldBackgroundColor;
    final Color cardThemedColor = theme.cardColor;
    // Get default text colors from the theme's text theme and on-colors from colorScheme
    // Use onBackground for text directly on the Scaffold background
    final Color primaryTextThemedColor = colorScheme.onBackground;
    final Color secondaryTextThemedColor = colorScheme.onBackground.withOpacity(0.7);
    // Explicitly using white for text on solid colors including warning/yellow
    const Color textOnSolidColor = Colors.white;
    // Text color on surface/card background uses onSurface
    final Color onSurfaceThemedColor = colorScheme.onSurface;


    bool showStatusCards = _currentConnectionState == BleConnectionState.connected ||
        _currentConnectionState == BleConnectionState.connecting ||
        _currentConnectionState == BleConnectionState.disconnecting ||
        _currentConnectionState == BleConnectionState.scanning ||
        _currentConnectionState == BleConnectionState.scanStopped ||
        _currentConnectionState == BleConnectionState.bluetoothOff ||
        _currentConnectionState == BleConnectionState.noPermissions ||
        _currentConnectionState == BleConnectionState.unknown;


    // Determine which content to show in the main flexible area
    Widget mainBodyContent;

    if (_currentConnectionState == BleConnectionState.connected && _currentConnectedDevice != null) {
      // Connected Device Info CONTENT
      mainBodyContent = Column(
        key: const ValueKey('connected_info'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          Text(
            'Device Information',
            style: textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: primaryTextThemedColor, // Use themed primary text color (on background)
            ),
          ),
          const SizedBox(height: 16),
          Card(
            elevation: 2,
            color: cardThemedColor, // Use themed card color
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Device Name: ${_currentConnectedDevice!.platformName}',
                      style: textTheme.bodyMedium?.copyWith(color: onSurfaceThemedColor) // Text on card uses onSurface
                  ),
                  const SizedBox(height: 8),
                  Text('Device ID: ${_currentConnectedDevice!.id.toString()}',
                      style: textTheme.bodyMedium?.copyWith(color: onSurfaceThemedColor) // Text on card uses onSurface
                  ),
                ],
              ),
            ),
          ),
        ],
      );

    } else if ((_currentConnectionState == BleConnectionState.scanning || _currentConnectionState == BleConnectionState.scanStopped) && _scanResults.isNotEmpty) {
      // Scan Results List CONTENT
      mainBodyContent = Column(
        key: const ValueKey('scan_results'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Discovered Devices:',
            style: textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: primaryTextThemedColor, // Use themed text color (on background)
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: _scanResults.length,
              itemBuilder: (context, index) {
                final result = _scanResults[index];
                // Use themed colors for ListTile text (on background)
                return ListTile(
                  title: Text(result.device.platformName,
                      style: textTheme.bodyMedium?.copyWith(color: primaryTextThemedColor)
                  ),
                  subtitle: Text(result.device.id.toString(),
                      style: textTheme.bodySmall?.copyWith(color: secondaryTextThemedColor)
                  ),
                  trailing: Text('${result.rssi} dBm',
                      style: textTheme.bodySmall?.copyWith(color: secondaryTextThemedColor)
                  ),
                  onTap: () {
                    print("HomeScreen: Tapped on device: ${result.device.platformName}");
                    _bleService.stopScan();
                    _bleService.connectToScannedDevice(result.device);
                  },
                );
              },
            ),
          ),
        ],
      );
    } else {
      // Placeholder or guidance text when not connected and no scan results
      mainBodyContent = Center(
        key: ValueKey('placeholder_${_currentConnectionState}'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Text(
            _currentConnectionState == BleConnectionState.connecting ? 'Connecting...'
                : (_currentConnectionState == BleConnectionState.disconnecting ? 'Disconnecting...'
                : (_currentConnectionState == BleConnectionState.scanning ? 'Searching for devices...'
                : (_currentConnectionState == BleConnectionState.scanStopped ? (_scanResults.isEmpty ? 'Scan finished. No devices found.' : 'Tap device to connect.')
                : (_currentConnectionState == BleConnectionState.bluetoothOff ? 'Bluetooth is turned off.'
                : (_currentConnectionState == BleConnectionState.noPermissions ? 'Permissions Needed.'
                : (_currentConnectionState == BleConnectionState.unknown ? 'Status Unknown.'
                : 'Tap "Scan for Cane" to find your device.'
            )))))),
            style: textTheme.bodyMedium?.copyWith(
              color: secondaryTextThemedColor, // Use themed secondary text color (on background)
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }


    return Scaffold(
      // Use themed background color
      backgroundColor: backgroundThemedColor,
      appBar: AppBar(
        // AppBar colors and title text style are handled by AppBarTheme in AppTheme
        title: const Text('Smart Cane Dashboard'), // Text widget itself doesn't need style here if AppBarTheme is set
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign Out',
            onPressed: _handleSignOut,
            // Icon color handled by AppBarTheme in AppTheme
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Status',
              style: textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: primaryTextThemedColor // Use themed primary text color (on background)
              ),
            ),
            const SizedBox(height: 16),

            // --- Status Cards (Animated Opacity) ---
            AnimatedOpacity(
              opacity: showStatusCards ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeIn,
              child: showStatusCards ? Column(
                children: [
                  // Connectivity Status Card
                  StreamBuilder<BleConnectionState>(
                    stream: _bleService.connectionStateStream,
                    initialData: _bleService.getCurrentConnectionState(),
                    builder: (context, snapshot) {
                      final state = snapshot.data ?? BleConnectionState.disconnected;
                      String statusText;
                      IconData statusIcon;
                      Color cardBackgroundColor; // Background color of this card
                      Color cardElementColor; // Text/Icon color on this card's background
                      Widget? trailingWidget;

                      switch (state) {
                        case BleConnectionState.connected:
                          statusText = "Connected";
                          statusIcon = Icons.bluetooth_connected;
                          cardBackgroundColor = accentThemedColor; // Connected card is accent colored
                          cardElementColor = textOnSolidColor; // Text color on accent background (white)
                          trailingWidget = Icon(Icons.check_circle, color: cardElementColor); // Icon color on accent background
                          break;
                        case BleConnectionState.connecting:
                          statusText = "Connecting...";
                          statusIcon = Icons.bluetooth_searching;
                          cardBackgroundColor = warningThemedColor; // Connecting card is warning colored (yellow)
                          cardElementColor = textOnSolidColor; // Text color on warning background (explicitly white)
                          trailingWidget = CircularProgressIndicator(strokeWidth: 2, color: cardElementColor); // Progress indicator color
                          break;
                        case BleConnectionState.disconnected:
                          statusText = "Disconnected";
                          statusIcon = Icons.bluetooth_disabled;
                          cardBackgroundColor = cardThemedColor; // Disconnected card is standard card color
                          cardElementColor = onSurfaceThemedColor; // Text color on card background (dark/light based on theme)
                          break;
                        case BleConnectionState.disconnecting:
                          statusText = "Disconnecting...";
                          statusIcon = Icons.bluetooth_disabled;
                          cardBackgroundColor = warningThemedColor; // Disconnecting card is warning colored (yellow)
                          cardElementColor = textOnSolidColor; // Text color on warning background (explicitly white)
                          trailingWidget = CircularProgressIndicator(strokeWidth: 2, color: cardElementColor); // Progress indicator color
                          break;
                        case BleConnectionState.bluetoothOff:
                          statusText = "Bluetooth is Off";
                          statusIcon = Icons.bluetooth_disabled;
                          cardBackgroundColor = errorThemedColor; // Error states are error colored (red)
                          cardElementColor = textOnSolidColor; // Text color on error background (white)
                          break;
                        case BleConnectionState.noPermissions:
                          statusText = "Permissions Needed";
                          statusIcon = Icons.bluetooth_disabled;
                          cardBackgroundColor = errorThemedColor; // Error states are error colored (red)
                          cardElementColor = textOnSolidColor; // Text color on error background (white)
                          break;
                        case BleConnectionState.unknown:
                          statusText = "Status Unknown";
                          statusIcon = Icons.bluetooth_disabled;
                          cardBackgroundColor = errorThemedColor; // Error states are error colored (red)
                          cardElementColor = textOnSolidColor; // Text color on error background (white)
                          break;
                        case BleConnectionState.scanning:
                          statusText = "Scanning...";
                          statusIcon = Icons.bluetooth_searching;
                          cardBackgroundColor = warningThemedColor; // Scanning card is warning colored (yellow)
                          cardElementColor = textOnSolidColor; // Text color on warning background (explicitly white)
                          trailingWidget = CircularProgressIndicator(strokeWidth: 2, color: cardElementColor); // Progress indicator color
                          break;
                        case BleConnectionState.scanStopped:
                          statusText = "Scan Stopped";
                          statusIcon = Icons.bluetooth_disabled;
                          cardBackgroundColor = cardThemedColor; // Scan stopped card is standard card color
                          cardElementColor = onSurfaceThemedColor; // Text color on card background (dark/light based on theme)
                          break;
                      }


                      return Card(
                        elevation: 2,
                        color: cardBackgroundColor, // Use determined background color
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Row(
                            children: [
                              Icon(statusIcon, color: cardElementColor), // Icon color matches text color
                              const SizedBox(width: 16),
                              Expanded(
                                child: Text(
                                  'Connectivity Status: $statusText',
                                  style: textTheme.bodyMedium?.copyWith(color: cardElementColor), // Use determined text color
                                ),
                              ),
                              if (trailingWidget != null) trailingWidget,
                            ],
                          ),
                        ),
                      );
                    },
                  ),

                  const SizedBox(height: 16),

                  // Battery Level Card
                  StreamBuilder<int?>(
                    stream: _bleService.batteryLevelStream,
                    initialData: _currentBatteryLevel,
                    builder: (context, snapshot) {
                      final batteryLevel = snapshot.data;
                      IconData batteryIcon; // Variable to hold the icon data
                      Color batteryIconColor; // Variable to hold the icon color
                      String batteryText;
                      Color cardElementColor = onSurfaceThemedColor; // Text color on standard card

                      // --- Logic to determine icon and color ---
                      if (_currentConnectionState != BleConnectionState.connected) {
                        batteryIcon = Icons.battery_unknown; // Unknown icon when not connected
                        batteryIconColor = secondaryTextThemedColor; // Use secondary color when not connected
                        batteryText = 'N/A';
                      } else if (batteryLevel != null) {
                        // Determine icon based on battery level when connected
                        if (batteryLevel > 95) {
                          batteryIcon = Icons.battery_full;
                        } else if (batteryLevel > 90) {
                          batteryIcon = Icons.battery_6_bar;
                        } else if (batteryLevel > 75) {
                          batteryIcon = Icons.battery_5_bar;
                        } else if (batteryLevel > 60) {
                          batteryIcon = Icons.battery_4_bar;
                        } else if (batteryLevel > 45) {
                          batteryIcon = Icons.battery_3_bar;
                        } else if (batteryLevel > 30) {
                          batteryIcon = Icons.battery_2_bar;
                        } else if (batteryLevel > 15) {
                          batteryIcon = Icons.battery_1_bar;
                        } else if (batteryLevel > 5) {
                          batteryIcon = Icons.battery_0_bar;
                        } else {
                          batteryIcon = Icons.battery_alert;
                        }

                        // Determine icon color based on battery level when connected
                        batteryIconColor = (batteryLevel > 45)
                            ? accentThemedColor // Use accent color for good battery
                            : (batteryLevel > 15 ? warningThemedColor
                            : errorThemedColor); // Use error color for low battery

                        batteryText = '$batteryLevel%';
                      } else {
                        batteryIcon = Icons.battery_unknown; // Unknown icon if level is null
                        batteryIconColor = secondaryTextThemedColor; // Use secondary color if level is null
                        batteryText = 'Loading...'; // Text if level is null
                      }
                      // --- End of Logic ---


                      return Card(
                        elevation: 2,
                        color: cardThemedColor, // Use themed card color
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Row(
                            children: [
                              Icon(batteryIcon, color: batteryIconColor), // Use determined icon and color
                              const SizedBox(width: 16),
                              Text(
                                'Battery Level: $batteryText',
                                style: textTheme.bodyMedium?.copyWith(color: cardElementColor), // Use themed text color on card
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),

                  const SizedBox(height: 16),

                  // Fall Detection Status Card with Reset Button
                  StreamBuilder<bool?>( // Stream type matches service stream
                    stream: _bleService.fallDetectedStream,
                    initialData: _currentFallDetected, // Initial data is non-nullable bool
                    builder: (context, snapshot) {
                      // Use the internal state for UI display, which is controlled by the stream listener
                      final fallDetected = _currentFallDetected; // Use the state variable

                      // Text and icon color when fall is detected is explicitly white
                      // Text and icon color when NOT detected is onSurfaceThemedColor (text color on card background)
                      final Color cardElementColor = fallDetected ? textOnSolidColor : onSurfaceThemedColor;


                      return Card(
                        elevation: 2,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        color: fallDetected ? errorThemedColor : cardThemedColor, // Use themed error/card color for background
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Row(
                            children: [
                              Icon(
                                fallDetected ? Icons.warning :
                                (_currentConnectionState == BleConnectionState.connected ? Icons.check_circle_outline : Icons.sync_problem_outlined),
                                color: fallDetected || _currentConnectionState != BleConnectionState.connected ? cardElementColor : accentThemedColor, // Apply determined color
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Text(
                                  '${fallDetected ? 'Fall Detected!' :
                                  (_currentConnectionState == BleConnectionState.connected ? 'No Fall Detected' : 'No Device Connected!')}',
                                  style: textTheme.bodyMedium?.copyWith(
                                    color: cardElementColor, // Apply determined text color
                                  ),
                                ),
                              ),
                              if (fallDetected)
                                TextButton(
                                  onPressed: _handleFallDetectedReset,
                                  child: Text(
                                    'Reset',
                                    style: textTheme.labelLarge?.copyWith(
                                      color: cardElementColor, // Apply determined text color (should be white when fallDetected)
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ) : const SizedBox.shrink(),
            ),


            const SizedBox(height: 40),

            // --- Action Buttons ---

            // Connect/Disconnect/Scan Button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _currentConnectionState == BleConnectionState.connecting ||
                    _currentConnectionState == BleConnectionState.disconnecting ||
                    _currentConnectionState == BleConnectionState.bluetoothOff ||
                    _currentConnectionState == BleConnectionState.noPermissions ||
                    _currentConnectionState == BleConnectionState.unknown ? null : _handleConnectDisconnect,
                style: ElevatedButton.styleFrom(
                  // Ensure foreground color is white on colored buttons
                  foregroundColor: textOnSolidColor, // Explicitly use white for text on this primary colored button
                ),
                child: Text(
                  _currentConnectionState == BleConnectionState.connected ? 'Disconnect'
                      : (_currentConnectionState == BleConnectionState.connecting ? 'Connecting...'
                      : (_currentConnectionState == BleConnectionState.scanning ? 'Scanning...'
                      : (_currentConnectionState == BleConnectionState.scanStopped ? (_scanResults.isEmpty ? 'Scan finished. No devices found.' : 'Tap device to connect.')
                      : 'Scan for Cane'))),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Calibrate Button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _currentConnectionState == BleConnectionState.connected && !_calibrationSuccess // Disable button while showing success
                    ? _handleCalibrate
                    : null,
                style: ButtonStyle( // Use ButtonStyle for MaterialStateProperty
                  // --- More Robust Background Color Logic ---
                  backgroundColor: MaterialStateProperty.resolveWith<Color?>((states) {
                    if (_calibrationSuccess) {
                      return accentThemedColor; // Green when successful
                    }
                    if (states.contains(MaterialState.disabled)) {
                      return theme.disabledColor; // Theme's disabled color
                    }
                    // Use primary color when connected and not successful/disabled
                    return primaryThemedColor;
                  }),
                  // --- More Robust Foreground Color (Text/Icon) Logic ---
                  foregroundColor: MaterialStateProperty.resolveWith<Color?>((states) {
                    if (_calibrationSuccess || _currentConnectionState == BleConnectionState.connected) {
                      // White text/icon when showing success (green background)
                      // or when connected (blue background)
                      return textOnSolidColor;
                    }
                    // Dark text when disabled (on disabled color background)
                    if (states.contains(MaterialState.disabled)) {
                      return theme.colorScheme.onSurface.withOpacity(0.38);
                    }
                    // Default text color (shouldn't be reached with the above logic but good practice)
                    return theme.colorScheme.onSurface;
                  }),
                  padding: MaterialStateProperty.all(const EdgeInsets.symmetric(horizontal: 24, vertical: 12)),
                  shape: MaterialStateProperty.all(RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  )),
                  // Text style is often inherited, but can be set here if needed
                  // textStyle: MaterialStateProperty.all(textTheme.labelLarge),
                ),
                // --- Refined AnimatedSwitcher with Scale Transition ---
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300), // Animation duration
                  transitionBuilder: (Widget child, Animation<double> animation) {
                    // Scale Transition
                    return ScaleTransition(
                      scale: animation, // Scale the child widget
                      child: child,
                    );
                    // Or a simple Fade Transition
                    // return FadeTransition(
                    //   opacity: animation,
                    //   child: child,
                    // );
                  },
                  child: _calibrationSuccess // Show different content based on success state
                      ? Row( // Row for checkmark and text
                    key: const ValueKey('calibration_success'), // Unique key for AnimatedSwitcher
                    mainAxisSize: MainAxisSize.min, // Keep row size minimal
                    mainAxisAlignment: MainAxisAlignment.center, // Center content in the button
                    children: [
                      Icon(Icons.check_circle_outline, color: textOnSolidColor), // White checkmark icon
                      const SizedBox(width: 8), // Spacing
                      Text(
                        'Calibration Successful',
                        style: textTheme.labelLarge?.copyWith(color: textOnSolidColor), // White text
                      ),
                    ],
                  )
                      : Text( // Standard button text
                      key: const ValueKey('calibrate_button_text'), // Unique key for AnimatedSwitcher
                      'Calibrate Cane',
                      style: textTheme.labelLarge?.copyWith( // Apply theme text style
                        color: textOnSolidColor, // Text color is white on colored button
                      )
                  ),
                ),
                // --- End of AnimatedSwitcher ---
              ),
            ),

            const SizedBox(height: 24),

            // --- Main Body Section (Animated Switcher) ---
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                switchInCurve: Curves.easeIn,
                switchOutCurve: Curves.easeOut,
                transitionBuilder: (widget, animation) {
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0.0, 0.05),
                        end: Offset.zero,
                      ).animate(animation),
                      child: widget,
                    ),
                  );
                },
                child: KeyedSubtree(
                  key: ValueKey<String>(
                      _currentConnectionState == BleConnectionState.connected ? 'connected'
                          : (_currentConnectionState == BleConnectionState.scanning || _currentConnectionState == BleConnectionState.scanStopped ? 'scan_results'
                          : 'placeholder')
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