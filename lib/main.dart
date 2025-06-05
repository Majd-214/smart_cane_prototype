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

// String? contactNumber = await getEmergencyContactNumberFromPrefs(); // You'd need to implement this

Timer? _notificationCountdownTimer;
int currentNotificationCountdownSeconds = DEFAULT_FALL_COUNTDOWN_SECONDS;
const String INTERACTIVE_FALL_NOTIFICATION_PAYLOAD =
    'INTERACTIVE_FALL_DETECTED_PAYLOAD';
const int INTERACTIVE_FALL_NOTIFICATION_ID = 1001; // Ensure unique ID

const int DEFAULT_FALL_COUNTDOWN_SECONDS = 30;

// Near other global variables like isCurrentlyHandlingFall
bool emergencyCallInitiatedByNotificationTimeout = false;

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

  // Set or confirm fall lock
  if (!isCurrentlyHandlingFall) {
    isCurrentlyHandlingFall = true;
    print(
        "MAIN_APP: Navigating for fall from '$from'. Lock was OFF, now SET. Effective Resume: ${resumeCountdownSeconds ??
            currentNotificationCountdownSeconds}");
  } else {
    print(
        "MAIN_APP: Navigating for fall from '$from'. Lock already ON. Effective Resume: ${resumeCountdownSeconds ??
            currentNotificationCountdownSeconds}");
  }

  // **MODIFICATION START**
  // If we are navigating to show the full overlay,
  // ensure any active notification countdown is stopped and notification cleared.
  // This is because the overlay will now be the primary interface.
  _notificationCountdownTimer?.cancel();
  _notificationCountdownTimer = null;
  flutterLocalNotificationsPlugin.cancel(INTERACTIVE_FALL_NOTIFICATION_ID);
  // Sound and Wakelock should continue as the overlay is now active or will be.
  // The overlay's own cleanup logic (via confirmFallHandledByOverlay) will handle these later.
  // **MODIFICATION END**

  if (navigatorKey.currentState != null) {
    print(
        "MAIN_APP: navigatorKey IS available. Attempting navigation for '$from'.");
    navigatorKey.currentState?.pushNamedAndRemoveUntil(
      '/home', (route) => false,
      arguments: {
        'fallDetected': true,
        'from': from,
        // Pass the centrally managed countdown value if available and valid, otherwise default or the provided one.
        'resumeCountdownSeconds': (resumeCountdownSeconds != null &&
            resumeCountdownSeconds >= 0)
            ? resumeCountdownSeconds
            : (currentNotificationCountdownSeconds >= 0 &&
            currentNotificationCountdownSeconds <=
                DEFAULT_FALL_COUNTDOWN_SECONDS)
            ? currentNotificationCountdownSeconds
            : DEFAULT_FALL_COUNTDOWN_SECONDS,
      },
    );
  } else {
    print(
        "MAIN_APP: navigatorKey IS NULL for '$from'. Setting prefs for launch.");
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('resume_fall_overlay_on_launch', true);
      // Use the centrally managed countdown value or the provided one for prefs
      prefs.setInt('resume_countdown_seconds',
          (resumeCountdownSeconds != null && resumeCountdownSeconds >= 0)
              ? resumeCountdownSeconds
              : (currentNotificationCountdownSeconds >= 0 &&
              currentNotificationCountdownSeconds <=
                  DEFAULT_FALL_COUNTDOWN_SECONDS)
              ? currentNotificationCountdownSeconds
              : DEFAULT_FALL_COUNTDOWN_SECONDS);
      prefs.setString('resume_fall_from', from);
    });
  }
}

