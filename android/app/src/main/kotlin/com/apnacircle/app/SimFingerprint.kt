package com.apnacircle.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import java.security.MessageDigest

/**
 * SIM fingerprint for SIM-change detection (v0.5, 23 Nov 2026).
 *
 * HONEST LIMIT — read this before trusting the alert:
 * On Android 10+ a normal Play Store app CANNOT read the SIM's
 * ICCID or IMSI (those need READ_PRIVILEGED_PHONE_STATE, which
 * only system apps get). So the fingerprint is built from what a
 * normal app CAN read with READ_PHONE_STATE: the SIM operator
 * (MCC+MNC), the SIM country and the operator name. That catches
 * the realistic theft case — the thief inserts a DIFFERENT
 * carrier's SIM — but a same-carrier SIM swap will NOT be
 * detected. The fingerprint is SHA-256 hashed before it is stored
 * anywhere; the raw operator values never leave this file.
 *
 * Used by BootReceiver (after reboot) and by MainActivity's
 * "apnacircle/sim" channel (while the app runs). Both use the
 * same prefs + the same hash, so a change is caught either way.
 */
object SimFingerprint {
    const val PREFS_NAME = "apnacircle_sim"
    const val KEY_SIM_HASH = "sim_hash"
    const val KEY_PENDING_CHANGE = "pending_sim_change"

    /** Joined raw operator fields, or null when unreadable. */
    fun rawFingerprint(context: Context): String? {
        if (ContextCompat.checkSelfPermission(
                context, Manifest.permission.READ_PHONE_STATE
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return null
        }
        return try {
            val tm = context.getSystemService(Context.TELEPHONY_SERVICE)
                as TelephonyManager
            val operator = tm.simOperator ?: ""
            val country = tm.simCountryIso ?: ""
            val name = tm.simOperatorName ?: ""
            if (operator.isBlank() && country.isBlank() && name.isBlank()) {
                null
            } else {
                "$operator|$country|$name"
            }
        } catch (e: Exception) {
            null
        }
    }

    /** SHA-256 hex of the fingerprint. Never store the raw value. */
    fun hashFingerprint(raw: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val bytes = digest.digest(raw.toByteArray(Charsets.UTF_8))
        return bytes.joinToString("") { "%02x".format(it) }
    }

    /** Current SIM hash, or null when it cannot be read. */
    fun currentHash(context: Context): String? {
        val raw = rawFingerprint(context) ?: return null
        return hashFingerprint(raw)
    }
}
