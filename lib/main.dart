// lib/main.dart
import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_cane_prototype/screens/home_screen.dart';
import 'package:smart_cane_prototype/screens/login_screen.dart';
import 'package:smart_cane_prototype/services/background_service_handler.dart'; // For constants
import 'package:smart_cane_prototype/utils/app_theme.dart';

import 'firebase_options.dart';

// --- Global Variables & Constants ---
bool isCurrentlyHandlingFall = false;
const int fallNotificationId = 999;
const String fallHandledKey = 'fall_handled_for_this_launch_detail';
// const String fallPendingAlertKey = 'fall_pending_alert'; // Defined in background_service_handler

// --- Notification Plugin & Navigator Key ---
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// --- Stream Controllers ---
final StreamController<bool> fallAlertStreamController = StreamController<
    bool>.broadcast();
Stream<bool> get onFallAlertTriggered => fallAlertStreamController.stream;

final StreamController<Map<String,
    dynamic>> backgroundConnectionUpdateStreamController = StreamController<
    Map<String, dynamic>>.broadcast();

Stream<Map<String, dynamic>> get onBackgroundConnectionUpdate =>
    backgroundConnectionUpdateStreamController.stream;

// --- Notification Channel Constants ---
const String fallNotificationChannelId = 'smart_cane_fall_channel';
// Using constants from imported background_service_handler.dart for service channel
// const String serviceNotificationChannelId = notificationChannelId;
// const String serviceNotificationChannelName = notificationChannelName;


@pragma('vm:entry-point')
void _onDidReceiveNotificationResponse(NotificationResponse response) async {
  print("MAIN_APP: Notification Tapped! Payload: ${response
      .payload}, Action ID: ${response.actionId}");
  if (response.payload == 'FALL_DETECTED_PAYLOAD') {
    print(
        "MAIN_APP: Fall payload detected from notification tap. Setting '$fallPendingAlertKey'.");
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(fallPendingAlertKey, true);
    await prefs.remove(fallHandledKey);
  }
}

// Renamed and modified: only configures, doesn't start. Start is now explicit.
Future<void> configureBackgroundService() async {
  final service = FlutterBackgroundService();

  if (await Permission.notification.isDenied) {
    await Permission.notification.request();
  }

  const AndroidNotificationChannel fallChannel = AndroidNotificationChannel(
    fallNotificationChannelId, 'Fall Alerts',
    description: 'High-priority notifications for Smart Cane fall detection.',
    importance: Importance.max, playSound: true,
  );

  const AndroidNotificationChannel serviceChannelForNotifications = AndroidNotificationChannel(
    notificationChannelId, notificationChannelName,
    // From background_service_handler.dart
    description: 'This channel is used for Smart Cane background monitoring.',
    importance: Importance.low,
  );

  final androidLocalNotificationsPlugin = flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  if (androidLocalNotificationsPlugin != null) {
    await androidLocalNotificationsPlugin.createNotificationChannel(
        fallChannel);
    await androidLocalNotificationsPlugin.createNotificationChannel(
        serviceChannelForNotifications);
  }

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      // Explicitly false
      isForegroundMode: true,
      notificationChannelId: notificationChannelId,
      initialNotificationTitle: 'Smart Cane Service',
      initialNotificationContent: 'Service Idle. Select a cane.',
      // Updated initial content
      foregroundServiceNotificationId: notificationId,
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );

  service.on(triggerFallAlertUIEvent).listen((event) {
    print(
        "MAIN_APP: Received '$triggerFallAlertUIEvent' from background service.");
    // 1. Always show the notification (this handles bringing the app up)
    _showFallNotification();
    // 2. Always send the event via stream (HomeScreen will handle it if active)
    if (!fallAlertStreamController.isClosed) {
      fallAlertStreamController.add(true);
    }
  });

  service.on(backgroundServiceConnectionUpdateEvent).listen((event) {
    if (event != null &&
        backgroundConnectionUpdateStreamController.hasListener &&
        !backgroundConnectionUpdateStreamController.isClosed) {
      backgroundConnectionUpdateStreamController.add(
          event as Map<String, dynamic>);
    }
  });
  print(
      "MAIN_APP: Background Service Configured (not yet started). UI listeners set up.");
}