Future<void> _initializeMainAudioPlayer() async {
  if (_mainAudioPlayerInitialized) return;
  try {
    await _mainAudioPlayer.setAudioContext(AudioContext(
      android: AudioContextAndroid(
        isSpeakerphoneOn: true,
        // This is for the *alarm* player, not the call. Might be confusing.
        // Consider if true is needed here or if it should be false.
        stayAwake: true,
        contentType: AndroidContentType.sonification,
        usageType: AndroidUsageType.alarm,
        audioFocus: AndroidAudioFocus
            .gainTransientExclusive, // Correct for an alarm
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
    if (isCurrentlyHandlingFall) {
      await _handleInteractiveFallAction("CALL_EMERGENCY_INTERNAL_TIMEOUT");
    }
    return;
  }

  // Main notification text (visible when compact and as title for expanded)
  String mainTitle = "FALL DETECTED!";
  // Body will be primarily for the expanded style via BigTextStyleInformation
  // For compact view, we can try to fit more here, but it's limited.
  String mainBody = "TAP TO RESPOND! EMS in ${currentNotificationCountdownSeconds}s";

  final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
    fallNotificationChannelId,
    'Fall Alerts',
    channelDescription: 'Critical fall alerts. Tap to respond or EMS will be called.',
    importance: Importance.max,
    priority: Priority.high,
    showWhen: true,
    playSound: false,
    enableVibration: true,
    fullScreenIntent: true,
    category: AndroidNotificationCategory.alarm,
    ongoing: true,
    autoCancel: false,

    color: AppTheme.errorColor,
    colorized: true,
    // Makes background errorColor

    // Small icon appears on the right (often status bar area, monochrome)
    // This is standard. If you meant a large content icon on the right, that's not standard.
    icon: 'ic_siren_drawable',
    // Ensure this (without extension) matches your drawable file name
    // This is the small icon.

    largeIcon: const DrawableResourceAndroidBitmap('ic_falling_icon'),
    // Large icon on the left.

    showProgress: true,
    maxProgress: DEFAULT_FALL_COUNTDOWN_SECONDS,
    // MODIFIED LINE FOR COUNTDOWN (BAR EMPTIES)
    progress: currentNotificationCountdownSeconds.clamp(
      0,
      DEFAULT_FALL_COUNTDOWN_SECONDS,
    ),
    indeterminate: false,
    // Make sure it's a determinate progress bar

    ticker: 'FALL DETECTED! - ACTION REQUIRED',

    // We'll use BigTextStyle and try to make it look like separate lines of large text.
    // Android's rendering of HTML in notifications is limited.
    styleInformation: BigTextStyleInformation(
      // The main body of the BigTextStyle.
      // We will format this with HTML to try and achieve the desired look.
      '<b>TAP TO RESPOND!</b><br>EMS Call In: <b>${currentNotificationCountdownSeconds}s</b>',
      htmlFormatBigText: true,
      // Enable HTML parsing for bigText
      // contentTitle will be shown above the bigText.
      contentTitle: '<b>FALL DETECTED!</b>',
      // This will be the first line
      htmlFormatContentTitle: true,
      // summaryText is often shown below or for grouped notifications, keep it concise.
      // summaryText: 'Tap alert to open app.',
      // // Simpler summary
      // htmlFormatSummaryText: false,
    ),
  );

  await flutterLocalNotificationsPlugin.show(
    INTERACTIVE_FALL_NOTIFICATION_ID,
    mainTitle, // This is the title shown when notification is compact/in shade.
    mainBody, // This is body shown when notification is compact/in shade.
    NotificationDetails(android: androidDetails),
    payload: INTERACTIVE_FALL_NOTIFICATION_PAYLOAD,
  );
}

void _startInteractiveNotificationCountdown() {
  if (!isCurrentlyHandlingFall) {
    print(
        "MAIN_APP: Start interactive countdown SKIPPED as fall is no longer active.");
    return;
  }

  // If this function is called, it means the notification is the intended primary alert view.
  // We reset the global countdown to the default for this notification sequence.
  // If an overlay was previously active, its state would have been handled by its own lifecycle
  // and cleanup (confirmFallHandledByOverlay).
  currentNotificationCountdownSeconds = DEFAULT_FALL_COUNTDOWN_SECONDS;
  print(
      "MAIN_APP: Starting INTERACTIVE notification countdown. Global lock ON. Countdown reset to default for notification.");


  WakelockPlus.enable().catchError((e) =>
      print("MAIN_APP: Wakelock enable error: $e"));
  _playAlarmSoundInMain(); // Ensure sound is playing

  _notificationCountdownTimer
      ?.cancel(); // Cancel any existing timer before starting a new one
  _showOrUpdateInteractiveFallNotification(
      isInitialShow: true);

  _notificationCountdownTimer =
      Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!isCurrentlyHandlingFall) {
          // This condition means the fall was resolved (e.g., user tapped "I'm OK" on an overlay
          // that might have been brought up, or another cleanup occurred).
          timer.cancel();
          _cleanupInteractiveFallNotificationController(
              calledFromWithinTimer: true,
              reason: "Fall no longer active in notification countdown");
          return;
        }
        currentNotificationCountdownSeconds--;
        if (currentNotificationCountdownSeconds < 0) {
          timer.cancel();
          // Check isCurrentlyHandlingFall again, as it might change during the last second.
          if (isCurrentlyHandlingFall) {
            print(
                "MAIN_APP: Interactive Countdown ended by timer. Triggering emergency.");
            _handleInteractiveFallAction("CALL_EMERGENCY_INTERNAL_TIMEOUT");
          } else {
            _cleanupInteractiveFallNotificationController(
                calledFromWithinTimer: true,
                reason: "Notification countdown <0, but fall became inactive");
          }
        } else {
          _showOrUpdateInteractiveFallNotification(); // Update notification content
        }
      });
}

