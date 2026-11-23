package com.apnacircle.app

import android.content.Context
import org.json.JSONObject
import kotlin.math.asin
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Member lookup cache for the real SIM-call distance overlay (v0.6.5).
 *
 * Dart writes ONE JSON string into Flutter SharedPreferences on every
 * member change (see lib/core/call_member_cache.dart, hooked into
 * FamilyService._save — add/remove/location/remote sync all flow
 * through it):
 *   file "FlutterSharedPreferences", key "flutter.apnacircle_call_cache"
 *   {"myLat":31.52,"myLon":74.35,"myAt":1732...,
 *    "members":[{"phone":"+923001234567","name":"Ali",
 *                "lat":31.5,"lon":74.3,"at":1732...}]}
 *
 * The native CallStateReceiver reads this WITHOUT the Flutter engine
 * running — a call can arrive while the app is dead, so the overlay
 * cannot depend on Dart. Only members with a stored phone AND
 * location sharing ON are in the cache (Dart filters the rest).
 *
 * NUMBER NORMALIZATION — the same rules as Dart's
 * CallMemberCache.normalizePhoneNumber. Keep the two in sync; the
 * test vectors live in test/call_overlay_test.dart (Dart) and are
 * repeated here:
 *   "+92 300 1234567" -> "+923001234567"
 *   "0300-1234567"    -> "+923001234567"
 *   "923001234567"    -> "+923001234567"
 *   "+1 415 555 0132" -> "+14155550132" (non-PK numbers kept as-is)
 * Matching is normalized-equality, with a last-10-digits fallback
 * (covers +92 vs 03… and any other country-code spelling).
 */
object CallMemberCache {
    const val PREFS_FILE = "FlutterSharedPreferences"
    const val KEY_CACHE = "flutter.apnacircle_call_cache"

    data class Lookup(
        val name: String,
        val lat: Double?,
        val lon: Double?,
        val myLat: Double?,
        val myLon: Double?,
    )

    fun normalize(raw: String): String {
        val digits = raw.filter { it.isDigit() }
        val hasPlus = raw.trimStart().startsWith("+")
        if (hasPlus) return "+$digits"
        // 92XXXXXXXXXX (12 digits, no +) -> +92...
        if (digits.length == 12 && digits.startsWith("92")) return "+$digits"
        // 03XXXXXXXXX (11 digits, Pakistani mobile) -> +92 + rest.
        if (digits.length == 11 && digits.startsWith("0")) {
            return "+92" + digits.substring(1)
        }
        // 3XXXXXXXXX (10 digits) -> +92...
        if (digits.length == 10 && digits.startsWith("3")) return "+92$digits"
        return digits
    }

    fun phonesMatch(a: String, b: String): Boolean {
        val na = normalize(a)
        val nb = normalize(b)
        if (na.isNotEmpty() && na == nb) return true
        val da = na.filter { it.isDigit() }
        val db = nb.filter { it.isDigit() }
        if (da.length >= 10 && db.length >= 10) {
            return da.takeLast(10) == db.takeLast(10)
        }
        return false
    }

    /** Find the cached member for a call number, or null when the
     *  caller is not a circle member (or there is no cache yet). */
    fun lookup(context: Context, rawNumber: String): Lookup? {
        val prefs = context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_CACHE, null) ?: return null
        val root = try {
            JSONObject(raw)
        } catch (e: Exception) {
            return null
        }
        val myLat = root.optDouble("myLat", Double.NaN).takeIf { !it.isNaN() }
        val myLon = root.optDouble("myLon", Double.NaN).takeIf { !it.isNaN() }
        val members = root.optJSONArray("members") ?: return null
        for (i in 0 until members.length()) {
            val obj = members.optJSONObject(i) ?: continue
            val phone = obj.optString("phone", "")
            if (phone.isBlank()) continue
            if (!phonesMatch(phone, rawNumber)) continue
            return Lookup(
                name = obj.optString("name", "Family"),
                lat = obj.optDouble("lat", Double.NaN).takeIf { !it.isNaN() },
                lon = obj.optDouble("lon", Double.NaN).takeIf { !it.isNaN() },
                myLat = myLat,
                myLon = myLon,
            )
        }
        return null
    }

    /** Haversine distance in km — same formula as Dart's
     *  LocationService.distanceKm / CallDistanceService.distanceKm. */
    fun distanceKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val r = 6371.0
        val dLat = Math.toRadians(lat2 - lat1)
        val dLon = Math.toRadians(lon2 - lon1)
        val a = sin(dLat / 2) * sin(dLat / 2) +
            cos(Math.toRadians(lat1)) * cos(Math.toRadians(lat2)) *
            sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(sqrt(a))
    }

    /** Same formatting as Dart's CallDistanceService.formatKm:
     *  under 1 km shows metres, otherwise one decimal + " km". */
    fun formatKm(km: Double): String =
        if (km < 1) {
            "${(km * 1000).roundToInt()} m"
        } else {
            String.format(java.util.Locale.US, "%.1f", km) + " km"
        }
}
