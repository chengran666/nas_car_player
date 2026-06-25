package com.example.nas_car_player // ⚠️ 这里一定要保留你自己的包名！

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.widget.Toast

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action

        if (action == Intent.ACTION_BOOT_COMPLETED ||
            action == "android.intent.action.LOCKED_BOOT_COMPLETED" ||
            action == "android.intent.action.QUICKBOOT_POWERON" ||
            action == "com.htc.intent.action.QUICKBOOT_POWERON") {

            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val shouldStartOnBoot = prefs.getBoolean("flutter.startOnBoot", false)

            // 💡 Flutter 的 int 存到 Android 底层会自动变成 Long 类型
            val bootDelaySeconds = prefs.getLong("flutter.bootDelay", 5L)

            if (shouldStartOnBoot) {
                // 如果秒数是 0，直接拉起
                if (bootDelaySeconds <= 0L) {
                    // Toast.makeText(context, "NAS Player: 开机启动，立刻拉起...", Toast.LENGTH_SHORT).show()
                    val launchIntent = Intent(context, MainActivity::class.java).apply {
                        // 💡 增加 SINGLE_TOP 防止重复拉起多个 MainActivity 实例
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    }
                    context.startActivity(launchIntent)
                } else {
                    // 💡 如果设置了延迟，委托系统的 AlarmManager 进行安全倒计时启动！
                    Toast.makeText(context, "NAS Player: 系统已通电，将在 ${bootDelaySeconds} 秒后启动", Toast.LENGTH_LONG).show()

                    val launchIntent = Intent(context, MainActivity::class.java).apply {
                        // 💡 增加 SINGLE_TOP 防止重复拉起多个 MainActivity 实例
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    }

                    // 兼容不同版本 Android 的防弹 PendingIntent
                    val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                    } else {
                        PendingIntent.FLAG_UPDATE_CURRENT
                    }

                    val pendingIntent = PendingIntent.getActivity(context, 10086, launchIntent, flags)
                    val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

                    val triggerTime = System.currentTimeMillis() + (bootDelaySeconds * 1000L)

                    // 极其安全的倒计时触发逻辑
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerTime, pendingIntent)
                        } else {
                            alarmManager.setExact(AlarmManager.RTC_WAKEUP, triggerTime, pendingIntent)
                        }
                    } catch (e: SecurityException) {
                        // 兼容某些车机系统权限限制的降级方案
                        alarmManager.set(AlarmManager.RTC_WAKEUP, triggerTime, pendingIntent)
                    }
                }
            } else {
                // Toast.makeText(context, "NAS Player: 已拦截开机信号，但未开启自启", Toast.LENGTH_SHORT).show()
            }
        }
    }
}