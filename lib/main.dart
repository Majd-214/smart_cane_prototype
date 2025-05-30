// lib/main.dart
import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart'; // For
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_cane_prototype/screens/home_screen.dart';
import 'package:smart_cane_prototype/screens/login_screen.dart';
import 'package:smart_cane_prototype/services/background_service_handler.dart';
import 'package:smart_cane_prototype/services/ble_service.dart';
import 'package:smart_cane_prototype/utils/app_theme.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'firebase_options.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
FlutterLocalNotificationsPlugin();
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

final StreamController<bool> fallAlertStreamController =
StreamController<bool>.broadcast();
Stream<bool> get onFallAlertTriggered => fallAlertStreamController.stream;

final StreamController<Map<String, dynamic>>
backgroundConnectionUpdateStreamController =
StreamController<Map<String, dynamic>>.broadcast();
Stream<Map<String, dynamic>> get onBackgroundConnectionUpdate =>
    backgroundConnectionUpdateStreamController.stream;

const String fallNotificationChannelId = 'smart_cane_fall_channel_v2'; // Changed ID for new settings
bool isCurrentlyHandlingFall = false;

// --- Unified Notification & Single Audio Source Logic ---
final AudioPlayer _mainAudioPlayer = AudioPlayer();
bool _mainAlarmSoundPlaying = false;
bool _mainAudioPlayerInitialized = false;

Timer? _notificationCountdownTimer;
int currentNotificationCountdownSeconds = DEFAULT_FALL_COUNTDOWN_SECONDS;
const String INTERACTIVE_FALL_NOTIFICATION_PAYLOAD =
    'INTERACTIVE_FALL_DETECTED_PAYLOAD';
const String INTERACTIVE_FALL_ACTION_IM_OK =
    'INTERACTIVE_FALL_ACTION_IM_OK';
const String INTERACTIVE_FALL_ACTION_CALL_EMERGENCY =
    'INTERACTIVE_FALL_ACTION_CALL_EMERGENCY';
const String INTERACTIVE_FALL_ACTION_IM_OK_FROM_SWIPE =
    'INTERACTIVE_FALL_ACTION_IM_OK_FROM_SWIPE';
const int INTERACTIVE_FALL_NOTIFICATION_ID = 1001; // Ensure unique ID
Timer? _swipeDetectionTimer;
const int DEFAULT_FALL_COUNTDOWN_SECONDS = 30;


void _navigateToHomeWithFall(
    {required String from, int? resumeCountdownSeconds}) {
  bool alreadyOnFallScreen = false;
  if (navigatorKey.currentContext != null) {
    final ModalRoute<dynamic>? currentRoute =
    ModalRoute.of(navigatorKey.currentContext!);
    if (currentRoute?.settings.name == '/home') {
      final args = currentRoute?.settings.arguments as Map<String, dynamic>?;
      if (args?['fallDetected'] == true) {
        alreadyOnFallScreen = true;
      }
    }
  }

  if (alreadyOnFallScreen && isCurrentlyHandlingFall) {
    print(
        "MAIN_APP: Already on fall screen for '$from' & fall handling active. No re-navigation.");
    return;
  }

  if (!isCurrentlyHandlingFall) {
    isCurrentlyHandlingFall = true;
    print(
        "MAIN_APP: Navigating for fall from '$from'. Lock was OFF, now SET. Resume: ${resumeCountdownSeconds ??
            DEFAULT_FALL_COUNTDOWN_SECONDS}");
  } else {
    print(
        "MAIN_APP: Navigating for fall from '$from'. Lock already ON. Resume: ${resumeCountdownSeconds ??
            DEFAULT_FALL_COUNTDOWN_SECONDS}");
  }

  if (navigatorKey.currentState != null) {
    navigatorKey.currentState?.pushNamedAndRemoveUntil(
      '/home', (route) => false,
      arguments: {
        'fallDetected': true, 'from': from,
        'resumeCountdownSeconds': resumeCountdownSeconds ??
            DEFAULT_FALL_COUNTDOWN_SECONDS,
      },
    );
  } else {
    print("MAIN_APP: Nav key null for '$from'. Setting prefs for launch.");
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('resume_fall_overlay_on_launch', true);
      prefs.setInt('resume_countdown_seconds',
          resumeCountdownSeconds ?? DEFAULT_FALL_COUNTDOWN_SECONDS);
      prefs.setString('resume_fall_from', from);
    });
  }
}

