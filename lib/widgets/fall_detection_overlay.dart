// lib/widgets/fall_detection_overlay.dart

import 'dart:async'; // Add this import
import 'package:flutter/material.dart';
import 'package:smart_cane_prototype/utils/app_theme.dart';

// Convert to StatefulWidget
class FallDetectionOverlay extends StatefulWidget {
  final VoidCallback onImOk;
  final VoidCallback onCallEmergency;
  final int initialCountdownSeconds; // Renamed for clarity

  const FallDetectionOverlay({
    super.key,
    required this.onImOk,
    required this.onCallEmergency,
    this.initialCountdownSeconds = 30, // Default countdown, Google's is often 60s, adjust as needed
  });

  @override
  State<FallDetectionOverlay> createState() => _FallDetectionOverlayState();
}

class _FallDetectionOverlayState extends State<FallDetectionOverlay> {
  late Timer _timer;
  late int _remainingSeconds;
  bool _isTimerActive = true; // To prevent calling emergency multiple times

  @override
  void initState() {
    super.initState();
    _remainingSeconds = widget.initialCountdownSeconds;
    _startTimer();
  }

  void _startTimer() {
    _isTimerActive = true;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_remainingSeconds > 0) {
        if (mounted) { // Check if the widget is still in the tree
          setState(() {
            _remainingSeconds--;
          });
        }
      } else {
        _timer.cancel();
        if (_isTimerActive && mounted) { // Check if still active and mounted
          _isTimerActive = false; // Prevent multiple calls
          widget.onCallEmergency(); // Timer finished, trigger emergency call
        }
      }
    });
  }

  void _stopTimerAndDismiss(VoidCallback action) {
    _timer.cancel();
    _isTimerActive = false; // Ensure timer doesn't trigger emergency call after manual action
    if (mounted) {
      action(); // Perform the passed action (onImOk or onCallEmergency)
    }
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final Color alertColor = AppTheme.errorColor;
    const Color onAlertColor = Colors.white;

    return Scaffold(
      backgroundColor: alertColor,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Icon(
                  Icons.warning_amber_rounded,
                  color: onAlertColor,
                  size: 80,
                ),
                const SizedBox(height: 24),
                Text(
                  'Fall Detected!',
                  textAlign: TextAlign.center,
                  style: textTheme.displaySmall?.copyWith(
                    color: onAlertColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                // Text updated by the countdown
                Text(
                  _remainingSeconds > 0 ? 'Are you OK?' : 'Calling emergency services...',
                  textAlign: TextAlign.center,
                  style: textTheme.headlineMedium?.copyWith(
                    color: onAlertColor,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24.0),
                  // Display the remaining seconds
                  child: Text(
                    '$_remainingSeconds', // Show the dynamic remaining seconds
                    textAlign: TextAlign.center,
                    style: textTheme.displayLarge?.copyWith(
                      color: onAlertColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 80, // Make countdown number larger
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                ElevatedButton(
                  // Pass a wrapper to _stopTimerAndDismiss
                  onPressed: () => _stopTimerAndDismiss(widget.onImOk),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: onAlertColor,
                    foregroundColor: alertColor,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    textStyle: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                  child: const Text("I'm OK"),
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  // Pass a wrapper to _stopTimerAndDismiss
                  onPressed: () => _stopTimerAndDismiss(widget.onCallEmergency),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: onAlertColor, width: 2),
                    foregroundColor: onAlertColor,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    textStyle: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                  child: const Text('Call Emergency Now'), // Clarified button text
                ),
                const SizedBox(height: 24),
                Padding( // Add Padding for horizontal constraints if needed
                  padding: const EdgeInsets.symmetric(horizontal: 32.0), // Adjust padding as needed
                  child: Text(
                    _remainingSeconds > 0
                        ? 'An emergency call will be made automatically if you don\'t respond.' // Slightly rephrased for flow
                        : 'Attempting to contact emergency services.',
                    textAlign: TextAlign.center,
                    style: textTheme.bodyMedium?.copyWith(
                      color: onAlertColor.withOpacity(0.9), // Slightly more opaque
                      height: 1.4, // Adjust line height for better readability if it wraps
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}