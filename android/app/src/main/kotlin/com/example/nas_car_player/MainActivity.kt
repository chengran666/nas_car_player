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
    private val MEDIA_CHANNEL = "com.nascarplayer/media_control"
    private var methodChannel: MethodChannel? = null
    private var mediaMethodChannel: MethodChannel? = null
    private val appUpdater by lazy { AppUpdater(this) }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (!appUpdater.onActivityResult(requestCode, resultCode, data)) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        val desktopChannel = methodChannel
        DesktopLyricsController.get(this).onLockChanged = { locked ->
            desktopChannel?.invokeMethod("onDesktopLyricsLockChanged", locked)
        }
        DesktopLyricsController.get(this).onEnabledChanged = { enabled ->
            desktopChannel?.invokeMethod("onDesktopLyricsEnabledChanged", enabled)
        }
        DesktopLyricsController.get(this).onWidthChanged = { width ->
            desktopChannel?.invokeMethod("onDesktopLyricsWidthChanged", width)
        }
        mediaMethodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA_CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "setDesktopLyricsColor" -> {
                    DesktopLyricsController.get(this).setColor(call.argument<Number>("color")?.toInt() ?: -1)
                    result.success(null)
                }
                "getAppVersion", "getUpdateDownloadPath", "canInstallUpdates", "requestInstallPermission", "installUpdate", "saveUpdateToDownloads" -> {
                    try { appUpdater.handle(call, result) }
                    catch (e: Exception) { result.error("UPDATE_FAILED", e.message, null) }
                }
                "configureDesktopLyrics", "setDesktopLyrics", "setDesktopPlaybackClock", "resetDesktopLyricsPosition" -> {
                    try {
                        val controller = DesktopLyricsController.get(this)
                        when (call.method) {
                            "configureDesktopLyrics" -> controller.configure(call.arguments as? Map<*, *> ?: emptyMap<String, Any>())
                            "setDesktopLyrics" -> controller.setLyrics(call.arguments as? Map<*, *> ?: emptyMap<String, Any>())
                            "setDesktopPlaybackClock" -> controller.setPlaybackClock(call.arguments as? Map<*, *> ?: emptyMap<String, Any>())
                            else -> controller.resetPosition()
                        }
                        result.success(if (call.method == "configureDesktopLyrics")
                            mapOf("locked" to controller.isLocked, "enabled" to controller.isEnabled,
                                "widthFraction" to controller.savedWidthFraction) else null)
                    } catch (e: Exception) {
                        result.error("DESKTOP_LYRICS_FAILED", e.message, null)
                    }
                }
                "getAndroidId" -> {
                    try {
                        result.success(Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID))
                    } catch (e: Exception) {
                        result.error("DEVICE_ID_FAILED", e.message, null)
                    }
                }
                "sendToBackground" -> {
                    try {
                        moveTaskToBack(true)
                    } catch (e: Exception) {
                        // 部分车机ROM可能抛异常
                    }
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

    override fun onStart() {
        super.onStart()
        DesktopLyricsController.get(this).setForeground(true)
        DesktopLyricsController.get(this).setInstallUIActive(false)
    }

    override fun onStop() {
        DesktopLyricsController.get(this).setForeground(false)
        super.onStop()
    }

    // 拦截方向盘多媒体按键，通过 MethodChannel 传递给 Flutter
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        when (keyCode) {
            KeyEvent.KEYCODE_MEDIA_NEXT -> {
                mediaMethodChannel?.invokeMethod("onMediaButton", "NEXT")
                return true
            }
            KeyEvent.KEYCODE_MEDIA_PREVIOUS -> {
                mediaMethodChannel?.invokeMethod("onMediaButton", "PREVIOUS")
                return true
            }
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> {
                mediaMethodChannel?.invokeMethod("onMediaButton", "PLAY_PAUSE")
                return true
            }
            KeyEvent.KEYCODE_MEDIA_PLAY -> {
                mediaMethodChannel?.invokeMethod("onMediaButton", "PLAY")
                return true
            }
            KeyEvent.KEYCODE_MEDIA_PAUSE -> {
                mediaMethodChannel?.invokeMethod("onMediaButton", "PAUSE")
                return true
            }
        }
        return super.onKeyDown(keyCode, event)
    }
}
