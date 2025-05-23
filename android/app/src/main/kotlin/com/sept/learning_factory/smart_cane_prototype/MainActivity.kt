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

    // --- REMOVE: We won't use this channel or action anymore ---
    // private val APP_LIFECYCLE_CHANNEL = "com.sept.learning_factory.smart_cane_prototype/app_lifecycle"
    // const val FALL_DETECTED_ACTION = "com.sept.learning_factory.smart_cane_prototype.FALL_DETECTED_ACTION"
    // private var appLifecycleMethodChannel: MethodChannel? = null
    // ----------------------------------------------------------
    private val TAG = "MainActivity"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.d(TAG, "onCreate called, intent action: ${intent?.action}")
        // --- ADD: Attempt to wake/unlock on create ---
        handleScreenWakeUnlock()
        // ------------------------------------------
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Log.d(TAG, "configureFlutterEngine called")

        // Audio Channel (Keep this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "setSpeakerphoneOn") {
                // ... (keep speakerphone logic) ...
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

        // --- REMOVE: Lifecycle channel setup and intent handling ---
        // appLifecycleMethodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_LIFECYCLE_CHANNEL)
        // handleIntentOnFlutterReady(intent)
        // -------------------------------------------------------
    }

    // --- REMOVE: handleIntentOnFlutterReady ---

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        Log.d(TAG, "onNewIntent called, action: ${intent.action}")
        setIntent(intent)
        // --- ADD: Attempt to wake/unlock on new intent too ---
        handleScreenWakeUnlock()
        // -------------------------------------------------
        // --- REMOVE: handleIntentOnFlutterReady(intent) ---
    }

    // --- ADD: Screen Waking Logic ---
    private fun handleScreenWakeUnlock() {
        Log.d(TAG, "Attempting to wake/unlock screen.")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            // Note: requestDismissKeyguard might require user interaction on secure lock screens
            keyguardManager.requestDismissKeyguard(this, null)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                        WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            )
        }
    }
    // --------------------------------

    override fun onResume() {
        super.onResume()
        Log.d(TAG, "onResume called.")
        // --- Optional: Could call handleScreenWakeUnlock() here too, but might be redundant ---
    }
}