# Smart Cane Prototype

## Project Description

The Smart Cane Prototype is a project aimed at developing a smart walking cane equipped with sensors and Bluetooth Low Energy (BLE) connectivity. It consists of two main components:

1.  **ESP32 Firmware:** Runs on an ESP32 microcontroller connected to an IMU sensor (MPU9250). It detects potential falls and monitors battery level, exposing this data via a custom BLE service. It also accepts calibration commands via BLE.
2.  **Flutter Mobile Application:** A cross-platform mobile app (Android/iOS) that connects to the Smart Cane via BLE. It allows users to scan for the cane, connect to it, view real-time status information (connection state, battery level, fall detection state), and trigger calibration.

This prototype focuses on establishing reliable BLE communication, displaying key sensor data, and implementing basic interaction commands.

## Features

### Flutter Mobile Application

* **BLE Scanning:** Discover available Smart Cane devices.
* **BLE Connection Management:** Connect to and disconnect from a selected Smart Cane.
* **Status Display:** View real-time connection state, battery level, and fall detection status.
* **Calibration Command:** Send a calibration command to the connected cane (requires corresponding firmware implementation).
* **Adaptive Theme:** Supports both Light and Dark modes based on system preferences.
* **Custom Font:** Uses the 'Outfit' Google Font for a consistent look and feel.
* **Basic Login Screen:** A simple placeholder login screen (authentication logic is not currently implemented).

### ESP32 Firmware

* **MPU9250 Integration:** Reads sensor data (accelerometer, gyroscope) for fall detection.
* **BLE Service:** Advertises a custom BLE service for the Smart Cane.
* **BLE Characteristics:**
    * Battery Level (Standard 2A19): Exposes mock battery data (currently).
    * Fall Detection (Custom UUID): Indicates a potential fall event (currently based on mock or simple logic).
    * Calibration Command (Custom UUID): Accepts write commands for calibration (requires implementation).
* **Basic State Indication:** Uses the onboard LED to show connection status.
* **Mock Data:** Includes mock battery level and simple fall triggering for initial testing.

## Technologies Used