Future<void> _handleInteractiveFallAction(String actionOrPayload) async {
  print(
      "MAIN_APP: Handling interactive action: $actionOrPayload. Initial Fall active state: $isCurrentlyHandlingFall");

  if (!isCurrentlyHandlingFall &&
      (actionOrPayload == INTERACTIVE_FALL_NOTIFICATION_PAYLOAD ||
          actionOrPayload == "CALL_EMERGENCY_INTERNAL_TIMEOUT")) {
    isCurrentlyHandlingFall = true;
    print(
        "MAIN_APP: Fall handling (re)activated by interactive action: $actionOrPayload");
  } else if (!isCurrentlyHandlingFall) {
    print(
        "MAIN_APP: Action '$actionOrPayload' received, but fall not active. Cleaning up and ignoring.");
    _cleanupInteractiveFallNotificationController(
        reason: "Fall not active for action: $actionOrPayload");
    return;
  }

  final bleService = BleService();

  switch (actionOrPayload) {
    case "CALL_EMERGENCY_INTERNAL_TIMEOUT":
      print("MAIN_APP: Interactive Fall - CALL EMERGENCY (Timeout).");
      _notificationCountdownTimer?.cancel();
      _notificationCountdownTimer = null;
      // Don't cancel the notification immediately; let the user see it if the call takes time to initiate.
      // It will be cleaned up by _cleanupInteractiveFallNotificationController eventually.

      if (!emergencyCallInitiatedByNotificationTimeout) {
        print(
            "MAIN_APP: Directly initiating emergency call due to notification timeout.");
        emergencyCallInitiatedByNotificationTimeout = true; // Set flag
        bleService.makePhoneCall(
            '+19058028483', emergencyContactNumber: '+19058028483');
        // TODO: Use a configurable number
      } else {
        print(
            "MAIN_APP: Emergency call already flagged as initiated by notification timeout, not calling again from here.");
      }

      // Still navigate to home to show the state (e.g., "Calling emergency...")
      _navigateToHomeWithFall(
          from: "Interactive Notification Timeout - Call Initiated",
          resumeCountdownSeconds: 0
      );
      break;

    case INTERACTIVE_FALL_NOTIFICATION_PAYLOAD: // Notification body tap
      print(
          "MAIN_APP: Interactive Fall - Body tapped. Opening app overlay. Sound should continue.");
      _notificationCountdownTimer?.cancel();
      _notificationCountdownTimer = null;
      // Cancel the notification because the full overlay will take over.
      await flutterLocalNotificationsPlugin.cancel(
          INTERACTIVE_FALL_NOTIFICATION_ID);

      _navigateToHomeWithFall(
          from: "Interactive Notification Tap",
          resumeCountdownSeconds: currentNotificationCountdownSeconds);
      break;

    default:
      print(
          "MAIN_APP: Unknown or unhandled interactive fall action: $actionOrPayload");
      _cleanupInteractiveFallNotificationController(
          reason: "Unknown or unhandled action: $actionOrPayload");
  }
}

