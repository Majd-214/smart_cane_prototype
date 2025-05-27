// lib/main.dart
import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart'; // Ensure this is imported
import 'package:smart_cane_prototype/screens/home_screen.dart';
import 'package:smart_cane_prototype/screens/login_screen.dart';
import 'package:smart_cane_prototype/services/background_service_handler.dart';
import 'package:smart_cane_prototype/utils/app_theme.dart';

import 'firebase_options.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// --- DEFINITIONS ---
final StreamController<bool> fallAlertStreamController = StreamController<
    bool>.broadcast();

Stream<bool> get onFallAlertTriggered => fallAlertStreamController.stream;

final StreamController<Map<String,
    dynamic>> backgroundConnectionUpdateStreamController = StreamController<
    Map<String, dynamic>>.broadcast();

Stream<Map<String, dynamic>> get onBackgroundConnectionUpdate =>
    backgroundConnectionUpdateStreamController.stream;

const String fallNotificationChannelId = 'smart_cane_fall_channel'; // Channel ID for fall alerts

// At the top level (outside any class)
bool isCurrentlyHandlingFall = false;
const int fallNotificationId = 999; // Use a constant

// NEW Global Navigation Function
void _navigateToHomeWithFall({required String from}) {
  if (isCurrentlyHandlingFall) {
    print(
        "MAIN_APP: Ignoring navigation from '$from' - already handling fall.");
    return; // <-- The Lock!
  }

  print("MAIN_APP: Proceeding with navigation from '$from'. Setting lock.");
  isCurrentlyHandlingFall = true; // <-- Set Lock!

  // Ensure we have a navigator key and context
  if (navigatorKey.currentState != null) {
    navigatorKey.currentState?.pushNamedAndRemoveUntil(
      '/home', (route) => false,
      arguments: {'fallDetected': true, 'from': from},
    );
  } else {
    print("MAIN_APP: Navigator key is null - cannot navigate.");
    // Maybe set a flag to navigate once ready? But this shouldn't happen often.
    isCurrentlyHandlingFall = false; // Release lock if can't navigate.
  }
}

@pragma('vm:entry-point')
void _onDidReceiveNotificationResponse(NotificationResponse response) {
  print("MAIN_APP: Notification Tapped! Payload: ${response.payload}");
  if (response.payload == 'FALL_DETECTED_PAYLOAD') {
    print("MAIN_APP: Fall payload detected. Attempting navigation via tap.");
    _navigateToHomeWithFall(from: "Notification Tap");
  }
}

Future<void> _showFallNotification() async {
  print("MAIN_APP: Attempting to show FULL SCREEN fall notification.");
  const AndroidNotificationDetails androidPlatformChannelSpecifics =
  AndroidNotificationDetails(
    fallNotificationChannelId, // Use the constant
    'Fall Alerts',
    channelDescription: 'High-priority notifications for Smart Cane fall detection.',
    importance: Importance.max,
    // Make sure this is max
    priority: Priority.high,
    // Make sure this is high
    showWhen: true,
    playSound: true,
    enableVibration: true,
    fullScreenIntent: true,
    // Make sure this is true
    ticker: '!!! FALL DETECTED !!!',
  );
  const NotificationDetails platformChannelSpecifics =
  NotificationDetails(android: androidPlatformChannelSpecifics);

  await flutterLocalNotificationsPlugin.show(
      999, // Unique ID for fall notifications
      '!!! FALL DETECTED !!!',
      'A fall has been detected. Opening Smart Cane app...',
      platformChannelSpecifics,
      payload: 'FALL_DETECTED_PAYLOAD');
  print("MAIN_APP: Full screen fall notification shown command issued.");
}