@pragma('vm:entry-point')
Future<void> onDidReceiveBackgroundNotificationResponse(
    NotificationResponse response) async {
  print("MAIN_APP (Background): Notif Response: payload=${response
      .payload}, actionId=${response.actionId}");
  // Ensure essential services can be initialized if needed in this isolate context
  // WidgetsFlutterBinding.ensureInitialized(); // Usually handled by plugin if isolate is spawned by it

  if (response.actionId == INTERACTIVE_FALL_ACTION_IM_OK ||
      response.actionId == INTERACTIVE_FALL_ACTION_CALL_EMERGENCY) {
    await _handleInteractiveFallAction(response.actionId!);
  } else if (response.payload == INTERACTIVE_FALL_NOTIFICATION_PAYLOAD) {
    await _handleInteractiveFallAction(response.payload!);
  }
}

@pragma('vm:entry-point')
void _onDidReceiveNotificationResponse(NotificationResponse response) {
  print("MAIN_APP (FG/Terminated): Notif Tapped! Payload: ${response
      .payload}, ActionID: ${response.actionId}");
  if (response.actionId == INTERACTIVE_FALL_ACTION_IM_OK ||
      response.actionId == INTERACTIVE_FALL_ACTION_CALL_EMERGENCY) {
    _handleInteractiveFallAction(response.actionId!);
  } else if (response.payload == INTERACTIVE_FALL_NOTIFICATION_PAYLOAD) {
    _handleInteractiveFallAction(response.payload!);
  }
}

Future<void> _initializeMainAudioPlayer() async {
  if (_mainAudioPlayerInitialized) return;
  try {
    await _mainAudioPlayer.setAudioContext(AudioContext(
      android: AudioContextAndroid(
        isSpeakerphoneOn: true,
        stayAwake: true,
        contentType: AndroidContentType.sonification,
        usageType: AndroidUsageType.alarm,
        audioFocus: AndroidAudioFocus.gainTransientExclusive,
      ),
    ));
    await _mainAudioPlayer.setReleaseMode(ReleaseMode.loop);
    await _mainAudioPlayer.setVolume(1.0);
    _mainAudioPlayer.onPlayerStateChanged.listen((state) {
      _mainAlarmSoundPlaying = (state == PlayerState.playing);
      if (kDebugMode) print(
          "MAIN_APP: Audio Player State: $state, IsPlaying: $_mainAlarmSoundPlaying");
    });
    _mainAudioPlayerInitialized = true;
    print("MAIN_APP: Main Audio Player Initialized");
  } catch (e) {
    print("MAIN_APP: Error initializing main audio player: $e");
  }
}

Future<void> _playAlarmSoundInMain() async {
  if (!_mainAudioPlayerInitialized) await _initializeMainAudioPlayer();
  if (_mainAlarmSoundPlaying && _mainAudioPlayer.state == PlayerState.playing) {
    print("MAIN_APP: Main alarm sound already playing.");
    return;
  }
  try {
    await _mainAudioPlayer.play(AssetSource('sounds/alarm.mp3'));
    print("MAIN_APP: Main alarm sound play command issued.");
  } catch (e) {
    _mainAlarmSoundPlaying = false;
    print("MAIN_APP: Error playing main alarm sound: $e");
  }
}

Future<void> _stopAlarmSoundInMain() async {
  if (!_mainAudioPlayerInitialized) {
    print("MAIN_APP: Stop alarm called, but player not initialized.");
    _mainAlarmSoundPlaying = false; // Ensure flag is correct
    return;
  }
  if (_mainAudioPlayer.state == PlayerState.playing ||
      _mainAudioPlayer.state == PlayerState.paused) {
    try {
      await _mainAudioPlayer.stop();
      print("MAIN_APP: Main alarm sound stop command issued.");
    } catch (e) {
      print("MAIN_APP: Error stopping main alarm sound: $e");
    }
  } else {
    print(
        "MAIN_APP: Stop main alarm called, but not playing/paused. State: ${_mainAudioPlayer
            .state}");
  }
  _mainAlarmSoundPlaying = false; // Update after attempt to stop
}

