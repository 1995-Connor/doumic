package com.doumic.app

import android.annotation.SuppressLint
import android.content.AttributionSource
import android.content.Context
import android.content.ContextWrapper
import android.os.Build
import android.os.Process
import androidx.annotation.RequiresApi

/**
 * Context that reports as [com.android.shell] (UID 2000).
 *
 * Shizuku UserService already runs as shell UID, but the Context Shizuku passes
 * is still the host app's package. AudioPolicy / AudioFlinger attribute checks
 * then see UID 2000 + package com.doumic.app and either refuse or silently keep
 * hardware mic routing — Typeless hears the phone mic while DouMic levels move.
 *
 * Pattern from scrcpy FakeContext / ShizuCallRecorder (reimplemented).
 */
@SuppressLint("PrivateApi")
class ShellFakeContext private constructor(
    base: Context,
) : ContextWrapper(base) {
    companion object {
        const val PACKAGE_NAME = "com.android.shell"

        @Volatile
        private var instance: ShellFakeContext? = null

        fun get(): ShellFakeContext {
            instance?.let { return it }
            synchronized(this) {
                instance?.let { return it }
                val created = ShellFakeContext(ShellWorkarounds.getSystemContext())
                instance = created
                return created
            }
        }
    }

    override fun getPackageName(): String = PACKAGE_NAME

    override fun getOpPackageName(): String = PACKAGE_NAME

    override fun getApplicationContext(): Context = this

    override fun createPackageContext(packageName: String, flags: Int): Context = this

    @RequiresApi(Build.VERSION_CODES.S)
    override fun getAttributionSource(): AttributionSource {
        return AttributionSource.Builder(Process.SHELL_UID)
            .setPackageName(PACKAGE_NAME)
            .build()
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    override fun getDeviceId(): Int = Context.DEVICE_ID_DEFAULT
}
