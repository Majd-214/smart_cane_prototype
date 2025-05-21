package com.sept.learning_factory.smart_cane_prototype

import android.content.Context
import android.media.AudioManager
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val AUDIO_CHANNEL = "com.sept.learning_factory.smart_cane_prototype/audio"
    private val TAG = "MainActivityAudio" // For logging

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "setSpeakerphoneOn") {
                val on = call.argument<Boolean>("on")
                if (on != null) {
                    try {
                        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        if (on) {
                            // For turning speaker ON
                            Log.d(TAG, "Turning speakerphone ON")
                            // It's often crucial to set the mode before turning speakerphone on,
                            // especially if a call is active or about to be.
                            // MODE_IN_COMMUNICATION is generally preferred for VoIP or SIP calls,
                            // MODE_IN_CALL is for traditional phone calls.
                            // If the call is already established by flutter_phone_direct_caller,
                            // MODE_IN_CALL should be active.
                            // Setting it explicitly can sometimes help.

                            // Persist an an audio mode until it is abandonned
                            // if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            // audioManager.requestAudioFocus(null, AudioManager.STREAM_VOICE_CALL, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                            // }

                            audioManager.mode = AudioManager.MODE_IN_CALL // Or MODE_IN_COMMUNICATION
                            audioManager.isSpeakerphoneOn = true
                            Log.d(
                                TAG,
                                "Speakerphone is now: ${audioManager.isSpeakerphoneOn}, Mode: ${audioManager.mode}"
                            )

                        } else {
                            // For turning speaker OFF (optional, if you need to control it off too)
                            Log.d(TAG, "Turning speakerphone OFF")
                            audioManager.isSpeakerphoneOn = false
                            // Optionally reset mode if you changed it
                            // audioManager.mode = AudioManager.MODE_NORMAL
                            Log.d(TAG, "Speakerphone is now: ${audioManager.isSpeakerphoneOn}")
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to set speakerphone: ${e.message}", e)
                        result.error("SPEAKERPHONE_ERROR", "Failed to set speakerphone: ${e.message}", null)
                    }
                } else {
                    Log.w(TAG, "Argument 'on' is null for setSpeakerphoneOn")
                    result.error("INVALID_ARGUMENT", "Argument 'on' is null for setSpeakerphoneOn", null)
                }
            } else {
                result.notImplemented()
            }
        }
    }
}