import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
// We will access theme colors via Theme.of(context) now,
// so the direct import for color constants is less critical here,
// but keep it if you still reference AppTheme.warningColor or similar
// that are not part of the standard ColorScheme.
// import 'package:smart_cane_prototype/utils/app_theme.dart';
import 'package:smart_cane_prototype/screens/home_screen.dart'; // Navigate to Home after login

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    // Optional: Specify scopes if needed
    // scopes: ['email'],
  );

  // Function to handle Google Sign-In
  Future<void> _handleSignIn() async {
    try {
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      if (googleUser != null) {
        print('Signed in: ${googleUser.displayName}');
        // Get authentication details if needed (e.g., for backend)
        // final GoogleSignInAuthentication googleAuth = await googleUser.authentication;
        // print('ID Token: ${googleAuth.idToken}');
        // print('Access Token: ${googleAuth.accessToken}');

        // Navigate to the home screen on successful login
        if (mounted) { // Check if the widget is still in the tree
          Navigator.pushReplacementNamed(context, '/home');
        }
      } else {
        // User cancelled the sign-in process
        print('Sign-in cancelled');
        // Optionally show a message to the user
      }
    } catch (error) {
      print('Error signing in: $error');
      // Show an error message to the user using the theme's error color
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error signing in: ${error.toString()}'),
            backgroundColor: Theme.of(context).colorScheme.error, // Use themed error color
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Access the current theme, text styles, and color scheme
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final colorScheme = theme.colorScheme;

    // Determine text colors based on the theme's onBackground color
    final Color primaryTextThemedColor = colorScheme.onBackground;
    final Color secondaryTextThemedColor = colorScheme.onBackground.withOpacity(0.7); // Slightly less opaque for secondary text


    return Scaffold(
      // Use the themed background color defined in MaterialApp
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch, // Stretch to fill width
            children: <Widget>[
              // App Logo or Icon (Placeholder)
              Icon(
                Icons.elderly, // Example icon, find a suitable one
                size: 100,
                color: colorScheme.primary, // Use primary color from the theme's color scheme
              ),
              const SizedBox(height: 24), // Increased spacing
              Text(
                'Smart Cane',
                textAlign: TextAlign.center,
                // Use headlineMedium from the themed textTheme
                style: textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: primaryTextThemedColor, // Use themed primary text color
                ),
              ),
              const SizedBox(height: 8), // Reduced spacing
              Text(
                'Sign in to continue',
                textAlign: TextAlign.center,
                // Use titleMedium from the themed textTheme
                style: textTheme.titleMedium?.copyWith(
                  color: secondaryTextThemedColor, // Use themed secondary text color
                ),
              ),
              const SizedBox(height: 40),
              // Google Sign-In Button
              ElevatedButton.icon(
                label: Text(
                  'Sign in with Google',
                  style: textTheme.labelLarge?.copyWith(
                    fontSize: 18, // Explicitly setting font size if needed, but theme should handle
                    fontWeight: FontWeight.w500, // Explicitly setting weight if needed
                    // ** Adjusted: Explicitly set text color to a dark shade for the white button **
                    color: Colors.black87, // Dark text color for the white button
                  ),
                ),
                icon: Image.asset( // Use your Google logo asset
                  'assets/google_g.png',
                  height: 24,
                  // ** Adjusted: Explicitly set icon color if needed to match text **
                  // color: Colors.black87, // Uncomment if your PNG needs tinting
                ),
                onPressed: _handleSignIn,
                style: ElevatedButton.styleFrom(
                  // ** Adjusted: Explicitly set background color to white **
                  backgroundColor: Colors.white, // White background for the login button
                  // ** Adjusted: Explicitly set foreground color to a dark shade **
                  foregroundColor: Colors.black87, // Dark foreground color for the login button
                  minimumSize: const Size(double.infinity, 50), // Full width button
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}