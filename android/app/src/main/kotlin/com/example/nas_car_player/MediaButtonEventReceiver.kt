package com.example.nas_car_player

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.view.KeyEvent
import io.flutter.plugin.common.MethodChannel

class MediaButtonEventReceiver : BroadcastReceiver() {

    companion object {
        var eventChannel: MethodChannel? = null
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (Intent.ACTION_MEDIA_BUTTON != intent.action) return

        val event = intent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT) ?: return
        if (event.action != KeyEvent.ACTION_DOWN) return

        try {
            eventChannel?.invokeMethod("onRawKeyDown", event.keyCode)
        } catch (_: Exception) {
        }
    }
}