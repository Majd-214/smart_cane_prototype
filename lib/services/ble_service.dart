import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart'; // Import for phone calls

// Define the Service and Characteristic UUIDs based on ESP32 sketch
const String SMART_CANE_SERVICE_UUID = "A5A20D8A-E137-4B30-9F30-1A7A91579C9C";
const String BATTERY_CHARACTERISTIC_UUID = "2A19"; // Standard Battery Level Characteristic UUID
const String FALL_CHARACTERISTIC_UUID = "C712A5B2-2C13-4088-8D53-F7E3291B0155"; // Custom Fall Detection Characteristic UUID (NOTIFY)
const String CALIBRATION_CHARACTERISTIC_UUID = "E9A10B6B-8A65-4F56-82C3-6768F0EE38A1"; // Custom Calibration Command Characteristic UUID (WRITE)
const String SMART_CANE_DEVICE_NAME = "Smart Cane"; // Match the name in ESP32 sketch

enum BleConnectionState {
  disconnected,
  connecting,
  connected,
  disconnecting,
  // Adding states for adapter issues could be helpful
  bluetoothOff,
  noPermissions,
  unknown, // e.g., Adapter unavailable
}

class BleService {
  // Singleton pattern
  static final BleService _instance = BleService._internal();
  factory BleService() {
    return _instance;
  }
  BleService._internal(); // Private constructor

  // Streams to broadcast BLE state changes
  final _connectionStateController = StreamController<BleConnectionState>.broadcast();
  Stream<BleConnectionState> get connectionStateStream => _connectionStateController.stream;

  final _scanResultsController = StreamController<List<ScanResult>>.broadcast();
  Stream<List<ScanResult>> get scanResultsStream => _scanResultsController.stream;

  final _batteryLevelController = StreamController<int?>.broadcast();
  Stream<int?> get batteryLevelStream => _batteryLevelController.stream;

  final _fallDetectedController = StreamController<bool>.broadcast();
  Stream<bool> get fallDetectedStream => _fallDetectedController.stream;

  // Keep track of the current connection state internally
  BleConnectionState _currentConnectionState = BleConnectionState.disconnected;

  // Currently connected device and its subscriptions
  BluetoothDevice? _connectedDevice;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  List<StreamSubscription> _characteristicValueSubscriptions = [];


  // Keep track of discovered characteristics
  BluetoothCharacteristic? _batteryCharacteristic;
  BluetoothCharacteristic? _fallCharacteristic;
  BluetoothCharacteristic? _calibrationCharacteristic;


  // --- Initialization and Permissions ---
  Future<void> initialize() async {
    print("BleService Initializing...");
    // Request necessary permissions
    await _requestPermissions();

    // Listen for BLE adapter state changes using the new API
    FlutterBluePlus.adapterState.listen((state) { // Corrected access: Use adapterState directly
      print("BLE Adapter State: $state");
      // Update internal state and broadcast based on adapter state
      if (state == BluetoothAdapterState.on) {
        // If adapter turns on, and we weren't connected/connecting, update state
        if (_currentConnectionState == BleConnectionState.bluetoothOff || _currentConnectionState == BleConnectionState.unknown) {
          _updateConnectionState(BleConnectionState.disconnected); // Assume disconnected until we connect
        }
      } else if (state == BluetoothAdapterState.off) {
        // If adapter turns off, we are definitely disconnected
        _updateConnectionState(BleConnectionState.bluetoothOff);
        disconnectFromDevice(); // Force disconnect if adapter goes off
      } else if (state == BluetoothAdapterState.unavailable) {
        _updateConnectionState(BleConnectionState.unknown); // Indicate BLE is not available
      }
      // Handle other states like unauthorized
      if (state == BluetoothAdapterState.unauthorized) {
        _updateConnectionState(BleConnectionState.noPermissions);
      }
    });

    // Listen for scan results using the new API
    FlutterBluePlus.scanResults.listen((results) { // Corrected access: Use scanResults directly
      // print("Scan Results Updated: ${results.length} devices found"); // Can be chatty
      _scanResultsController.add(results);
    });

    print("BleService Initialized.");
  }

  // Helper to update internal state and broadcast
  void _updateConnectionState(BleConnectionState state) {
    if (_currentConnectionState != state) {
      _currentConnectionState = state;
      _connectionStateController.add(state);
      print("Connection State Updated: $state");
    }
  }