Future<void> _showOrUpdateInteractiveFallNotification(
    {bool isInitialShow = false}) async {
  if (currentNotificationCountdownSeconds < 0 &&
      (_notificationCountdownTimer?.isActive ?? false)) {
    _notificationCountdownTimer?.cancel();
    _swipeDetectionTimer?.cancel();
    if (isCurrentlyHandlingFall) {
      await _handleInteractiveFallAction(
          INTERACTIVE_FALL_ACTION_CALL_EMERGENCY);
    }
    return;
  }

  final List<AndroidNotificationAction> actions = [
    AndroidNotificationAction(
      INTERACTIVE_FALL_ACTION_IM_OK, "I'm OK",
      showsUserInterface: false, cancelNotification: true,
      titleColor: AppTheme.accentColor, // Attempt to color "I'm OK"
    ),
    AndroidNotificationAction(
      INTERACTIVE_FALL_ACTION_CALL_EMERGENCY, "Call Emergency",
      showsUserInterface: false, cancelNotification: true,
      icon: const DrawableResourceAndroidBitmap('ic_emergency_call_icon'),
      titleColor: AppTheme.errorColor, // Attempt to color "Call Emergency"
    ),
  ];

  final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
    fallNotificationChannelId, 'Fall Alerts',
    channelDescription: 'Critical fall alert. Attempts Full-Screen display.',
    importance: Importance.max,
    priority: Priority.high,
    showWhen: true,
    playSound: false,
    enableVibration: true,
    fullScreenIntent: true,
    category: AndroidNotificationCategory.alarm,
    ongoing: true,
    autoCancel: false,
    actions: actions,
    showProgress: true,
    maxProgress: DEFAULT_FALL_COUNTDOWN_SECONDS,
    progress: currentNotificationCountdownSeconds,
    // Correct for depletion
    // invertProgress: true, // This was incorrect, remove
    color: AppTheme.errorColor,
    // Sets accent color, may colorize background on some Android versions if `colorized` is true
    colorized: true,
    // Attempt to use `color` for notification background
    ticker: '!!! FALL DETECTED !!!',
    styleInformation: BigTextStyleInformation(
      "!!! FALL DETECTED !!!", htmlFormatBigText: true,
      contentTitle: "Action required within <b>$currentNotificationCountdownSeconds seconds</b>",
      htmlFormatContentTitle: true,
      summaryText: "Tap body to open app, or use action buttons.",
      htmlFormatSummaryText: true,
    ),
  );

  await flutterLocalNotificationsPlugin.show(
    INTERACTIVE_FALL_NOTIFICATION_ID,
    "!!! FALL DETECTED !!!",
    "Smart Cane: Action required in $currentNotificationCountdownSeconds seconds.",
    NotificationDetails(android: androidDetails),
    payload: INTERACTIVE_FALL_NOTIFICATION_PAYLOAD,
  );

  if (isInitialShow) _startSwipeDetectionTimer();
}

void _startInteractiveNotificationCountdown() {
  if (!isCurrentlyHandlingFall) { // If a cleanup just happened
    print(
        "MAIN_APP: Start interactive countdown SKIPPED as fall is no longer active.");
    return;
  }
  print(
      "MAIN_APP: Starting INTERACTIVE notification countdown (FSI attempt). Global lock ON.");

  currentNotificationCountdownSeconds = DEFAULT_FALL_COUNTDOWN_SECONDS;

  WakelockPlus.enable().catchError((e) =>
      print("MAIN_APP: Wakelock enable error: $e"));
  _playAlarmSoundInMain(); // Unified audio start

  _notificationCountdownTimer?.cancel();
  _showOrUpdateInteractiveFallNotification(isInitialShow: true);

  _notificationCountdownTimer =
      Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!isCurrentlyHandlingFall) {
          timer.cancel();
          _swipeDetectionTimer?.cancel();
          _cleanupInteractiveFallNotificationController(
              calledFromWithinTimer: true,
              reason: "Fall no longer active in countdown");
          return;
        }
        currentNotificationCountdownSeconds--;
        if (currentNotificationCountdownSeconds < 0) {
          timer.cancel();
          _swipeDetectionTimer?.cancel();
          if (isCurrentlyHandlingFall) {
            print(
                "MAIN_APP: Interactive Countdown ended by timer. Triggering emergency.");
            _handleInteractiveFallAction(
                INTERACTIVE_FALL_ACTION_CALL_EMERGENCY);
          } else {
            _cleanupInteractiveFallNotificationController(
                calledFromWithinTimer: true,
                reason: "Countdown <0, but fall not active");
          }
        } else {
          _showOrUpdateInteractiveFallNotification();
        }
      });
}

