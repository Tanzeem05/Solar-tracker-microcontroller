package com.solartracker.solar_tracker_app

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.MethodChannel

class TrackerNotifications(private val activity: Activity) {
    private val manager = activity.getSystemService(NotificationManager::class.java)
    private var permissionReply: MethodChannel.Result? = null

    init {
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(
                CHANNEL, "Tracker alerts", NotificationManager.IMPORTANCE_HIGH
            ).apply { description = "High temperature and rain detected by the connected solar tracker" })
        }
    }

    fun enabled(): Boolean {
        if (Build.VERSION.SDK_INT >= 33 &&
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return false
        if (!manager.areNotificationsEnabled()) return false
        return Build.VERSION.SDK_INT < 26 || manager.getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE
    }

    fun requestPermission(result: MethodChannel.Result) {
        if (permissionReply != null) {
            result.error("permission_busy", "Notification permission request already open", null)
        } else if (Build.VERSION.SDK_INT >= 33 &&
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            permissionReply = result
            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST)
        } else {
            result.success(enabled())
        }
    }

    fun permissionResult(requestCode: Int) {
        if (requestCode == REQUEST) {
            permissionReply?.success(enabled())
            permissionReply = null
        }
    }

    @Suppress("DEPRECATION")
    fun show(id: Int, title: String, body: String): Boolean {
        if (!enabled()) return false
        val launch = Intent(activity, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pending = PendingIntent.getActivity(activity, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(activity, CHANNEL)
                      else Notification.Builder(activity).setPriority(Notification.PRIORITY_HIGH)
                          .setDefaults(Notification.DEFAULT_ALL)
        val notification = builder.setSmallIcon(R.drawable.ic_tracker_notification)
            .setContentTitle(title).setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setCategory(Notification.CATEGORY_STATUS)
            .setContentIntent(pending).setAutoCancel(true).build()
        return try {
            manager.notify(id, notification)
            true
        } catch (_: SecurityException) { false }
    }

    fun dispose() {
        permissionReply?.success(false)
        permissionReply = null
    }

    companion object {
        private const val CHANNEL = "tracker_alerts_v1"
        private const val REQUEST = 5040
    }
}
