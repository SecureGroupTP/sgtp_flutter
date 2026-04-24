package com.example.sgtp_flutter

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class NotificationHostBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED -> {
                // Account-aware host is started from Flutter after active account resolution.
            }
        }
    }
}
