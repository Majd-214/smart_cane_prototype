import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:smart_cane_prototype/utils/app_theme.dart'; // Using our theme colors
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
        Navigator.pushReplacementNamed(context, '/home');
      } else {
        // User cancelled the sign-in process
        print('Sign-in cancelled');
        // Optionally show a message to the user
      }
    } catch (error) {
      print('Error signing in: $error');
      // Show an error message to the user
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error signing in: ${error.toString()}'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Access the theme's text styles
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      // Use a dark background for the login screen for a Google-inspired look
      backgroundColor: AppTheme.darkBackgroundColor,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              // App Logo or Icon (Placeholder)
              Icon(
                Icons.assist_walker, // Example icon, find a suitable one
                size: 100,
                color: AppTheme.darkPrimaryColor,
              ),
              const SizedBox(height: 20),
              Text(
                'Smart Cane',
                // Use headlineMedium from the theme and adjust if needed
                style: textTheme.headlineMedium?.copyWith(
                  fontSize: 36, // Override font size
                  fontWeight: FontWeight.bold, // Override weight
                  color: AppTheme.darkTextColorPrimary, // Use color from theme
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Sign in to continue',
                // Use bodyMedium from the theme and adjust if needed
                style: textTheme.bodyMedium?.copyWith(
                  fontSize: 18, // Override font size
                  color: AppTheme.darkTextColorSecondary, // Use color from theme
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),
              // Google Sign-In Button
              ElevatedButton.icon(
                icon: Image.asset(
                  'assets/google_logo.png', // You'll need to add a Google logo asset
                  height: 24,
                ),
                label: Text(
                  'Sign in with Google',
                  // Use button style text from the theme or define here
                  style: textTheme.labelLarge?.copyWith(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.textColorPrimary, // Text color on button
                  ),
                ),
                onPressed: _handleSignIn,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.darkTextColorPrimary, // White background for button
                  foregroundColor: AppTheme.textColorPrimary, // Dark text color
                  minimumSize: const Size(double.infinity, 50), // Full width button
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
              // Asset declaration reminder
            ],
          ),
        ),
      ),
    );
  }
}