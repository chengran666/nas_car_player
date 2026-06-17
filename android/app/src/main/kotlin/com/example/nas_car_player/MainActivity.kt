package com.example.nas_car_player // ⚠️ 再次提醒：千万保留你自己的包名第一行！

import android.content.Intent
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Bundle
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private lateinit var mediaSession: MediaSession
    private lateinit var channel: MethodChannel

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.nascarplayer/app_retain")

        // 💡 1. 彻底抛弃旧版兼容包，直接使用 Android 纯血原生 MediaSession！
        mediaSession = MediaSession(this, "NasCarPlayerSession")
        mediaSession.isActive = true

        // 💡 2. 劫持系统的全局媒体按键
        mediaSession.setCallback(object : MediaSession.Callback() {
            override fun onPlay() { runOnUiThread { channel.invokeMethod("onMediaButton", "play") } }
            override fun onPause() { runOnUiThread { channel.invokeMethod("onMediaButton", "pause") } }
            override fun onSkipToNext() { runOnUiThread { channel.invokeMethod("onMediaButton", "next") } }
            override fun onSkipToPrevious() { runOnUiThread { channel.invokeMethod("onMediaButton", "prev") } }

            // 💡 双保险：直接拦截底层硬件键码，防止某些老旧车机不触发上面四个标准方法！
            // 💡 双保险：直接拦截底层硬件键码
            override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                val keyEvent = mediaButtonIntent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT)
                if (keyEvent != null && keyEvent.action == KeyEvent.ACTION_DOWN) {
                    when (keyEvent.keyCode) {
                        KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> {
                            runOnUiThread { channel.invokeMethod("onMediaButton", "play_pause") }
                            return true // 💡 杀手锏：拦截后直接返回 true 吃掉事件！绝不让 super 再次触发双重回调！
                        }
                        KeyEvent.KEYCODE_MEDIA_PLAY -> {
                            runOnUiThread { channel.invokeMethod("onMediaButton", "play") }
                            return true
                        }
                        KeyEvent.KEYCODE_MEDIA_PAUSE -> {
                            runOnUiThread { channel.invokeMethod("onMediaButton", "pause") }
                            return true
                        }
                        KeyEvent.KEYCODE_MEDIA_NEXT -> {
                            runOnUiThread { channel.invokeMethod("onMediaButton", "next") }
                            return true
                        }
                        KeyEvent.KEYCODE_MEDIA_PREVIOUS -> {
                            runOnUiThread { channel.invokeMethod("onMediaButton", "prev") }
                            return true
                        }
                    }
                }
                return super.onMediaButtonEvent(mediaButtonIntent)
            }
        })

        // 💡 3. 处理 Flutter 端发来的同步指令
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "sendToBackground" -> {
                    moveTaskToBack(true)
                    result.success(null)
                }
                "updatePlaybackState" -> {
                    val isPlaying = call.arguments as Boolean
                    val state = if (isPlaying) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED
                    val stateBuilder = PlaybackState.Builder()
                        .setActions(
                            PlaybackState.ACTION_PLAY or
                                    PlaybackState.ACTION_PAUSE or
                                    PlaybackState.ACTION_PLAY_PAUSE or
                                    PlaybackState.ACTION_SKIP_TO_NEXT or
                                    PlaybackState.ACTION_SKIP_TO_PREVIOUS
                        )
                        .setState(state, PlaybackState.PLAYBACK_POSITION_UNKNOWN, 1.0f)
                    mediaSession.setPlaybackState(stateBuilder.build())
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        mediaSession.release()
        super.onDestroy()
    }

    // 💡 侦察机：拦截一切到达当前画面的硬件按键，并弹窗显示键码！
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN) {
            // 在屏幕上打印出按下的键码
            android.widget.Toast.makeText(this, "侦测到物理按键，键码: ${event.keyCode}", android.widget.Toast.LENGTH_SHORT).show()
        }
        return super.dispatchKeyEvent(event)
    }
}