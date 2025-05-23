package com.sept.learning_factory.smart_cane_prototype

import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val AUDIO_CHANNEL = "com.sept.learning_factory.smart_cane_prototype/audio"
    private val APP_LIFECYCLE_CHANNEL = "com.sept.learning_factory.smart_cane_prototype/app_lifecycle"
    private val TAG = "MainActivity"

    private var appLifecycleMethodChannel: MethodChannel? = null

    companion object {
        const val FALL_DETECTED_ACTION = "com.sept.learning_factory.smart_cane_prototype.FALL_DETECTED_ACTION"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.d(TAG, "onCreate called, intent action: ${intent?.action}, extras: ${intent?.extras}")
        // It's important to handle the intent here if the activity is created fresh.
        // If the Flutter engine is already running, onNewIntent might be more relevant for subsequent intents.
        // However, configureFlutterEngine is where MethodChannel is set up, so we need to ensure
        // the message is sent *after* the channel is ready.
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Log.d(TAG, "configureFlutterEngine called")

        // Audio Channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "setSpeakerphoneOn") {
                val on = call.argument<Boolean>("on")
                if (on != null) {
                    try {
                        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        // Consider device API level for MODE_IN_COMMUNICATION vs MODE_IN_CALL
                        audioManager.mode = AudioManager.MODE_IN_CALL
                        audioManager.isSpeakerphoneOn = on
                        Log.d(TAG, "Speakerphone set to $on")
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to set speakerphone", e)
                        result.error("SPEAKERPHONE_ERROR", "Failed to set speakerphone: ${e.message}", null)
                    }
                } else {
                    result.error("INVALID_ARGUMENT", "Argument 'on' is null", null)
                }
            } else {
                result.notImplemented()
            }
        }

        // App Lifecycle/Event Channel (for sending events from Native to Dart)
        appLifecycleMethodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_LIFECYCLE_CHANNEL)
        Log.d(TAG, "App Lifecycle MethodChannel registered.")

        // Check initial intent again after engine is configured
        // This ensures that if launched from terminated state with the action, Dart gets notified.
        handleIntentOnFlutterReady(intent)
    }

    // This method ensures we only send to Dart after the channel is ready.
    private fun handleIntentOnFlutterReady(intent: Intent?) {
        if (intent?.action == FALL_DETECTED_ACTION) {
            Log.d(TAG, "handleIntentOnFlutterReady: Fall detected action found. Invoking Dart 'onFallDetectedLaunch'.")
            appLifecycleMethodChannel?.invokeMethod("onFallDetectedLaunch", null)
            // Clear the action so it's not processed again if activity is paused/resumed without new intent
            // intent.action = null // Or create a new intent without the action if needed
        }
    }


    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        Log.d(TAG, "onNewIntent called, action: ${intent.action}, extras: ${intent.extras}")
        setIntent(intent) // Important to update the activity's current intent
        // Handle the intent, which will check the action and invoke Dart if needed
        handleIntentOnFlutterReady(intent)
    }

    // onResume is called when the activity comes to the foreground.
    // This is a good place to ensure the screen is unlocked and visible.
    override fun onResume() {
        super.onResume()
        Log.d(TAG, "onResume called. Current intent action: ${intent?.action}")
        // If the intent that brought the activity to front was the fall detection,
        // ensure screen is on and keyguard is dismissed.
        if (intent?.action == FALL_DETECTED_ACTION) {
            Log.d(TAG, "onResume: Fall detected action present. Ensuring screen is on and unlocked.")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(true)
                setTurnScreenOn(true)
                val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
                if (keyguardManager.isKeyguardLocked) { // Only request if actually locked
                    keyguardManager.requestDismissKeyguard(this, null)
                }
            } else {
                window.addFlags(
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
                            or WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
                            or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON // Added FLAG_TURN_SCREEN_ON
                            or WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                )
            }
            // Potentially re-invoke Dart side if configureFlutterEngine might not have run yet
            // or if onNewIntent wasn't the one that brought it up.
            // However, handleIntentOnFlutterReady in configureFlutterEngine and onNewIntent should cover this.
            // appLifecycleMethodChannel?.invokeMethod("onFallDetectedLaunch", null)
        }
    }
}