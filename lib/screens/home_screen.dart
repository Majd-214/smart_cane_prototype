import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:smart_cane_prototype/utils/app_theme.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:smart_cane_prototype/services/ble_service.dart';
import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

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

  StreamSubscription<BleConnectionState>? _connectionStateSubscription;
  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;
  StreamSubscription<int?>? _batteryLevelSubscription;
  StreamSubscription<bool>? _fallDetectedSubscription;
  StreamSubscription<BluetoothDevice?>? _connectedDeviceSubscription;


  @override
  void initState() {
    super.initState();
    print("HomeScreen initState");

    _bleService.initialize();

    _connectionStateSubscription = _bleService.connectionStateStream.listen((state) {
      print("HomeScreen received connection state: $state");
      print("showStatusCards will be: ${state == BleConnectionState.connected || state == BleConnectionState.connecting || state == BleConnectionState.disconnecting || state == BleConnectionState.scanning || state == BleConnectionState.scanStopped || state == BleConnectionState.bluetoothOff || state == BleConnectionState.noPermissions || state == BleConnectionState.unknown}");
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
          _currentFallDetected = false;
          print("Battery and Fall status reset.");
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

    _fallDetectedSubscription = _bleService.fallDetectedStream.listen((detected) {
      print("HomeScreen received fall detected: $detected");
      if (detected) {
        setState(() {
          _currentFallDetected = detected;
        });
        print("Fall detected in HomeScreen! Time to show the overlay.");
      }
    });

    _connectedDeviceSubscription = _bleService.connectedDeviceStream.listen((device) {
      print("HomeScreen received connected device: ${device?.platformName}");
      setState(() {
        _currentConnectedDevice = device;
      });
    });


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

    _bleService.disconnectCurrentDevice();

    super.dispose();
    print("HomeScreen dispose finished.");
  }


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
    } else {
      print("HomeScreen: Cannot calibrate: Not connected to the cane.");
    }
  }

  void _handleFallDetectedReset() {
    print("HomeScreen: Fall Detected Reset requested.");
    setState(() {
      _currentFallDetected = false;
    });
    _bleService.resetFallDetectedState();
  }


  Future<void> _handleSignOut() async {
    try {
      print("HomeScreen: Attempting sign out.");
      await GoogleSignIn().signOut();
      print('Signed out');
      _bleService.disconnectCurrentDevice();
      if (mounted) {
        Navigator.pushReplacementNamed(context, '/login');
      }
    } catch (error) {
      print('Error signing out: $error');
    }
  }


  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    bool showStatusCards = _currentConnectionState == BleConnectionState.connected ||
        _currentConnectionState == BleConnectionState.connecting ||
        _currentConnectionState == BleConnectionState.disconnecting ||
        _currentConnectionState == BleConnectionState.scanning ||
        _currentConnectionState == BleConnectionState.scanStopped ||
        _currentConnectionState == BleConnectionState.bluetoothOff ||
        _currentConnectionState == BleConnectionState.noPermissions ||
        _currentConnectionState == BleConnectionState.unknown;


    // Determine which content to show in the main flexible area
    Widget mainBodyContent; // This variable holds the WIDGET that goes inside the Expanded AnimatedSwitcher

    if (_currentConnectionState == BleConnectionState.connected && _currentConnectedDevice != null) {
      // Connected Device Info CONTENT
      mainBodyContent = Column(
        key: const ValueKey('connected_info'), // Add unique key for AnimatedSwitcher
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          Text(
            'Device Information',
            style: textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Device Name: ${_currentConnectedDevice!.platformName}', style: textTheme.bodyMedium),
                  const SizedBox(height: 8),
                  Text('Device ID: ${_currentConnectedDevice!.id.toString()}', style: textTheme.bodyMedium),
                ],
              ),
            ),
          ),
        ],
      );

    } else if ((_currentConnectionState == BleConnectionState.scanning || _currentConnectionState == BleConnectionState.scanStopped) && _scanResults.isNotEmpty) {
      // Scan Results List CONTENT
      mainBodyContent = Column( // This column is the child of the Expanded AnimatedSwitcher
        key: const ValueKey('scan_results'), // Add unique key for AnimatedSwitcher
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Discovered Devices:',
            style: textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Expanded( // This Expanded is correctly inside the content column
            child: ListView.builder(
              itemCount: _scanResults.length,
              itemBuilder: (context, index) {
                final result = _scanResults[index];
                return ListTile(
                  title: Text(result.device.platformName, style: textTheme.bodyMedium),
                  subtitle: Text(result.device.id.toString(), style: textTheme.bodySmall),
                  trailing: Text('${result.rssi} dBm', style: textTheme.bodySmall),
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
      // Also show placeholder during connection/disconnection phases
      mainBodyContent = Center(
        key: ValueKey('placeholder_${_currentConnectionState}'),
        child: Text(
          _currentConnectionState == BleConnectionState.connecting ? 'Connecting...'
              : (_currentConnectionState == BleConnectionState.disconnecting ? 'Disconnecting...'
              : (_currentConnectionState == BleConnectionState.scanning ? 'Searching for devices...'
              : (_currentConnectionState == BleConnectionState.scanStopped ? (_scanResults.isEmpty ? 'Scan finished. No devices found.' : 'Tap device to connect.') // Clarify scan stopped text
              : (_currentConnectionState == BleConnectionState.bluetoothOff ? 'Bluetooth is turned off.'
              : (_currentConnectionState == BleConnectionState.noPermissions ? 'Bluetooth permissions needed.'
              : (_currentConnectionState == BleConnectionState.unknown ? 'Bluetooth status unknown.'
              : 'Tap "Scan for Cane" to find your device.'
          )))))),
          style: textTheme.bodyMedium?.copyWith(
            color: AppTheme.textColorSecondary,
          ),
          textAlign: TextAlign.center,
        ),
      );
    }


    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Smart Cane Dashboard',
          style: textTheme.titleLarge?.copyWith(
              color: AppTheme.darkTextColorPrimary
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign Out',
            onPressed: _handleSignOut,
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
                      Color statusColor;
                      Widget? trailingWidget;

                      switch (state) {
                        case BleConnectionState.connected:
                          statusText = "Connected";
                          statusIcon = Icons.bluetooth_connected;
                          statusColor = AppTheme.accentColor;
                          trailingWidget = Icon(Icons.check_circle, color: AppTheme.accentColor);
                          break;
                        case BleConnectionState.connecting:
                          statusText = "Connecting...";
                          statusIcon = Icons.bluetooth_searching;
                          statusColor = AppTheme.warningColor;
                          trailingWidget = const SizedBox(
                            height: 20, width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          );
                          break;
                        case BleConnectionState.disconnected:
                          statusText = "Disconnected";
                          statusIcon = Icons.bluetooth_disabled;
                          statusColor = AppTheme.textColorSecondary;
                          break;
                        case BleConnectionState.disconnecting:
                          statusText = "Disconnecting...";
                          statusIcon = Icons.bluetooth_disabled;
                          statusColor = AppTheme.warningColor;
                          trailingWidget = const SizedBox(
                            height: 20, width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          );
                          break;
                        case BleConnectionState.bluetoothOff:
                          statusText = "Bluetooth is Off";
                          statusIcon = Icons.bluetooth_disabled;
                          statusColor = AppTheme.errorColor;
                          break;
                        case BleConnectionState.noPermissions:
                          statusText = "Permissions Needed";
                          statusIcon = Icons.bluetooth_disabled;
                          statusColor = AppTheme.errorColor;
                          break;
                        case BleConnectionState.unknown:
                          statusText = "Status Unknown";
                          statusIcon = Icons.bluetooth_disabled;
                          statusColor = AppTheme.errorColor;
                          break;
                        case BleConnectionState.scanning:
                          statusText = "Scanning...";
                          statusIcon = Icons.bluetooth_searching;
                          statusColor = AppTheme.warningColor;
                          trailingWidget = const SizedBox(
                            height: 20, width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          );
                          break;
                        case BleConnectionState.scanStopped:
                          statusText = "Scan Stopped";
                          statusIcon = Icons.bluetooth_disabled;
                          statusColor = AppTheme.textColorSecondary;
                          break;
                      }

                      return Card(
                        elevation: 2,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Row(
                            children: [
                              Icon(statusIcon, color: statusColor),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Text(
                                  'Connectivity Status: $statusText',
                                  style: textTheme.bodyMedium,
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
                      IconData batteryIcon;
                      Color batteryColor;
                      String batteryText;

                      if (_currentConnectionState != BleConnectionState.connected) {
                        batteryIcon = Icons.battery_unknown;
                        batteryColor = AppTheme.textColorSecondary;
                        batteryText = 'N/A';
                      } else if (batteryLevel != null) {
                        batteryIcon = (batteryLevel > 75 ? Icons.battery_full : (batteryLevel > 25 ? Icons.battery_std : Icons.battery_alert));
                        batteryColor = (batteryLevel > 25 ? AppTheme.accentColor : AppTheme.errorColor);
                        batteryText = '$batteryLevel%';
                      } else {
                        batteryIcon = Icons.battery_unknown;
                        batteryColor = AppTheme.textColorSecondary;
                        batteryText = 'Loading...';
                      }

                      return Card(
                        elevation: 2,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Row(
                            children: [
                              Icon(batteryIcon, color: batteryColor),
                              const SizedBox(width: 16),
                              Text(
                                'Battery Level: $batteryText',
                                style: textTheme.bodyMedium,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),

                  const SizedBox(height: 16),

                  // Fall Detection Status Card with Reset Button
                  StreamBuilder<bool>(
                    stream: _bleService.fallDetectedStream,
                    initialData: _currentFallDetected,
                    builder: (context, snapshot) {
                      final fallDetected = _currentFallDetected;

                      return Card(
                        elevation: 2,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        color: fallDetected ? AppTheme.errorColor : null,
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Row(
                            children: [
                              Icon(
                                fallDetected ? Icons.warning : Icons.check_circle_outline,
                                color: fallDetected ? Colors.white : AppTheme.accentColor,
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Text(
                                  'Fall Detected: ${fallDetected ? 'Yes' : 'No'}',
                                  style: textTheme.bodyMedium?.copyWith(
                                    color: fallDetected ? Colors.white : AppTheme.textColorPrimary,
                                  ),
                                ),
                              ),
                              if (fallDetected)
                                TextButton(
                                  onPressed: _handleFallDetectedReset,
                                  child: Text(
                                    'Reset',
                                    style: textTheme.labelLarge?.copyWith(
                                      color: fallDetected ? Colors.white : AppTheme.primaryColor,
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
                onPressed: _currentConnectionState == BleConnectionState.connected ? _handleCalibrate : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _currentConnectionState == BleConnectionState.connected ? AppTheme.primaryColor : Colors.grey,
                ),
                child: const Text('Calibrate Cane'),
              ),
            ),
            const SizedBox(height: 24),

            // --- Main Body Section (Animated Switcher) ---
            // Wrap the AnimatedSwitcher in Expanded to give it flexible space
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
                      // The widget is the content we want to animate
                      child: widget,
                    ),
                  );
                },
                child: KeyedSubtree( // Always wrap the child in KeyedSubtree for AnimatedSwitcher
                  // Use a unique key based on the content type or state combination
                  key: ValueKey<String>(
                      _currentConnectionState == BleConnectionState.connected ? 'connected'
                          : (_currentConnectionState == BleConnectionState.scanning || _currentConnectionState == BleConnectionState.scanStopped ? 'scan_results'
                          : 'placeholder')
                  ),
                  child: mainBodyContent, // The content widget determined by the state logic above
                ),
              ),
            ),

            // Removed the Spacer()
          ],
        ),
      ),
    );
  }
}