Future<void> initializeAppServices() async {
  final service = FlutterBackgroundService();

  if (await Permission.notification.isDenied) {
    await Permission.notification.request();
  }

  const AndroidNotificationChannel fallChannel = AndroidNotificationChannel(
    fallNotificationChannelId, // Use the constant
    'Fall Alerts',
    description: 'High-priority notifications for Smart Cane fall detection.',
    importance: Importance.max,
    playSound: true,
  );

  const AndroidNotificationChannel serviceChannel = AndroidNotificationChannel(
    notificationChannelId, // From background_service_handler
    notificationChannelName, // From background_service_handler
    description: 'This channel is used for Smart Cane background monitoring.',
    importance: Importance.low,
  );

  final androidLocalNotificationsPlugin = flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();

  await androidLocalNotificationsPlugin?.createNotificationChannel(fallChannel);
  await androidLocalNotificationsPlugin?.createNotificationChannel(
      serviceChannel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: notificationChannelId,
      // Use service channel ID here
      initialNotificationTitle: 'Smart Cane Service',
      initialNotificationContent: 'Monitoring Inactive',
      foregroundServiceNotificationId: notificationId,
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );

  service.on(triggerFallAlertUIEvent).listen((event) {
    print(
        "MAIN_APP: Received '$triggerFallAlertUIEvent'. Showing notification & attempting navigation.");
    _showFallNotification();
    fallAlertStreamController.add(true); // Still signal via stream
  });

  service.on(backgroundServiceConnectionUpdateEvent).listen((event) {
    if (event != null &&
        backgroundConnectionUpdateStreamController.hasListener &&
        !backgroundConnectionUpdateStreamController.isClosed) {
      backgroundConnectionUpdateStreamController.add(event);
    }
  });

  print("Background Service Configured and UI listeners set up.");
}

Future<bool> _isUserSignedIn() async {
  return await GoogleSignIn().isSignedIn();
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // We removed the native method channel handling as we use SharedPreferences now.

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings(
      '@mipmap/ic_launcher');
  const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid);

  final prefs = await SharedPreferences.getInstance();
  bool launchedDueToPendingFall = prefs.getBool('fall_pending_alert') ?? false;
  if (launchedDueToPendingFall) {
    print("MAIN: App launched, found 'fall_pending_alert' flag.");
    await prefs.remove('fall_pending_alert'); // Clear it immediately
  }

  final NotificationAppLaunchDetails? notificationAppLaunchDetails = await flutterLocalNotificationsPlugin
      .getNotificationAppLaunchDetails();
  bool launchedViaFallNotificationTap = false;
  if (notificationAppLaunchDetails?.didNotificationLaunchApp ?? false) {
    if (notificationAppLaunchDetails!.notificationResponse?.payload ==
        'FALL_DETECTED_PAYLOAD') {
      launchedViaFallNotificationTap = true;
      print("MAIN: App launched from TAPPING fall notification (Fallback).");
    }
  }

  await flutterLocalNotificationsPlugin.initialize(
    initializationSettings,
    onDidReceiveNotificationResponse: _onDidReceiveNotificationResponse,
  );

  await initializeAppServices();
  bool signedIn = await _isUserSignedIn();

  bool isFallLaunch = launchedDueToPendingFall ||
      launchedViaFallNotificationTap;
  String determinedInitialRoute = isFallLaunch ? '/home_fall_launch' : (signedIn
      ? '/home'
      : '/login');

  runApp(MyApp(
      initialRoute: determinedInitialRoute,
      launchedFromFallNotificationTap: isFallLaunch
  ));
}

class MyApp extends StatefulWidget {
  final String initialRoute;
  final bool launchedFromFallNotificationTap;

  const MyApp({
    super.key,
    required this.initialRoute,
    required this.launchedFromFallNotificationTap,
  });

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  StreamSubscription<bool>? _fallAlertSubscription;

  @override
  void initState() {
    super.initState();
    _fallAlertSubscription = onFallAlertTriggered.listen((isFall) {
      if (isFall && mounted) {
        print(
            "MyApp: Fall alert stream received. Attempting navigation via stream.");
        _navigateToHomeWithFall(from: "Stream");
      }
    });
  }

  @override
  void dispose() {
    _fallAlertSubscription?.cancel();
    backgroundConnectionUpdateStreamController.close();
    fallAlertStreamController.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Smart Cane Prototype App',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      initialRoute: widget.initialRoute,
      routes: {
        '/login': (context) => const LoginScreen(),
        '/home': (context) {
          final args = ModalRoute
              .of(context)
              ?.settings
              .arguments as Map<String, dynamic>?;
          bool isFallLaunch = widget.launchedFromFallNotificationTap ||
              (args?['fallDetected'] ?? false);
          print(
              "MyApp routing to /home: isFallLaunch = $isFallLaunch, args = $args");
          return HomeScreen(launchedFromFall: isFallLaunch);
        },
        '/home_fall_launch': (context) =>
        const HomeScreen(launchedFromFall: true),
      },
      debugShowCheckedModeBanner: false,
    );
  }
}