  Future<void> _requestPermissions() async {
    print("Requesting BLE and Location Permissions...");
    // Request Bluetooth Scan and Connect permissions (for Android 12+)
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
    // Request Location permissions (often required for BLE scanning on many Android versions)
    // Use locationWhenInUse for foreground scanning, locationAlways for background scanning
    await Permission.locationWhenInUse.request();
    // Optional: Request background location if needed for background scanning
    await Permission.locationAlways.request();
    // Request Phone Call permission for 911 dialing
    await Permission.phone.request();
    // Request System Alert Window permission for overlay (Android)
    await Permission.systemAlertWindow.request();
    print("Permission requests finished.");
  }

  // --- Scanning ---
  Future<void> startScan({Duration timeout = const Duration(seconds: 10)}) async {
    print("Starting BLE scan...");
    _scanResultsController.add([]); // Clear previous scan results
    _updateConnectionState(BleConnectionState.disconnected); // Ensure state is disconnected before scan
    try {
      // Check Bluetooth state and permissions before scanning using the new API
      final adapterState = await FlutterBluePlus.adapterState.first; // Corrected access
      if (adapterState != BluetoothAdapterState.on) {
        print("Cannot start scan: Bluetooth adapter is ${adapterState.name}.");
        if (adapterState == BluetoothAdapterState.off) _updateConnectionState(BleConnectionState.bluetoothOff);
        if (adapterState == BluetoothAdapterState.unauthorized) _updateConnectionState(BleConnectionState.noPermissions);
        return; // Do not proceed with scan if adapter is not on
      }

      // Check for necessary location permissions before scanning
      final locationStatus = await Permission.locationWhenInUse.status;
      final bluetoothScanStatus = await Permission.bluetoothScan.status;
      if (!locationStatus.isGranted || !bluetoothScanStatus.isGranted) {
        print("Cannot start scan: Missing Location or Bluetooth Scan permissions.");
        _updateConnectionState(BleConnectionState.noPermissions);
        await _requestPermissions(); // Prompt again
        return; // Do not proceed with scan
      }


      // You can scan for specific services or devices if you know them using the new API
      // await FlutterBluePlus.startScan(timeout: timeout, withServices: [Guid(SMART_CANE_SERVICE_UUID)]);
      await FlutterBluePlus.startScan(timeout: timeout); // Corrected access: Use startScan directly
      print("BLE scan started.");
      // Note: We don't update state to 'scanning' here, scanResults stream will handle devices found
    } catch (e) {
      print("Error starting scan: $e");
      _updateConnectionState(BleConnectionState.disconnected); // Indicate scan failed
    }
  }

  Future<void> stopScan() async {
    // Check if a scan is currently active before stopping using the new API
    if (FlutterBluePlus.isScanningNow) { // Corrected access: Use isScanningNow directly
      print("Stopping BLE scan...");
      try {
        await FlutterBluePlus.stopScan(); // Corrected access: Use stopScan directly
        print("BLE scan stopped.");
      } catch (e) {
        print("Error stopping scan: $e");
      }
    } else {
      print("No active BLE scan to stop.");
    }
  }

