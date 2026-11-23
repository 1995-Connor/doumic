package com.doumic.app

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecordingConfiguration
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * System-wide virtual microphone via AudioPolicy LOOP_BACK injector.
 *
 * Critical details (AOSP / LineageOS MicInjector / VirtuMic):
 * - Mix must be MIX_ROLE_INJECTOR + ROUTE_FLAG_LOOP_BACK
 * - [setPersistent(true)] keeps the remote-submix attached even between writes;
 *   without it, capturing apps often keep reading the **hardware** mic
 * - AudioTrack must be fed continuously; underruns make IME meters stay flat
 *   even while DouMic's own level UI (pre-inject) still moves
 *
 * Must run as shell/root (Shizuku UserService) on Android 13+.
 */
@SuppressLint("PrivateApi")
class VirtualMicEngine(context: Context) : AutoCloseable {
    private val appContext = context.applicationContext
    private val audioManager =
        appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private var policy: Any? = null
    private var track: AudioTrack? = null
    private val running = AtomicBoolean(false)

    private val pcmLock = ReentrantLock()
    private val pcmNotEmpty = pcmLock.newCondition()
    // ~2 s of 48 kHz mono PCM16
    private val ring = ByteArray(RING_BYTES)
    private var ringRead = 0
    private var ringWrite = 0
    private var ringFilled = 0

    private var writerThread: Thread? = null
    private var callbackThread: HandlerThread? = null
    private var recordingCallback: AudioManager.AudioRecordingCallback? = null

    private val bytesInjected = AtomicLong(0)
    private val writeErrors = AtomicLong(0)

    @Volatile
    private var clientsOnVirtualMic = 0

    @Volatile
    var lastStatus: String = "idle"
        private set

    fun isRunning(): Boolean = running.get()

