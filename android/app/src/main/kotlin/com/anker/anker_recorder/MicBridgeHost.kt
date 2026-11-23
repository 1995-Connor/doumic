package com.anker.anker_recorder

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Shared host between Flutter, [MicBridgeService], and [BeanMicImeService].
 *
 * Holds the latest PCM ring buffer and relays dictation text / control events.
 */
object MicBridgeHost {
    const val METHOD_CHANNEL = "com.anker.anker_recorder/mic_bridge"
    const val EVENT_CHANNEL = "com.anker.anker_recorder/mic_bridge_events"

    private val mainHandler = Handler(Looper.getMainLooper())
    private val enabled = AtomicBoolean(false)
    private val dictating = AtomicBoolean(false)

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    /** Newest PCM16 LE mono bytes (16 kHz). Cap ~2s @ 16kHz mono = 64KB. */
    private val pcmLock = Any()
    private var pcmRing = ByteArray(64 * 1024)
    private var pcmWrite = 0
    private var pcmFilled = 0

    private val partialText = AtomicReference("")
    private val finalText = AtomicReference<String?>(null)

    var textListener: ((partial: String?, finalText: String?) -> Unit)? = null

    fun isEnabled(): Boolean = enabled.get()

    fun isDictating(): Boolean = dictating.get()

    fun setMethodCallHandler(): MethodChannel.MethodCallHandler {
        return MethodChannel.MethodCallHandler { call, result ->
            try {
                handleMethod(call, result)
            } catch (e: Exception) {
                result.error("mic_bridge", e.message, null)
            }
        }
    }

    fun setEventStreamHandler(): EventChannel.StreamHandler {
        return object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        }
    }

    private fun handleMethod(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isReady" -> result.success(true)
            "setEnabled" -> {
                val on = call.argument<Boolean>("enabled") == true
                enabled.set(on)
                result.success(null)
            }
            "pushPcm" -> {
                val bytes = call.arguments as? ByteArray
                if (bytes != null) pushPcm(bytes)
                result.success(null)
            }
            "pushPartialText" -> {
                val text = call.argument<String>("text").orEmpty()
                partialText.set(text)
                finalText.set(null)
                mainHandler.post { textListener?.invoke(text, null) }
                result.success(null)
            }
            "pushFinalText" -> {
                val text = call.argument<String>("text").orEmpty()
                partialText.set(text)
                finalText.set(text)
                mainHandler.post { textListener?.invoke(text, text) }
                result.success(null)
            }
            "openImeSettings" -> {
                val ctx = appContext
                if (ctx != null) {
                    ctx.startActivity(
                        Intent(Settings.ACTION_INPUT_METHOD_SETTINGS).addFlags(
                            Intent.FLAG_ACTIVITY_NEW_TASK,
                        ),
                    )
                }
                result.success(null)
            }
            "showImePicker" -> {
                val ctx = appContext
                if (ctx != null) {
                    val imm = ctx.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
                    imm.showInputMethodPicker()
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    @Volatile
    var appContext: Context? = null

    fun pushPcm(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        synchronized(pcmLock) {
            var offset = 0
            while (offset < bytes.size) {
                val space = pcmRing.size - pcmWrite
                val n = minOf(space, bytes.size - offset)
                System.arraycopy(bytes, offset, pcmRing, pcmWrite, n)
                pcmWrite = (pcmWrite + n) % pcmRing.size
                pcmFilled = minOf(pcmRing.size, pcmFilled + n)
                offset += n
            }
        }
    }

    /** Copy up to [maxBytes] of the newest PCM into [out]; returns bytes copied. */
    fun readLatestPcm(out: ByteArray, maxBytes: Int): Int {
        synchronized(pcmLock) {
            val n = minOf(maxBytes, out.size, pcmFilled)
            if (n <= 0) return 0
            val start = (pcmWrite - n + pcmRing.size) % pcmRing.size
            val first = minOf(n, pcmRing.size - start)
            System.arraycopy(pcmRing, start, out, 0, first)
            if (first < n) {
                System.arraycopy(pcmRing, 0, out, first, n - first)
            }
            return n
        }
    }

    fun clearPcm() {
        synchronized(pcmLock) {
            pcmWrite = 0
            pcmFilled = 0
        }
    }

    fun requestDictationStart() {
        if (!dictating.compareAndSet(false, true)) return
        finalText.set(null)
        partialText.set("")
        emit(mapOf("type" to "dictationStart"))
    }

    fun requestDictationStop() {
        if (!dictating.compareAndSet(true, false)) return
        emit(mapOf("type" to "dictationStop"))
    }

    fun consumeFinalText(): String? = finalText.getAndSet(null)

    fun currentPartial(): String = partialText.get()

    private fun emit(event: Map<String, Any?>) {
        mainHandler.post {
            try {
                eventSink?.success(event)
            } catch (_: Exception) {
            }
        }
    }
}
