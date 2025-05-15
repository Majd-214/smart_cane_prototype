import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:smart_cane_prototype/utils/app_theme.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:smart_cane_prototype/services/ble_service.dart'; // Import our BLE Service
import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'; // Import for ScanResult and BluetoothDevice

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Get the singleton instance of the BleService
  final BleService _bleService = BleService();

  // State variables to hold the latest data from streams
  BleConnectionState _currentConnectionState = BleConnectionState.disconnected;
  List<ScanResult> _scanResults = [];
  int? _currentBatteryLevel;
  bool _currentFallDetected = false;
  BluetoothDevice? _currentConnectedDevice; // State variable to hold the connected device

  // Stream subscriptions to cancel in dispose
  StreamSubscription<BleConnectionState>? _connectionStateSubscription;
  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;
  StreamSubscription<int?>? _batteryLevelSubscription;
  StreamSubscription<bool>? _fallDetectedSubscription;
  StreamSubscription<BluetoothDevice?>? _connectedDeviceSubscription; // Subscription for connected device stream


  @override
  void initState() {
    super.initState();
    // Initialize the BLE service (requests permissions and starts listening to adapter state)
    _bleService.initialize();

    // Start listening to the streams provided by the BleService
    _connectionStateSubscription = _bleService.connectionStateStream.listen((state) {
      print("HomeScreen received connection state: $state");
      setState(() {
        _currentConnectionState = state;
        // Clear scan results when connected or disconnected
        if (state == BleConnectionState.connected || state == BleConnectionState.disconnected) {
          _scanResults = [];
        }
        // Reset battery and fall status on disconnect or error states
        if (state == BleConnectionState.disconnected ||
            state == BleConnectionState.bluetoothOff ||
            state == BleConnectionState.noPermissions ||
            state == BleConnectionState.unknown) {
          _currentBatteryLevel = null;
          _currentFallDetected = false;
        }
      });
    });

    _scanResultsSubscription = _bleService.scanResultsStream.listen((results) {
      // print("HomeScreen received scan results: ${results.length} devices"); // Can be chatty
      setState(() {
        _scanResults = results;
        // Filter results to only show devices with the Smart Cane Service UUID or name if needed
        // For now, let's filter by name being non-empty
        _scanResults = results.where((result) => result.device.platformName.isNotEmpty).toList();

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
      setState(() {
        _currentFallDetected = detected;
      });
      // TODO: Trigger the fall detection overlay here when _currentFallDetected becomes true
      if (detected) {
        print("Fall detected in HomeScreen! Time to show the overlay.");
        // We will implement the overlay in a later part
      }
    });

    // --- Listen to the new connected device stream ---
    _connectedDeviceSubscription = _bleService.connectedDeviceStream.listen((device) {
      print("HomeScreen received connected device: ${device?.platformName}");
      setState(() {
        _currentConnectedDevice = device; // Update state variable
      });
    });
    // -------------------------------------------------


    // Optionally start a scan when the screen loads if not connected
    // Check initial connection state
    if (_bleService.getCurrentConnectionState() == BleConnectionState.disconnected) {
      _bleService.startBleScan();
    }

  }

  @override
  void dispose() {
    // Cancel stream subscriptions to prevent memory leaks
    _connectionStateSubscription?.cancel();
    _scanResultsSubscription?.cancel();
    _batteryLevelSubscription?.cancel();
    _fallDetectedSubscription?.cancel();
    _connectedDeviceSubscription?.cancel(); // Cancel the new subscription

    // Consider if you want to disconnect from the cane when the screen is disposed
    // _bleService.disconnectCurrentDevice(); // Uncomment if needed

    super.dispose();
    print("HomeScreen Disposed.");
  }


  // --- Button Actions ---
  void _handleConnectDisconnect() {
    if (_currentConnectionState == BleConnectionState.connected || _currentConnectionState == BleConnectionState.connecting) {
      // If connected or connecting, initiate disconnect
      _bleService.disconnectCurrentDevice();
    } else {
      // If disconnected, start a scan
      _bleService.startBleScan();
    }
  }

  void _handleCalibrate() {
    if (_currentConnectionState == BleConnectionState.connected) {
      _bleService.sendCalibrationCommand();
    } else {
      print("Cannot calibrate: Not connected to the cane.");
      // Optionally show a message to the user
    }
  }

  // Optional: Function to handle signing out
  Future<void> _handleSignOut() async {
    try {
      await GoogleSignIn().signOut();
      print('Signed out');
      // Disconnect BLE before navigating back to login
      _bleService.disconnectCurrentDevice();
      // Navigate back to the login screen after signing out
      if (mounted) { // Check if widget is still mounted before navigating
        Navigator.pushReplacementNamed(context, '/login');
      }
    } catch (error) {
      print('Error signing out: $error');
      // Optionally show an error message
    }
  }


  @override
  Widget build(BuildContext context) {
    // Access the theme's text styles
    final textTheme = Theme.of(context).textTheme;

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

            // --- Connectivity Status Card (Uses StreamBuilder) ---
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

            // --- Battery Level Card (Uses StreamBuilder) ---
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
                  // Updated battery icons
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

            // --- Fall Detection Status Card (Uses StreamBuilder) ---
            StreamBuilder<bool>(
              stream: _bleService.fallDetectedStream,
              initialData: _currentFallDetected,
              builder: (context, snapshot) {
                final fallDetected = snapshot.data ?? false;

                return Card(
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  color: fallDetected ? AppTheme.errorColor : null, // Highlight on fall
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Row(
                      children: [
                        Icon(
                          fallDetected ? Icons.warning : Icons.check_circle_outline,
                          color: fallDetected ? Colors.white : AppTheme.accentColor,
                        ),
                        const SizedBox(width: 16),
                        Text(
                          'Fall Detected: ${fallDetected ? 'Yes' : 'No'}',
                          style: textTheme.bodyMedium?.copyWith(
                            color: fallDetected ? Colors.white : AppTheme.textColorPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),


            const SizedBox(height: 40),

            // --- Action Buttons ---

            // Connect/Disconnect/Scan Button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _currentConnectionState == BleConnectionState.connecting || _currentConnectionState == BleConnectionState.disconnecting || _currentConnectionState == BleConnectionState.bluetoothOff || _currentConnectionState == BleConnectionState.noPermissions ? null : _handleConnectDisconnect,
                child: Text(
                    _currentConnectionState == BleConnectionState.connected ? 'Disconnect'
                        : (_currentConnectionState == BleConnectionState.connecting ? 'Connecting...'
                        : (_currentConnectionState == BleConnectionState.disconnected ? 'Scan for Cane'
                        : 'BLE Unavailable'))
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

            // --- Scan Results List (Appears when scanning or disconnected with results) ---
            // Only show scan results if disconnected and results are available
            if (_currentConnectionState == BleConnectionState.disconnected && _scanResults.isNotEmpty)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Discovered Devices:',
                      style: textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded( // Use Expanded for the ListView within the Column
                      child: ListView.builder(
                        itemCount: _scanResults.length,
                        itemBuilder: (context, index) {
                          final result = _scanResults[index];
                          // Filter by name being non-empty is already done in setState
                          // You could add more specific filtering here if needed

                          return ListTile(
                            title: Text(result.device.platformName, style: textTheme.bodyMedium),
                            subtitle: Text(result.device.id.toString(), style: textTheme.bodySmall),
                            trailing: Text('${result.rssi} dBm', style: textTheme.bodySmall),
                            onTap: () {
                              // Attempt to connect to the selected device
                              print("Tapped on device: ${result.device.platformName}");
                              _bleService.connectToScannedDevice(result.device);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),

            // --- Connected Device Info (Appears when connected) ---
            StreamBuilder<BluetoothDevice?>(
              stream: _bleService.connectedDeviceStream,
              initialData: _currentConnectedDevice, // Use initial state
              builder: (context, snapshot) {
                final connectedDevice = snapshot.data; // Get connected device from stream
                // Only show this section if a device is connected
                if (_currentConnectionState == BleConnectionState.connected && connectedDevice != null) {
                  return Column(
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
                              // Access properties on the connectedDevice from the stream
                              Text('Device Name: ${connectedDevice.platformName}', style: textTheme.bodyMedium),
                              const SizedBox(height: 8),
                              Text('Device ID: ${connectedDevice.id.toString()}', style: textTheme.bodyMedium),
                              // Add more device info if available via characteristics
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                } else {
                  return const SizedBox.shrink(); // Hide this section when not connected
                }
              },
            ),


            const Spacer(),
          ],
        ),
      ),
    );
  }
}