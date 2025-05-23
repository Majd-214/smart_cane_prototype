// lib/widgets/fall_detection_overlay.dart
import 'dart:async';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_vibrate/flutter_vibrate.dart';
import 'package:slide_to_act/slide_to_act.dart';
import 'package:smart_cane_prototype/utils/app_theme.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

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
  Color _currentBackgroundColor = AppTheme.errorColor;

  late AnimationController _sliderFadeController;
  late Animation<double> _sliderOpacityAnimation;
  bool _hideSliders = false;

  bool _popCircleToFullWhite = false;
  bool _hideCountdownNumber = false;

  final AudioPlayer _audioPlayer = AudioPlayer();
  StreamSubscription? _playerStateSubscription;
  bool _alarmSoundPlaying = false;
  bool _canVibrateDevice = false;

  final Duration _rushProgressDuration = const Duration(milliseconds: 400);
  final Duration _zoomIconDuration = const Duration(milliseconds: 500);
  final Duration _bgColorChangeDuration = const Duration(milliseconds: 400);
  final Duration _numberFadeDuration = const Duration(milliseconds: 250);
  final Duration _sliderFadeDuration = const Duration(milliseconds: 200);

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable().then((_) =>
        print("FallDetectionOverlay: Wakelock enabled."));

    _remainingSeconds = widget.initialCountdownSeconds;
    _currentBackgroundColor =
        AppTheme.errorColor; // Default to error color (e.g., red or yellow)

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
        .animate(CurvedAnimation(parent: _zoomIconAnimationController,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOut)));

    _bgColorAnimationController = AnimationController(vsync: this, duration: _bgColorChangeDuration)
      ..addListener(() {
        if (mounted) setState(() => _currentBackgroundColor = _bgColorAnimation.value ?? _currentBackgroundColor);
      });

    _sliderFadeController = AnimationController(vsync: this, duration: _sliderFadeDuration);
    _sliderOpacityAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
        CurvedAnimation(parent: _sliderFadeController, curve: Curves.easeOut)
    );

    _setupAudioAndHaptics();
    _progressAnimationController.forward();
    _startSecondUpdaterTimer();
  }

  Future<void> _setupAudioAndHaptics() async {
    print("FallDetectionOverlay: Setting up Audio and Haptics.");
    bool? canVibrate = await Vibrate.canVibrate;
    if (mounted) {
      _canVibrateDevice = canVibrate ?? false;
      if (_canVibrateDevice) {
        Vibrate.feedback(FeedbackType.error);
        print("FallDetectionOverlay: Initial ERROR haptic triggered (flutter_vibrate).");
      } else {
        HapticFeedback.heavyImpact();
        print("FallDetectionOverlay: Initial HEAVY haptic triggered (built-in fallback).");
      }
    }

    _playerStateSubscription = _audioPlayer.onPlayerStateChanged.listen((PlayerState s) {
      print('FallDetectionOverlay: AudioPlayer current state: $s');
    });
    _audioPlayer.onLog.listen((msg) =>
        print('FallDetectionOverlay: audioplayers log: $msg'));

    await _audioPlayer.setAudioContext(AudioContext(
      android: AudioContextAndroid(
        isSpeakerphoneOn: true,
        stayAwake: true,
        contentType: AndroidContentType.sonification,
        usageType: AndroidUsageType.alarm,
        audioFocus: AndroidAudioFocus.gain,
      ),
    ));
    await _audioPlayer.setReleaseMode(ReleaseMode.loop);
    await _audioPlayer.setVolume(1.0);
    _playAlarmSound();
  }

  Future<void> _playAlarmSound() async {
    if (_alarmSoundPlaying && _audioPlayer.state == PlayerState.playing) return;
    try {
      print("FallDetectionOverlay: Attempting to play alarm sound.");
      await _audioPlayer.play(
          AssetSource('sounds/alarm.mp3')); // Ensure this asset exists
      if (mounted) setState(() {
        _alarmSoundPlaying = true;
      });
      print("FallDetectionOverlay: Alarm sound play command issued.");
    } catch (e) {
      print("FallDetectionOverlay: Error playing alarm sound: $e");
      if (mounted) setState(() => _alarmSoundPlaying = false);
    }
  }

  Future<void> _stopAlarmSound({bool calledFromDispose = false}) async {
    print("FallDetectionOverlay: Attempting to stop alarm sound. Playing: $_alarmSoundPlaying, State: ${_audioPlayer.state}");
    if (_audioPlayer.state == PlayerState.playing || _audioPlayer.state == PlayerState.paused) {
      try {
        await _audioPlayer.stop();
        print("FallDetectionOverlay: Alarm sound stop command issued.");
      } catch (e) {
        print("FallDetectionOverlay: Error stopping alarm sound: $e");
      }
    }
    if (!calledFromDispose && mounted) {
      setState(() { _alarmSoundPlaying = false; });
    } else {
      _alarmSoundPlaying = false;
    }
  }

  void _triggerHapticFeedback(FeedbackType type) {
    if (!_canVibrateDevice) {
      switch(type){
        case FeedbackType.light: HapticFeedback.lightImpact(); break;
        case FeedbackType.medium: HapticFeedback.mediumImpact(); break;
        default:
          HapticFeedback.heavyImpact();
      }
      return;
    }
    Vibrate.feedback(type);
  }

  void _pulseHapticForCountdown() {
    if (mounted && _isTimerActive) _triggerHapticFeedback(FeedbackType.medium);
  }

  void _startSecondUpdaterTimer() {
    _isTimerActive = true;
    _secondUpdaterTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _pulseHapticForCountdown();
      if (_remainingSeconds > 0) {
        if (mounted) setState(() => _remainingSeconds--);
      } else {
        timer.cancel();
        if (_isTimerActive && mounted) {
          _triggerActionSequence(widget.onCallEmergency, Icons.phone_in_talk_outlined, isOkAction: false, autoTriggered: true);
        }
      }
    });
  }

  Future<void> _triggerActionSequence(VoidCallback action, IconData icon, {required bool isOkAction, bool autoTriggered = false}) async {
    if ((!_isTimerActive && !autoTriggered) ||
        _actionSubmitted) { // Added _actionSubmitted check
      print(
          "FallDetectionOverlay: Action sequence blocked or already submitted.");
      return;
    }
    print(
        "FallDetectionOverlay: Triggering action. isOkAction: $isOkAction, auto: $autoTriggered");
    _actionSubmitted = true; // Set submitted flag early
    _isTimerActive = false;

    _secondUpdaterTimer.cancel();
    _progressAnimationController.stop();
    await _stopAlarmSound();
    _triggerHapticFeedback(FeedbackType.heavy);

    _rushAnimationStartProgress = _currentAnimationProgress;
    setState(() {
      _submittedIconData = icon;
      _hideCountdownNumber = true;
      _hideSliders = true;
    });

    _sliderFadeController.forward();
    Color targetBgColor = isOkAction ? AppTheme.accentColor : AppTheme.errorColor;
    if (_currentBackgroundColor != targetBgColor) {
      _bgColorAnimation = ColorTween(begin: _currentBackgroundColor, end: targetBgColor)
          .animate(CurvedAnimation(parent: _bgColorAnimationController, curve: Curves.easeInOutCubic));
      _bgColorAnimationController.reset();
      _bgColorAnimationController.forward();
    }

    await Future.delayed(const Duration(milliseconds: 150));
    if (mounted) _rushProgressAnimationController.forward(from: 0.0);
    await Future.delayed(Duration(
        milliseconds: isOkAction ? 2000 : 1800)); // Shortened delay a bit

    if (mounted) {
      WakelockPlus.disable().then((_) =>
          print("FallDetectionOverlay: Wakelock disabled before action call."));
      action();
    }
  }

  @override
  void dispose() {
    print("FallDetectionOverlay: Disposing...");
    WakelockPlus.disable().then((_) =>
        print("FallDetectionOverlay: Wakelock disabled in dispose."));
    _stopAlarmSound(calledFromDispose: true); // Pass the flag
    _secondUpdaterTimer.cancel();
    _progressAnimationController.dispose();
    _rushProgressAnimationController.dispose();
    _zoomIconAnimationController.dispose();
    _bgColorAnimationController.dispose();
    _sliderFadeController.dispose();
    _playerStateSubscription?.cancel();
    _audioPlayer.dispose();
    print("FallDetectionOverlay: Disposed. Resources released.");
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    const Color onAlertColor = Colors.white;

    final double displayProgress = _popCircleToFullWhite
        ? 1.0
        : _currentAnimationProgress;
    final Color currentProgressCircleColor = onAlertColor;
    final Color progressCircleBackground = onAlertColor.withOpacity(0.20);

    const double countdownCircleDiameter = 280.0;
    const double countdownStrokeWidth = 12.0;
    const double sliderHeight = 70.0; // Slightly smaller
    const double sliderIconSize = 36.0; // Slightly smaller
    final double sliderCircleAvatarRadius = sliderHeight / 2.3;
    const double sliderTextFontSize = 20.0; // Slightly smaller
    const double titleFontSize = 32.0; // Slightly smaller
    const double subtitleFontSize = 18.0; // Slightly smaller
    const double countdownNumberFontSize = 90.0; // Slightly smaller

    Widget submittedActionFeedback() {
      if (!_actionSubmitted || _submittedIconData == null) return const SizedBox.shrink();
      return FadeTransition(
        opacity: _zoomIconOpacityAnimation,
        child: ScaleTransition(
          scale: _zoomIconScaleAnimation,
          child: Icon(_submittedIconData, color: onAlertColor,
              size: 110), // Slightly smaller
        ),
      );
    }

    return Scaffold(
      backgroundColor: _currentBackgroundColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(height: MediaQuery.of(context).size.height * 0.02),
                  Text('Fall Detected!', textAlign: TextAlign.center,
                      style: textTheme.displaySmall?.copyWith(
                          color: onAlertColor,
                          fontWeight: FontWeight.bold,
                          fontSize: titleFontSize,
                          fontFamily: 'ProductSans')),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12.0),
                    child: Text(
                      _actionSubmitted ? 'Action Confirmed' : (_isTimerActive &&
                          _remainingSeconds > 0
                          ? 'Calling emergency services in...'
                          : 'Contacting emergency services...'),
                      textAlign: TextAlign.center,
                      style: textTheme.titleMedium?.copyWith(
                          color: onAlertColor.withOpacity(0.95),
                          fontSize: subtitleFontSize,
                          fontFamily: 'ProductSans',
                          height: 1.25),
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
                        padding: const EdgeInsets.symmetric(vertical: 6.0),
                        child: SlideAction(
                          key: _slideOkKey,
                          text: "I'm OK",
                          textStyle: TextStyle(color: AppTheme.accentColor,
                              fontWeight: FontWeight.bold,
                              fontSize: sliderTextFontSize,
                              fontFamily: 'ProductSans'),
                          outerColor: onAlertColor,
                          innerColor: AppTheme.accentColor.withAlpha(30),
                          sliderButtonIconPadding: 0,
                          sliderButtonIcon: Container(margin: const EdgeInsets
                              .all(5),
                              child: CircleAvatar(
                                  radius: sliderCircleAvatarRadius,
                                  backgroundColor: AppTheme.accentColor,
                                  child: Icon(Icons.check, color: onAlertColor,
                                      size: sliderIconSize))),
                          borderRadius: sliderHeight / 2,
                          height: sliderHeight,
                          elevation: 0,
                          sliderRotate: false,
                          submittedIcon: const SizedBox.shrink(),
                          onSubmit: () => _triggerActionSequence(
                              widget.onImOk, Icons.check_circle_outline,
                              isOkAction: true),
                          enabled: _isTimerActive,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6.0),
                        child: SlideAction(
                          key: _slideEmergencyKey,
                          text: 'Call Emergency',
                          textStyle: TextStyle(color: AppTheme.errorColor,
                              fontWeight: FontWeight.bold,
                              fontSize: sliderTextFontSize,
                              fontFamily: 'ProductSans'),
                          outerColor: onAlertColor,
                          innerColor: AppTheme.errorColor.withAlpha(30),
                          sliderButtonIconPadding: 0,
                          sliderButtonIcon: Container(margin: const EdgeInsets
                              .all(5),
                              child: CircleAvatar(
                                  radius: sliderCircleAvatarRadius,
                                  backgroundColor: AppTheme.errorColor,
                                  child: Icon(Icons.call, color: onAlertColor,
                                      size: sliderIconSize))),
                          borderRadius: sliderHeight / 2,
                          height: sliderHeight,
                          elevation: 0,
                          sliderRotate: false,
                          submittedIcon: const SizedBox.shrink(),
                          onSubmit: () => _triggerActionSequence(
                              widget.onCallEmergency,
                              Icons.phone_in_talk_outlined, isOkAction: false),
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

class CountdownPainter extends CustomPainter {
  final double progress;
  final Color backgroundColor;
  final Color progressColor;
  final double strokeWidth;

  CountdownPainter(
      {required this.progress, required this.backgroundColor, required this.progressColor, required this.strokeWidth});
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
    canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius), -math.pi / 2,
        2 * math.pi * progress, false, progressPaint);
  }
  @override
  bool shouldRepaint(covariant CountdownPainter oldDelegate) =>
      oldDelegate.progress != progress ||
          oldDelegate.backgroundColor != backgroundColor ||
          oldDelegate.progressColor != progressColor ||
          oldDelegate.strokeWidth != strokeWidth;
}