  // --- Connection ---
  Future<void> connectToDevice(BluetoothDevice device) async {
    if (_currentConnectionState == BleConnectionState.connecting || _currentConnectionState == BleConnectionState.connected) {
      print("Already connecting or connected. Ignoring connect request.");
      return;
    }

    print("Attempting to connect to ${device.platformName}...");
    _updateConnectionState(BleConnectionState.connecting);
    try {
      // Stop scanning before connecting
      await stopScan();

      // Connect to the device
      // Use firstWhere to wait until the state is connected
      _connectionStateSubscription?.cancel(); // Cancel any previous subscription
      _connectionStateSubscription = device.connectionState.listen((state) {
        print("Device ${device.platformName} connection state: $state");
        if (state == BluetoothConnectionState.disconnected) {
          _connectedDevice = null; // Clear connected device on disconnect
          _updateConnectionState(BleConnectionState.disconnected);
          print("Disconnected from ${device.platformName}");
          _clearCharacteristicReferences(); // Clear characteristic references on disconnect
          _cancelCharacteristicValueSubscriptions(); // Cancel subscriptions

        } else if (state == BluetoothConnectionState.connected) {
          _updateConnectionState(BleConnectionState.connected);
          print("Successfully connected to ${device.platformName}");
          // Discover services and characteristics after connection is confirmed
          _discoverServices(device); // Don't await here to avoid blocking connectFuture
        }
        // Handle other states like connecting, disconnecting if needed
      });


      // Explicitly call connect and wait for the state stream to confirm connection
      await device.connect(timeout: const Duration(seconds: 15));
      _connectedDevice = device; // Set connected device reference immediately upon connect call

      // The state change listener will handle the rest (updating state, discovering services)

    } catch (e) {
      print("Error connecting to device: $e");
      _updateConnectionState(BleConnectionState.disconnected); // Revert state on error
      _connectedDevice = null; // Clear connected device
      _clearCharacteristicReferences(); // Clear characteristic references on error
      _connectionStateSubscription?.cancel(); // Cancel connection state listener on error
      // Handle connection errors (e.g., device out of range, connection failed)
      // You might want to emit an error on the connectionStateStream
    }
  }

  Future<void> disconnectFromDevice() async {
    if (_currentConnectionState == BleConnectionState.disconnected || _connectedDevice == null) {
      print("Not connected. Ignoring disconnect request.");
      return;
    }

    print("Attempting to disconnect from ${_connectedDevice!.platformName}...");
    _updateConnectionState(BleConnectionState.disconnecting);
    try {
      // Cancel subscriptions before disconnecting
      _cancelCharacteristicValueSubscriptions();
      _clearCharacteristicReferences();
      _connectionStateSubscription?.cancel(); // Cancel connection state listener

      await _connectedDevice!.disconnect();
      // The connectionState listener (if still active for some reason) or the successful
      // disconnect call should eventually lead to the disconnected state.
      // We proactively update state here, but the listener confirms.
      _updateConnectionState(BleConnectionState.disconnected);

    } catch (e) {
      print("Error disconnecting from device: $e");
      _updateConnectionState(BleConnectionState.connected); // Revert state if disconnect fails
      // Handle disconnection errors
    } finally {
      _connectedDevice = null; // Ensure device reference is cleared
    }
  }

  // Helper to clear characteristic references
  void _clearCharacteristicReferences() {
    _batteryCharacteristic = null;
    _fallCharacteristic = null;
    _calibrationCharacteristic = null;
    print("Characteristic references cleared.");
  }

  // Helper to cancel all characteristic value subscriptions
  void _cancelCharacteristicValueSubscriptions() {
    for (var sub in _characteristicValueSubscriptions) {
      sub.cancel();
    }
    _characteristicValueSubscriptions.clear();
    print("Characteristic value subscriptions cancelled.");
  }