void _startSwipeDetectionTimer() {
  _swipeDetectionTimer?.cancel();
  _swipeDetectionTimer =
      Timer(Duration(seconds: DEFAULT_FALL_COUNTDOWN_SECONDS - 2), () async {
        if (!isCurrentlyHandlingFall ||
            !(_notificationCountdownTimer?.isActive ?? false)) return;

        final List<
            ActiveNotification> activeNotifications = await flutterLocalNotificationsPlugin
            .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
            ?.getActiveNotifications() ?? [];
        bool notificationStillPresent = activeNotifications.any((notif) =>
        notif.id == INTERACTIVE_FALL_NOTIFICATION_ID);

        if (!notificationStillPresent && isCurrentlyHandlingFall) {
          print("MAIN_APP: Swipe inferred by timer. Treating as I'M OK.");
          await _handleInteractiveFallAction(
              INTERACTIVE_FALL_ACTION_IM_OK_FROM_SWIPE);
        }
      });
}

Future<void> _handleInteractiveFallAction(String actionOrPayload) async {
  print(
      "MAIN_APP: Handling interactive action: $actionOrPayload. Initial Fall active state: $isCurrentlyHandlingFall");

  // If an action button was pressed, and the notification was presumably shown due to a fall,
  // we should ensure isCurrentlyHandlingFall is true for the duration of this handler.
  // This is to make sure the action is processed correctly even if there was a slight
  // timing issue or state discrepancy with the global flag.
  bool wasFallActiveInitially = isCurrentlyHandlingFall; // Capture state

  if (actionOrPayload == INTERACTIVE_FALL_ACTION_IM_OK ||
      actionOrPayload == INTERACTIVE_FALL_ACTION_CALL_EMERGENCY ||
      actionOrPayload == INTERACTIVE_FALL_ACTION_IM_OK_FROM_SWIPE) {
    if (!isCurrentlyHandlingFall) {
      print(
          "MAIN_APP: Action button '$actionOrPayload' tapped, but global fall flag was OFF. Temporarily setting ON for action processing.");
      isCurrentlyHandlingFall =
      true; // Assume active if an action button is pressed
    }
  }

  // Stop countdown timers immediately as an action is being processed.
  _notificationCountdownTimer?.cancel();
  _notificationCountdownTimer = null;
  _swipeDetectionTimer?.cancel();
  _swipeDetectionTimer = null;

  final prefs = await SharedPreferences.getInstance();
  final bleService = BleService();

  switch (actionOrPayload) {
    case INTERACTIVE_FALL_ACTION_IM_OK:
    case INTERACTIVE_FALL_ACTION_IM_OK_FROM_SWIPE:
      print("MAIN_APP: Interactive Fall - I'M OK.");
      // Sound stopped by cleanup.
      bleService.resetFallDetectedState();
      FlutterBackgroundService().invoke(resetFallHandlingEvent);
      await prefs.remove('fall_pending_alert');
      _cleanupInteractiveFallNotificationController(
          reason: "I'M OK action/swipe"); // This will set isCurrentlyHandlingFall = false
      break;

  // In lib/main.dart -> _handleInteractiveFallAction
    case INTERACTIVE_FALL_ACTION_CALL_EMERGENCY:
      print("MAIN_APP: Interactive Fall - CALL EMERGENCY action received.");
      // Instead of calling directly:
      // bleService.makePhoneCall('+19058028483');

      // Option 1: Bring app to foreground to make the call
      // This requires native code to launch the app's MainActivity with specific extras.
      // For now, let's log that this path is taken. The actual implementation
      // of bringing app to foreground and then calling is more involved.
      print(
          "MAIN_APP: TODO - Implement bringing app to foreground then making call.");
      // For now, to ensure cleanup happens and avoid repeated notifications:
      await prefs.setString('pending_action',
          'call_emergency'); // Signal to app when it launches/resumes

      // Attempt to launch the app - this uses the flutter_local_notifications' ability
      // to launch the app when a notification is tapped. We're mimicking a body tap's effect
      // to bring the app forward.
      // The MainActivity will then need to check for 'pending_action'.
      // This is a simplified approach; a dedicated PendingIntent in the action is better.

      // For now, we will proceed with the cleanup and let the app handle the call when it comes to foreground.
      // The actual call will need to be triggered from a foreground context (e.g., HomeScreen initState or didChangeAppLifecycleState).

      bleService.resetFallDetectedState();
      FlutterBackgroundService().invoke(resetFallHandlingEvent);
      await prefs.remove('fall_pending_alert');
      _cleanupInteractiveFallNotificationController(
          reason: "Call Emergency action initiated");
      break;

    case INTERACTIVE_FALL_NOTIFICATION_PAYLOAD:
      print(
          "MAIN_APP: Interactive Fall - Body tapped. Opening app overlay. Sound should continue.");
      if (!wasFallActiveInitially &&
          !isCurrentlyHandlingFall) { // If was off, and still is (no action button forced it on)
        isCurrentlyHandlingFall =
        true; // Body tap implies we are now handling it
        print("MAIN_APP: Fall handling activated by body tap.");
      }
      await flutterLocalNotificationsPlugin.cancel(
          INTERACTIVE_FALL_NOTIFICATION_ID); // Cancel current notification, overlay will take over
      _navigateToHomeWithFall(
          from: "Interactive Notification Tap",
          resumeCountdownSeconds: currentNotificationCountdownSeconds);
      // Lock `isCurrentlyHandlingFall` remains true. Cleanup handled by overlay confirmation.
      break;
    default:
      print("MAIN_APP: Unknown interactive fall action: $actionOrPayload");
      if (isCurrentlyHandlingFall) { // Only cleanup if we thought we were handling something
        _cleanupInteractiveFallNotificationController(reason: "Unknown action");
      }
  }
}

