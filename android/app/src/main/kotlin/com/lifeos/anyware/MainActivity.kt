package com.lifeos.anyware

import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.lifeos.anyware/platform"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isTV" -> {
                        val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
                        val isTV = uiModeManager.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
                        result.success(isTV)
                    }
                    "updateDirectShareTargets" -> {
                        @Suppress("UNCHECKED_CAST")
                        val devices = call.argument<List<Map<String, Any>>>("devices")
                        if (devices != null) {
                            DirectShareService.updateShortcuts(applicationContext, devices)
                            result.success(true)
                        } else {
                            result.error("INVALID_ARGS", "devices argument is required", null)
                        }
                    }
                    "clearDirectShareTargets" -> {
                        DirectShareService.clearShortcuts(applicationContext)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
