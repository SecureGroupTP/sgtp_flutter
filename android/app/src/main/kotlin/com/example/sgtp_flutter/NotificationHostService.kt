package com.example.sgtp_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

class NotificationHostService : Service() {
    override fun onCreate() {
        super.onCreate()
        ensureChannel(this)
        startForeground(kForegroundNotificationId, buildNotification())
        isRunning = true
        Log.i(kLogTag, "Notification host service started")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        activeAccountId = intent?.getStringExtra(kExtraAccountId)?.trim().orEmpty()
        Log.i(kLogTag, "Notification host active account=${activeAccountId.take(8)}")
        return START_STICKY
    }

    override fun onDestroy() {
        Log.i(kLogTag, "Notification host service stopped")
        isRunning = false
        activeAccountId = ""
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, kChannelId)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("SGTP background sync")
            .setContentText("Notification host is active")
            .setOngoing(true)
            .setSilent(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    companion object {
        private const val kChannelId = "sgtp_notification_host"
        private const val kAppNotificationsChannelId = "sgtp_app_notifications"
        private const val kForegroundNotificationId = 42042
        private const val kExtraAccountId = "account_id"
        private const val kLogTag = "SGTPNotificationHost"

        @Volatile
        var isRunning: Boolean = false
        @Volatile
        var activeAccountId: String = ""

        fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                return
            }
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                ?: return
            val channel = NotificationChannel(
                kChannelId,
                "SGTP Notification Host",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Keeps Android notification host alive for SGTP"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }

        fun ensureAppNotificationsChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                return
            }
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                ?: return
            val channel = NotificationChannel(
                kAppNotificationsChannelId,
                "App Notifications",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "General SGTP app notifications"
                setShowBadge(true)
            }
            manager.createNotificationChannel(channel)
        }

        fun areNotificationsEnabled(context: Context): Boolean {
            return NotificationManagerCompat.from(context).areNotificationsEnabled()
        }

        fun start(context: Context, accountId: String) {
            ensureChannel(context)
            val intent = Intent(context, NotificationHostService::class.java).apply {
                putExtra(kExtraAccountId, accountId.trim())
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, NotificationHostService::class.java))
            isRunning = false
            activeAccountId = ""
        }

        fun stopForAccount(context: Context, accountId: String) {
            val normalized = accountId.trim()
            if (normalized.isEmpty()) {
                return
            }
            if (activeAccountId == normalized) {
                stop(context)
            }
        }
    }
}
