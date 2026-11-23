package com.apnacircle.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import org.json.JSONObject

/**
 * Boot receiver — restarts ApnaCircle's background awareness after
 * a reboot, and catches a SIM swap (v0.5, 23 Nov 2026).
 *
 * What it DOES on BOOT_COMPLETED:
 * 1. Compares the current SIM fingerprint hash with the stored one
 *    (see SimFingerprint). First boot ever just stores the baseline
 *    silently — no alert, because there is nothing to compare with.
 * 2. On a MISMATCH it stores a pending SIM-change event in
 *    SharedPreferences and posts a notification. Dart reads the
 *    pending event on the next app start and publishes it to the
 *    circle's RTDB events (with the last known location), so the
 *    parent is alerted even though the app itself was not running.
 *
 * What it CANNOT do (honest limits):
 * - It cannot restart the SIM-call listener: that needs the
 *   Activity, so call detection resumes only when the app is next
 *   opened. The SMS receiver is manifest-registered, so offline
 *   SMS location works after a reboot without the app opening.
 * - The alert needs net on the new SIM: with no data the pending
 *   event waits in SharedPreferences and is published when the app
 *   next runs with internet.
 * - A factory reset deletes the app, so no receiver runs at all
 *   after a reset (see README — no app can stop a recovery reset).
 * - This receiver runs after the user unlocks the phone (it is not
 *   direct-boot aware); a thief who never unlocks the phone sends
 *   nothing — the last location is all the family has.
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        try {
            val current = SimFingerprint.currentHash(context) ?: return
            val prefs = context.getSharedPreferences(
                SimFingerprint.PREFS_NAME, Context.MODE_PRIVATE
            )
            val stored = prefs.getString(SimFingerprint.KEY_SIM_HASH, null)
            if (stored == null) {
                // First boot ever seen: baseline, no alert.
                prefs.edit()
                    .putString(SimFingerprint.KEY_SIM_HASH, current)
                    .apply()
                return
            }
            if (stored != current) {
                val event = JSONObject().apply {
                    put("type", "simChanged")
                    put("at", System.currentTimeMillis())
                    put("oldHash", stored)
                    put("newHash", current)
                }
                prefs.edit()
                    .putString(SimFingerprint.KEY_SIM_HASH, current)
                    .putString(SimFingerprint.KEY_PENDING_CHANGE, event.toString())
                    .apply()
                postSimChangedNotification(context)
            }
        } catch (e: Exception) {
            // Never crash boot for a SIM check.
        }
    }

    private fun postSimChangedNotification(context: Context) {
        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    ApnaCircleDeviceAdminReceiver.CHANNEL_ID,
                    "ApnaCircle protection alerts",
                    NotificationManager.IMPORTANCE_HIGH,
                )
                nm.createNotificationChannel(channel)
            }
            val notification = NotificationCompat.Builder(
                context, ApnaCircleDeviceAdminReceiver.CHANNEL_ID
            )
                .setSmallIcon(android.R.drawable.ic_dialog_alert)
                .setContentTitle("SIM card changed")
                .setContentText(
                    "A different SIM was detected in this phone. " +
                        "Your family will be alerted."
                )
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
                .build()
            nm.notify(9002, notification)
        } catch (e: Exception) {
            // Silently no-ops without notification permission.
        }
    }
}
