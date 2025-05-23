// lib/main.dart
import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Ensure this is imported
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:smart_cane_prototype/screens/home_screen.dart';
import 'package:smart_cane_prototype/screens/login_screen.dart';
import 'package:smart_cane_prototype/services/background_service_handler.dart';
import 'package:smart_cane_prototype/utils/app_theme.dart';

import 'firebase_options.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

final StreamController<
    bool> fallDetectedNativeStreamController = StreamController<
    bool>.broadcast();

Stream<bool> get onFallDetectedNative =>
    fallDetectedNativeStreamController.stream;

final StreamController<Map<String,
    dynamic>> backgroundConnectionUpdateStreamController = StreamController<
    Map<String, dynamic>>.broadcast();

Stream<Map<String, dynamic>> get onBackgroundConnectionUpdate =>
    backgroundConnectionUpdateStreamController.stream;

// Make sure _appLifecycleChannel is defined and accessible
const MethodChannel _appLifecycleChannel = MethodChannel(
    'com.sept.learning_factory.smart_cane_prototype/app_lifecycle');


void _onDidReceiveNotificationResponse(NotificationResponse response) {
  print(
      "MAIN_APP: Notification Tapped (while app is running)! Payload: ${response
          .payload}");
  if (response.payload == 'FALL_DETECTED_PAYLOAD') {
    // If tapped, we still want to ensure we navigate correctly.
    // The forceLaunch might already be doing this, but this provides a backup.
    navigatorKey.currentState?.pushNamedAndRemoveUntil(
      '/home',
          (route) => false,
      arguments: {'fallDetected': true, 'fromNotificationTap': true},
    );
  }
}

// ** NEW Function **
Future<void> _showFallNotificationAndLaunch() async {
  print("MAIN_APP: Attempting to show fall notification AND launch app.");

  // 1. Show the Notification (still important for visual/audio cue & fullScreenIntent backup)
  const AndroidNotificationDetails androidPlatformChannelSpecifics =
  AndroidNotificationDetails(
    'smart_cane_fall_channel', // Use the high-priority channel
    'Fall Alerts',
    channelDescription: 'High-priority notifications for Smart Cane fall detection.',
    importance: Importance.max,
    priority: Priority.high,
    showWhen: true,
    playSound: true,
    enableVibration: true,
    fullScreenIntent: true,
    // Keep this - it helps!
    ticker: '!!! FALL DETECTED !!!',
  );
  const NotificationDetails platformChannelSpecifics =
  NotificationDetails(android: androidPlatformChannelSpecifics);

  await flutterLocalNotificationsPlugin.show(
      999, // Use a specific ID for fall notifications
      '!!! FALL DETECTED !!!',
      'A fall has been detected. Opening Smart Cane app...',
      platformChannelSpecifics,
      payload: 'FALL_DETECTED_PAYLOAD');
  print("MAIN_APP: Fall notification shown command issued.");

  // 2. Attempt to launch via Platform Channel ** ADDED **
  try {
    print("MAIN_APP: Invoking 'forceLaunch' on native channel.");
    await _appLifecycleChannel.invokeMethod('forceLaunch');
    print("MAIN_APP: 'forceLaunch' invoked successfully.");
  } on PlatformException catch (e) {
    print("MAIN_APP: Failed to invoke 'forceLaunch': ${e.message}");
  }
}


