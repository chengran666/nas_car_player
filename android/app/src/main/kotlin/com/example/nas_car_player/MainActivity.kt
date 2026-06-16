package com.example.nas_car_player

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 💡 在安卓底层接通这条通讯管道
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.nascarplayer/app_retain")
            .setMethodCallHandler { call, result ->
                if (call.method == "sendToBackground") {
                    // 💡 收到挂起指令，调用安卓原生的 moveTaskToBack，完美退到后台不死！
                    moveTaskToBack(true)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }
}