* **Flutter:** UI Toolkit for building cross-platform mobile applications.
* **Dart:** Programming language for Flutter development.
* **ESP32:** Microcontroller for the cane's firmware.
* **Arduino IDE:** Development environment for ESP32 firmware.
* **Bluetooth Low Energy (BLE):** Wireless communication protocol.
* **MPU9250:** 9-axis IMU sensor (Accelerometer, Gyroscope, Magnetometer).
* `flutter_blue_plus`: Flutter plugin for BLE communication.
* `google_fonts`: Flutter package for easily using Google Fonts.
* `sign_in_button`: Flutter package for a standard Google Sign-In button UI (used as a placeholder UI element).
* `permission_handler`: Flutter package for managing permissions (Bluetooth, Location).
* `url_launcher`: Flutter package for launching URLs (e.g., initiating phone calls - although the emergency call feature is not fully implemented in the app's current state).
* `MPU9250_WE`: Arduino library for MPU9250 sensor.
* ESP32 BLE Arduino Library.

## Prerequisites

### For Flutter App Development

* [Flutter SDK](https://flutter.dev/docs/get-started/install) installed and configured.
* A code editor (e.g., VS Code, Android Studio) with Flutter and Dart plugins.
* An Android or iOS device/emulator for running the app.

### For ESP32 Firmware Development

* [Arduino IDE](https://www.arduino.cc/en/software) installed.
* ESP32 Board Support added to the Arduino IDE.
* Required libraries installed in the Arduino IDE:
    * `MPU9250_WE` (Available via Arduino Library Manager)
    * ESP32 BLE (Comes with ESP32 Board Support)
* An ESP32 development board.
* An MPU9250 sensor module.
* Necessary wiring to connect the MPU9250 to the ESP32 (refer to the sketch for pin definitions).

## Getting Started

Follow these steps to get the Smart Cane Prototype up and running.

### 1. Clone the Repository

Clone this GitHub repository to your local machine:

```bash
git clone [https://github.com/Majd-214/smart_cane_prototype.git](https://github.com/Majd-214/smart_cane_prototype.git)
cd smart_cane_prototype
```

### 2. Flutter Application Setup
Navigate to the smart_cane_prototype folder (where pubspec.yaml is located).

Install Dependencies:

Fetch the required Flutter packages:

Bash

flutter pub get
Connect/Prepare ESP32:

Ensure your ESP32 board is programmed with the compatible firmware and is powered on and advertising via BLE.

Run the Application:

Connect your mobile device or start an emulator. Then run the app:

```Bash
flutter run
```

The app should start on the login screen. Tapping the "Sign in with Google" button will currently bypass authentication and navigate directly to the Home Screen.

### 3. ESP32 Firmware Setup
Open the smart_cane_prototype.ino sketch file in the Arduino IDE.

Install ESP32 Board Support:

If you haven't already, follow the instructions to add ESP32 board support to your Arduino IDE: Install ESP32 in Arduino IDE

Install Libraries:

Open the Arduino Library Manager (Sketch > Include Library > Manage Libraries...) and search for and install MPU9250_WE.

Update Configuration:

Verify that the SERVICE_UUID, BATTERY_CHARACTERISTIC_UUID, FALL_CHARACTERISTIC_UUID, and CALIBRATION_CHARACTERISTIC_UUID defined in the sketch match the UUIDs in lib/services/ble_service.dart in the Flutter app.
Adjust the I2C pins (I2C_SDA_PIN, I2C_SCL_PIN) in the sketch to match your specific ESP32 board and wiring.
Review and adjust batteryUpdateIntervalMs and FALL_COOLDOWN_MS if needed for testing or desired behavior.
&lt;span style="color:red;">CRITICAL FIX: Add BLE2902 Descriptors for Notifications!&lt;/span>

The current ESP32 sketch does not include the necessary BLE2902 Client Characteristic Configuration Descriptors (CCCDs) for the Battery Level and Fall Detection characteristics. Without these descriptors, the Flutter app cannot subscribe to notifications from these characteristics, meaning real-time updates for battery level and fall detection will not be received by the app.

To fix this, you must modify your ESP32 sketch:

Include #include <BLE2902.h> at the top of your sketch.

After creating your pBatteryCharacteristic and pFallCharacteristic objects, add these lines:

```C++
// After creating pBatteryCharacteristic
pBatteryCharacteristic->addDescriptor(new BLE2902());

// After creating pFallCharacteristic
pFallCharacteristic->addDescriptor(new BLE2902());
```

Ensure that when you create these characteristics, their properties include BLECharacteristic::PROPERTY::NOTIFY. For Battery Level, it should typically be READ | NOTIFY. For Fall Detection, it might just be NOTIFY.

```C++
// Example of creating characteristics with NOTIFY property
BLECharacteristic *pBatteryCharacteristic = pService->createCharacteristic(
                                             BATTERY_CHARACTERISTIC_UUID,
                                             BLECharacteristic::PROPERTY::READ |
                                             BLECharacteristic::PROPERTY::NOTIFY // Make sure NOTIFY is included
                                           );

BLECharacteristic *pFallCharacteristic = pService->createCharacteristic(
                                             FALL_CHARACTERISTIC_UUID,
                                             BLECharacteristic::PROPERTY::NOTIFY // Make sure NOTIFY is included
                                           );

// Add the descriptors AFTER creating the characteristics
pBatteryCharacteristic->addDescriptor(new BLE2902());
pFallCharacteristic->addDescriptor(new BLE2902());
```

Upload Sketch:

Select the correct ESP32 board and COM port in the Arduino IDE (Tools > Board, Tools > Port). Upload the modified sketch to your ESP32 board.

Configuration Details
UUIDs: Ensure the SERVICE_UUID, BATTERY_CHARACTERISTIC_UUID, FALL_CHARACTERISTIC_UUID, and CALIBRATION_CHARACTERISTIC_UUID are identical in lib/services/ble_service.dart and your smart_cane_prototype.ino sketch.
ESP32 Sketch: Adjust I2C_SDA_PIN, I2C_SCL_PIN for your wiring. Modify batteryUpdateIntervalMs and FALL_COOLDOWN_MS for desired behavior. Implement actual MPU9250 reading and fall detection logic in the sketch if you haven't already (the provided sketch might contain placeholder/mock logic). Implement logic to handle the Calibration Characteristic write command.
Usage
Power on your ESP32 Smart Cane.
Open the Flutter mobile application.
Tap the "Sign in with Google" button on the login screen (this bypasses auth and goes to Home).
On the Home Screen, tap "Scan for Cane".
Once your "Smart Cane" device appears in the list, tap on it to connect.
After connecting, the status cards should update, showing "Connected", a battery level (from mock data), and "Fall Detected: No".
Tap "Calibrate Cane" to send the calibration command (requires firmware implementation).
If the firmware triggers a fall detection notification (once CCCD is fixed), the "Fall Detected" status should change to "Yes", and a "Reset" button will appear.
Tap "Disconnect" to disconnect from the cane.
Known Issues
BLE Notifications Not Working: The most critical issue is that the ESP32 sketch lacks the required BLE2902 descriptors for the Battery Level and Fall Detection characteristics. This prevents the mobile app from receiving real-time notification updates for these values. This must be fixed in the ESP32 sketch as described in the "CRITICAL FIX" section above.
Future Enhancements
Implement the Fall Detection Overlay and Emergency Call feature in the Flutter app (logic was started but reverted).
Implement background BLE scanning and monitoring in the Flutter app.
Develop a robust fall detection algorithm in the ESP32 firmware using MPU9250 data.
Implement actual battery level reading on the ESP32.
Implement the calibration process on the ESP32.
Add user account management and persistent data storage (requires re-integrating authentication and potentially a database).
Improve power management on the ESP32.
Refine the UI/UX based on user feedback.
Contributing
(Placeholder: Describe how others can contribute to the project)

License
(Placeholder: State the project's license, e.g., MIT)

Credits
MPU9250_WE Library by Wolfgang Ewald (for the ESP32 sketch)
flutter_blue_plus
google_fonts
sign_in_button
permission_handler
url_launcher
<!-- end list -->


**Explanation of the README Content:**

* **Project Overview:** Provides a clear title and description of the project's two main parts.
* **Features:** Lists the functionalities of both the mobile app and the firmware in their current state.
* **Technologies:** Lists the key technologies used.
* **Prerequisites & Getting Started:** Provides step-by-step instructions for setting up both the Flutter app and the ESP32 firmware, assuming the user has the necessary development environments.
* **CRITICAL FIX:** A dedicated, highly visible section explains the essential modification needed in the ESP32 sketch to enable BLE notifications, which is currently preventing key features from working correctly.
* **Configuration Details:** Points out important settings to verify in both the app and the sketch.
* **Usage:** Explains how to interact with the app and cane.
* **Known Issues:** Explicitly mentions the critical CCCD issue as the main current problem.
* **Future Enhancements:** Lists potential features that were planned or could be added, including the Fall Detection Overlay and Emergency Call that were previously worked on.
* **Placeholders:** Includes placeholders for sections like Contributing and License, which you can fill in later.

Remember to replace the placeholder content (like contributing and license details) with the actual information for your project.

This README should provide a comprehensive guide for anyone wanting to understand, set up, or contribute to your Smart Cane Prototype project in its current state. Let me know if you'd like any adjustments!