void _cleanupInteractiveFallNotificationController(
    {bool calledFromOverlay = false,
      bool calledFromWithinTimer = false,
      required String reason}) {
  print(
      "MAIN_APP: Cleanup. Reason: $reason. Initial FallActive: $isCurrentlyHandlingFall. CallInitiatedFlag: $emergencyCallInitiatedByNotificationTimeout");

  if (!isCurrentlyHandlingFall && !calledFromOverlay) {
    print(
        "MAIN_APP: Cleanup ($reason), but global lock was already OFF and not an overlay confirmation. May be a redundant cleanup.");
  } else {
    isCurrentlyHandlingFall = false;
    print(
        "MAIN_APP: Global fall handling lock RELEASED by cleanup ($reason).");
  }

  _notificationCountdownTimer?.cancel();
  _notificationCountdownTimer = null;

  currentNotificationCountdownSeconds = DEFAULT_FALL_COUNTDOWN_SECONDS;

  flutterLocalNotificationsPlugin.cancel(INTERACTIVE_FALL_NOTIFICATION_ID);
  _stopAlarmSoundInMain();
  WakelockPlus.disable()
      .catchError((e) => print("MAIN_APP: Wakelock disable error: $e"));

  emergencyCallInitiatedByNotificationTimeout = false; // **ADD THIS RESET**
  print(
      "MAIN_APP: Cleanup also reset _emergencyCallInitiatedByNotificationTimeout.");
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
    if (event != null &&
        backgroundConnectionUpdateStreamController.hasListener &&
        !backgroundConnectionUpdateStreamController.isClosed) {
      backgroundConnectionUpdateStreamController.add(
          event as Map<String, dynamic>);
    }
  });
  print("MAIN_APP: Background Service Configured.");
}

Future<bool> _isUserSignedIn() async {
  return await GoogleSignIn().isSignedIn();
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await _initializeMainAudioPlayer();

  const AndroidInitializationSettings initializationSettingsAndroid =
  AndroidInitializationSettings('@mipmap/ic_launcher');
  const DarwinInitializationSettings initializationSettingsIOS =
  DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: true,
  );
  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
    iOS: initializationSettingsIOS,
  );

  final prefs = await SharedPreferences.getInstance();
  bool launchedDueToPendingFall =
      prefs.getBool('resume_fall_overlay_on_launch') ?? false;
  String? launchFrom = prefs.getString('resume_fall_from');
  int resumeSeconds =
      prefs.getInt('resume_countdown_seconds') ??
          DEFAULT_FALL_COUNTDOWN_SECONDS;

  if (launchedDueToPendingFall) {
    print(
        "MAIN: App launched with SharedPreferences pending fall flag from: $launchFrom. Resume secs: $resumeSeconds");
    // Clear them once read
    await prefs.remove('resume_fall_overlay_on_launch');
    await prefs.remove('resume_fall_from');
    await prefs.remove('resume_countdown_seconds');
  }

  final NotificationAppLaunchDetails? notificationAppLaunchDetails =
  await flutterLocalNotificationsPlugin.getNotificationAppLaunchDetails();

  bool appLaunchedFromInteractiveFallNotification = false;

  if (notificationAppLaunchDetails?.didNotificationLaunchApp ?? false) {
    final response = notificationAppLaunchDetails!.notificationResponse;
    if (response != null) {
      print(
          "MAIN: App launched by notification tap. Payload: ${response
              .payload}, Action: ${response.actionId}, Input: ${response
              .input}");
      if (response.payload == INTERACTIVE_FALL_NOTIFICATION_PAYLOAD &&
          response.actionId == null) {
        appLaunchedFromInteractiveFallNotification = true;
        launchFrom =
            launchFrom ??
                "Interactive Notification Tap (App Launch)"; // Prioritize existing launchFrom if any
        if (!isCurrentlyHandlingFall) {
          isCurrentlyHandlingFall = true;
          print(
              "MAIN: Fall handling lock SET due to app launch from notification tap.");
        }
        // If launched from notification, use default countdown, or what was last known for notifications
        // For simplicity now, let's ensure currentNotificationCountdownSeconds reflects this state.
        currentNotificationCountdownSeconds = DEFAULT_FALL_COUNTDOWN_SECONDS;
        resumeSeconds = currentNotificationCountdownSeconds;
      }
    }
  }

  await flutterLocalNotificationsPlugin.initialize(
    initializationSettings,
    onDidReceiveNotificationResponse:
        (NotificationResponse notificationResponse) async {
      print(
          "MAIN: Notification tapped while app running (onDidReceiveNotificationResponse). Payload: ${notificationResponse
              .payload}, Action: ${notificationResponse.actionId}");
      if (notificationResponse.payload ==
          INTERACTIVE_FALL_NOTIFICATION_PAYLOAD &&
          notificationResponse.actionId == null) {
        if (!isCurrentlyHandlingFall) {
          isCurrentlyHandlingFall = true;
          print(
              "MAIN: Fall handling lock SET due to notification tap (app running - onDidReceiveNotificationResponse).");
        }
        _navigateToHomeWithFall(
            from:
            "Interactive Notification Tap (App Running - onDidReceiveNotificationResponse)",
            resumeCountdownSeconds: currentNotificationCountdownSeconds);
      }
    },
  );

  await initializeAppServices();
  bool signedIn = await _isUserSignedIn();

  // Determine initial route based on signed-in state first
  String determinedInitialRoute = signedIn ? '/home' : '/login';

  // **CORRECTED LOGIC START**
  // Now, check if we need to override for a fall-related launch
  // based on flags calculated within main()
  bool shouldLaunchIntoFall = appLaunchedFromInteractiveFallNotification ||
      launchedDueToPendingFall;

  if (shouldLaunchIntoFall) {
    determinedInitialRoute =
    '/home_fall_launch'; // Always use the special fall launch route if these flags are true
    print(
        "MAIN: Overriding initial route for fall. Determined: $determinedInitialRoute, Reason: $launchFrom, ResumeSecs: $resumeSeconds, appLaunchedFromInteractiveFallNotification: $appLaunchedFromInteractiveFallNotification, launchedDueToPendingFall: $launchedDueToPendingFall");
  }
  // **CORRECTED LOGIC END**

  // Prepare arguments for MyApp
  // The 'launchedFromFallSystemFlag' passed to MyApp should reflect the decision made here.
  bool finalLaunchedFromFallSystemFlag = shouldLaunchIntoFall;
  int finalResumeSecondsOnLaunch = resumeSeconds;
  String? finalLaunchFromReason = launchFrom;

  runApp(MyApp(
    initialRoute: determinedInitialRoute,
    launchedFromFallSystemFlag: finalLaunchedFromFallSystemFlag,
    resumeCountdownSecondsOnLaunch: finalResumeSecondsOnLaunch,
    launchFromReason: finalLaunchFromReason,
  ));
}

