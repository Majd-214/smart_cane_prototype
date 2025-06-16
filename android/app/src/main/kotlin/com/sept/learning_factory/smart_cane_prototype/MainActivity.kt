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
import android.speech.tts.TextToSpeech
import android.util.Log
import android.view.WindowManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.*

class MainActivity : FlutterFragmentActivity(), TextToSpeech.OnInitListener {
    private val AUDIO_CHANNEL = "com.sept.learning_factory.smart_cane_prototype/audio"
    private val CALL_CHANNEL = "com.sept.learning_factory.smart_cane_prototype/call"
    private val TAG = "MainActivitySmartCane"

    private var audioManager: AudioManager? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private var tts: TextToSpeech? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        tts = TextToSpeech(this, this)
        Log.d(TAG, "onCreate called, intent action: ${intent?.action}")
        handleScreenWakeUnlock()
    }

    override fun onInit(status: Int) {
        if (status == TextToSpeech.SUCCESS) {
            val result = tts?.setLanguage(Locale.US)
            if (result == TextToSpeech.LANG_MISSING_DATA || result == TextToSpeech.LANG_NOT_SUPPORTED) {
                Log.e(TAG, "TTS language is not supported")
            } else {
                Log.d(TAG, "TTS Engine Initialized Successfully")
            }
        } else {
            Log.e(TAG, "TTS Initialization failed")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Log.d(TAG, "configureFlutterEngine called")

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setSpeakerphoneOn" -> {
                    val on = call.argument<Boolean>("on")
                    if (on != null) {
                        setSpeakerphoneNative(on, result)
                    } else {
                        result.error("INVALID_ARGUMENT", "Argument 'on' is null", null)
                    }
                }

                "speakMessage" -> {
                    val message = call.argument<String>("message")
                    if (message != null) {
                        speakMessageNative(message, result)
                    } else {
                        result.error("INVALID_ARGUMENT", "Argument 'message' is null", null)
                    }
                }

                else -> result.notImplemented()
            }
        }

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

    private fun speakMessageNative(message: String, result: MethodChannel.Result) {
        if (tts == null) {
            result.error("TTS_ERROR", "TTS engine not initialized", null)
            return
        }

        try {
            // This is the key part: set the audio stream to the voice call stream
            val params = Bundle()
            params.putInt(TextToSpeech.Engine.KEY_PARAM_STREAM, AudioManager.STREAM_VOICE_CALL)
            tts?.speak(message, TextToSpeech.QUEUE_FLUSH, params, null)
            Log.d(TAG, "TTS speak command issued for message: $message")
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "TTS speak command failed", e)
            result.error("TTS_ERROR", "Failed to speak message: ${e.message}", null)
        }
    }

    private fun setSpeakerphoneNative(on: Boolean, result: MethodChannel.Result) {
        // This function remains largely the same
        try {
            if (audioManager == null) {
                audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audioFocusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setOnAudioFocusChangeListener {}.build()
                audioManager!!.requestAudioFocus(audioFocusRequest!!)
            } else {
                @Suppress("DEPRECATION")
                audioManager!!.requestAudioFocus(null, AudioManager.STREAM_VOICE_CALL, AudioManager.AUDIOFOCUS_GAIN)
            }
            audioManager!!.mode = AudioManager.MODE_IN_CALL
            audioManager!!.isSpeakerphoneOn = on
            result.success(audioManager!!.isSpeakerphoneOn == on)
        } catch (e: Exception) {
            result.error("SPEAKERPHONE_ERROR", "Failed to set speakerphone: ${e.message}", null)
        }
    }

    private fun initiateCallAndSpeaker(phoneNumber: String, result: MethodChannel.Result) {
        Log.d(TAG, "Initiating emergency call to $phoneNumber")
        try {
            if (audioManager == null) audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audioFocusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN).build()
                audioManager!!.requestAudioFocus(audioFocusRequest!!)
            } else {
                @Suppress("DEPRECATION")
                audioManager!!.requestAudioFocus(null, AudioManager.STREAM_VOICE_CALL, AudioManager.AUDIOFOCUS_GAIN)
            }

            audioManager!!.mode = AudioManager.MODE_IN_CALL
            audioManager!!.isSpeakerphoneOn = true
            Log.d(TAG, "Speakerphone ON, Mode IN_CALL set before initiating call.")

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

                Thread {
                    Thread.sleep(1500)
                    runOnUiThread {
                        if (audioManager != null && !audioManager!!.isSpeakerphoneOn) {
                            Log.w(TAG, "Speakerphone was NOT on after 1.5s. Re-asserting.")
                            audioManager!!.isSpeakerphoneOn = true
                        }
                        result.success(audioManager?.isSpeakerphoneOn ?: false)
                    }
                }.start()
            } else {
                result.error("PERMISSION_ERROR", "CALL_PHONE permission not granted.", null)
            }
        } catch (e: Exception) {
            result.error("CALL_SETUP_ERROR", "Failed to initiate call/speakerphone: ${e.message}", null)
        }
    }

    fun abandonAudioFocus() {
        Log.d(TAG, "Attempting to abandon audio focus.")
        if (audioManager != null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (audioFocusRequest != null) {
                    audioManager!!.abandonAudioFocusRequest(audioFocusRequest!!)
                }
            } else {
                @Suppress("DEPRECATION")
                audioManager!!.abandonAudioFocus(null)
            }
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
        } catch (e: Exception) {
            Log.e(TAG, "Error in handleScreenWakeUnlock: ${e.message}")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        Log.d(TAG, "onDestroy called.")
        if (tts != null) {
            tts!!.stop()
            tts!!.shutdown()
            Log.d(TAG, "TTS Engine shutdown.")
        }
        abandonAudioFocus()
    }
}