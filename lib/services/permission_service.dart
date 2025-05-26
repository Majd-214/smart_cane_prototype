// lib/services/permission_service.dart
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  static Future<bool> requestAllPermissions(BuildContext context) async {
    print("PERMISSION_SERVICE: Requesting all necessary permissions...");

    // Define all permissions needed for core & background BLE, notifications, calls
    final List<Permission> permissionsToRequest = [
      Permission.location, // Must be granted before locationAlways
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.notification,
      Permission.phone,
      Permission.systemAlertWindow,
    ];

    // Request the primary set
    Map<Permission, PermissionStatus> statuses =
        await permissionsToRequest.request();

    bool allGranted = true;
    List<String> deniedPermissions = [];
    List<Permission> permanentlyDenied = [];
    bool alertWindowNeeded = false;

    // Check primary permissions
    statuses.forEach((permission, status) {
      print("  Permission: $permission, Status: $status");

      if (permission == Permission.systemAlertWindow) {
        if (!status.isGranted) {
          print("  WARNING: System Alert Window permission is NOT granted.");
          alertWindowNeeded = true;
          // Don't mark as denied/allGranted = false *just* for this,
          // but track that it needs special handling.
        }
      } else if (!status.isGranted && !status.isLimited) {
        allGranted = false;
        deniedPermissions.add(_getPermissionName(permission));
        if (status.isPermanentlyDenied) {
          permanentlyDenied.add(permission);
        }
      }
    });

    // Request background location only if primary location is granted
    if (statuses[Permission.location]?.isGranted == true) {
      PermissionStatus bgStatus = await Permission.locationAlways.request();
      print("  Permission: ${Permission.locationAlways}, Status: $bgStatus");
      if (!bgStatus.isGranted) {
        allGranted = false;
        deniedPermissions.add(_getPermissionName(Permission.locationAlways));
        if (bgStatus.isPermanentlyDenied) {
          permanentlyDenied.add(Permission.locationAlways);
        }
      }
    } else {
      allGranted = false;
      if (!deniedPermissions.contains(
          _getPermissionName(Permission.location))) {
        deniedPermissions.add(_getPermissionName(Permission.location));
      }
    }

    if (!allGranted || alertWindowNeeded && context.mounted) {
      print(
          "PERMISSION_SERVICE: Some permissions were denied or need manual setup.");
      await _showPermissionDialog(
        context,
        deniedPermissions,
        alertWindowNeeded, // Pass this flag
        permanentlyDenied.isNotEmpty,
      );
    } else if (allGranted) {
      print("PERMISSION_SERVICE: All necessary permissions granted!");
    }

    return allGranted;
  }

  static String _getPermissionName(Permission permission) {
    if (permission == Permission.location) return "Location";
    if (permission == Permission.locationAlways) return "Background Location";
    if (permission == Permission.bluetoothScan) return "Bluetooth Scan";
    if (permission == Permission.bluetoothConnect) return "Bluetooth Connect";
    if (permission == Permission.notification) return "Notifications";
    if (permission == Permission.phone) return "Phone Calls";
    // Add the name for System Alert Window
    if (permission == Permission.systemAlertWindow)
      return "Display Over Other Apps";
    return permission.toString().split('.').last;
  }

  static Future<void> _showPermissionDialog(BuildContext context,
      List<String> denied,
      bool needsAlertWindow, // Added parameter
      bool isPermanent,) async {
    if (!context.mounted) return;

    String alertWindowMessage = needsAlertWindow
        ? "\n\n• Display Over Other Apps (Crucial for immediate alerts when unlocked. You *must* grant this manually in settings)."
        : "";

    String permanentMessage = isPermanent
        ? "Some permissions were permanently denied. Please go to your phone's Settings -> Apps -> Smart Cane -> Permissions to grant them."
        : "Please grant these permissions for the app to work correctly.";

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("Permissions Required"),
          content: Text(
            "The Smart Cane app needs these permissions:\n\n• ${denied.join(
                '\n• ')}" +
                alertWindowMessage + // Add the alert window message
                "\n\n" + permanentMessage,
          ),
          actions: <Widget>[
            TextButton(
              child: const Text("Open Settings"),
              onPressed: () {
                openAppSettings(); // This will open the app's settings page
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              child: const Text("OK"),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }
}