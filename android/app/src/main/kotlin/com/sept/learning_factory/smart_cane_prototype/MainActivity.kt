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
import io.flutter.plugin.common.MethodCall // Added for clarity
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
        // Handle initial intent *after* engine is configured
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Log.d(TAG, "configureFlutterEngine called")

        // Audio Channel (Keep as is)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "setSpeakerphoneOn") {
                val on = call.argument<Boolean>("on")
                if (on != null) {
                    try {
                        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
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

        // App Lifecycle/Event Channel
        appLifecycleMethodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_LIFECYCLE_CHANNEL)
        appLifecycleMethodChannel?.setMethodCallHandler { call, result ->
            handleAppLifecycleMethodCalls(call, result)
        }
        Log.d(TAG, "App Lifecycle MethodChannel registered.")

        // Check initial intent now that the channel is ready
        handleIntentOnFlutterReady(intent)
    }

    // ** NEW Function to handle method calls **
    private fun handleAppLifecycleMethodCalls(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "onFallDetectedLaunch" -> {
                // This is now mainly for logging/confirmation if needed
                Log.d(TAG, "Received 'onFallDetectedLaunch' - Dart should now navigate.")
                result.success(null)
            }

            "forceLaunch" -> {
                Log.d(TAG, "Received 'forceLaunch'. Creating and starting intent.")

                // Ensure screen is on and unlocked first
                wakeAndUnlock()

                // Create and launch the intent
                val intent = Intent(this, MainActivity::class.java).apply {
                    action = FALL_DETECTED_ACTION // Set our custom action
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                }
                applicationContext.startActivity(intent) // Use applicationContext with NEW_TASK
                Log.d(TAG, "startActivity called with FALL_DETECTED_ACTION.")
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }


    private fun handleIntentOnFlutterReady(intent: Intent?) {
        if (intent?.action == FALL_DETECTED_ACTION) {
            Log.d(TAG, "handleIntentOnFlutterReady: Fall detected action found. Invoking Dart 'onFallDetectedLaunch'.")
            // Ensure screen is on and unlocked when handling this intent too
            wakeAndUnlock()
            appLifecycleMethodChannel?.invokeMethod("onFallDetectedLaunch", null)
            // It might be useful to clear the action after processing,
            // but be careful as it might affect re-launches. Test this if needed.
            // setIntent(Intent(this, MainActivity::class.java))
        }
    }


    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        Log.d(TAG, "onNewIntent called, action: ${intent.action}, extras: ${intent.extras}")
        setIntent(intent) // Update the activity's current intent
        handleIntentOnFlutterReady(intent)
    }

    // ** NEW Function to handle wake/unlock **
    private fun wakeAndUnlock() {
        Log.d(TAG, "Attempting to wake and unlock screen.")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            keyguardManager.requestDismissKeyguard(this, null) // Request dismiss
        } else {
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
                        or WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
                        or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                        or WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            )
        }
        Log.d(TAG, "Wake/Unlock flags set.")
    }

    override fun onResume() {
        super.onResume()
        Log.d(TAG, "onResume called. Current intent action: ${intent?.action}")
        // Re-check intent on resume, might be necessary if activity was only paused
        if (intent?.action == FALL_DETECTED_ACTION) {
            wakeAndUnlock()
        }
    }
}