    fun debugSnapshot(): Map<String, Any> = mapOf(
        "running" to running.get(),
        "bytesInjected" to bytesInjected.get(),
        "writeErrors" to writeErrors.get(),
        "ringFilled" to ringFilled,
        "clientsOnVirtualMic" to clientsOnVirtualMic,
        "message" to lastStatus,
    )

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
            }.onFailure { Log.w(TAG, "setTargetMixRole failed", it) }
        }

        val addMixRule = mixingRuleBuilderClass.getMethod(
            "addMixRule",
            Int::class.javaPrimitiveType,
            Any::class.java,
        )
        for (preset in capturePresets()) {
            val attrsBuilder = AudioAttributes.Builder()
            AudioAttributes.Builder::class.java
                .getMethod("setCapturePreset", Int::class.javaPrimitiveType)
                .invoke(attrsBuilder, preset)
            addMixRule.invoke(ruleBuilder, ruleMatchPreset, attrsBuilder.build())
        }
        val rule = mixingRuleBuilderClass.getMethod("build").invoke(ruleBuilder)

        val mixBuilder = audioMixBuilderClass.getConstructor(mixingRuleClass).newInstance(rule)
        audioMixBuilderClass.getMethod("setFormat", AudioFormat::class.java)
            .invoke(mixBuilder, format)
        audioMixBuilderClass.getMethod("setRouteFlags", Int::class.javaPrimitiveType)
            .invoke(mixBuilder, routeLoopBack)
        // Without persistence, captures often never attach to the injector and
        // keep reading the built-in mic — Typeless bars stay flat while DouMic moves.
        runCatching {
            audioMixBuilderClass
                .getMethod("setPersistent", Boolean::class.javaPrimitiveType)
                .invoke(mixBuilder, true)
            Log.i(TAG, "AudioMix setPersistent(true)")
        }.onFailure {
            Log.w(TAG, "setPersistent unavailable: ${it.message}")
        }
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
            unregisterPolicy(createdPolicy, audioPolicyClass)
            lastStatus = "创建注入音轨失败: ${e.message}"
            throw IllegalStateException(lastStatus, e)
        }

        if (createdTrack.state != AudioTrack.STATE_INITIALIZED) {
            createdTrack.release()
            unregisterPolicy(createdPolicy, audioPolicyClass)
            lastStatus = "注入音轨未初始化"
            throw IllegalStateException(lastStatus)
        }

        runCatching { createdTrack.setVolume(1.0f) }
        // Prefill a little silence so the first client capture doesn't see underrun.
        val prefill = ByteArray(createdTrack.bufferSizeInFrames.coerceAtLeast(OUT_RATE / 50) * 2)
        createdTrack.write(prefill, 0, prefill.size)
        createdTrack.play()

        policy = createdPolicy
        track = createdTrack
        bytesInjected.set(0)
        writeErrors.set(0)
        pcmLock.withLock {
            ringRead = 0
            ringWrite = 0
            ringFilled = 0
        }
        running.set(true)
        startWriterLoop()
        startRecordingWatch()
        lastStatus = "虚拟麦克风已开启（持续注入中）"
        Log.i(
            TAG,
            "$lastStatus trackBuf=${createdTrack.bufferSizeInFrames} " +
                "session=${createdTrack.audioSessionId}",
        )
        return lastStatus
    }

    /** Enqueue PCM16 LE mono @ 16 kHz; writer thread upsamples + feeds AudioTrack. */
    fun writePcm16k(pcm16k: ByteArray) {
        if (!running.get() || pcm16k.isEmpty()) return
        val up = upsample16kTo48k(pcm16k)
        pcmLock.withLock {
            var offset = 0
            while (offset < up.size) {
                if (ringFilled >= ring.size) {
                    // Drop oldest to keep latency bounded under BLE bursts.
                    val drop = minOf(FRAME_BYTES, ringFilled)
                    ringRead = (ringRead + drop) % ring.size
                    ringFilled -= drop
                }
                val space = ring.size - ringFilled
                if (space <= 0) break
                val n = minOf(space, up.size - offset, ring.size - ringWrite)
                System.arraycopy(up, offset, ring, ringWrite, n)
                ringWrite = (ringWrite + n) % ring.size
                ringFilled += n
                offset += n
            }
            pcmNotEmpty.signalAll()
        }
    }

    private fun startWriterLoop() {
        writerThread = Thread({
            val silence = ByteArray(FRAME_BYTES)
            val chunk = ByteArray(FRAME_BYTES)
            android.os.Process.setThreadPriority(
                android.os.Process.THREAD_PRIORITY_URGENT_AUDIO,
            )
            while (running.get()) {
                val t = track
                if (t == null) break
                var toWrite = 0
                pcmLock.withLock {
                    if (ringFilled >= FRAME_BYTES) {
                        val first = minOf(FRAME_BYTES, ring.size - ringRead)
                        System.arraycopy(ring, ringRead, chunk, 0, first)
                        if (first < FRAME_BYTES) {
                            System.arraycopy(ring, 0, chunk, first, FRAME_BYTES - first)
                        }
                        ringRead = (ringRead + FRAME_BYTES) % ring.size
                        ringFilled -= FRAME_BYTES
                        toWrite = FRAME_BYTES
                    }
                }
                val buf = if (toWrite == FRAME_BYTES) chunk else silence
                val written = try {
                    t.write(buf, 0, FRAME_BYTES, AudioTrack.WRITE_BLOCKING)
                } catch (e: Exception) {
                    writeErrors.incrementAndGet()
                    Log.w(TAG, "track.write failed: ${e.message}")
                    -1
                }
                if (written > 0) {
                    bytesInjected.addAndGet(written.toLong())
                } else if (written < 0) {
                    writeErrors.incrementAndGet()
                    try {
                        Thread.sleep(5)
                    } catch (_: InterruptedException) {
                        break
                    }
                }
            }
            Log.i(TAG, "writer loop exit injected=${bytesInjected.get()} err=${writeErrors.get()}")
        }, "DouMicInject").also {
            it.isDaemon = true
            it.start()
        }
    }

    private fun startRecordingWatch() {
        val thread = HandlerThread("DouMicRecWatch").also { it.start() }
        callbackThread = thread
        val handler = Handler(thread.looper)
        val cb = object : AudioManager.AudioRecordingCallback() {
            override fun onRecordingConfigChanged(configs: List<AudioRecordingConfiguration>) {
                var hits = 0
                for (c in configs) {
                    val dev = c.audioDevice ?: continue
                    val onSubmix = dev.type == AudioDeviceInfo.TYPE_REMOTE_SUBMIX
                    val silenced = runCatching { c.isClientSilenced }.getOrDefault(false)
                    if (onSubmix && !silenced &&
                        c.clientAudioSource != MediaRecorder.AudioSource.REMOTE_SUBMIX
                    ) {
                        hits++
                        val uid = runCatching {
                            c.javaClass.getMethod("getClientUid").invoke(c) as Int
                        }.getOrDefault(-1)
                        Log.i(
                            TAG,
                            "capture via virtual mic: uid=$uid src=${c.clientAudioSource}",
                        )
                    }
                }
                clientsOnVirtualMic = hits
                if (hits > 0) {
                    lastStatus = "虚拟麦工作中 · 有 $hits 个 App 正在从注入通路采麦"
                } else if (running.get()) {
                    lastStatus = "虚拟麦克风已开启（持续注入中）· 尚无 App 走注入通路"
                }
            }
        }
        recordingCallback = cb
        runCatching {
            audioManager.registerAudioRecordingCallback(cb, handler)
            cb.onRecordingConfigChanged(audioManager.activeRecordingConfigurations)
        }.onFailure { Log.w(TAG, "registerAudioRecordingCallback: ${it.message}") }
    }

    private fun createTrackSource(
        policyObj: Any,
        mix: Any,
        policyClass: Class<*>,
        mixClass: Class<*>,
    ): AudioTrack {
        val method = runCatching {
            policyClass.getMethod("createAudioTrackSource", mixClass)
        }.getOrNull()
        if (method != null) {
            return method.invoke(policyObj, mix) as AudioTrack
        }
        throw IllegalStateException("createAudioTrackSource unavailable on this ROM")
    }

    private fun unregisterPolicy(policyObj: Any, policyClass: Class<*>) {
        runCatching {
            audioManager.javaClass
                .getMethod("unregisterAudioPolicy", policyClass)
                .invoke(audioManager, policyObj)
        }
    }

    @Synchronized
    override fun close() {
        running.set(false)
        pcmLock.withLock { pcmNotEmpty.signalAll() }
        runCatching { writerThread?.join(500) }
        writerThread = null
        recordingCallback?.let { cb ->
            runCatching { audioManager.unregisterAudioRecordingCallback(cb) }
        }
        recordingCallback = null
        callbackThread?.quitSafely()
        callbackThread = null
        runCatching { track?.pause() }
        runCatching { track?.flush() }
        runCatching { track?.stop() }
        runCatching { track?.release() }
        track = null
        val p = policy
        policy = null
        if (p != null) {
            runCatching {
                val policyClass = Class.forName("android.media.audiopolicy.AudioPolicy")
                unregisterPolicy(p, policyClass)
            }
        }
        clientsOnVirtualMic = 0
        lastStatus = "虚拟麦克风已关闭"
        Log.i(TAG, lastStatus)
    }

    companion object {
        private const val TAG = "VirtualMicEngine"
        const val OUT_RATE = 48000
        // 20 ms @ 48 kHz mono PCM16
        private const val FRAME_BYTES = OUT_RATE / 50 * 2
        private const val RING_BYTES = OUT_RATE * 2 * 2

        private fun capturePresets(): IntArray {
            val list = mutableListOf(
                MediaRecorder.AudioSource.DEFAULT,
                MediaRecorder.AudioSource.MIC,
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                MediaRecorder.AudioSource.CAMCORDER,
                MediaRecorder.AudioSource.UNPROCESSED,
            )
            runCatching {
                list += MediaRecorder.AudioSource::class.java
                    .getField("VOICE_PERFORMANCE").getInt(null)
            }
            // Hidden HOTWORD — some IMEs / assistants use it.
            runCatching {
                list += MediaRecorder.AudioSource::class.java
                    .getField("HOTWORD").getInt(null)
            }.onFailure {
                list += 1999
            }
            return list.distinct().toIntArray()
        }

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