void _cleanupInteractiveFallNotificationController(
    {bool calledFromOverlay = false, bool calledFromWithinTimer = false, required String reason}) {
  print(
      "MAIN_APP: Cleanup. Reason: $reason. Initial FallActive: $isCurrentlyHandlingFall");

  if (!isCurrentlyHandlingFall &&
      !calledFromOverlay) { // If already false and not from overlay (which expects it to be true)
    print(
        "MAIN_APP: Cleanup ($reason), but global lock was already OFF and not an overlay confirmation. May be a redundant cleanup.");
    // Still cancel timers and notification as a safety measure
  } else {
    isCurrentlyHandlingFall = false; // Set to false FIRST
    print("MAIN_APP: Global fall handling lock RELEASED by cleanup ($reason).");
  }

  _notificationCountdownTimer?.cancel();
  _notificationCountdownTimer = null;
  _swipeDetectionTimer?.cancel();
  _swipeDetectionTimer = null;

  currentNotificationCountdownSeconds = DEFAULT_FALL_COUNTDOWN_SECONDS;

  if (isCurrentlyHandlingFall) {
    isCurrentlyHandlingFall = false;
    print("MAIN_APP: Global fall handling lock RELEASED by cleanup ($reason).");
  } else {
    print("MAIN_APP: Cleanup ($reason), but global lock was already OFF.");
  }

  flutterLocalNotificationsPlugin.cancel(INTERACTIVE_FALL_NOTIFICATION_ID);
  _stopAlarmSoundInMain(); // Unified audio stop
  WakelockPlus.disable().catchError((e) =>
      print("MAIN_APP: Wakelock disable error: $e"));
}

void confirmFallHandledByOverlay() {
  print("MAIN_APP: Fall handled by overlay. Cleaning up controller state.");
  _cleanupInteractiveFallNotificationController(
      calledFromOverlay: true, reason: "Overlay confirmed handling");
}

