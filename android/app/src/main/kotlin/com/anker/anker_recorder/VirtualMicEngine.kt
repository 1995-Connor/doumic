package com.anker.anker_recorder

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Build
import android.os.Looper
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean

/**
 * System-wide virtual microphone via AudioPolicy LOOP_BACK injector.
 *
 * AudioPolicy is a system API; we access it by reflection so the app compiles
 * against the public SDK. Must run as shell/root (Shizuku UserService) on
 * Android 13+ where shell has MODIFY_AUDIO_ROUTING.
 *
 * Pattern adapted from VirtuMic (MIT) / AOSP AudioPolicy loopback.
 */
@SuppressLint("PrivateApi")
class VirtualMicEngine(context: Context) : AutoCloseable {
    private val appContext = context.applicationContext
    private val audioManager =
        appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private var policy: Any? = null
    private var track: AudioTrack? = null
    private val running = AtomicBoolean(false)

    @Volatile
    var lastStatus: String = "idle"
        private set

    fun isRunning(): Boolean = running.get()

    @Synchronized
    fun start(): String {
        if (running.get()) return lastStatus
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            lastStatus = "需要 Android 13+ 才能注册系统虚拟麦克风"
            throw IllegalStateException(lastStatus)
        }

        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(OUT_RATE)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
            .build()

        val mixingRuleClass = Class.forName("android.media.audiopolicy.AudioMixingRule")
        val mixingRuleBuilderClass =
            Class.forName("android.media.audiopolicy.AudioMixingRule\$Builder")
        val audioMixClass = Class.forName("android.media.audiopolicy.AudioMix")
        val audioMixBuilderClass = Class.forName("android.media.audiopolicy.AudioMix\$Builder")
        val audioPolicyClass = Class.forName("android.media.audiopolicy.AudioPolicy")
        val audioPolicyBuilderClass =
            Class.forName("android.media.audiopolicy.AudioPolicy\$Builder")

        val ruleMatchPreset =
            mixingRuleClass.getField("RULE_MATCH_ATTRIBUTE_CAPTURE_PRESET").getInt(null)
        val mixRoleInjector = runCatching {
            mixingRuleClass.getField("MIX_ROLE_INJECTOR").getInt(null)
        }.getOrDefault(-1)
        val routeLoopBack = audioMixClass.getField("ROUTE_FLAG_LOOP_BACK").getInt(null)

        val ruleBuilder = mixingRuleBuilderClass.getConstructor().newInstance()
        if (mixRoleInjector >= 0) {
            runCatching {
                mixingRuleBuilderClass
                    .getMethod("setTargetMixRole", Int::class.javaPrimitiveType)
                    .invoke(ruleBuilder, mixRoleInjector)
            }
        }

        val addMixRule = mixingRuleBuilderClass.getMethod(
            "addMixRule",
            Int::class.javaPrimitiveType,
            Any::class.java,
        )
        val presets = intArrayOf(
            MediaRecorder.AudioSource.DEFAULT,
            MediaRecorder.AudioSource.MIC,
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            MediaRecorder.AudioSource.CAMCORDER,
            MediaRecorder.AudioSource.UNPROCESSED,
        )
        for (preset in presets) {
            val attrsBuilder = AudioAttributes.Builder()
            // setCapturePreset is @SystemApi — invoke via reflection.
            AudioAttributes.Builder::class.java
                .getMethod("setCapturePreset", Int::class.javaPrimitiveType)
                .invoke(attrsBuilder, preset)
            val attrs = attrsBuilder.build()
            addMixRule.invoke(ruleBuilder, ruleMatchPreset, attrs)
        }
        val rule = mixingRuleBuilderClass.getMethod("build").invoke(ruleBuilder)

        val mixBuilder = audioMixBuilderClass.getConstructor(mixingRuleClass).newInstance(rule)
        audioMixBuilderClass.getMethod("setFormat", AudioFormat::class.java)
            .invoke(mixBuilder, format)
        audioMixBuilderClass.getMethod("setRouteFlags", Int::class.javaPrimitiveType)
            .invoke(mixBuilder, routeLoopBack)
        val injectionMix = audioMixBuilderClass.getMethod("build").invoke(mixBuilder)

        val policyBuilder =
            audioPolicyBuilderClass.getConstructor(Context::class.java).newInstance(appContext)
        runCatching {
            audioPolicyBuilderClass
                .getMethod("setLooper", Looper::class.java)
                .invoke(policyBuilder, Looper.getMainLooper())
        }
        audioPolicyBuilderClass.getMethod("addMix", audioMixClass)
            .invoke(policyBuilder, injectionMix)
        val createdPolicy = audioPolicyBuilderClass.getMethod("build").invoke(policyBuilder)

