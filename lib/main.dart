// lib/main.dart
import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

void _onDidReceiveNotificationResponse(NotificationResponse response) {
  print(
      "MAIN_APP: Notification Tapped (while app is running)! Payload: ${response
          .payload}");
  if (response.payload == 'FALL_DETECTED_PAYLOAD') {
    navigatorKey.currentState?.pushNamedAndRemoveUntil(
      '/home',
          (route) => false,
      arguments: {'fallDetected': true, 'fromNotificationTap': true},
    );
  }
}

Future<void> _showFallNotificationInMainIsolate() async {
  print("MAIN_APP: Attempting to show fall notification via Main Isolate.");
  const AndroidNotificationDetails androidPlatformChannelSpecifics =
  AndroidNotificationDetails(
    'smart_cane_fall_channel',
    'Fall Alerts',
    channelDescription: 'High-priority notifications for Smart Cane fall detection.',
    importance: Importance.max,
    priority: Priority.high,
    showWhen: true,
    playSound: true,
    enableVibration: true,
    fullScreenIntent: true,
    ticker: '!!! FALL DETECTED !!!',
  );
  const NotificationDetails platformChannelSpecifics =
  NotificationDetails(android: androidPlatformChannelSpecifics);

  await flutterLocalNotificationsPlugin.show(
      999,
      '!!! FALL DETECTED !!!',
      'A fall has been detected. Opening Smart Cane app...',
      platformChannelSpecifics,
      payload: 'FALL_DETECTED_PAYLOAD');
  print("MAIN_APP: Fall notification shown command issued from Main Isolate.");
}

Future<void> initializeAppServices() async {
  final service = FlutterBackgroundService();

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

  service.on(triggerFallAlertUIEvent).listen((event) {
    print(
        "MAIN_APP: Received '$triggerFallAlertUIEvent' from background service.");
    _showFallNotificationInMainIsolate();
  });

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

Future<bool> _isUserSignedIn() async {
  return await GoogleSignIn().isSignedIn();
}

const MethodChannel _appLifecycleChannel = MethodChannel(
    'com.sept.learning_factory.smart_cane_prototype/app_lifecycle');

Future<void> _handleNativeMethodCalls(MethodCall call) async {
  print("MAIN_APP: Received native method call: ${call.method}");
  if (call.method == "onFallDetectedLaunch") {
    print(
        "MAIN_APP: Fall detected launch signal from native. Triggering fall UI via stream.");
    if (fallDetectedNativeStreamController.hasListener &&
        !fallDetectedNativeStreamController.isClosed) {
      fallDetectedNativeStreamController.add(true);
    }
    navigatorKey.currentState?.pushNamedAndRemoveUntil(
      '/home',
          (route) => false,
      arguments: {'fallDetected': true, 'fromNativeDirectLaunch': true},
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _appLifecycleChannel.setMethodCallHandler(_handleNativeMethodCalls);

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

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

  bool signedIn = await _isUserSignedIn();

  String determinedInitialRoute = launchedViaFallNotificationTap
      ? '/home_fall_launch'
      : (signedIn ? '/home' : '/login');

  runApp(MyApp(
      initialRoute: determinedInitialRoute,
      launchedFromFallNotificationTap: launchedViaFallNotificationTap
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
  StreamSubscription<bool>? _nativeFallSubscription;

  @override
  void initState() {
    super.initState();
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
    backgroundConnectionUpdateStreamController.close(); // Close streams
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