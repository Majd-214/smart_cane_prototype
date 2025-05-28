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
    private val TAG = "MainActivity"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.d(TAG, "onCreate called, intent action: ${intent?.action}, payload: ${intent?.extras?.toString()}")
        // Attempt to wake/unlock right away
        handleScreenWakeUnlock()
        // If launched by our notification, you could potentially parse extras here
        // and pass them to Flutter, but fullScreenIntent should bring the activity
        // to the front, and Flutter's notification handling should manage the rest.
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Log.d(TAG, "configureFlutterEngine called")

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "setSpeakerphoneOn") {
                val on = call.argument<Boolean>("on")
                if (on != null) {
                    try {
                        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        audioManager.mode = AudioManager.MODE_IN_CALL // Ensure mode is set
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
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        Log.d(TAG, "onNewIntent called, action: ${intent.action}, payload: ${intent?.extras?.toString()}")
        setIntent(intent) // Update the intent
        // Attempt to wake/unlock *again* if brought up via new intent
        handleScreenWakeUnlock()
        // Flutter's notification plugin should handle sending the payload to Dart.
    }

    private fun handleScreenWakeUnlock() {
        Log.d(TAG, "Attempting to wake/unlock screen.")
        // Use setShowWhenLocked and setTurnScreenOn for modern Android
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            // Requesting keyguard dismiss can bring up the lock screen for user interaction
            val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            keyguardManager.requestDismissKeyguard(this, null)
            Log.d(TAG, "Using setShowWhenLocked(true), setTurnScreenOn(true)")
        } else {
            // Deprecated method for older versions
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                        WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            )
            Log.d(TAG, "Using legacy window flags for wake/unlock.")
        }
    }

    override fun onResume() {
        super.onResume()
        Log.d(TAG, "onResume called.")
    }
}