        val registerResult = audioManager.javaClass
            .getMethod("registerAudioPolicy", audioPolicyClass)
            .invoke(audioManager, createdPolicy) as Int
        if (registerResult != 0) {
            lastStatus =
                "AudioPolicy 注册失败 ($registerResult)，请确认已通过 Shizuku/ADB 获得权限"
            throw IllegalStateException(lastStatus)
        }

        val createdTrack = try {
            createTrackSource(createdPolicy, injectionMix, audioPolicyClass, audioMixClass)
        } catch (e: Exception) {
            runCatching {
                audioManager.javaClass
                    .getMethod("unregisterAudioPolicy", audioPolicyClass)
                    .invoke(audioManager, createdPolicy)
            }
            lastStatus = "创建注入音轨失败: ${e.message}"
            throw IllegalStateException(lastStatus, e)
        }

        if (createdTrack.state != AudioTrack.STATE_INITIALIZED) {
            createdTrack.release()
            runCatching {
                audioManager.javaClass
                    .getMethod("unregisterAudioPolicy", audioPolicyClass)
                    .invoke(audioManager, createdPolicy)
            }
            lastStatus = "注入音轨未初始化"
            throw IllegalStateException(lastStatus)
        }

        createdTrack.play()
        policy = createdPolicy
        track = createdTrack
        running.set(true)
        lastStatus = "虚拟麦克风已开启（系统麦 → 录音豆）"
        Log.i(TAG, lastStatus)
        return lastStatus
    }

    private fun createTrackSource(
        policyObj: Any,
        mix: Any,
        policyClass: Class<*>,
        mixClass: Class<*>,
    ): AudioTrack {
        // Prefer AudioPolicy#createAudioTrackSource(AudioMix)
        val method = runCatching {
            policyClass.getMethod("createAudioTrackSource", mixClass)
        }.getOrNull()
        if (method != null) {
            return method.invoke(policyObj, mix) as AudioTrack
        }
        // Fallback: construct AudioTrack with mix registration tag (older paths).
        throw IllegalStateException("createAudioTrackSource unavailable on this ROM")
    }

    /** Accept PCM16 LE mono @ 16 kHz, upsample to 48 kHz, write injection track. */
    fun writePcm16k(pcm16k: ByteArray) {
        val t = track ?: return
        if (!running.get() || pcm16k.isEmpty()) return
        val up = upsample16kTo48k(pcm16k)
        var offset = 0
        while (offset < up.size) {
            val written = t.write(up, offset, up.size - offset)
            if (written <= 0) break
            offset += written
        }
    }

    @Synchronized
    override fun close() {
        running.set(false)
        runCatching { track?.stop() }
        runCatching { track?.release() }
        track = null
        val p = policy
        policy = null
        if (p != null) {
            runCatching {
                val policyClass = Class.forName("android.media.audiopolicy.AudioPolicy")
                audioManager.javaClass
                    .getMethod("unregisterAudioPolicy", policyClass)
                    .invoke(audioManager, p)
            }
        }
        lastStatus = "虚拟麦克风已关闭"
        Log.i(TAG, lastStatus)
    }

    companion object {
        private const val TAG = "VirtualMicEngine"
        const val OUT_RATE = 48000

        fun upsample16kTo48k(pcm: ByteArray): ByteArray {
            val inSamples = pcm.size / 2
            if (inSamples == 0) return ByteArray(0)
            val out = ByteArray(inSamples * 3 * 2)
            var oi = 0
            for (i in 0 until inSamples) {
                val s0 = (pcm[i * 2].toInt() and 0xff) or (pcm[i * 2 + 1].toInt() shl 8)
                val sample0 = if (s0 > 32767) s0 - 65536 else s0
                val sample1 = if (i + 1 < inSamples) {
                    val s1 =
                        (pcm[(i + 1) * 2].toInt() and 0xff) or (pcm[(i + 1) * 2 + 1].toInt() shl 8)
                    if (s1 > 32767) s1 - 65536 else s1
                } else {
                    sample0
                }
                for (k in 0 until 3) {
                    val t = k / 3.0
                    val v =
                        (sample0 + ((sample1 - sample0) * t)).toInt().coerceIn(-32768, 32767)
                    out[oi++] = (v and 0xff).toByte()
                    out[oi++] = ((v shr 8) and 0xff).toByte()
                }
            }
            return out
        }
    }
}
