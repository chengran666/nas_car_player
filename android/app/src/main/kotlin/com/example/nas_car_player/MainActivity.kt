package com.example.nas_car_player // ⚠️ 依然保留你自己的包名！

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// 🔥🔥🔥 黑魔法 1：系统级常驻不死服务 (Foreground Service)
class CarMusicService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // 在底层建一个无声的系统通知，以此换取系统最高后台保活特权
            val channel = NotificationChannel("nas_car", "NAS 音乐守护进程", NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
            val builder = Notification.Builder(this, "nas_car")
                .setContentTitle("NAS Car Player 正在守护")
                .setContentText("NAS Car Player")
                .setSmallIcon(android.R.drawable.ic_media_play)
            startForeground(1, builder.build()) // 亮出免死金牌
        }
        return START_STICKY // 杀不死特性：就算被系统误杀，也会瞬间满血复活
    }
}

// 🔥🔥🔥 原生主程序
class MainActivity: FlutterActivity() {
    private lateinit var mediaSession: MediaSession
    private lateinit var channel: MethodChannel
    private var carKeyReceiver: BroadcastReceiver? = null

    // 焦点控制变量
    private lateinit var audioManager: AudioManager
    private var audioFocusRequest: AudioFocusRequest? = null

    @Suppress("DEPRECATION")
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.nascarplayer/app_retain")
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        // 🔥 黑魔法 2：准备音频焦点死锁炸弹
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
                .setOnAudioFocusChangeListener { focusChange ->
                    // 💡 核心奥义：留空！
                    // 当比亚迪导航播报时，系统会发来 LOSS_TRANSIENT，企图让我们暂停。
                    // 我们直接假装没听见（不调用 pause），强行把混音丢给 14 通道！
                    // 这样音乐不仅不会断，方向盘控制权也依然死死捏在我们手里！
                }
                .build()
        }

        // 绑定媒体会话
        mediaSession = MediaSession(this, "NasCarPlayerSession")
        mediaSession.setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS)
        mediaSession.isActive = true

        mediaSession.setCallback(object : MediaSession.Callback() {
            override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                val keyEvent = mediaButtonIntent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT)
                if (keyEvent != null && keyEvent.action == KeyEvent.ACTION_DOWN) {
                    runOnUiThread { channel.invokeMethod("onRawKeyDown", keyEvent.keyCode) }
                    return true
                }
                return super.onMediaButtonEvent(mediaButtonIntent)
            }
        })

        // 后台霸王级广播雷达
        carKeyReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action == Intent.ACTION_MEDIA_BUTTON) {
                    val keyEvent = intent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT)
                    if (keyEvent != null && keyEvent.action == KeyEvent.ACTION_DOWN) {
                        runOnUiThread { channel.invokeMethod("onRawKeyDown", keyEvent.keyCode) }
                    }
                }
            }
        }
        val filter = IntentFilter(Intent.ACTION_MEDIA_BUTTON).apply { priority = 1000 } // 优先级拉满
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(carKeyReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            registerReceiver(carKeyReceiver, filter)
        }

        // 监听 Flutter 传来的状态
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "sendToBackground" -> { moveTaskToBack(true); result.success(null) }
                "updatePlaybackState" -> {
                    val isPlaying = call.arguments as Boolean

                    if (isPlaying) {
                        // 1. 抢夺焦点！
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            audioFocusRequest?.let { audioManager.requestAudioFocus(it) }
                        } else {
                            audioManager.requestAudioFocus(null, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
                        }

                        // 2. 激活免死金牌服务！
                        val serviceIntent = Intent(this, CarMusicService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(serviceIntent)
                        } else {
                            startService(serviceIntent)
                        }
                    }

                    // 3. 持续高调向系统广播我们的状态
                    val state = if (isPlaying) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED
                    val stateBuilder = PlaybackState.Builder()
                        .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SKIP_TO_PREVIOUS)
                        .setState(state, PlaybackState.PLAYBACK_POSITION_UNKNOWN, 1.0f)
                    mediaSession.setPlaybackState(stateBuilder.build())

                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // 上帝通道兜底
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN) {
            runOnUiThread { channel.invokeMethod("onRawKeyDown", event.keyCode) }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onDestroy() {
        mediaSession.release()
        carKeyReceiver?.let { unregisterReceiver(it) }
        super.onDestroy()
    }
}