class MyApp extends StatefulWidget {
  final String initialRoute;
  final bool launchedFromFallSystemFlag; // This seems to cover 'appLaunchedFromInteractiveFallNotification'
  final int resumeCountdownSecondsOnLaunch;
  final String? launchFromReason;

  const MyApp({
    super.key,
    required this.initialRoute,
    required this.launchedFromFallSystemFlag, // Keep this
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

    // This logic seems mostly fine for when the app is explicitly told to launch into a fall state
    if (widget.initialRoute == '/home_fall_launch' ||
        widget.launchedFromFallSystemFlag) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          print(
              "MyApp initState: Initial route is fall-related. Navigating. Reason: ${widget
                  .launchFromReason}, Secs: ${widget
                  .resumeCountdownSecondsOnLaunch}");
          if (!isCurrentlyHandlingFall) {
            // Ensure fall lock is set if we are about to navigate to fall screen
            isCurrentlyHandlingFall = true;
            print(
                "MyApp initState: Fall handling lock SET for /home_fall_launch or launchedFromFallSystemFlag.");
          }
          _navigateToHomeWithFall(
              from: widget.launchFromReason ??
                  "Launch via Fall System Flag or /home_fall_launch",
              resumeCountdownSeconds: widget.resumeCountdownSecondsOnLaunch);
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    print("MyApp Lifecycle: $state. Fall active: $isCurrentlyHandlingFall");
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
    String currentInitialRoute = widget.initialRoute;
    Map<String, dynamic>? homeRouteArgs;

    // If a fall is actively being handled, we MUST ensure /home is launched with correct args.
    if (isCurrentlyHandlingFall) {
      // We want to navigate to HomeScreen and make it show the overlay.
      // The arguments for HomeScreen are crucial.
      currentInitialRoute = '/home'; // Force to home if handling a fall
      homeRouteArgs = {
        'fallDetected': true,
        'from': 'Critical Fall Active',
        // Generic source for this forced navigation
        'resumeCountdownSeconds': (currentNotificationCountdownSeconds > 0 &&
            currentNotificationCountdownSeconds <
                DEFAULT_FALL_COUNTDOWN_SECONDS)
            ? currentNotificationCountdownSeconds
            : DEFAULT_FALL_COUNTDOWN_SECONDS,
      };
      print(
          "MyApp build: Critical fall is active. Forcing /home with args: $homeRouteArgs");
    }

    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Smart Cane Prototype App',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      initialRoute: currentInitialRoute,
      // Use the potentially overridden initial route
      onGenerateRoute: (settings) { // Using onGenerateRoute for more control
        if (settings.name == '/home') {
          Map<String,
              dynamic>? finalArgs = homeRouteArgs; // Args forced if fall is active

          if (finalArgs == null &&
              settings.arguments != null) { // If not forced, use passed args
            finalArgs = settings.arguments as Map<String, dynamic>;
          }
          finalArgs ??= {}; // Ensure finalArgs is not null

          // Determine effectiveFallLaunch and resumeSeconds based on the final arguments
          // and global state, similar to your previous route builder.
          bool isCriticalFallLaunchFromGlobal = isCurrentlyHandlingFall;
          bool argumentIndicatesFall = finalArgs['fallDetected'] ?? false;

          bool effectiveFallLaunch = isCriticalFallLaunchFromGlobal ||
              widget.launchedFromFallSystemFlag || argumentIndicatesFall;

          int resumeSeconds = DEFAULT_FALL_COUNTDOWN_SECONDS;
          int? resumeSecondsFromArgs = finalArgs['resumeCountdownSeconds'] as int?;

          if (effectiveFallLaunch) { // Only adjust countdown if it's a fall launch
            if (isCriticalFallLaunchFromGlobal &&
                currentNotificationCountdownSeconds > 0 &&
                currentNotificationCountdownSeconds <
                    DEFAULT_FALL_COUNTDOWN_SECONDS) {
              resumeSeconds = currentNotificationCountdownSeconds;
            } else if (resumeSecondsFromArgs != null) {
              resumeSeconds = resumeSecondsFromArgs;
            } else if (widget.launchedFromFallSystemFlag) {
              resumeSeconds = widget.resumeCountdownSecondsOnLaunch;
            }
          }

          print(
              "MyApp onGenerateRoute for /home: effectiveFallLaunch=$effectiveFallLaunch, resumeSecs=$resumeSeconds. Final Args: $finalArgs");

          return MaterialPageRoute(
            builder: (context) =>
                HomeScreen(
                  launchedFromFall: effectiveFallLaunch,
                  resumeCountdownSeconds: resumeSeconds,
                ),
            settings: settings, // Pass along the original settings
          );
        }
        if (settings.name == '/login') {
          return MaterialPageRoute(builder: (context) => const LoginScreen());
        }
        // Handle /home_fall_launch if still needed, or remove if this new logic covers it.
        if (settings.name == '/home_fall_launch') {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              // This should now also use the onGenerateRoute logic if it navigates to /home
              _navigateToHomeWithFall(
                  from: widget.launchFromReason ??
                      "Launch from /home_fall_launch",
                  resumeCountdownSeconds: widget
                      .resumeCountdownSecondsOnLaunch);
            }
          });
          return MaterialPageRoute(builder: (context) =>
          const Scaffold(
              body: Center(child: CircularProgressIndicator())));
        }
        // Fallback or unknown route
        if (widget.initialRoute == '/login' && !isCurrentlyHandlingFall)
          return MaterialPageRoute(builder: (context) => const LoginScreen());
        return MaterialPageRoute(builder: (context) =>
            HomeScreen(
              launchedFromFall: false,
              resumeCountdownSeconds: DEFAULT_FALL_COUNTDOWN_SECONDS,));
      },
      // Removed 'routes' map in favor of onGenerateRoute for /home
      debugShowCheckedModeBanner: false,
    );
  }
}