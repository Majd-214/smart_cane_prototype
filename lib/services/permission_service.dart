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
    ];

    // Request the primary set
    Map<Permission, PermissionStatus> statuses =
        await permissionsToRequest.request();

    bool allGranted = true;
    List<String> deniedPermissions = [];
    List<Permission> permanentlyDenied = [];

    // Check primary permissions
    statuses.forEach((permission, status) {
      print("  Permission: $permission, Status: $status");
      if (!status.isGranted && !status.isLimited) {
        // isLimited is mostly for photos/iOS
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
        // Decide if background is mandatory. For your feature, it likely is.
        allGranted = false;
        deniedPermissions.add(_getPermissionName(Permission.locationAlways));
        if (bgStatus.isPermanentlyDenied) {
          permanentlyDenied.add(Permission.locationAlways);
        }
        print(
          "  WARNING: Background location not granted. Background features will fail.",
        );
      }
    } else {
      print(
        "  INFO: Skipping Background location request as primary location was denied.",
      );
      allGranted = false; // If primary isn't granted, we can't get background.
      if (!deniedPermissions.contains(
        _getPermissionName(Permission.location),
      )) {
        deniedPermissions.add(_getPermissionName(Permission.location));
      }
    }

    if (!allGranted && context.mounted) {
      print(
        "PERMISSION_SERVICE: Some permissions were denied: $deniedPermissions",
      );
      // Show dialog guiding user to settings if any are permanently denied.
      await _showPermissionDialog(
        context,
        deniedPermissions,
        permanentlyDenied.isNotEmpty,
      );
    } else if (allGranted) {
      print("PERMISSION_SERVICE: All necessary permissions granted!");
    }

    return allGranted;
  }

  static String _getPermissionName(Permission permission) {
    if (permission == Permission.location) return "Location";
    if (permission == Permission.locationAlways)
      return "Background Location (Always)";
    if (permission == Permission.bluetoothScan) return "Bluetooth Scan";
    if (permission == Permission.bluetoothConnect) return "Bluetooth Connect";
    if (permission == Permission.notification) return "Notifications";
    if (permission == Permission.phone) return "Phone Calls";
    return permission.toString().split('.').last;
  }

  static Future<void> _showPermissionDialog(
    BuildContext context,
    List<String> denied,
    bool isPermanent,
  ) async {
    // Check if the context is still mounted before showing the dialog
    if (!context.mounted) return;

    await showDialog(
      context: context,
      barrierDismissible: false, // User must interact
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("Permissions Required"),
          content: Text(
            "The Smart Cane app needs these permissions for safety features like fall detection and emergency calls:\n\n• ${denied.join('\n• ')}\n\n" +
                (isPermanent
                    ? "Some permissions were permanently denied. Please go to your phone's Settings -> Apps -> Smart Cane -> Permissions to grant them."
                    : "Please grant these permissions for the app to work correctly."),
          ),
          actions: <Widget>[
            if (isPermanent)
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