Future<void> _showFallNotification() async {
  print("MAIN_APP: Attempting to show FULL SCREEN fall notification.");
  const AndroidNotificationDetails androidPlatformChannelSpecifics =
  AndroidNotificationDetails(
    fallNotificationChannelId, 'Fall Alerts', // Ensure this ID is high-priority
    channelDescription: 'High-priority notifications for Smart Cane fall detection.',
    importance: Importance.max,
    // MUST be max
    priority: Priority.high,
    // MUST be high
    showWhen: true,
    playSound: true,
    enableVibration: true,
    fullScreenIntent: true,
    // THE KEY!
    ticker: '!!! FALL DETECTED !!!',
  );
  const NotificationDetails platformChannelSpecifics =
  NotificationDetails(android: androidPlatformChannelSpecifics);

  await flutterLocalNotificationsPlugin.show(
      fallNotificationId, '!!! FALL DETECTED !!!',
      'A fall has been detected. Opening Smart Cane app...',
      platformChannelSpecifics, payload: 'FALL_DETECTED_PAYLOAD');
  print("MAIN_APP: Full screen fall notification shown command issued.");
}

Future<bool> _isUserSignedIn() async {
  return await GoogleSignIn().isSignedIn();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  isCurrentlyHandlingFall = false;
  print("MAIN: Global fall handling lock reset at app start/restart.");

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings(
      '@mipmap/ic_launcher');
  const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid);

  final prefs = await SharedPreferences.getInstance();
  bool fallAlreadyHandledForThisLaunchDetail = prefs.getBool(fallHandledKey) ??
      false;
  bool pendingFallAlert = prefs.getBool(fallPendingAlertKey) ?? false;

  if (pendingFallAlert) {
    print("MAIN: App launch, found '$fallPendingAlertKey' flag. Clearing it.");
    await prefs.remove(fallPendingAlertKey);
    await prefs.remove(fallHandledKey);
    fallAlreadyHandledForThisLaunchDetail = false;
  }

  await flutterLocalNotificationsPlugin.initialize(
    initializationSettings,
    onDidReceiveNotificationResponse: _onDidReceiveNotificationResponse,
  );

  final NotificationAppLaunchDetails? notificationAppLaunchDetails =
  await flutterLocalNotificationsPlugin.getNotificationAppLaunchDetails();

  // Determine if launched *specifically* from tapping our fall notification.
  bool launchedFromFallTap =
      (notificationAppLaunchDetails?.didNotificationLaunchApp ?? false) &&
          notificationAppLaunchDetails!.notificationResponse?.payload ==
              'FALL_DETECTED_PAYLOAD';

  await configureBackgroundService();
  bool signedIn = await _isUserSignedIn();

  // If launched via tap, *always* go to home with a flag.
  // Otherwise, normal login/home logic.
  String determinedInitialRoute = signedIn ? '/home' : '/login';
  bool passFallFlag = launchedFromFallTap;

  print(
      "MAIN: Initial Route: $determinedInitialRoute, Fall Flag: $passFallFlag");

  runApp(MyApp(
    initialRoute: determinedInitialRoute,
    launchedFromFallNotificationTap: passFallFlag, // Pass the flag
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
    _fallAlertSubscription = fallAlertStreamController.stream.listen((isFall) {
      if (isFall && mounted) {
        print(
            "MyApp State: Fall alert stream received while app is active. Attempting navigation.");
      }
    });
  }

  @override
  void dispose() {
    _fallAlertSubscription?.cancel();
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
          // Use the flag from main() OR arguments (in case of stream-based nav)
          bool isFallLaunch = widget.launchedFromFallNotificationTap ||
              (args?['fallDetected'] ?? false);
          print(
              "MyApp routing to /home: Effective isFallLaunch = $isFallLaunch");
          return HomeScreen(launchedFromFall: isFallLaunch);
        },
      },
      debugShowCheckedModeBanner: false,
    );
  }
}