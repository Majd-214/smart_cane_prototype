import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:smart_cane_prototype/screens/login_screen.dart';
import 'package:smart_cane_prototype/utils/app_theme.dart';
import 'package:smart_cane_prototype/screens/home_screen.dart';
// Import Firebase Core
import 'package:firebase_core/firebase_core.dart';
// Import the generated Firebase Options file
import 'firebase_options.dart';

void main() async { // Make main async
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    // Optional: Specify scopes if needed beyond basic profile info
    // scopes: ['email'],
  );

  // Check if a user is already signed in on app start
  Future<bool> _isSignedIn() async {
    return await _googleSignIn.isSignedIn();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Cane Prototype App', // Updated title
      theme: AppTheme.lightTheme, // Set the light theme
      darkTheme: AppTheme.darkTheme, // Set the dark theme
      themeMode: ThemeMode.system, // Use the system theme preference
      home: FutureBuilder<bool>(
        future: _isSignedIn(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            // Show a loading indicator while checking sign-in status
            return const Scaffold(
              body: Center(
                child: CircularProgressIndicator(),
              ),
            );
          } else {
            if (snapshot.hasData && snapshot.data == true) {
              // If signed in, go directly to the home screen
              return const HomeScreen();
            } else {
              // If not signed in, show the login screen
              return const LoginScreen();
            }
          }
        },
      ),
      // Define routes for navigation
      routes: {
        '/login': (context) => const LoginScreen(),
        '/home': (context) => const HomeScreen(),
      },
      debugShowCheckedModeBanner: false, // Hide debug banner
    );
  }
}