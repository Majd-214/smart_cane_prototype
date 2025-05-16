// lib/widgets/fall_detection_overlay.dart
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // For built-in HapticFeedback if flutter_vibrate fails
import 'package:smart_cane_prototype/utils/app_theme.dart';
import 'package:slide_to_act/slide_to_act.dart';
import 'package:audioplayers/audioplayers.dart';
// import 'package:flutter_vibrate/flutter_vibrate.dart'; // Keep if it works, otherwise use HapticFeedback

class FallDetectionOverlay extends StatefulWidget {
  final VoidCallback onImOk;
  final VoidCallback onCallEmergency;
  final int initialCountdownSeconds;

  const FallDetectionOverlay({
    super.key,
    required this.onImOk,
    required this.onCallEmergency,
    this.initialCountdownSeconds = 30,
  });

  @override
  State<FallDetectionOverlay> createState() => _FallDetectionOverlayState();
}

class _FallDetectionOverlayState extends State<FallDetectionOverlay>
    with TickerProviderStateMixin {
  late Timer _secondUpdaterTimer;
  late int _remainingSeconds;
  bool _isTimerActive = true;

  final GlobalKey<SlideActionState> _slideOkKey = GlobalKey<SlideActionState>();
  final GlobalKey<SlideActionState> _slideEmergencyKey = GlobalKey<SlideActionState>();

  late AnimationController _progressAnimationController;
  late AnimationController _rushProgressAnimationController;
  double _currentAnimationProgress = 1.0;
  double _rushAnimationStartProgress = 1.0;

  late AnimationController _zoomIconAnimationController;
  late Animation<double> _zoomIconScaleAnimation;
  late Animation<double> _zoomIconOpacityAnimation;
  bool _actionSubmitted = false;
  IconData? _submittedIconData;

  late AnimationController _bgColorAnimationController;
  late Animation<Color?> _bgColorAnimation;
  Color _currentBackgroundColor = AppTheme.warningColor;

  late AnimationController _sliderFadeController;
  late Animation<double> _sliderOpacityAnimation;
  bool _hideSliders = false;

  bool _popCircleToFullWhite = false;
  bool _hideCountdownNumber = false;

  // Audio and Haptics
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _canVibrate = true; // Assume true, or check with flutter_vibrate if using it
  bool _alarmSoundPlaying = false;

  // Durations
  final Duration _rushProgressDuration = const Duration(milliseconds: 600);
  final Duration _zoomIconDuration = const Duration(milliseconds: 700);
  final Duration _bgColorChangeDuration = const Duration(milliseconds: 400);
  final Duration _numberFadeDuration = const Duration(milliseconds: 250);
  final Duration _sliderFadeDuration = const Duration(milliseconds: 200);

  @override
  void initState() {
    super.initState();
    _remainingSeconds = widget.initialCountdownSeconds;
    _currentBackgroundColor = AppTheme.warningColor;

    // --- Animation Controllers Initialization (same as before) ---
    _progressAnimationController = AnimationController(
      vsync: this, duration: Duration(seconds: widget.initialCountdownSeconds),
    )..addListener(() {
      if (mounted && !_rushProgressAnimationController.isAnimating && _isTimerActive) {
        setState(() => _currentAnimationProgress = 1.0 - _progressAnimationController.value);
      }
    });

    _rushProgressAnimationController = AnimationController(
      vsync: this, duration: _rushProgressDuration,
    )..addListener(() {
      if (mounted) {
        setState(() {
          double rushVal = (1.0 - _rushProgressAnimationController.value) * _rushAnimationStartProgress;
          _currentAnimationProgress = rushVal.clamp(0.0, 1.0);
        });
      }
    })..addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        if (mounted) {
          setState(() {
            _currentAnimationProgress = 0.0; _popCircleToFullWhite = true;
            _zoomIconAnimationController.reset(); _zoomIconAnimationController.forward();
          });
        }
      }
    });

    _zoomIconAnimationController = AnimationController(vsync: this, duration: _zoomIconDuration);
    _zoomIconScaleAnimation = Tween<double>(begin: 0.3, end: 1.0)
        .animate(CurvedAnimation(parent: _zoomIconAnimationController, curve: Curves.elasticOut));
    _zoomIconOpacityAnimation = Tween<double>(begin: 0.0, end: 1.0)
        .animate(CurvedAnimation(parent: _zoomIconAnimationController, curve: Interval(0.0, 0.6, curve: Curves.easeOut)));

    _bgColorAnimationController = AnimationController(vsync: this, duration: _bgColorChangeDuration)
      ..addListener(() {
        if (mounted) setState(() => _currentBackgroundColor = _bgColorAnimation.value ?? _currentBackgroundColor);
      });

    _sliderFadeController = AnimationController(vsync: this, duration: _sliderFadeDuration);
    _sliderOpacityAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
        CurvedAnimation(parent: _sliderFadeController, curve: Curves.easeOut)
    );
    // --- End Animation Controllers Initialization ---

    _initAudioAndHaptics(); // Initialize audio and haptics

    _progressAnimationController.forward();
    _startSecondUpdaterTimer();
  }

  Future<void> _initAudioAndHaptics() async {
    // For flutter_vibrate (if using and working)
    // _canVibrate = await Vibrate.canVibrate;
    // if (mounted && _canVibrate) {
    //   Vibrate.feedback(FeedbackType.heavy); // Initial heavy impact
    // }

    // For built-in HapticFeedback
    HapticFeedback.heavyImpact(); // Initial heavy impact

    // Configure audio player for looping
    await _audioPlayer.setReleaseMode(ReleaseMode.loop);
    // Consider using a specific alarm sound from your assets
    // For example: await _audioPlayer.play(AssetSource('sounds/emergency_alarm.mp3'));
    // For now, a placeholder for where you'd start the sound:
    _playAlarmSound();
  }

  Future<void> _playAlarmSound() async {
    if (_alarmSoundPlaying) return;
    try {
      // Replace 'sounds/your_alarm_sound.mp3' with your actual asset path
      await _audioPlayer.play(AssetSource('sounds/alarm.mp3'));
      _alarmSoundPlaying = true;
      print("Alarm sound started.");
    } catch (e) {
      print("Error playing alarm sound: $e");
    }
  }

  Future<void> _stopAlarmSound() async {
    if (!_alarmSoundPlaying) return;
    try {
      await _audioPlayer.stop();
      _alarmSoundPlaying = false;
      print("Alarm sound stopped.");
    } catch (e) {
      print("Error stopping alarm sound: $e");
    }
  }

  void _triggerHapticFeedback(FeedbackType type) { // Using flutter_vibrate types as example
    // if (_canVibrate) {
    //   Vibrate.feedback(type);
    // }
    // If using built-in HapticFeedback:
    switch (type) {
      case FeedbackType.light:
        HapticFeedback.lightImpact();
        break;
      case FeedbackType.medium:
        HapticFeedback.mediumImpact();
        break;
      case FeedbackType.heavy:
        HapticFeedback.heavyImpact();
        break;
      case FeedbackType.success:
        HapticFeedback.mediumImpact(); // Or a specific success pattern if available
        break;
    // Add other cases if needed
      default:
        HapticFeedback.selectionClick();
    }
  }


  void _startSecondUpdaterTimer() {
    _isTimerActive = true;
    _secondUpdaterTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _triggerHapticFeedback(FeedbackType.light); // Haptic pulse each second
      if (_remainingSeconds > 0) {
        if (mounted) setState(() => _remainingSeconds--);
      } else {
        timer.cancel();
        if (_isTimerActive && mounted) {
          _stopAlarmSound(); // Stop alarm before triggering sequence
          _triggerActionSequence(widget.onCallEmergency, Icons.phone_in_talk_outlined, isOkAction: false, autoTriggered: true);
        }
      }
    });
  }

  Future<void> _triggerActionSequence(VoidCallback action, IconData icon, {required bool isOkAction, bool autoTriggered = false}) async {
    if (!_isTimerActive && !autoTriggered) return;

    _isTimerActive = false;
    _secondUpdaterTimer.cancel();
    _progressAnimationController.stop();
    _rushAnimationStartProgress = _currentAnimationProgress;

    _stopAlarmSound(); // Ensure alarm is stopped
    _triggerHapticFeedback(FeedbackType.success); // Confirmation haptic

    setState(() {
      _actionSubmitted = true;
      _submittedIconData = icon;
      _hideCountdownNumber = true;
      _hideSliders = true;
    });

    _sliderFadeController.forward();

    Color targetBgColor = isOkAction ? AppTheme.accentColor : AppTheme.errorColor;
    _bgColorAnimation = ColorTween(begin: _currentBackgroundColor, end: targetBgColor)
        .animate(CurvedAnimation(parent: _bgColorAnimationController, curve: Curves.easeInOut));
    _bgColorAnimationController.reset();
    _bgColorAnimationController.forward();

    await Future.delayed(const Duration(milliseconds: 150));

    if (mounted && !_isTimerActive) {
      _rushProgressAnimationController.forward(from: 0.0);
    }

    await Future.delayed(Duration(milliseconds: isOkAction ? 2500 : 2400));

    if (mounted) {
      action();
    }
  }

  @override
  void dispose() {
    _secondUpdaterTimer.cancel();
    _progressAnimationController.dispose();
    _rushProgressAnimationController.dispose();
    _zoomIconAnimationController.dispose();
    _bgColorAnimationController.dispose();
    _sliderFadeController.dispose();
    _audioPlayer.dispose(); // Release audio player resources
    print("FallDetectionOverlay disposed, alarm should be stopped.");
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ... (rest of the build method is identical to the previous version)
    // ... (ensure all size constants and widget building logic remains the same)
    // ... (including submittedActionFeedback, buildSliderWrapper, Scaffold, etc.)

    // --- For brevity, I'm not repeating the entire build method if no changes were made to it ---
    // --- The changes are primarily in initState, _initAudioAndHaptics, _play/stopAlarmSound, _triggerHapticFeedback, _startSecondUpdaterTimer, _triggerActionSequence, and dispose ---

    // --- PASTE THE PREVIOUS CORRECT `build` METHOD HERE ---
    // Starting from:
    // final theme = Theme.of(context);
    // ... down to the end of the build method.
    // NO CHANGES were made to the UI rendering part of the build method in this step.
    // The logic for haptics and audio is in the state management methods.

    // --- Placeholder for where the build method content from the previous step goes ---
    // This is just to keep the response size manageable.
    // Ensure you use the full build method from the prior correct version.
    // The key changes are in the state logic, not the widget tree structure itself.
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    const Color onAlertColor = Colors.white;

    final double displayProgress;
    final Color currentProgressCircleColor;

    if (_popCircleToFullWhite) {
      displayProgress = 1.0; // Full circle for "pop"
      currentProgressCircleColor = onAlertColor; // Solid white
    } else {
      displayProgress = _currentAnimationProgress;
      currentProgressCircleColor = onAlertColor;
    }
    final Color progressCircleBackground = onAlertColor.withOpacity(0.20);

    const double countdownCircleDiameter = 280.0;
    const double countdownStrokeWidth = 12.0;
    const double sliderHeight = 80.0;
    const double sliderIconSize = 40.0; // For the icon inside CircleAvatar
    final double sliderCircleAvatarRadius = sliderHeight / 2.2; // Radius of CircleAvatar
    const double sliderTextFontSize = 22.0;
    const double titleFontSize = 36.0;
    const double subtitleFontSize = 22.0;
    const double countdownNumberFontSize = 100.0;

    Widget submittedActionFeedback() {
      if (!_actionSubmitted || _submittedIconData == null) return const SizedBox.shrink();
      return FadeTransition(
        opacity: _zoomIconOpacityAnimation,
        child: ScaleTransition(
          scale: _zoomIconScaleAnimation,
          child: Icon(_submittedIconData, color: onAlertColor, size: 120),
        ),
      );
    }

    return Scaffold(
      backgroundColor: _currentBackgroundColor, // Animated background
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16.0, 10.0, 16.0, 20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Column( /* Title and Subtitle */
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(height: MediaQuery.of(context).size.height * 0.02),
                  Text('Fall Detected!', textAlign: TextAlign.center, style: textTheme.displayMedium?.copyWith(color: onAlertColor, fontWeight: FontWeight.bold, fontSize: titleFontSize, fontFamily: 'ProductSans')),
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12.0),
                    child: Text(
                      _remainingSeconds > 0 && _isTimerActive
                          ? 'Calling emergency services and sharing location in...'
                          : (_actionSubmitted ? 'Action Confirmed' : 'Contacting emergency services...'),
                      textAlign: TextAlign.center,
                      style: textTheme.headlineSmall?.copyWith(color: onAlertColor.withOpacity(0.95), fontSize: subtitleFontSize, fontFamily: 'ProductSans', height: 1.25),
                    ),
                  ),
                ],
              ),

              Stack( /* Countdown Circle and Zoom Icon */
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: countdownCircleDiameter, height: countdownCircleDiameter,
                    child: CustomPaint(
                      painter: CountdownPainter(
                        progress: displayProgress, backgroundColor: progressCircleBackground,
                        progressColor: currentProgressCircleColor, strokeWidth: countdownStrokeWidth,
                      ),
                      child: Center(
                        child: AnimatedOpacity(
                          opacity: _hideCountdownNumber ? 0.0 : 1.0,
                          duration: _numberFadeDuration,
                          child: Text(
                            '$_remainingSeconds',
                            style: TextStyle(color: onAlertColor, fontSize: countdownNumberFontSize, fontWeight: FontWeight.bold, fontFamily: 'ProductSans'),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if(_actionSubmitted) submittedActionFeedback(),
                ],
              ),

              FadeTransition( // Wrap the Column of sliders with FadeTransition
                opacity: _sliderOpacityAnimation,
                child: IgnorePointer(
                  ignoring: _hideSliders, // Disable interaction when fading out
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0), // Spacing between sliders
                        child: SlideAction(
                          key: _slideOkKey,
                          text: "I'm OK",
                          textStyle: TextStyle(
                            color: AppTheme.accentColor, fontWeight: FontWeight.bold, fontSize: sliderTextFontSize, fontFamily: 'ProductSans',
                          ),
                          outerColor: onAlertColor, // White track
                          innerColor: AppTheme.accentColor.withAlpha(30), // Lighter thumb background
                          sliderButtonIconPadding: 0, // Control padding with Container
                          sliderButtonIcon: Container(
                            margin: const EdgeInsets.all(6), // Margin around CircleAvatar inside thumb
                            child: CircleAvatar(
                              radius: sliderCircleAvatarRadius, backgroundColor: AppTheme.accentColor,
                              child: Icon(Icons.check, color: onAlertColor, size: sliderIconSize),
                            ),
                          ),
                          borderRadius: sliderHeight / 2, height: sliderHeight, elevation: 0, sliderRotate: false,
                          submittedIcon: const SizedBox.shrink(), // Using custom central zoom
                          onSubmit: () => _triggerActionSequence(
                            widget.onImOk, Icons.check_circle_outline, isOkAction: true,
                          ),
                          enabled: _isTimerActive, // Disable if action already triggered
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0), // Spacing between sliders
                        child: SlideAction(
                          key: _slideEmergencyKey,
                          text: 'Call Emergency',
                          textStyle: TextStyle(
                            color: AppTheme.errorColor, fontWeight: FontWeight.bold, fontSize: sliderTextFontSize, fontFamily: 'ProductSans',
                          ),
                          outerColor: onAlertColor,
                          innerColor: AppTheme.errorColor.withAlpha(30),
                          sliderButtonIconPadding: 0,
                          sliderButtonIcon: Container(
                            margin: const EdgeInsets.all(6),
                            child: CircleAvatar(
                              radius: sliderCircleAvatarRadius, backgroundColor: AppTheme.errorColor,
                              child: Icon(Icons.call, color: onAlertColor, size: sliderIconSize),
                            ),
                          ),
                          borderRadius: sliderHeight / 2, height: sliderHeight, elevation: 0, sliderRotate: false,
                          submittedIcon: const SizedBox.shrink(),
                          onSubmit: () => _triggerActionSequence(
                            widget.onCallEmergency, Icons.phone_in_talk_outlined, isOkAction: false,
                          ),
                          enabled: _isTimerActive, // Disable if action already triggered
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: MediaQuery.of(context).size.height * 0.01),
            ],
          ),
        ),
      ),
    );
  }
}

// --- CountdownPainter (remains unchanged, ensure it's in your file) ---
class CountdownPainter extends CustomPainter {
  final double progress;
  final Color backgroundColor;
  final Color progressColor;
  final double strokeWidth;

  CountdownPainter({
    required this.progress,
    required this.backgroundColor,
    required this.progressColor,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width / 2, size.height / 2) - strokeWidth / 2;

    final backgroundPaint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawCircle(center, radius, backgroundPaint);

    final progressPaint = Paint()
      ..color = progressColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    double sweepAngle = 2 * math.pi * progress;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      sweepAngle,
      false,
      progressPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CountdownPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.progressColor != progressColor ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}

// --- FeedbackType enum (if you use it with flutter_vibrate) ---
// This might be defined in flutter_vibrate itself, or you can define a simple one.
// For built-in HapticFeedback, specific methods are called.
enum FeedbackType { light, medium, heavy, success, warning, error, selectionClick }