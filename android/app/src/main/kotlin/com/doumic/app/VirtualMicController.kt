package com.doumic.app

import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
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

    private val enabled = AtomicBoolean(false)
    private val running = AtomicBoolean(false)
    private val serviceRef = AtomicReference<IVirtualMicUserService?>(null)

    @Volatile
    var statusMessage: String = "未启动"
        private set

    @Volatile
    private var appContext: Context? = null

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
            .version(1)
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
    }

    fun shizukuState(): String {
        return try {
            when {
                Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ->
                    "需要 Android 13 及以上"
                !Shizuku.pingBinder() ->
                    "请先安装并启动 Shizuku（无线调试）"
                Shizuku.getVersion() < MIN_SHIZUKU ->
                    "Shizuku 版本过旧，请升级"
                Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED ->
                    "需要授权 Shizuku（点下方按钮）"
                else -> "Shizuku 已就绪"
            }
        } catch (e: Exception) {
            "Shizuku 不可用: ${e.message}"
        }
    }

    fun requestShizukuPermission(requestCode: Int = 1001): Boolean {
        return try {
            if (!Shizuku.pingBinder()) return false
            if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) return true
            Shizuku.requestPermission(requestCode)
            true
        } catch (e: Exception) {
            statusMessage = "请求 Shizuku 权限失败: ${e.message}"
            false
        }
    }

    fun setEnabled(on: Boolean) {
        enabled.set(on)
        if (on) start() else stop()
    }

    fun isRunning(): Boolean = running.get()

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