  // --- Service and Characteristic Discovery ---
  Future<void> _discoverServices(BluetoothDevice device) async {
    print("Discovering services for ${device.platformName}...");
    _clearCharacteristicReferences(); // Clear before discovering new ones
    _cancelCharacteristicValueSubscriptions(); // Cancel any old subscriptions

    try {
      List<BluetoothService> services = await device.discoverServices();
      print("Discovered ${services.length} services.");

      bool smartCaneServiceFound = false;

      for (BluetoothService service in services) {
        print("  Service UUID: ${service.uuid.str.toUpperCase()}");
        if (service.uuid.str.toUpperCase() == SMART_CANE_SERVICE_UUID.toUpperCase()) {
          smartCaneServiceFound = true;
          print("    Found Smart Cane Service!");
          for (BluetoothCharacteristic characteristic in service.characteristics) {
            print("    Characteristic UUID: ${characteristic.uuid.str.toUpperCase()}");
            // Identify our characteristics
            if (characteristic.uuid.str.toUpperCase() == BATTERY_CHARACTERISTIC_UUID.toUpperCase()) {
              _batteryCharacteristic = characteristic;
              print("      Found Battery Characteristic.");
              // Subscribe to battery notifications if supported
              if (characteristic.properties.notify) {
                _subscribeToCharacteristic(characteristic, _batteryLevelController); // Don't await here
              } else {
                print("Warning: Battery characteristic does not support notifications.");
              }
              // If read is supported, you could read the initial value
              if (characteristic.properties.read) {
                readBatteryLevel(); // Read initial value, don't await
              }


            } else if (characteristic.uuid.str.toUpperCase() == FALL_CHARACTERISTIC_UUID.toUpperCase()) {
              _fallCharacteristic = characteristic;
              print("      Found Fall Characteristic.");
              // Subscribe to fall notifications if supported
              if (characteristic.properties.notify) {
                _subscribeToCharacteristic(characteristic, _fallDetectedController); // Don't await here
              } else {
                print("Warning: Fall characteristic does not support notifications.");
              }


            } else if (characteristic.uuid.str.toUpperCase() == CALIBRATION_CHARACTERISTIC_UUID.toUpperCase()) {
              _calibrationCharacteristic = characteristic;
              print("      Found Calibration Characteristic.");
              if (!characteristic.properties.write && !characteristic.properties.writeWithoutResponse) {
                print("Warning: Calibration characteristic does not support writing.");
              }
            }
          }
        }
      }

      // Check if the Smart Cane service and all required characteristics were found
      if (!smartCaneServiceFound) {
        print("Error: Smart Cane Service not found on the device.");
        disconnectFromDevice(); // Disconnect if the main service is missing
      } else if (_batteryCharacteristic == null || _fallCharacteristic == null || _calibrationCharacteristic == null) {
        print("Warning: Could not find all required characteristics on the Smart Cane Service.");
        // Decide how to handle partial discovery - disconnect or proceed with warnings?
        // For now, we'll proceed but log a warning.
      } else {
        print("All required Smart Cane characteristics found.");
        // You might want to emit an event or update a state indicating readiness to interact
      }


    } catch (e) {
      print("Error discovering services: $e");
      // Handle discovery errors - usually disconnect or show error
      disconnectFromDevice(); // Disconnect on discovery error
    }
  }


  // --- Reading and Writing ---

  // Implement reading battery level (if needed, since we subscribe to notifications)
  Future<int?> readBatteryLevel() async {
    if (_batteryCharacteristic != null && _connectedDevice != null && _batteryCharacteristic!.properties.read) {
      print("Reading battery level...");
      try {
        List<int> value = await _batteryCharacteristic!.read();
        if (value.isNotEmpty) {
          // Assuming battery level is a single byte (0-100)
          int batteryLevel = value[0];
          // Basic validation
          if (batteryLevel >= 0 && batteryLevel <= 100) {
            print("  Read Battery Level: $batteryLevel%");
            _batteryLevelController.add(batteryLevel); // Update stream
            return batteryLevel;
          } else {
            print("  Received unexpected battery value: ${value[0]}");
          }

        } else {
          print("  Received empty value from Battery Characteristic.");
        }
      } catch (e) {
        print("Error reading battery level: $e");
        // Handle read errors
      }
    } else {
      print("Cannot read battery level: Not connected, characteristic not found, or does not support reading.");
    }
    return null; // Return null on error or if not available
  }