Future<void> initializeAppServices() async {
  final service = FlutterBackgroundService();
  // ... (Permission requests remain the same)
  var notificationStatus = await Permission.notification.status;
  if (notificationStatus.isDenied) await Permission.notification.request();

  const AndroidNotificationChannel fallChannel = AndroidNotificationChannel(
    fallNotificationChannelId, 'Fall Alerts',
    description: 'Critical fall alerts with interactive options. Attempts Full-Screen display.',
    importance: Importance.max, playSound: true, enableVibration: true,
  );
  const AndroidNotificationChannel serviceChannel = AndroidNotificationChannel(
    notificationChannelId, notificationChannelName,
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
      foregroundServiceNotificationId: bg_notificationId,
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );

  service.on(triggerFallAlertUIEvent).listen((event) async {
    if (isCurrentlyHandlingFall) {
      print(
          "MAIN_APP: '$triggerFallAlertUIEvent' received, but fall ALREADY being handled. Ignoring.");
      return;
    }
    isCurrentlyHandlingFall = true;
    print("MAIN_APP: '$triggerFallAlertUIEvent' received. Global lock SET.");

    final AppLifecycleState lifecycleState = WidgetsBinding.instance
        .lifecycleState ?? AppLifecycleState.detached;
    print("MAIN_APP: Fall trigger. Lifecycle: $lifecycleState");

    _playAlarmSoundInMain(); // Start sound REGARDLESS of FG/BG, it will carry through or be stopped.

    if (lifecycleState == AppLifecycleState.resumed) {
      print(
          "MAIN_APP: App is FOREGROUND. Navigating to full overlay directly.");
      _navigateToHomeWithFall(
          from: "Foreground Fall Event",
          resumeCountdownSeconds: DEFAULT_FALL_COUNTDOWN_SECONDS);
    } else {
      print(
          "MAIN_APP: App NOT resumed (state: $lifecycleState). Starting INTERACTIVE notification (FSI attempt).");
      _startInteractiveNotificationCountdown();
    }
  });

  service.on(backgroundServiceConnectionUpdateEvent).listen((event) {
    /* ... same ... */
  });
  print("MAIN_APP: Background Service Configured.");
}

Future<bool> _isUserSignedIn() async {
  /* ... same ... */ return await GoogleSignIn().isSignedIn();
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await _initializeMainAudioPlayer();

  const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings(
      '@mipmap/ic_launcher');
  const DarwinInitializationSettings initializationSettingsIOS = DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: true,
  );
  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid, iOS: initializationSettingsIOS,
  );

  // ... (prefs and notificationAppLaunchDetails logic remains same) ...
  final prefs = await SharedPreferences.getInstance();
  bool launchedDueToPendingFall = prefs.getBool(
      'resume_fall_overlay_on_launch') ?? false;
  String? launchFrom = prefs.getString('resume_fall_from');
  int resumeSeconds = prefs.getInt('resume_countdown_seconds') ??
      DEFAULT_FALL_COUNTDOWN_SECONDS;

  if (launchedDueToPendingFall) {
    print(
        "MAIN: App launched with pending fall flag from: $launchFrom. Resume secs: $resumeSeconds");
    await prefs.remove('resume_fall_overlay_on_launch');
    await prefs.remove('resume_fall_from');
    await prefs.remove('resume_countdown_seconds');
  }

  final NotificationAppLaunchDetails? notificationAppLaunchDetails =
  await flutterLocalNotificationsPlugin.getNotificationAppLaunchDetails();

  if (notificationAppLaunchDetails?.didNotificationLaunchApp ?? false) {
    final response = notificationAppLaunchDetails!.notificationResponse;
    if (response != null) {
      print("MAIN: App launched by notification tap. Payload: ${response
          .payload}, Action: ${response.actionId}");
      if (response.payload == INTERACTIVE_FALL_NOTIFICATION_PAYLOAD &&
          response.actionId == null) {
        launchedDueToPendingFall = true;
        launchFrom = "Interactive Notification Tap (App Launch)";
      }
    }
  }

  await flutterLocalNotificationsPlugin.initialize(
    initializationSettings,
    onDidReceiveNotificationResponse: _onDidReceiveNotificationResponse,
    onDidReceiveBackgroundNotificationResponse: onDidReceiveBackgroundNotificationResponse,
  );

  await initializeAppServices();
  bool signedIn = await _isUserSignedIn();
  String determinedInitialRoute = signedIn ? '/home' : '/login';
  if (launchedDueToPendingFall) determinedInitialRoute = '/home_fall_launch';

  runApp(MyApp(
    initialRoute: determinedInitialRoute,
    launchedFromFallSystemFlag: launchedDueToPendingFall,
    resumeCountdownSecondsOnLaunch: resumeSeconds,
    launchFromReason: launchFrom,
  ));
}

