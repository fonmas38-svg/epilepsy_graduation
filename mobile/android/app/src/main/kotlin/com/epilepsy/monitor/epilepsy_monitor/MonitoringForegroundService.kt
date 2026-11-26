package com.epilepsy.monitor.epilepsy_monitor

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps the app process at foreground priority while monitoring runs, with a
 * persistent low-importance notification («المراقبة العصبية نشطة»).
 *
 * The monitoring loop itself stays in the Flutter engine. If the user removes
 * the task, the engine is destroyed and monitoring really stops, so this
 * service stops too: the notification must never claim monitoring that is not
 * happening. For the same reason it is START_NOT_STICKY.
 */
class MonitoringForegroundService : Service() {
    companion object {
        const val CHANNEL_ID = "monitoring_service"
        const val NOTIFICATION_ID = 7301
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val ACTION_STOP = "com.epilepsy.monitor.STOP_MONITORING_SERVICE"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelfCompat()
            return START_NOT_STICKY
        }
        ensureChannel()
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "المراقبة العصبية نشطة"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
        val notification = buildNotification(title, text)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSelfCompat()
        super.onTaskRemoved(rootIntent)
    }

    private fun stopSelfCompat() {
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Monitoring status",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shows that seizure monitoring is running"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(title: String, text: String): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK
        }
        val pending = launch?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setContentIntent(pending)
            .build()
    }
}
