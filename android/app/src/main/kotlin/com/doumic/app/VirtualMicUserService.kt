package com.doumic.app

import android.content.Context
import android.util.Log
import androidx.annotation.Keep

/**
 * Runs under Shizuku as the shell UID so [VirtualMicEngine] can register
 * AudioPolicy with MODIFY_AUDIO_ROUTING.
 */
@Keep
class VirtualMicUserService @Keep constructor(
    private val context: Context,
) : IVirtualMicUserService.Stub() {
    private val lock = Any()
    private var engine: VirtualMicEngine? = null

    override fun start(): String {
        synchronized(lock) {
            engine?.let { return it.lastStatus }
            val created = VirtualMicEngine(context)
            return try {
                val msg = created.start()
                engine = created
                msg
            } catch (e: Exception) {
                created.close()
                Log.e(TAG, "start failed", e)
                throw e
            }
        }
    }

    override fun stop() {
        synchronized(lock) {
            engine?.close()
            engine = null
        }
    }

    override fun writePcm16k(pcm: ByteArray?) {
        if (pcm == null || pcm.isEmpty()) return
        engine?.writePcm16k(pcm)
    }

    override fun isRunning(): Boolean = engine?.isRunning() == true

    override fun status(): String = engine?.lastStatus ?: "idle"

    override fun debugStatus(): String {
        val e = engine ?: return "idle"
        val snap = e.debugSnapshot()
        return "clients=${snap["clientsOnVirtualMic"]} injected=${snap["bytesInjected"]} " +
            "err=${snap["writeErrors"]} ring=${snap["ringFilled"]} | ${snap["message"]}"
    }

    fun destroy() {
        stop()
        Log.i(TAG, "UserService destroyed")
    }

    companion object {
        private const val TAG = "VirtualMicUserService"
    }
}