Future<void> initializeAppServices() async {
  final service = FlutterBackgroundService();

  // ... (Keep existing permission and channel creation code) ...
  PermissionStatus notificationStatus = await Permission.notification.status;
  if (notificationStatus.isDenied) {
    await Permission.notification.request();
  }

  const AndroidNotificationChannel fallChannel = AndroidNotificationChannel(
    'smart_cane_fall_channel',
    'Fall Alerts',
    description: 'High-priority notifications for Smart Cane fall detection.',
    importance: Importance.max,
    playSound: true,
  );

  const AndroidNotificationChannel serviceChannel = AndroidNotificationChannel(
    notificationChannelId,
    notificationChannelName,
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
      initialNotificationTitle: 'Smart Cane Service',
      initialNotificationContent: 'Monitoring Inactive',
      foregroundServiceNotificationId: notificationId,
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );

  // ** UPDATE the listener here **
  service.on(triggerFallAlertUIEvent).listen((event) {
    print(
        "MAIN_APP: Received '$triggerFallAlertUIEvent' from background service.");
    _showFallNotificationAndLaunch(); // Call the NEW function
  });

  // ... (Keep existing backgroundConnectionUpdateEvent listener) ...
  service.on(backgroundServiceConnectionUpdateEvent).listen((event) {
    if (event != null) {
      print(
          "MAIN_APP: Received '$backgroundServiceConnectionUpdateEvent': $event");
      if (backgroundConnectionUpdateStreamController.hasListener &&
          !backgroundConnectionUpdateStreamController.isClosed) {
        backgroundConnectionUpdateStreamController.add(event);
      }
    }
  });


  print("Background Service Configured and UI listeners set up.");
}

// ** NEW Handler for the native method call **
Future<void> _handleNativeMethodCalls(MethodCall call) async {
  print("MAIN_APP: Received native method call: ${call.method}");
  if (call.method == "onFallDetectedLaunch") {
    print(
        "MAIN_APP: Fall detected launch signal from native. Triggering fall UI via stream / nav.");
    // This stream helps if HomeScreen is already active,
    // but the navigation is key for launching/bringing to front.
    if (fallDetectedNativeStreamController.hasListener &&
        !fallDetectedNativeStreamController.isClosed) {
      fallDetectedNativeStreamController.add(true);
    }
    // This navigation is crucial for bringing the app state correctly
    navigatorKey.currentState?.pushNamedAndRemoveUntil(
      '/home',
          (route) => false,
      arguments: {'fallDetected': true, 'fromNativeDirectLaunch': true},
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // ** Ensure the handler is set BEFORE running the app **
  _appLifecycleChannel.setMethodCallHandler(_handleNativeMethodCalls);

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // ... (Keep existing notification setup and main logic) ...
  const AndroidInitializationSettings initializationSettingsAndroid =
  AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings =
  InitializationSettings(android: initializationSettingsAndroid);

  final NotificationAppLaunchDetails? notificationAppLaunchDetails =
  await flutterLocalNotificationsPlugin.getNotificationAppLaunchDetails();

  bool launchedViaFallNotificationTap = false;
  if (notificationAppLaunchDetails?.didNotificationLaunchApp ?? false) {
    if (notificationAppLaunchDetails!.notificationResponse?.payload ==
        'FALL_DETECTED_PAYLOAD') {
      launchedViaFallNotificationTap = true;
      print("MAIN: App launched from TAPPING fall notification.");
    }
  }

  await flutterLocalNotificationsPlugin.initialize(
    initializationSettings,
    onDidReceiveNotificationResponse: _onDidReceiveNotificationResponse,
  );

  await initializeAppServices();
  bool signedIn = await GoogleSignIn().isSignedIn();
  String determinedInitialRoute = launchedViaFallNotificationTap
      ? '/home_fall_launch'
      : (signedIn ? '/home' : '/login');

  runApp(MyApp(
      initialRoute: determinedInitialRoute,
      launchedFromFallNotificationTap: launchedViaFallNotificationTap
  ));
}

// ... (Keep MyApp and _MyAppState as is, ensuring _nativeFallSubscription exists) ...

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
  StreamSubscription<bool>? _nativeFallSubscription;

  @override
  void initState() {
    super.initState();
    // This listener handles the 'onFallDetectedLaunch' from native,
    // ensuring navigation happens if the app is already running.
    _nativeFallSubscription = onFallDetectedNative.listen((isFall) {
      if (isFall && mounted && navigatorKey.currentState != null) {
        print(
            "MyApp initState: Native fall detected stream received. Navigating to home with fall args.");
        navigatorKey.currentState!.pushNamedAndRemoveUntil(
          '/home',
              (route) => false,
          arguments: {'fallDetected': true, 'fromNativeStream': true},
        );
      }
    });
  }

  @override
  void dispose() {
    _nativeFallSubscription?.cancel();
    backgroundConnectionUpdateStreamController.close();
    fallDetectedNativeStreamController.close();
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