  // --- Notifications (Subscriptions) ---
  void _subscribeToCharacteristic(BluetoothCharacteristic characteristic, StreamController controller) { // Made sync as listen returns subscription
    print("Subscribing to notifications for ${characteristic.uuid.str.toUpperCase()}...");
    try {
      // setNotifyValue is async, but we don't need to await it here to add the listener
      characteristic.setNotifyValue(true).catchError((e) {
        print("Error setting notify value for ${characteristic.uuid.str.toUpperCase()}: $e");
        // Handle error setting notify value
      });


      // Listen for incoming data
      final subscription = characteristic.value.listen((value) {
        // print("Received data from ${characteristic.uuid.str.toUpperCase()}: $value"); // Can be chatty

        // Process the received data based on the characteristic
        if (characteristic.uuid.str.toUpperCase() == BATTERY_CHARACTERISTIC_UUID.toUpperCase()) {
          if (value.isNotEmpty) {
            // Battery level is typically a single byte (0-100)
            int batteryLevel = value[0];
            // Basic validation
            if (batteryLevel >= 0 && batteryLevel <= 100) {
              print("  Parsed Battery Level: $batteryLevel%");
              controller.add(batteryLevel); // Add to battery stream
            } else {
              print("  Received unexpected battery value: ${value[0]}");
            }

          } else {
            print("  Received empty value from Battery Characteristic.");
          }
        } else if (characteristic.uuid.str.toUpperCase() == FALL_CHARACTERISTIC_UUID.toUpperCase()) {
          if (value.isNotEmpty) {
            // Fall detection is a single byte (e.g., 1 for detected)
            // Assuming 1 means fall detected, 0 means not detected or reset
            bool fallDetected = value[0] == 1;
            print("  Parsed Fall Detected: $fallDetected");
            controller.add(fallDetected); // Add to fall stream

            // --- Trigger Fall Detection Overlay Here ---
            if (fallDetected) {
              print("FALL EVENT DETECTED! Triggering overlay logic.");
              // We will implement the overlay triggering in a later part,
              // potentially interacting with a background service/isolate.
              // For now, this print statement confirms detection.
            }
          } else {
            print("  Received empty value from Fall Characteristic.");
          }
        }
        // Add other characteristic data processing here if needed
      },
          onError: (e) {
            print("Error receiving data from ${characteristic.uuid.str.toUpperCase()}: $e");
            // Handle errors in the data stream
          },
          onDone: () {
            print("Stream for ${characteristic.uuid.str.toUpperCase()} is done.");
            // Handle stream closure - might indicate disconnect or characteristic issue
          }
      );

      _characteristicValueSubscriptions.add(subscription); // Keep track of the subscription
    } catch (e) {
      print("Error setting up subscription for ${characteristic.uuid.str.toUpperCase()}: $e");
      // Handle errors in setting up the listener
    }
  }

  // --- Public Methods to interact with the Service ---

  // Method to get the current connection state
  BleConnectionState getCurrentConnectionState() {
    // Return the internally managed state
    return _currentConnectionState;
  }


  // Method to initiate scanning from the UI
  void startBleScan() {
    startScan(); // No await here, let it run in the background
  }

  // Method to connect to a specific device from the UI
  void connectToScannedDevice(BluetoothDevice device) {
    connectToDevice(device); // No await here, let it run in the background
  }

  // Method to disconnect from the current device from the UI
  void disconnectCurrentDevice() {
    disconnectFromDevice(); // No await here, let it run in the background
  }

  // Method to send calibration command
  Future<void> sendCalibrationCommand() async {
    // Check for write or writeWithoutResponse property before writing
    if (_calibrationCharacteristic != null && _connectedDevice != null && (_calibrationCharacteristic!.properties.write || _calibrationCharacteristic!.properties.writeWithoutResponse)) {
      print("Sending calibration command...");
      try {
        // Send a single byte, e.g., 1, to trigger calibration
        // Use writeWithoutResponse if possible, as it's faster and the command doesn't need a response
        await _calibrationCharacteristic!.write([1], withoutResponse: _calibrationCharacteristic!.properties.writeWithoutResponse);
        print("Calibration command sent.");
        // Optionally provide feedback to the user that command was sent
      } catch (e) {
        print("Error sending calibration command: $e");
        // Handle write errors
        // Optionally provide feedback to the user that command failed
      }
    } else {
      print("Cannot send calibration command: Not connected or calibration characteristic not found or does not support writing.");
      // Optionally provide feedback to the user
    }
  }

  // Method to manually trigger a call (for testing the 911 call later)
  Future<void> makePhoneCall(String phoneNumber) async {
    final Uri launchUri = Uri(
      scheme: 'tel',
      path: phoneNumber,
    );
    try {
      // launchUrl requires the URL launcher package and permission
      await launchUrl(launchUri);
      print("Attempting to call: $phoneNumber");
    } catch (e) {
      print("Error launching phone call: $e");
      // Handle error, maybe show a dialog
      // Note: Actual emergency calls to 911 might have system restrictions
      // Using the 'tel' scheme will open the dialer with the number pre-filled
      // The user will typically have to press the call button themselves due to OS restrictions
    }
  }


  // Don't forget to close stream controllers and cancel subscriptions when the service is no longer needed
  void dispose() {
    print("BleService Disposing...");
    _cancelCharacteristicValueSubscriptions();
    _connectionStateSubscription?.cancel(); // Cancel connection state listener
    disconnectFromDevice(); // Attempt to disconnect on dispose
    _connectionStateController.close();
    _scanResultsController.close();
    _batteryLevelController.close();
    _fallDetectedController.close();
    print("BleService Disposed.");
  }
}