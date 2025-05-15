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
