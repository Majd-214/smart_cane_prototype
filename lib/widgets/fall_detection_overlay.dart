// lib/widgets/fall_detection_overlay.dart
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // For HapticFeedback
import 'package:smart_cane_prototype/utils/app_theme.dart';
import 'package:slide_to_act/slide_to_act.dart';
import 'package:audioplayers/audioplayers.dart';

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

  final AudioPlayer _audioPlayer = AudioPlayer();
  StreamSubscription? _playerStateSubscription; // To listen to player state
  bool _alarmSoundPlaying = false;


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

    _setupAudioPlayer(); // Setup audio player and listeners
    _initHapticsAndPlaySound(); // Trigger initial haptics and sound

    _progressAnimationController.forward();
    _startSecondUpdaterTimer();
  }

  Future<void> _setupAudioPlayer() async {
    // Listen to player state changes for debugging
    _playerStateSubscription = _audioPlayer.onPlayerStateChanged.listen((PlayerState s) {
      print('FallDetectionOverlay: AudioPlayer current state: $s');
      if (s == PlayerState.completed && _alarmSoundPlaying) {
        // If it completed and wasn't stopped intentionally, and loop is desired, play again.
        // Note: setReleaseMode(ReleaseMode.loop) should handle this, but this is a fallback.
        // Be careful with this manual re-play if ReleaseMode.loop is also active.
        // For now, relying on ReleaseMode.loop.
      }
      if (s == PlayerState.stopped || s == PlayerState.completed || s == PlayerState.disposed) {
        // If it stopped for any reason other than pause, mark as not playing.
        // This helps ensure _playAlarmSound can be called again if needed.
        // However, _stopAlarmSound should be the primary way to set _alarmSoundPlaying to false.
        // if (_alarmSoundPlaying && s != PlayerState.paused) {
        //   _alarmSoundPlaying = false;
        // }
      }
    });

    _audioPlayer.onLog.listen((msg) { // Listen to logs from audioplayers
      print('FallDetectionOverlay: audioplayers log: $msg');
    });

    // Set AudioContext for Android to use ALARM stream
    await _audioPlayer.setAudioContext(AudioContext(
      android: AudioContextAndroid(
        isSpeakerphoneOn: true,
        stayAwake: true,
        contentType: AndroidContentType.sonification,
        usageType: AndroidUsageType.alarm, // CRITICAL
        audioFocus: AndroidAudioFocus.gain, // Try full gain instead of gainTransientMayDuck
      ),
      // iOS: AudioContextIOS(category: AVAudioSessionCategory.playback, options: []), // Minimal for iOS as per request
    ));
    await _audioPlayer.setReleaseMode(ReleaseMode.loop); // Ensure looping
    await _audioPlayer.setVolume(1.0); // Set volume to max for this player instance
  }

  Future<void> _initHapticsAndPlaySound() async {
    print("FallDetectionOverlay: Initializing Haptics and Playing Sound.");
    HapticFeedback.heavyImpact();
    print("FallDetectionOverlay: Initial heavyImpact triggered.");
    _playAlarmSound(); // Attempt to play alarm sound
  }

  Future<void> _playAlarmSound() async {
    if (_alarmSoundPlaying && _audioPlayer.state == PlayerState.playing) {
      print("FallDetectionOverlay: Alarm sound already playing.");
      return;
    }
    try {
      print("FallDetectionOverlay: Attempting to play alarm sound.");
      // IMPORTANT: Replace 'sounds/your_alarm_sound.mp3' with your asset path
      await _audioPlayer.play(AssetSource('sounds/your_alarm_sound.mp3'));
      _alarmSoundPlaying = true;
      print("FallDetectionOverlay: Alarm sound play command issued.");
    } catch (e) {
      print("FallDetectionOverlay: Error playing alarm sound: $e");
      _alarmSoundPlaying = false; // Ensure flag is false on error
    }
  }

  Future<void> _stopAlarmSound() async {
    print("FallDetectionOverlay: Attempting to stop alarm sound. Currently playing: $_alarmSoundPlaying, State: ${_audioPlayer.state}");
    if (_audioPlayer.state == PlayerState.playing || _audioPlayer.state == PlayerState.paused) {
      try {
        await _audioPlayer.stop();
        print("FallDetectionOverlay: Alarm sound stop command issued.");
      } catch (e) {
        print("FallDetectionOverlay: Error stopping alarm sound: $e");
      }
    }
    _alarmSoundPlaying = false; // Always set to false after attempting to stop
  }

  void _triggerHapticFeedback(String type) { /* ... (same as before) ... */
    print("FallDetectionOverlay: Triggering haptic: $type");
    switch (type) {
      case 'light': HapticFeedback.lightImpact(); break;
      case 'medium': HapticFeedback.mediumImpact(); break;
      case 'heavy': HapticFeedback.heavyImpact(); break;
      default: HapticFeedback.selectionClick();
    }
  }
  void _pulseHapticForCountdown() { /* ... (same as before) ... */
    if (mounted && _isTimerActive) {
      HapticFeedback.mediumImpact();
    }
  }


  void _startSecondUpdaterTimer() {
    _isTimerActive = true;
    _secondUpdaterTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _pulseHapticForCountdown();
      if (_remainingSeconds > 0) {
        if (mounted) setState(() => _remainingSeconds--);
      } else {
        timer.cancel(); // Stop this timer first
        if (_isTimerActive && mounted) { // Check _isTimerActive again
          // Auto-triggered emergency action
          _triggerActionSequence(widget.onCallEmergency, Icons.phone_in_talk_outlined, isOkAction: false, autoTriggered: true);
        }
      }
    });
  }

  Future<void> _triggerActionSequence(VoidCallback action, IconData icon, {required bool isOkAction, bool autoTriggered = false}) async {
    if (!_isTimerActive && !autoTriggered) { // If timer already inactive (e.g. user acted) and this isn't the auto-trigger
      print("FallDetectionOverlay: Action sequence blocked or already handled.");
      return;
    }
    print("FallDetectionOverlay: Triggering action sequence. isOkAction: $isOkAction, autoTriggered: $autoTriggered");

    // Stop everything related to ongoing alert sensory feedback
    _isTimerActive = false;
    _secondUpdaterTimer.cancel(); // Explicitly cancel, though it might have self-cancelled if autoTriggered
    _progressAnimationController.stop();
    await _stopAlarmSound(); // Stop sound FIRST
    _triggerHapticFeedback('heavy'); // Confirmation haptic

    _rushAnimationStartProgress = _currentAnimationProgress;

    setState(() {
      _actionSubmitted = true;
      _submittedIconData = icon;
      _hideCountdownNumber = true;
      _hideSliders = true;
    });

    _sliderFadeController.forward();

    Color targetBgColor = isOkAction ? AppTheme.accentColor : AppTheme.errorColor;
    if (_currentBackgroundColor != targetBgColor) {
      _bgColorAnimation = ColorTween(begin: _currentBackgroundColor, end: targetBgColor)
          .animate(CurvedAnimation(parent: _bgColorAnimationController, curve: Curves.easeInOut));
      _bgColorAnimationController.reset();
      _bgColorAnimationController.forward();
    }

    await Future.delayed(const Duration(milliseconds: 150));

    if (mounted) { // Check mounted before starting next phase animations
      _rushProgressAnimationController.forward(from: 0.0);
    }

    await Future.delayed(Duration(milliseconds: isOkAction ? 2500 : 2400));

    if (mounted) {
      action();
    }
  }

  @override
  void dispose() {
    _stopAlarmSound(); // Ensure sound is stopped
    _secondUpdaterTimer.cancel();
    _progressAnimationController.dispose();
    _rushProgressAnimationController.dispose();
    _zoomIconAnimationController.dispose();
    _bgColorAnimationController.dispose();
    _sliderFadeController.dispose();
    _playerStateSubscription?.cancel(); // Cancel player state listener
    _audioPlayer.dispose();
    print("FallDetectionOverlay disposed. Resources released.");
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // --- NO CHANGES TO THE BUILD METHOD ITSELF ---
    // --- Paste the previous correct 'build' method here ---
    // The logic changes are in initState, audio methods, and _triggerActionSequence
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    const Color onAlertColor = Colors.white;

    final double displayProgress;
    final Color currentProgressCircleColor;

    if (_popCircleToFullWhite) {
      displayProgress = 1.0;
      currentProgressCircleColor = onAlertColor;
    } else {
      displayProgress = _currentAnimationProgress;
      currentProgressCircleColor = onAlertColor;
    }
    final Color progressCircleBackground = onAlertColor.withOpacity(0.20);

    const double countdownCircleDiameter = 280.0;
    const double countdownStrokeWidth = 12.0;
    const double sliderHeight = 80.0;
    const double sliderIconSize = 40.0;
    final double sliderCircleAvatarRadius = sliderHeight / 2.2;
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
      backgroundColor: _currentBackgroundColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16.0, 10.0, 16.0, 20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Column(
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

              Stack(
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

              FadeTransition(
                opacity: _sliderOpacityAnimation,
                child: IgnorePointer(
                  ignoring: _hideSliders,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0),
                        child: SlideAction(
                          key: _slideOkKey,
                          text: "I'm OK",
                          textStyle: TextStyle(
                            color: AppTheme.accentColor, fontWeight: FontWeight.bold, fontSize: sliderTextFontSize, fontFamily: 'ProductSans',
                          ),
                          outerColor: onAlertColor,
                          innerColor: AppTheme.accentColor.withAlpha(30),
                          sliderButtonIconPadding: 0,
                          sliderButtonIcon: Container(
                            margin: const EdgeInsets.all(6),
                            child: CircleAvatar(
                              radius: sliderCircleAvatarRadius, backgroundColor: AppTheme.accentColor,
                              child: Icon(Icons.check, color: onAlertColor, size: sliderIconSize),
                            ),
                          ),
                          borderRadius: sliderHeight / 2, height: sliderHeight, elevation: 0, sliderRotate: false,
                          submittedIcon: const SizedBox.shrink(),
                          onSubmit: () => _triggerActionSequence(
                            widget.onImOk, Icons.check_circle_outline, isOkAction: true,
                          ),
                          enabled: _isTimerActive,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0),
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
                          enabled: _isTimerActive,
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


// CountdownPainter (no changes needed)
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