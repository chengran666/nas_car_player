package com.example.nas_car_player

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.media.MediaMetadata
import android.media.browse.MediaBrowser
import android.media.session.MediaController
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import android.text.TextUtils
import android.util.Log
import android.util.DisplayMetrics
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import com.ryanheise.audioservice.AudioService
import kotlin.math.roundToInt

/** Uses the existing audio service clock. No Flutter frames or extra foreground service. */
class DesktopLyricsController private constructor(private val context: Context) {
    private val windowManager = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val handler = Handler(Looper.getMainLooper())
    private val preferences = context.getSharedPreferences("desktopLyricsWindow", Context.MODE_PRIVATE)
    private var enabled = false
    private var foreground = true
    private var installUIActive = false
    private var screenOn = true
    private var fontSize = 32f
    private var opacity = .55f
    private var lyricColor = Color.WHITE
    private var scale = 1f
    private var locked = false
    private var staggered = false
    private var widthFraction = .85f
    val isLocked: Boolean get() = locked
    val isEnabled: Boolean get() = enabled
    val savedWidthFraction: Double get() = widthFraction.toDouble()
    var onLockChanged: ((Boolean) -> Unit)? = null
    var onEnabledChanged: ((Boolean) -> Unit)? = null
    var onWidthChanged: ((Double) -> Unit)? = null
    private var resizing = false
    private var browser: MediaBrowser? = null
    private var media: MediaController? = null
    private var state: PlaybackState? = null
    private var metadata: MediaMetadata? = null
    private var timeline = DesktopLyricTimeline(emptyList())
    private var clock = DesktopPlaybackClock()
    private var title = ""
    private var artist = ""
    private var ready = false
    private var root: LinearLayout? = null
    private var original: TextView? = null
    private var translation: TextView? = null
    private var nextOriginal: TextView? = null
    private var nextTranslation: TextView? = null
    private var nextRow: LinearLayout? = null
    private var close: TextView? = null
    private var lockButton: DesktopLockButton? = null
    private var resizeButton: DesktopResizeButton? = null
    // Separate touchable window: FLAG_NOT_TOUCHABLE on lyrics cannot exempt a child button.
    private var controls: LinearLayout? = null
    private var controlsParams: WindowManager.LayoutParams? = null
    private var currentRow: LinearLayout? = null
    private var params: WindowManager.LayoutParams? = null
    private var renderedIndex = Int.MIN_VALUE
    private var receiverRegistered = false
    private var xFraction = preferences.getFloat("x", .5f)
    private var yFraction = preferences.getFloat("y", .08f)
    private val tick = Runnable { refresh() }
    private val callback = object : MediaController.Callback() {
        override fun onPlaybackStateChanged(playbackState: PlaybackState?) {
            state = playbackState
            refresh()
        }
        override fun onMetadataChanged(newMetadata: MediaMetadata?) {
            metadata = newMetadata
            refresh()
        }
        override fun onSessionDestroyed() {
            state = null
            hide()
            disconnect()
            if (enabled) handler.postDelayed({ connect() }, 1000)
        }
    }
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Intent.ACTION_CONFIGURATION_CHANGED) {
                applyStyle()
                refresh()
                return
            }
            screenOn = intent?.action != Intent.ACTION_SCREEN_OFF
            refresh()
        }
    }

    fun configure(arguments: Map<*, *>) {
        // Overlay buttons remain authoritative when Flutter sends old settings
        // after a resume/restart. Only the user's settings switch overrides them.
        enabled = if (arguments["enabledOverride"] == true || !preferences.contains("enabled")) {
            (arguments["enabled"] == true).also { preferences.edit().putBoolean("enabled", it).apply() }
        } else preferences.getBoolean("enabled", false)
        fontSize = (arguments["fontSize"] as? Number)?.toFloat()?.coerceIn(12f, 100f) ?: 32f
        opacity = (arguments["opacity"] as? Number)?.toFloat()?.coerceIn(.0f, .9f) ?: .55f
        lyricColor = (arguments["color"] as? Number)?.toInt() ?: Color.WHITE
        scale = (arguments["scale"] as? Number)?.toFloat()?.coerceIn(.8f, 2.5f) ?: 1f
        if (!resizing) {
            widthFraction = if (arguments["widthOverride"] == true || !preferences.contains("width")) {
                ((arguments["widthFraction"] as? Number)?.toFloat()?.coerceIn(.3f, 1f) ?: .85f)
                    .also { preferences.edit().putFloat("width", it).apply() }
            } else preferences.getFloat("width", .85f).coerceIn(.3f, 1f)
        }
        val newStaggered = arguments["staggered"] == true
        if (newStaggered != staggered) {
            staggered = newStaggered
            renderedIndex = Int.MIN_VALUE
        }
        locked = if (arguments["lockOverride"] == true || !preferences.contains("locked")) {
            (arguments["locked"] == true).also { preferences.edit().putBoolean("locked", it).apply() }
        } else preferences.getBoolean("locked", false)
        if (enabled) {
            screenOn = (context.getSystemService(Context.POWER_SERVICE) as PowerManager).isInteractive
            if (!receiverRegistered) {
                val filter = IntentFilter().apply {
                    addAction(Intent.ACTION_SCREEN_ON)
                    addAction(Intent.ACTION_SCREEN_OFF)
                    addAction(Intent.ACTION_CONFIGURATION_CHANGED)
                }
                if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(screenReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
                else context.registerReceiver(screenReceiver, filter)
                receiverRegistered = true
            }
            connect()
            applyStyle()
            refresh()
        } else {
            disableOverlay()
        }
    }

    fun setForeground(value: Boolean) {
        foreground = value
        refresh()
    }

    fun setInstallUIActive(value: Boolean) {
        installUIActive = value
        refresh()
    }

    fun setLyrics(arguments: Map<*, *>) {
        if (title != arguments["title"] || artist != arguments["artist"]) clock = DesktopPlaybackClock()
        title = arguments["title"] as? String ?: ""
        artist = arguments["artist"] as? String ?: ""
        ready = arguments["ready"] == true
        readClock(arguments["clock"] as? Map<*, *>)
        val rows = arguments["lines"] as? List<*> ?: emptyList<Any>()
        timeline = DesktopLyricTimeline(rows.take(5000).mapNotNull { row ->
            val line = row as? Map<*, *> ?: return@mapNotNull null
            val time = (line["timeMs"] as? Number)?.toLong() ?: return@mapNotNull null
            val text = line["text"] as? String ?: return@mapNotNull null
            DesktopLyricLine(time, text.take(2000))
        }.sortedBy { it.timeMs })
        renderedIndex = Int.MIN_VALUE
        refresh()
    }

    fun setPlaybackClock(arguments: Map<*, *>) {
        if (arguments["title"] != title || arguments["artist"] != artist) return
        readClock(arguments)
        refresh()
    }

    private fun readClock(arguments: Map<*, *>?) {
        val position = (arguments?.get("positionMs") as? Number)?.toLong() ?: return
        clock.update(position, (arguments["sampledAtMs"] as? Number)?.toLong() ?: 0L,
            System.currentTimeMillis(), SystemClock.elapsedRealtime(),
            (arguments["speed"] as? Number)?.toFloat() ?: 1f, arguments["advancing"] == true)
    }

    fun resetPosition() {
        xFraction = .5f
        yFraction = .08f
        savePosition()
        reposition()
    }

    fun setColor(color: Int) {
        lyricColor = color
        applyStyle()
    }

    private fun connect() {
        if (!enabled || browser != null) return
        browser = MediaBrowser(context, ComponentName(context, AudioService::class.java),
            object : MediaBrowser.ConnectionCallback() {
                override fun onConnected() {
                    val token = browser?.sessionToken ?: return
                    media = MediaController(context, token).also {
                        it.registerCallback(callback, handler)
                        state = it.playbackState
                        metadata = it.metadata
                    }
                    refresh()
                }
                override fun onConnectionSuspended() {
                    state = null
                    hide()
                }
                override fun onConnectionFailed() {
                    disconnect()
                    if (enabled) handler.postDelayed({ connect() }, 2000)
                }
            }, null)
        browser?.connect()
    }

    private fun disconnect() {
        media?.unregisterCallback(callback)
        media = null
        browser?.disconnect()
        browser = null
        state = null
        metadata = null
    }

    private fun disableOverlay() {
        handler.removeCallbacks(tick)
        hide()
        disconnect()
        if (receiverRegistered) context.unregisterReceiver(screenReceiver)
        receiverRegistered = false
    }

    private fun refresh() {
        handler.removeCallbacks(tick)
        val playback = state
        val matches = metadata?.getString(MediaMetadata.METADATA_KEY_TITLE) == title &&
            metadata?.getString(MediaMetadata.METADATA_KEY_ARTIST).orEmpty() == artist
        if (!enabled || foreground || installUIActive || !screenOn || !ready || !matches ||
            playback?.state != PlaybackState.STATE_PLAYING ||
            (Build.VERSION.SDK_INT >= 23 && !Settings.canDrawOverlays(context))) {
            hide()
            return
        }
        if (clock.initialized && !clock.advancing) {
            hide()
            return
        }
        // The lyric-fetch duration must never become the playback origin. Use a
        // fresh player snapshot; MediaSession metadata is only a track/state guard.
        val position = if (clock.initialized) clock.position(SystemClock.elapsedRealtime())
            else DesktopLyricTimeline.position(playback.position, playback.lastPositionUpdateTime,
                SystemClock.elapsedRealtime(), playback.playbackSpeed, true)
        val speed = if (clock.initialized) clock.speed else playback.playbackSpeed
        val index = timeline.indexAt(position)
        if (index < 0 || timeline.lines[index].text.isBlank()) {
            hide()
        } else {
            if (root == null) show()
            if (root != null && renderedIndex != index) {
                val parts = timeline.lines[index].text.trim().split('\n')
                original?.text = parts.first()
                translation?.text = parts.drop(1).joinToString("\n")
                translation?.visibility = if (parts.size > 1) View.VISIBLE else View.GONE
                val next = if (staggered) timeline.nextVisibleIndex(index) else null
                val nextParts = next?.let { timeline.lines[it].text.trim().split('\n') }
                nextOriginal?.text = nextParts?.first().orEmpty()
                nextTranslation?.text = nextParts?.drop(1)?.joinToString("\n").orEmpty()
                nextTranslation?.visibility = if ((nextParts?.size ?: 0) > 1) View.VISIBLE else View.GONE
                nextRow?.visibility = if (next != null) View.VISIBLE else View.GONE
                renderedIndex = index
            }
        }
        // A single wake-up at the next boundary. Session callbacks handle seek/pause/track changes.
        timeline.nextDelay(position, speed)?.let { handler.postDelayed(tick, it) }
    }

    private fun dp(value: Float) = (value * context.resources.displayMetrics.density).roundToInt()
    @Suppress("DEPRECATION")
    private fun displayMetrics() = DisplayMetrics().also { windowManager.defaultDisplay.getRealMetrics(it) }
    private fun show() {
        val layout = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(14f), dp(8f), dp(8f), dp(8f))
        }
        val lyrics = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        currentRow = lyrics
        original = TextView(context).apply {
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
            maxLines = 2
            gravity = Gravity.CENTER
            setShadowLayer(dp(2f).toFloat(), 0f, 1f, Color.BLACK)
        }
        translation = TextView(context).apply {
            setTextColor(0xFFE5E5E5.toInt())
            maxLines = 2
            gravity = Gravity.CENTER
            setShadowLayer(dp(2f).toFloat(), 0f, 1f, Color.BLACK)
        }
        lyrics.addView(original, LinearLayout.LayoutParams(-1, -2))
        lyrics.addView(translation, LinearLayout.LayoutParams(-1, -2))
        nextRow = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(8f), 0, 0)
            visibility = View.GONE
        }
        nextOriginal = TextView(context).apply {
            typeface = Typeface.DEFAULT_BOLD
            setShadowLayer(dp(2f).toFloat(), 0f, 1f, Color.BLACK)
        }
        nextTranslation = TextView(context).apply {
            setShadowLayer(dp(2f).toFloat(), 0f, 1f, Color.BLACK)
        }
        nextRow?.addView(nextOriginal, LinearLayout.LayoutParams(-1, -2))
        nextRow?.addView(nextTranslation, LinearLayout.LayoutParams(-1, -2))
        // Reserve the button area only on the first row. The second row can
        // reach the right edge of the full lyric window without covering controls.
        layout.addView(lyrics, LinearLayout.LayoutParams(-1, -2))
        layout.addView(nextRow, LinearLayout.LayoutParams(-1, -2))
        val buttons = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        resizeButton = DesktopResizeButton(context)
        buttons.addView(resizeButton, LinearLayout.LayoutParams(controlSize(), controlSize()))
        installResize(resizeButton!!)
        lockButton = DesktopLockButton(context).apply {
            setOnClickListener {
                locked = !locked
                preferences.edit().putBoolean("locked", locked).apply()
                applyStyle()
                onLockChanged?.invoke(locked)
            }
        }
        buttons.addView(lockButton, LinearLayout.LayoutParams(controlSize(), controlSize()))
        close = TextView(context).apply {
            text = "×"
            contentDescription = "关闭桌面歌词，可在应用设置中重新开启"
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 24f)
            setOnClickListener {
                enabled = false
                preferences.edit().putBoolean("enabled", false).apply()
                disableOverlay()
                onEnabledChanged?.invoke(false)
            }
        }
        buttons.addView(close, LinearLayout.LayoutParams(controlSize(), controlSize()))
        val metrics = displayMetrics()
        @Suppress("DEPRECATION")
        val type = if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else WindowManager.LayoutParams.TYPE_PHONE
        params = WindowManager.LayoutParams(overlayWidth(metrics),
            WindowManager.LayoutParams.WRAP_CONTENT, type, windowFlags(), PixelFormat.TRANSLUCENT).apply {
            gravity = Gravity.TOP or Gravity.LEFT
            // Android 12+ allows touches through untrusted overlays only below maximum obscuring opacity.
            alpha = if (locked) .8f else 1f
        }
        root = layout
        controls = buttons
        controlsParams = WindowManager.LayoutParams(controlWidth(), controlSize(), type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT).apply { gravity = Gravity.TOP or Gravity.LEFT }
        applyStyle()
        installDrag(layout)
        layout.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> reposition() }
        try {
            windowManager.addView(layout, params)
            windowManager.addView(buttons, controlsParams)
            reposition()
        } catch (error: Exception) {
            Log.w("DesktopLyrics", "Cannot show overlay", error)
            hide()
        }
    }

    private fun windowFlags() = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
        WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
        (if (locked) WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE else 0)

    private fun applyStyle() {
        if (locked) finishResize()
        original?.gravity = if (staggered) Gravity.LEFT else Gravity.CENTER
        translation?.gravity = if (staggered) Gravity.LEFT else Gravity.CENTER
        listOf(original, translation).forEach {
            it?.textAlignment = View.TEXT_ALIGNMENT_GRAVITY
            it?.maxLines = if (staggered) 1 else 2
            it?.ellipsize = TextUtils.TruncateAt.END
        }
        listOf(nextOriginal, nextTranslation).forEach {
            it?.gravity = Gravity.RIGHT
            it?.textAlignment = View.TEXT_ALIGNMENT_GRAVITY
            it?.maxLines = 1
            it?.ellipsize = TextUtils.TruncateAt.END
        }
        if (!staggered) nextRow?.visibility = View.GONE
        original?.setTextColor(lyricColor)
        nextOriginal?.setTextColor(lyricColor)
        nextOriginal?.alpha = .72f
        nextTranslation?.setTextColor(lyricColor)
        nextTranslation?.alpha = .64f
        nextOriginal?.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSize)
        nextTranslation?.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSize * .74f)
        // Keep the translation slightly dimmer within the selected color family.
        translation?.setTextColor(Color.rgb(
            (Color.red(lyricColor) * .9f).toInt(),
            (Color.green(lyricColor) * .9f).toInt(),
            (Color.blue(lyricColor) * .9f).toInt()))
        original?.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSize)
        translation?.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSize * .74f)
        lockButton?.setLocked(locked)
        resizeButton?.visibility = if (locked) View.GONE else View.VISIBLE
        resizeButton?.layoutParams = LinearLayout.LayoutParams(controlSize(), controlSize())
        currentRow?.setPadding(0, 0, controlWidth() + dp(6f), 0)
        currentRow?.minimumHeight = controlSize()
        lockButton?.layoutParams = LinearLayout.LayoutParams(controlSize(), controlSize())
        close?.layoutParams = LinearLayout.LayoutParams(controlSize(), controlSize())
        root?.background = GradientDrawable().apply {
            cornerRadius = dp(12f).toFloat()
            setColor(Color.argb((this@DesktopLyricsController.opacity * 255).roundToInt(), 0, 0, 0))
        }
        params?.apply { flags = windowFlags(); alpha = if (locked) .8f else 1f }
        reposition()
    }

    private fun reposition() {
        val view = root ?: return
        if (!view.isAttachedToWindow) return
        val lp = params ?: return
        val metrics = displayMetrics()
        lp.width = overlayWidth(metrics)
        lp.x = ((metrics.widthPixels - lp.width).coerceAtLeast(0) * xFraction).roundToInt()
        lp.y = ((metrics.heightPixels - view.height).coerceAtLeast(0) * yFraction).roundToInt()
        try { windowManager.updateViewLayout(view, lp) } catch (_: IllegalArgumentException) { }
        val buttons = controls ?: return
        val buttonParams = controlsParams ?: return
        if (!buttons.isAttachedToWindow) return
        buttonParams.width = controlWidth()
        buttonParams.height = controlSize()
        buttonParams.x = lp.x + lp.width - dp(8f) - buttonParams.width
        buttonParams.y = lp.y + dp(8f) +
            (((currentRow?.height ?: 0) - buttonParams.height) / 2).coerceAtLeast(0)
        try { windowManager.updateViewLayout(buttons, buttonParams) } catch (_: IllegalArgumentException) { }
    }

    private fun controlSize() = dp((48f * scale).coerceIn(44f, 72f))
    private fun controlWidth() = controlSize() * (if (locked) 2 else 3)
    private fun overlayWidth(metrics: DisplayMetrics): Int =
        (metrics.widthPixels * widthFraction).roundToInt()
            .coerceIn((controlWidth() + dp(80f)).coerceAtMost(metrics.widthPixels), metrics.widthPixels)

    private fun installResize(view: View) {
        var startX = 0f
        var initialX = 0
        var initialWidth = 0
        fun updateWidth(rawX: Float) {
            if (!resizing) return
            val metrics = displayMetrics()
            val geometry = desktopLyricResize(initialWidth, initialX, rawX - startX,
                metrics.widthPixels, maxOf((metrics.widthPixels * .3f).roundToInt(), controlWidth() + dp(80f)))
            widthFraction = geometry.width.toFloat() / metrics.widthPixels
            val freeX = metrics.widthPixels - geometry.width
            if (freeX > 0) xFraction = geometry.x.toFloat() / freeX
            reposition()
        }
        view.setOnTouchListener { _, event ->
            val lp = params ?: return@setOnTouchListener false
            if (locked) return@setOnTouchListener false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    resizing = true
                    startX = event.rawX
                    initialX = lp.x
                    initialWidth = lp.width
                }
                MotionEvent.ACTION_MOVE -> updateWidth(event.rawX)
                MotionEvent.ACTION_UP -> { updateWidth(event.rawX); finishResize(); view.performClick() }
                MotionEvent.ACTION_CANCEL -> finishResize()
            }
            true
        }
    }

    private fun finishResize() {
        if (!resizing) return
        resizing = false
        preferences.edit().putFloat("width", widthFraction)
            .putFloat("x", xFraction).putFloat("y", yFraction).apply()
        // A single Flutter message after release; moving the handle only lays out native views.
        onWidthChanged?.invoke(widthFraction.toDouble())
    }

    private fun installDrag(view: View) {
        var startX = 0f
        var startY = 0f
        var initialX = 0
        var initialY = 0
        view.setOnTouchListener { _, event ->
            val lp = params ?: return@setOnTouchListener false
            if (locked) return@setOnTouchListener false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    startX = event.rawX; startY = event.rawY
                    initialX = lp.x; initialY = lp.y
                }
                MotionEvent.ACTION_MOVE -> {
                    val metrics = displayMetrics()
                    val freeX = (metrics.widthPixels - lp.width).coerceAtLeast(1)
                    val freeY = (metrics.heightPixels - (root?.height ?: 0)).coerceAtLeast(1)
                    xFraction = ((initialX + event.rawX - startX) / freeX).coerceIn(0f, 1f)
                    yFraction = ((initialY + event.rawY - startY) / freeY).coerceIn(0f, 1f)
                    reposition()
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> savePosition()
            }
            true
        }
    }

    private fun savePosition() { preferences.edit().putFloat("x", xFraction).putFloat("y", yFraction).apply() }
    private fun hide() {
        finishResize()
        handler.removeCallbacks(tick)
        controls?.let { try { windowManager.removeView(it) } catch (_: IllegalArgumentException) { } }
        root?.let { try { windowManager.removeView(it) } catch (_: IllegalArgumentException) { } }
        root = null
        original = null
        translation = null
        nextOriginal = null
        nextTranslation = null
        nextRow = null
        close = null
        lockButton = null
        resizeButton = null
        controls = null
        controlsParams = null
        currentRow = null
        params = null
        renderedIndex = Int.MIN_VALUE
    }

    companion object {
        private var instance: DesktopLyricsController? = null
        fun get(context: Context): DesktopLyricsController = instance ?: DesktopLyricsController(context.applicationContext).also { instance = it }
    }
}

