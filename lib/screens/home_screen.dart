import 'package:flutter/material.dart';
// Removed google_fonts import as we are using Theme.of(context).textTheme
import 'package:smart_cane_prototype/utils/app_theme.dart';
import 'package:google_sign_in/google_sign_in.dart'; // Needed for Sign Out (optional but good practice)

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Placeholder variables for device status - these will be updated by the BLE service
  String _connectivityStatus = "Disconnected";
  int? _batteryLevel; // Use nullable int, null means unknown
  bool _fallDetected = false;
  bool _isConnecting = false; // To indicate if connection is in progress

  // Placeholder functions for button actions
  void _connectToCane() {
    // TODO: Implement BLE scanning and connection logic here
    print("Connect button pressed");
    setState(() {
      _isConnecting = true; // Show loading state
      _connectivityStatus = "Connecting...";
    });
    // Simulate connection attempt
    Future.delayed(const Duration(seconds: 3), () {
      setState(() {
        _isConnecting = false;
        // Simulate success or failure
        // _connectivityStatus = "Connected";
        // _batteryLevel = 75; // Example data
        // _fallDetected = false; // Reset fall status on new connection
      });
      print("Simulated connection attempt finished.");
      // In a real scenario, update status based on BLE callbacks
    });
  }

  void _calibrateCane() {
    // TODO: Implement sending calibration command via BLE
    print("Calibrate button pressed");
    // Example: send command
    // BleService().sendCalibrationCommand();
  }

  // Optional: Function to handle signing out
  Future<void> _handleSignOut() async {
    try {
      await GoogleSignIn().signOut();
      print('Signed out');
      // Navigate back to the login screen after signing out
      Navigator.pushReplacementNamed(context, '/login');
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
          // AppBar title style is set in AppTheme, no need for GoogleFonts here
          style: textTheme.titleLarge?.copyWith( // Use titleLarge from theme
              color: AppTheme.darkTextColorPrimary // Ensure text color is correct in dark mode app bar
          ),
        ),
        // Optional: Add a sign-out button
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
              // Use headlineSmall from the theme and adjust if needed
              style: textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            // Connectivity Status Card
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    Icon(
                      _connectivityStatus == "Connected" ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                      color: _connectivityStatus == "Connected" ? AppTheme.accentColor : AppTheme.errorColor,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        'Connectivity Status: $_connectivityStatus',
                        style: textTheme.bodyMedium, // Use bodyMedium from theme
                      ),
                    ),
                    if (_isConnecting)
                      const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Battery Level Card
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    Icon(
                      _batteryLevel != null
                          ? (_batteryLevel! > 75 ? Icons.battery_full : _batteryLevel! > 25 ? Icons.battery_4_bar : Icons.battery_alert)
                          : Icons.battery_unknown,
                      color: _batteryLevel != null
                          ? (_batteryLevel! > 25 ? AppTheme.accentColor : AppTheme.errorColor)
                          : AppTheme.textColorSecondary,
                    ),
                    const SizedBox(width: 16),
                    Text(
                      'Battery Level: ${_batteryLevel != null ? '$_batteryLevel%' : 'N/A'}',
                      style: textTheme.bodyMedium, // Use bodyMedium from theme
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Fall Detection Status Card
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              color: _fallDetected ? AppTheme.errorColor : null, // Highlight on fall
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    Icon(
                      _fallDetected ? Icons.warning : Icons.check_circle_outline,
                      color: _fallDetected ? Colors.white : AppTheme.accentColor,
                    ),
                    const SizedBox(width: 16),
                    Text(
                      'Fall Detected: ${_fallDetected ? 'Yes' : 'No'}',
                      style: textTheme.bodyMedium?.copyWith( // Use bodyMedium and adjust color
                        color: _fallDetected ? Colors.white : AppTheme.textColorPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 40),
            // Action Buttons
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isConnecting ? null : _connectToCane, // Disable while connecting
                // Button text style is handled by ElevatedButton.styleFrom in AppTheme
                child: Text(_isConnecting ? 'Connecting...' : 'Connect to Smart Cane'),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _connectivityStatus == "Connected" ? _calibrateCane : null, // Enable only when connected
                style: ElevatedButton.styleFrom(
                  backgroundColor: _connectivityStatus == "Connected" ? AppTheme.primaryColor : Colors.grey, // Dim when disabled
                ),
                // Button text style is handled by ElevatedButton.styleFrom in AppTheme
                child: const Text('Calibrate Cane'),
              ),
            ),
            const SizedBox(height: 24),
            // Placeholder for future device info or settings
            Text(
              'Device Actions',
              // Use headlineSmall from the theme and adjust if needed
              style: textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            // You could add more buttons or info here later
          ],
        ),
      ),
    );
  }
}