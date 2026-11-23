package com.doumic.app

import android.inputmethodservice.InputMethodService
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.inputmethod.EditorInfo

/**
 * 豆麦输入法 — hold-to-talk voice input using D3200 PCM bridged from Flutter.
 *
 * Recognition runs in the Flutter app (Soniox). This IME requests dictation,
 * shows partial text, and commits finals into the focused editor.
 */
class BeanMicImeService : InputMethodService() {
    private val handler = Handler(Looper.getMainLooper())
    private var statusView: TextView? = null
    private var partialView: TextView? = null
    private var levelBar: ProgressBar? = null
    private var micButton: TextView? = null
    private var holding = false
    private val levelBuf = ByteArray(4096)

    private val levelTicker = object : Runnable {
        override fun run() {
            if (!holding) return
            val n = MicBridgeHost.readLatestPcm(levelBuf, levelBuf.size)
            var peak = 0
            var i = 0
            while (i + 1 < n) {
                val lo = levelBuf[i].toInt() and 0xff
                val hi = levelBuf[i + 1].toInt()
                var sample = (hi shl 8) or lo
                if (sample > 32767) sample -= 65536
                val abs = kotlin.math.abs(sample)
                if (abs > peak) peak = abs
                i += 4
            }
            levelBar?.progress = ((peak / 32768.0) * 100).toInt().coerceIn(0, 100)
            partialView?.text = MicBridgeHost.currentPartial().ifEmpty {
                if (MicBridgeHost.isEnabled()) "正在聆听…" else "请先在豆麦 App 中开启麦克风桥接"
            }
            val finalText = MicBridgeHost.consumeFinalText()
            if (!finalText.isNullOrBlank()) {
                currentInputConnection?.commitText(finalText, 1)
                partialView?.text = "已上屏"
            }
            handler.postDelayed(this, 50)
        }
    }

    private val textListener: (String?, String?) -> Unit = { partial, finalText ->
        handler.post {
            if (!finalText.isNullOrBlank()) {
                currentInputConnection?.commitText(finalText, 1)
                partialView?.text = "已上屏"
                statusView?.text = "松手结束 · 可继续按住说话"
            } else if (!partial.isNullOrBlank()) {
                partialView?.text = partial
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        MicBridgeHost.appContext = applicationContext
    }

    override fun onCreateInputView(): View {
        val density = resources.displayMetrics.density
        fun dp(v: Int) = (v * density).toInt()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(14), dp(16), dp(18))
            setBackgroundColor(Color.parseColor("#F5F6F8"))
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
            )
        }

        statusView = TextView(this).apply {
            text = "豆麦输入法 · 按住说话"
            setTextColor(Color.parseColor("#12141A"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        root.addView(statusView)

        partialView = TextView(this).apply {
            text = "连接录音豆并开启桥接后，按住下方按钮"
            setTextColor(Color.parseColor("#5C6578"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setPadding(0, dp(8), 0, dp(10))
            minHeight = dp(40)
        }
        root.addView(partialView)

        levelBar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 100
            progress = 0
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dp(8),
            )
        }
        root.addView(levelBar)

        val buttonBg = GradientDrawable().apply {
            cornerRadius = dp(28).toFloat()
            setColor(Color.parseColor("#3B7CFF"))
        }

        micButton = TextView(this).apply {
            text = "按住 说话"
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            background = buttonBg
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dp(56),
            ).also { it.topMargin = dp(14) }
            setOnTouchListener { _, event ->
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        holding = true
                        text = "松开 上屏"
                        buttonBg.setColor(Color.parseColor("#E03131"))
                        statusView?.text = "正在通过录音豆收音…"
                        MicBridgeHost.requestDictationStart()
                        handler.removeCallbacks(levelTicker)
                        handler.post(levelTicker)
                        true
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        holding = false
                        text = "按住 说话"
                        buttonBg.setColor(Color.parseColor("#3B7CFF"))
                        statusView?.text = "豆麦输入法 · 按住说话"
                        MicBridgeHost.requestDictationStop()
                        handler.removeCallbacks(levelTicker)
                        levelBar?.progress = 0
                        val leftover = MicBridgeHost.consumeFinalText()
                        if (!leftover.isNullOrBlank()) {
                            currentInputConnection?.commitText(leftover, 1)
                            partialView?.text = "已上屏"
                        }
                        true
                    }
                    else -> false
                }
            }
        }
        root.addView(micButton)

        val hint = TextView(this).apply {
            text = "需保持「豆麦」App 在后台运行，并已开启麦克风桥接"
            setTextColor(Color.parseColor("#8B93A7"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            setPadding(0, dp(10), 0, 0)
        }
        root.addView(hint)

        return root
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        MicBridgeHost.textListener = textListener
        statusView?.text = if (MicBridgeHost.isEnabled()) {
            "豆麦输入法 · 桥接已开启"
        } else {
            "豆麦输入法 · 请先在 App 中开启桥接"
        }
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        MicBridgeHost.textListener = null
        handler.removeCallbacks(levelTicker)
        if (holding) {
            holding = false
            MicBridgeHost.requestDictationStop()
        }
        super.onFinishInputView(finishingInput)
    }

    override fun onDestroy() {
        MicBridgeHost.textListener = null
        handler.removeCallbacks(levelTicker)
        super.onDestroy()
    }
}