class MyApp extends StatefulWidget {
  /* ... same ... */
  final String initialRoute;
  final bool launchedFromFallSystemFlag;
  final int resumeCountdownSecondsOnLaunch;
  final String? launchFromReason;

  const MyApp({
    super.key,
    required this.initialRoute,
    required this.launchedFromFallSystemFlag,
    required this.resumeCountdownSecondsOnLaunch,
    this.launchFromReason,
  });

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  StreamSubscription<bool>? _fallAlertStreamSubscriptionMainApp;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _fallAlertStreamSubscriptionMainApp =
        onFallAlertTriggered.listen((isFallSignal) {
          if (isFallSignal && mounted) {
            print(
                "MyApp: onFallAlertTriggered stream ($isFallSignal). Current fall handling: $isCurrentlyHandlingFall");
            if (isCurrentlyHandlingFall) {
              _navigateToHomeWithFall(
                  from: "Stream in MyApp (ensuring fall screen)",
                  resumeCountdownSeconds: currentNotificationCountdownSeconds);
            }
      }
    });

    if (widget.initialRoute == '/home_fall_launch') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          print(
              "MyApp initState: Initial route /home_fall_launch. Navigating. Reason: ${widget
                  .launchFromReason}, Secs: ${widget
                  .resumeCountdownSecondsOnLaunch}");
          _navigateToHomeWithFall(
              from: widget.launchFromReason ?? "Launch via /home_fall_launch",
              resumeCountdownSeconds: widget.resumeCountdownSecondsOnLaunch);
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    print("MyApp Lifecycle: $state. Fall active: $isCurrentlyHandlingFall");
    if (state == AppLifecycleState.resumed) {
      if (isCurrentlyHandlingFall &&
          (_notificationCountdownTimer?.isActive ?? false)) {
        flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
            ?.getActiveNotifications().then((activeNotifications) {
          bool notificationStillPresent = activeNotifications.any((
              notif) => notif.id == INTERACTIVE_FALL_NOTIFICATION_ID);
          if (!notificationStillPresent && isCurrentlyHandlingFall) {
            print(
                "MyApp resumed: Interactive notification GONE, fall was active. Treating as SWIPE/DISMISS.");
            _handleInteractiveFallAction(
                INTERACTIVE_FALL_ACTION_IM_OK_FROM_SWIPE);
          }
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _fallAlertStreamSubscriptionMainApp?.cancel();
    _mainAudioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    /* ... same MaterialApp structure ... */
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
          bool isFallLaunchArgument = args?['fallDetected'] ?? false;
          int resumeSeconds = args?['resumeCountdownSeconds'] as int? ??
              (isFallLaunchArgument
                  ? widget.resumeCountdownSecondsOnLaunch
                  : DEFAULT_FALL_COUNTDOWN_SECONDS);
          bool effectiveFallLaunch = widget.launchedFromFallSystemFlag ||
              isFallLaunchArgument;
          print(
              "MyApp routing to /home: effectiveFallLaunch=$effectiveFallLaunch, resumeSecs=$resumeSeconds.");
          return HomeScreen(
            launchedFromFall: effectiveFallLaunch,
            resumeCountdownSeconds: resumeSeconds,
          );
        },
        '/home_fall_launch': (context) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _navigateToHomeWithFall(
                  from: widget.launchFromReason ??
                      "Launch from /home_fall_launch",
                  resumeCountdownSeconds: widget
                      .resumeCountdownSecondsOnLaunch);
            }
          });
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        },
      },
      debugShowCheckedModeBanner: false,
    );
  }
}