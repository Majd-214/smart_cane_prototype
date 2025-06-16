// lib/services/permission_service.dart
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  static Future<bool> requestAllPermissions(BuildContext context) async {
    print("PERMISSION_SERVICE: Requesting all necessary permissions...");

    // Define all permissions needed
    final List<Permission> permissionsToRequest = [
      Permission.location,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.notification,
      Permission.phone,
      Permission.systemAlertWindow,
      Permission.sms, // <-- ADDED THIS LINE
      Permission.microphone, // <-- ADDED THIS LINE
    ];

    Map<Permission, PermissionStatus> statuses =
    await permissionsToRequest.request();

    bool allGranted = true;
    List<String> deniedPermissions = [];
    List<Permission> permanentlyDenied = [];
    bool alertWindowNeeded = false;

    // Check permissions
    statuses.forEach((permission, status) {
      print("  Permission: $permission, Status: $status");

      if (permission == Permission.systemAlertWindow) {
        if (!status.isGranted) {
          alertWindowNeeded = true;
        }
      } else if (!status.isGranted && !status.isLimited) {
        allGranted = false;
        deniedPermissions.add(_getPermissionName(permission));
        if (status.isPermanentlyDenied) {
          permanentlyDenied.add(permission);
        }
      }
    });

    // Check background location
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
      await _showPermissionDialog(
        context,
        deniedPermissions,
        alertWindowNeeded,
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
    if (permission == Permission.sms) return "SMS Messages";
    if (permission == Permission.microphone) return "Microphone";
    if (permission == Permission.systemAlertWindow)
      return "Display Over Other Apps";
    return permission.toString().split('.').last;
  }

  // _showPermissionDialog remains the same
  static Future<void> _showPermissionDialog(BuildContext context,
      List<String> denied,
      bool needsAlertWindow,
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
                alertWindowMessage +
                "\n\n" + permanentMessage,
          ),
          actions: <Widget>[
            TextButton(
              child: const Text("Open Settings"),
              onPressed: () {
                openAppSettings();
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