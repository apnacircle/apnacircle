package com.apnacircle.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.admin.DeviceAdminReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat

/**
 * Device Admin receiver — uninstall protection (v0.5, 23 Nov 2026).
 *
 * HONEST LIMIT, stated plainly: on modern Android NO app can truly
 * BLOCK its own uninstall. What Device Admin does is force an extra
 * step: Android refuses to uninstall the app while it is a device
 * admin, so a child must first deactivate the admin in Settings —
 * and the moment they do, this receiver fires onDisabled(), stores
 * a pending alert, and (when allowed) posts a notification. Dart
 * picks the pending alert up on the next start and writes it to the
 * circle's RTDB events so the parent sees it. The protection is
 * the friction + the alert, not an unbreakable lock.
 *
 * Enabling is always the user's own action: Dart fires the system
 * ACTION_ADD_DEVICE_ADMIN screen (see MainActivity, channel
 * "apnacircle/deviceadmin"); Android shows its own warning and the
 * user must accept. The app never enables admin silently.
 */
class ApnaCircleDeviceAdminReceiver : DeviceAdminReceiver() {

    companion object {
        const val PREFS_NAME = "apnacircle_admin"
        const val KEY_ADMIN_ACTIVE = "admin_active"
        const val KEY_ADMIN_ENABLED_AT = "admin_enabled_at"
        const val KEY_PENDING_DISABLED = "pending_admin_disabled"
        const val CHANNEL_ID = "apnacircle_admin_alerts"
    }

    /** Text Android shows when the user tries to deactivate admin. */
    override fun onDisableRequested(
        context: Context,
        intent: Intent,
    ): CharSequence {
        return "Warning: turning this off lets ApnaCircle be uninstalled, " +
            "and your parent will be alerted."
    }

    override fun onEnabled(context: Context, intent: Intent) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_ADMIN_ACTIVE, true)
            .putLong(KEY_ADMIN_ENABLED_AT, System.currentTimeMillis())
            .apply()
    }

    override fun onDisabled(context: Context, intent: Intent) {
        val atMs = System.currentTimeMillis()
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit()
            .putBoolean(KEY_ADMIN_ACTIVE, false)
            .putLong(KEY_PENDING_DISABLED, atMs)
            .apply()
        // v0.6.13: ALSO write the deactivation time into the
        // FlutterSharedPreferences file (the "flutter."-prefixed
        // key the shared_preferences plugin reads), so the
        // background location task — which runs every 60 s while
        // the app is still installed — can publish the
        // `adminDisabled` event to the parent within a minute,
        // instead of waiting for the next app start (which never
        // comes if the child uninstalls right after deactivating).
        // The Dart side claims (removes) the flag before
        // publishing, so it can only ever send one event.
        try {
            context.getSharedPreferences(
                "FlutterSharedPreferences", Context.MODE_PRIVATE
            ).edit()
                .putLong(
                    "flutter.apnacircle_admin_disabled_at", atMs
                )
                .apply()
        } catch (e: Exception) {
            // The native flag above is still the backup — the
            // next app start publishes from it.
        }
        postAdminDisabledNotification(context)
    }

    private fun postAdminDisabledNotification(context: Context) {
        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "ApnaCircle protection alerts",
                    NotificationManager.IMPORTANCE_HIGH,
                )
                nm.createNotificationChannel(channel)
            }
            val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_dialog_alert)
                .setContentTitle("ApnaCircle protection turned off")
                .setContentText(
                    "Device admin was deactivated — the app can now be " +
                        "uninstalled. Your parent will be alerted."
                )
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
                .build()
            // Silently no-ops when POST_NOTIFICATIONS was not granted.
            nm.notify(9001, notification)
        } catch (e: Exception) {
            // Never crash the receiver for a notification failure.
        }
    }
}