/** Separate from lyric dragging so changing width never moves the whole lyric block. */
private class DesktopResizeButton(context: Context) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    init {
        isClickable = true
        isFocusable = true
        contentDescription = "左右拖动调整桌面歌词宽度，松手后保存"
    }
    override fun performClick(): Boolean { super.performClick(); return true }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val unit = minOf(width, height) / 44f
        val cx = width / 2f
        val cy = height / 2f
        paint.strokeWidth = 2.3f * unit
        canvas.drawLine(cx - 12 * unit, cy, cx + 12 * unit, cy, paint)
        canvas.drawLine(cx - 12 * unit, cy, cx - 6 * unit, cy - 6 * unit, paint)
        canvas.drawLine(cx - 12 * unit, cy, cx - 6 * unit, cy + 6 * unit, paint)
        canvas.drawLine(cx + 12 * unit, cy, cx + 6 * unit, cy - 6 * unit, paint)
        canvas.drawLine(cx + 12 * unit, cy, cx + 6 * unit, cy + 6 * unit, paint)
    }
}

/** Draw once per state change; avoids emoji/font differences on Android car ROMs. */
private class DesktopLockButton(context: Context) : View(context) {
    private var locked = false
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    init { isClickable = true; isFocusable = true }
    fun setLocked(value: Boolean) {
        locked = value
        contentDescription = if (value) "已锁定，点击解锁并关闭穿透" else "已解锁，点击锁定并开启穿透"
        invalidate()
    }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val unit = minOf(width, height) / 44f
        val cx = width / 2f
        val cy = height / 2f
        paint.strokeWidth = 2.3f * unit
        paint.color = if (locked) 0xFFFFD166.toInt() else Color.WHITE
        canvas.drawRoundRect(cx - 9 * unit, cy - 1 * unit, cx + 9 * unit, cy + 12 * unit,
            2 * unit, 2 * unit, paint)
        val shackleX = if (locked) cx else cx + 6 * unit
        canvas.drawArc(shackleX - 6 * unit, cy - 13 * unit, shackleX + 6 * unit, cy - 1 * unit,
            180f, 180f, false, paint)
        canvas.drawLine(shackleX - 6 * unit, cy - 7 * unit, shackleX - 6 * unit, cy - 1 * unit, paint)
        if (locked) canvas.drawLine(shackleX + 6 * unit, cy - 7 * unit, shackleX + 6 * unit, cy - 1 * unit, paint)
        canvas.drawLine(cx, cy + 4 * unit, cx, cy + 7 * unit, paint)
    }
}
