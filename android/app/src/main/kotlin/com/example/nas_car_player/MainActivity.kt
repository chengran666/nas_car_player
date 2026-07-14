package com.example.nas_car_player // ⚠️注意保留你自己的包名

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.KeyEvent
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: AudioServiceActivity() {
    private val CHANNEL = "com.nascarplayer/app_retain"
    private var methodChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "sendToBackground" -> {
                    moveTaskToBack(true)
                    result.success(null)
                }
                "checkOverlayPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        result.success(Settings.canDrawOverlays(this))
                    } else {
                        result.success(true)
                    }
                }
                "requestOverlayPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        if (!Settings.canDrawOverlays(this)) {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName")
                            )
                            startActivity(intent)
                        }
                    }
                    result.success(null)
                }
                "listInstalledApps" -> {
                    try {
                        val pm = packageManager
                        val mainIntent = Intent(Intent.ACTION_MAIN, null)
                        mainIntent.addCategory(Intent.CATEGORY_LAUNCHER)
                        val apps = pm.queryIntentActivities(mainIntent, 0)
                            .filter { it.activityInfo.packageName != packageName }
                            .map { mapOf(
                                "packageName" to it.activityInfo.packageName,
                                "label" to it.loadLabel(pm).toString()
                            ) }
                            .sortedBy { it["label"]?.lowercase() }
                        result.success(apps)
                    } catch (e: Exception) {
                        result.error("LIST_APPS_FAILED", e.message, null)
                    }
                }
                "launchAppByPackage" -> {
                    try {
                        val packageName = call.argument<String>("packageName")
                        if (packageName == null) {
                            result.error("INVALID_ARGS", "packageName is required", null)
                            return@setMethodCallHandler
                        }
                        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                        if (launchIntent != null) {
                            launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(launchIntent)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    } catch (e: Exception) {
                        result.error("LAUNCH_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    // 💡 关键修复：BYD 等车机在后台可能直接分发 KeyEvent 而非走 MediaSession 框架
    // 在 Activity 层拦截方向盘多媒体按键，通过 AudioManager 转发给当前活跃的 MediaSession
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        when (keyCode) {
            KeyEvent.KEYCODE_MEDIA_NEXT,
            KeyEvent.KEYCODE_MEDIA_PREVIOUS,
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_MEDIA_PLAY,
            KeyEvent.KEYCODE_MEDIA_PAUSE,
            KeyEvent.KEYCODE_MEDIA_STOP -> {
                if (event != null) {
                    try {
                        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        audioManager.dispatchMediaKeyEvent(event)
                    } catch (_: Exception) {}
                }
                return true
            }
        }
        return super.onKeyDown(keyCode, event)
    }
}