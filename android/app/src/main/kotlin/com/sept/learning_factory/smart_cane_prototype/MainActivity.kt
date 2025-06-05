package com.sept.learning_factory.smart_cane_prototype

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.WindowManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val AUDIO_CHANNEL = "com.sept.learning_factory.smart_cane_prototype/audio"
    private val CALL_CHANNEL = "com.sept.learning_factory.smart_cane_prototype/call" // New channel for calls
    private val TAG = "MainActivitySmartCane"
    private var audioManager: AudioManager? = null
    private var audioFocusRequest: AudioFocusRequest? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        Log.d(TAG, "onCreate called, intent action: ${intent?.action}")
        handleScreenWakeUnlock()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Log.d(TAG, "configureFlutterEngine called")

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "setSpeakerphoneOn") {
                val on = call.argument<Boolean>("on")
                if (on != null) {
                    setSpeakerphoneNative(on, result)
                } else {
                    Log.e(TAG, "Argument 'on' is null for setSpeakerphoneOn")
                    result.error("INVALID_ARGUMENT", "Argument 'on' is null", null)
                }
            } else {
                result.notImplemented()
            }
        }

        // New MethodChannel for initiating call and setting speakerphone
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CALL_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "initiateEmergencyCallAndSpeaker") {
                val phoneNumber = call.argument<String>("phoneNumber")
                if (phoneNumber != null) {
                    initiateCallAndSpeaker(phoneNumber, result)
                } else {
                    result.error("INVALID_ARGUMENT", "Phone number is null", null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    private fun setSpeakerphoneNative(on: Boolean, result: MethodChannel.Result) {
        try {
            if (audioManager == null) {
                audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            }

            // Request audio focus - crucial for calls
            // Using AUDIOFOCUS_GAIN for calls is generally more robust than TRANSIENT
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audioFocusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setOnAudioFocusChangeListener { focusChange ->
                        Log.d(TAG, "Audio focus changed: $focusChange")
                        // Optional: Handle focus changes during the call if needed
                    }
                    .build()
                val focusResult = audioManager!!.requestAudioFocus(audioFocusRequest!!)
                if (focusResult != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                    Log.w(TAG, "Audio focus not granted for speakerphone operation. Result: $focusResult")
                    // Proceed anyway, but log it. Some devices might still allow it.
                } else {
                    Log.d(TAG, "Audio focus granted for speakerphone operation.")
                }
            } else {
                @Suppress("DEPRECATION")
                val focusResult = audioManager!!.requestAudioFocus(
                    null, // No listener for older APIs here, or implement one
                    AudioManager.STREAM_VOICE_CALL,
                    AudioManager.AUDIOFOCUS_GAIN
                )
                if (focusResult != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                    Log.w(TAG, "Audio focus not granted for speakerphone (legacy). Result: $focusResult")
                } else {
                    Log.d(TAG, "Audio focus granted for speakerphone (legacy).")
                }
            }

            audioManager!!.mode = AudioManager.MODE_IN_CALL
            audioManager!!.isSpeakerphoneOn = on
            Log.d(
                TAG,
                "Speakerphone explicitly set to $on. Current AudioManager state: Speaker=${audioManager!!.isSpeakerphoneOn}, Mode=${audioManager!!.mode}"
            )

            // Verify
            if (audioManager!!.isSpeakerphoneOn == on) {
                result.success(true)
            } else {
                Log.w(
                    TAG,
                    "Speakerphone state did not change as expected. Expected: $on, Actual: ${audioManager!!.isSpeakerphoneOn}"
                )
                // Attempt to set it one more time after a very short delay
                Thread.sleep(100) // Brief pause
                audioManager!!.isSpeakerphoneOn = on
                if (audioManager!!.isSpeakerphoneOn == on) {
                    Log.d(TAG, "Speakerphone set to $on on second attempt.")
                    result.success(true)
                } else {
                    Log.w(TAG, "Speakerphone still not $on after second attempt.")
                    result.success(false) // Report actual failure
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to set speakerphone", e)
            result.error("SPEAKERPHONE_ERROR", "Failed to set speakerphone: ${e.message}", null)
        }
    }

    private fun initiateCallAndSpeaker(phoneNumber: String, result: MethodChannel.Result) {
        Log.d(TAG, "Initiating emergency call to $phoneNumber and attempting to turn on speakerphone.")
        try {
            // 1. Prepare Audio Environment
            if (audioManager == null) {
                audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            }

            // Request audio focus for the call
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audioFocusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setOnAudioFocusChangeListener { } // Simple listener
                    .build()
                val focusResult = audioManager!!.requestAudioFocus(audioFocusRequest!!)
                if (focusResult == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                    Log.d(TAG, "Audio focus GRANTED for call.")
                } else {
                    Log.w(TAG, "Audio focus NOT granted for call. Proceeding with call attempt.")
                }
            } else {
                @Suppress("DEPRECATION")
                audioManager!!.requestAudioFocus(null, AudioManager.STREAM_VOICE_CALL, AudioManager.AUDIOFOCUS_GAIN)
            }

            audioManager!!.mode = AudioManager.MODE_IN_CALL
            audioManager!!.isSpeakerphoneOn = true
            Log.d(TAG, "Speakerphone ON, Mode IN_CALL set before initiating call.")

            // 2. Initiate Call
            val callIntent = Intent(Intent.ACTION_CALL)
            callIntent.data = Uri.parse("tel:$phoneNumber")
            callIntent.flags = Intent.FLAG_ACTIVITY_NEW_TASK

            if (ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.CALL_PHONE
                ) == PackageManager.PERMISSION_GRANTED
            ) {
                startActivity(callIntent)
                Log.d(TAG, "Call intent started for $phoneNumber.")

                // Short delay to allow call state to potentially settle, then re-verify speakerphone
                // This is a common trick.
                Thread {
                    Thread.sleep(1500) // Wait 1.5 seconds
                    runOnUiThread {
                        if (audioManager != null) {
                            if (!audioManager!!.isSpeakerphoneOn) {
                                Log.w(TAG, "Speakerphone was NOT on after 1.5s. Re-asserting.")
                                audioManager!!.isSpeakerphoneOn = true
                            }
                            Log.d(TAG, "Speakerphone status after 1.5s delay: ${audioManager!!.isSpeakerphoneOn}")
                            result.success(audioManager!!.isSpeakerphoneOn) // Report final status
                        } else {
                            result.success(false)
                        }
                    }
                }.start()

            } else {
                Log.e(TAG, "CALL_PHONE permission not granted.")
                result.error("PERMISSION_ERROR", "CALL_PHONE permission not granted.", null)
            }

        } catch (e: Exception) {
            Log.e(TAG, "Failed to initiate call or set speakerphone: ${e.message}", e)
            result.error("CALL_SETUP_ERROR", "Failed to initiate call/speakerphone: ${e.message}", null)
        }
    }

    // Method to abandon audio focus when no longer needed (e.g., when Flutter side signals call ended or app is paused)
    // You might call this from Flutter if you have a "call ended" signal.
    fun abandonAudioFocus() {
        Log.d(TAG, "Attempting to abandon audio focus.")
        if (audioManager != null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (audioFocusRequest != null) {
                    audioManager!!.abandonAudioFocusRequest(audioFocusRequest!!)
                    Log.d(TAG, "Abandoned audio focus (Android O+).")
                }
            } else {
                @Suppress("DEPRECATION")
                audioManager!!.abandonAudioFocus(null) // Pass the same listener instance if you used one
                Log.d(TAG, "Abandoned audio focus (legacy).")
            }
            // Optionally reset mode, though system usually handles this when call ends
            // audioManager!!.mode = AudioManager.MODE_NORMAL
        }
    }


    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        Log.d(TAG, "onNewIntent called, action: ${intent.action}")
        setIntent(intent)
        handleScreenWakeUnlock()
    }

    private fun handleScreenWakeUnlock() {
        Log.d(TAG, "Attempting to wake/unlock screen.")
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(true)
                setTurnScreenOn(true)
            } else {
                @Suppress("DEPRECATION")
                window.addFlags(
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                            WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
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
    }

    override fun onPause() {
        super.onPause()
        Log.d(TAG, "onPause called.")
        // Consider abandoning audio focus if a call isn't active and app is paused.
        // However, for an ongoing call, you'd want to keep focus.
        // This needs careful handling based on your app's state.
        // if (!isCallActive) { // Hypothetical check
        //     abandonAudioFocus()
        // }
    }

    override fun onDestroy() {
        super.onDestroy()
        Log.d(TAG, "onDestroy called.")
        abandonAudioFocus() // Clean up focus when activity is destroyed
    }
}