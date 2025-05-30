package com.sept.learning_factory.smart_cane_prototype

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

class MainActivity : FlutterFragmentActivity() { // Changed to FlutterFragmentActivity if not already
    private val AUDIO_CHANNEL = "com.sept.learning_factory.smart_cane_prototype/audio"
    private val TAG = "MainActivitySmartCane" // Changed TAG for clarity

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.d(TAG, "onCreate called, intent action: ${intent?.action}")
        handleScreenWakeUnlock() // Attempt to wake/unlock
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

                        // Explicitly set mode to MODE_IN_CALL each time before changing speakerphone state
                        // This can help if the mode was changed by another app or system process.
                        audioManager.mode = AudioManager.MODE_IN_CALL
                        Log.d(TAG, "Audio mode set to MODE_IN_CALL")

                        audioManager.isSpeakerphoneOn = on
                        Log.d(TAG, "Speakerphone set to $on. Current state: ${audioManager.isSpeakerphoneOn}")

                        // Verify if it actually changed
                        if (audioManager.isSpeakerphoneOn == on) {
                            result.success(true)
                        } else {
                            Log.w(
                                TAG,
                                "Speakerphone state did not change as expected. Still: ${audioManager.isSpeakerphoneOn}"
                            )
                            result.error(
                                "SPEAKERPHONE_UNCHANGED",
                                "Speakerphone state did not change as expected.",
                                null
                            )
                        }

                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to set speakerphone", e)
                        result.error("SPEAKERPHONE_ERROR", "Failed to set speakerphone: ${e.message}", null)
                    }
                } else {
                    Log.e(TAG, "Argument 'on' is null for setSpeakerphoneOn")
                    result.error("INVALID_ARGUMENT", "Argument 'on' is null", null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        Log.d(TAG, "onNewIntent called, action: ${intent.action}")
        setIntent(intent) // Update the activity's intent
        handleScreenWakeUnlock() // Attempt to wake/unlock again
    }

    private fun handleScreenWakeUnlock() {
        Log.d(TAG, "Attempting to wake/unlock screen.")
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(true)
                setTurnScreenOn(true)
                // val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
                // keyguardManager.requestDismissKeyguard(this, null) // This might need user interaction for secure lock screens
            } else {
                @Suppress("DEPRECATION")
                window.addFlags(
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                            WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or // Potentially problematic without user interaction
                            WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                )
            }
            Log.d(TAG, "Screen wake/unlock flags applied.")
        } catch (e: Exception) {
            Log.e(TAG, "Error in handleScreenWakeUnlock: ${e.message}")
        }
    }

    override fun onResume() {
        super.onResume()
        Log.d(TAG, "onResume called.")
        // It might be beneficial to try waking/unlocking here too,
        // especially if the activity was paused and is now resuming during an active call sequence.
        // handleScreenWakeUnlock()
    }
}