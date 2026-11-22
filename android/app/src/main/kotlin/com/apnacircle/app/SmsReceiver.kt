package com.apnacircle.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import org.json.JSONArray
import org.json.JSONObject

/**
 * Incoming-SMS receiver for the OFFLINE location fallback (v0.3,
 * 22 Nov 2026).
 *
 * When a child's phone has no data, it sends its GPS fix to the
 * parent's number by SMS in this format:
 *   APNACIRCLE LOC:<lat>,<lon>,<epochMillis>
 *
 * This receiver ONLY acts on messages starting with that prefix —
 * every other SMS is ignored completely (never read, never stored).
 *
 * Delivery: the message is saved to SharedPreferences
 * ("apnacircle_sms" / "pending_sms") so it survives even if the app
 * is closed, and — when the app is running — it is also pushed live
 * to Dart through MainActivity's "apnacircle/sms" channel
 * ("onSmsLocation"). Dart reads the pending list on start/resume
 * and clears it after processing.
 *
 * NOTE: SMS_RECEIVED is delivered to any app holding RECEIVE_SMS
 * (no need to be the default SMS app — that is only required for
 * SMS_DELIVER). The permission is declared in AndroidManifest.xml.
 * Multi-part SMS are re-assembled per sender before matching.
 * Code written, NOT yet tested on a real phone (see README).
 */
class SmsReceiver : BroadcastReceiver() {

    companion object {
        const val PREFS_NAME = "apnacircle_sms"
        const val KEY_PENDING = "pending_sms"
        const val SMS_PREFIX = "APNACIRCLE LOC:"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) {
            return
        }
        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        // Re-assemble multi-part SMS per sender.
        val bySender = linkedMapOf<String, StringBuilder>()
        for (msg in messages) {
            val from = msg.originatingAddress ?: ""
            val part = msg.messageBody ?: ""
            bySender.getOrPut(from) { StringBuilder() }.append(part)
        }
        for ((from, bodyBuilder) in bySender) {
            val body = bodyBuilder.toString()
            if (!body.startsWith(SMS_PREFIX)) continue
            savePending(context, from, body)
            MainActivity.deliverSmsLocation(from, body)
        }
    }

    private fun savePending(context: Context, from: String, body: String) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val existing = JSONArray(prefs.getString(KEY_PENDING, "[]"))
        val entry = JSONObject().apply {
            put("from", from)
            put("body", body)
            put("at", System.currentTimeMillis())
        }
        existing.put(entry)
        // Keep only the latest 20 — an old phone should not replay
        // a huge backlog of stale locations.
        while (existing.length() > 20) existing.remove(0)
        prefs.edit().putString(KEY_PENDING, existing.toString()).apply()
    }
}
