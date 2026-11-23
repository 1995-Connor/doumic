package com.doumic.app

import android.annotation.SuppressLint
import android.content.Context
import android.util.Log

/**
 * Minimal ActivityThread / system-context bootstrap for a Shizuku shell process.
 *
 * Inspired by scrcpy Workarounds + ShizuCallRecorder ShellWorkarounds (GPL-3.0 ideas;
 * this file is a short original reimplementation, not a verbatim copy).
 */
@SuppressLint("PrivateApi", "DiscouragedPrivateApi")
object ShellWorkarounds {
    private const val TAG = "ShellWorkarounds"

    @Volatile
    private var systemContext: Context? = null

    fun getSystemContext(): Context {
        systemContext?.let { return it }
        synchronized(this) {
            systemContext?.let { return it }
            val ctx = resolveSystemContext()
            systemContext = ctx
            return ctx
        }
    }

    private fun resolveSystemContext(): Context {
        val activityThreadClass = Class.forName("android.app.ActivityThread")
        val current = runCatching {
            activityThreadClass.getDeclaredMethod("currentActivityThread").invoke(null)
        }.getOrNull()
        val thread = current ?: run {
            Log.i(TAG, "No ActivityThread yet — creating systemMain()")
            activityThreadClass.getDeclaredMethod("systemMain").invoke(null)
                ?: error("ActivityThread.systemMain() returned null")
        }
        val getSystemContext = activityThreadClass.getDeclaredMethod("getSystemContext")
        return getSystemContext.invoke(thread) as Context
    }
}
