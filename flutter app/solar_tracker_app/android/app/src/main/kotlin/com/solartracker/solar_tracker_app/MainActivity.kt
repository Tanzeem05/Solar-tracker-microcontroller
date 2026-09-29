package com.solartracker.solar_tracker_app

import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var settingsChannel: MethodChannel? = null
    private var alertsChannel: MethodChannel? = null
    private var alerts: TrackerNotifications? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        alerts = TrackerNotifications(this)
        alertsChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "solar_tracker/alerts")
        alertsChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "enabled" -> result.success(alerts!!.enabled())
                "requestPermission" -> alerts!!.requestPermission(result)
                "show" -> {
                    val id = call.argument<Int>("id")
                    val title = call.argument<String>("title")
                    val body = call.argument<String>("body")
                    if (id == null || title == null || body == null) {
                        result.error("invalid_alert", "Alert details are required", null)
                    } else {
                        result.success(alerts!!.show(id, title, body))
                    }
                }
                else -> result.notImplemented()
            }
        }
        settingsChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "solar_tracker/settings")
        settingsChannel?.setMethodCallHandler { call, result ->
            if (call.method != "openBluetoothSettings") {
                result.notImplemented()
            } else {
                try {
                    startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
                    result.success(null)
                } catch (error: Exception) {
                    result.error("settings_unavailable", "Open Bluetooth Settings manually.", null)
                }
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        alerts?.dispose()
        alertsChannel?.setMethodCallHandler(null)
        alertsChannel = null
        alerts = null
        settingsChannel?.setMethodCallHandler(null)
        settingsChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        alerts?.permissionResult(requestCode)
    }
}
