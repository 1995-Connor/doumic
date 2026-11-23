package com.doumic.app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.util.Log
import rikka.shizuku.Shizuku
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Binds a Shizuku UserService that injects D3200 PCM as the system microphone.
 */
object VirtualMicController {
    private const val TAG = "VirtualMicController"
    private const val MIN_SHIZUKU = 11
    private const val SHIZUKU_PACKAGE = "moe.shizuku.privileged.api"

    private val enabled = AtomicBoolean(false)
    private val running = AtomicBoolean(false)
    private val serviceRef = AtomicReference<IVirtualMicUserService?>(null)

    @Volatile
    var statusMessage: String = "未启动"
        private set

    @Volatile
    private var appContext: Context? = null

    private val permissionResultListener =
        Shizuku.OnRequestPermissionResultListener { _, grantResult ->
            if (grantResult == PackageManager.PERMISSION_GRANTED) {
                statusMessage = "Shizuku 授权成功，可开启虚拟麦克风"
            } else {
                statusMessage = "Shizuku 授权被拒绝"
            }
            notifyFlutter()
        }

    private val userServiceArgs by lazy {
        Shizuku.UserServiceArgs(
            ComponentName(
                "com.doumic.app",
                VirtualMicUserService::class.java.name,
            ),
        )
            .daemon(false)
            .processNameSuffix("vmic")
            .debuggable(false)
            // Bump when AIDL changes so Shizuku restarts the UserService.
            .version(3)
    }

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(componentName: ComponentName, binder: IBinder?) {
            if (binder == null || !binder.pingBinder()) {
                statusMessage = "Shizuku 服务连接失败"
                notifyFlutter()
                return
            }
            val svc = IVirtualMicUserService.Stub.asInterface(binder)
            serviceRef.set(svc)
            try {
                val msg = svc.start()
                running.set(true)
                statusMessage = msg
                Log.i(TAG, "virtual mic started: $msg")
            } catch (e: Exception) {
                running.set(false)
                statusMessage = "启动虚拟麦失败: ${e.message}"
                Log.e(TAG, "start failed", e)
            }
            notifyFlutter()
        }

        override fun onServiceDisconnected(componentName: ComponentName) {
            serviceRef.set(null)
            running.set(false)
            statusMessage = "Shizuku 服务已断开"
            notifyFlutter()
        }
    }

    private val binderDeadListener = Shizuku.OnBinderDeadListener {
        serviceRef.set(null)
        running.set(false)
        statusMessage = "Shizuku 已停止，请重新启动 Shizuku"
        notifyFlutter()
    }

    fun init(context: Context) {
        appContext = context.applicationContext
        runCatching { Shizuku.addBinderDeadListener(binderDeadListener) }
        runCatching { Shizuku.addRequestPermissionResultListener(permissionResultListener) }
    }

    fun isShizukuInstalled(): Boolean {
        val ctx = appContext ?: return false
        return runCatching {
            ctx.packageManager.getPackageInfo(SHIZUKU_PACKAGE, 0)
            true
        }.getOrDefault(false)
    }

    fun shizukuState(): String {
        return try {
            when {
                Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ->
                    "需要 Android 13 及以上"
                !isShizukuInstalled() ->
                    "未安装 Shizuku，请先从应用商店安装"
                !Shizuku.pingBinder() ->
                    "Shizuku 未在运行：请先「配对」再点「启动」（配对≠启动）"
                Shizuku.getVersion() < MIN_SHIZUKU ->
                    "Shizuku 版本过旧，请升级"
                Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED ->
                    "Shizuku 已运行，但豆麦尚未授权（点下方「授权」）"
                else -> "Shizuku 已就绪"
            }
        } catch (e: Exception) {
            "Shizuku 不可用: ${e.message}"
        }
    }

    fun requestShizukuPermission(requestCode: Int = 1001): Boolean {
        return try {
            if (!Shizuku.pingBinder()) {
                statusMessage =
                    "还不能授权：Shizuku 未运行。请在 Shizuku 里先配对，再点启动"
                notifyFlutter()
                return false
            }
            if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
                statusMessage = "Shizuku 已授权"
                notifyFlutter()
                return true
            }
            Shizuku.requestPermission(requestCode)
            true
        } catch (e: Exception) {
            statusMessage = "请求 Shizuku 权限失败: ${e.message}"
            notifyFlutter()
            false
        }
    }

    fun openShizukuApp(): Boolean {
        val ctx = appContext ?: return false
        return try {
            val launch = ctx.packageManager.getLaunchIntentForPackage(SHIZUKU_PACKAGE)
            if (launch != null) {
                launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                ctx.startActivity(launch)
                true
            } else {
                // Fall back to store / package page.
                val market = Intent(
                    Intent.ACTION_VIEW,
                    Uri.parse("market://details?id=$SHIZUKU_PACKAGE"),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                ctx.startActivity(market)
                true
            }
        } catch (e: Exception) {
            statusMessage = "无法打开 Shizuku: ${e.message}"
            notifyFlutter()
            false
        }
    }

    fun openDeveloperOptions(): Boolean {
        val ctx = appContext ?: return false
        return try {
            ctx.startActivity(
                Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            true
        } catch (e: Exception) {
            statusMessage = "无法打开开发者选项: ${e.message}"
            notifyFlutter()
            false
        }
    }

    fun setEnabled(on: Boolean) {
        enabled.set(on)
        if (on) start() else stop()
    }

    fun isRunning(): Boolean = running.get()

    fun liveStatus(): String {
        return try {
            serviceRef.get()?.status()?.takeIf { it.isNotBlank() } ?: statusMessage
        } catch (_: Exception) {
            statusMessage
        }
    }

    fun debugStatus(): String {
        return try {
            serviceRef.get()?.debugStatus() ?: statusMessage
        } catch (e: Exception) {
            "debug unavailable: ${e.message}"
        }
    }

    fun writePcm16k(pcm: ByteArray) {
        if (!enabled.get() || !running.get()) return
        try {
            serviceRef.get()?.writePcm16k(pcm)
        } catch (e: Exception) {
            Log.w(TAG, "writePcm failed: ${e.message}")
        }
    }

    private fun start() {
        statusMessage = shizukuState()
        if (statusMessage != "Shizuku 已就绪") {
            notifyFlutter()
            return
        }
        if (serviceRef.get() != null) {
            try {
                statusMessage = serviceRef.get()!!.start()
                running.set(true)
            } catch (e: Exception) {
                statusMessage = "启动失败: ${e.message}"
                running.set(false)
            }
            notifyFlutter()
            return
        }
        statusMessage = "正在通过 Shizuku 注册系统虚拟麦克风…"
        notifyFlutter()
        try {
            Shizuku.bindUserService(userServiceArgs, connection)
        } catch (e: Exception) {
            statusMessage = "绑定 Shizuku 失败: ${e.message}"
            Log.e(TAG, "bind failed", e)
            notifyFlutter()
        }
    }

    private fun stop() {
        try {
            serviceRef.get()?.stop()
        } catch (_: Exception) {
        }
        runCatching { Shizuku.unbindUserService(userServiceArgs, connection, true) }
        serviceRef.set(null)
        running.set(false)
        statusMessage = "虚拟麦克风已关闭"
        notifyFlutter()
    }

    private fun notifyFlutter() {
        MicBridgeHost.emitStatus(statusMessage, running.get())
    }
}
