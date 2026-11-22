package com.apnacircle.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.telephony.PhoneStateListener
import android.telephony.SmsManager
import android.telephony.TelephonyManager
import android.view.accessibility.AccessibilityManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray

/**
 * ApnaCircle native bridge.
 *
 * Channels (must match lib/core/constants.dart):
 * - "apnacircle/calls"   : incoming SIM-call number for caller distance.
 * - "apnacircle/applock" : locked-app packages + schedule for AppLockService.
 * - "apnacircle/sms"     : offline SMS location (v0.3) — send a GPS fix
 *   by SMS to a parent number when the phone has no data, and read
 *   incoming APNACIRCLE LOC: messages saved by SmsReceiver.
 *
 * WHAT IS IMPLEMENTED HERE (v0.2, 22 Nov 2026 — code written, NOT
 * yet tested on a real phone):
 * - Calls: a TelephonyManager PhoneStateListener records the ringing
 *   number in memory + SharedPreferences ("apnacircle_last_caller")
 *   and "incomingNumber" returns it. This is the classic pre-Android-10
 *   path and works on minSdk 21 devices.
 * - AppLock: "applyLocks" persists the full schedule JSON
 *   (packages + per-app mode/time-window, from Dart) to
 *   SharedPreferences ("apnacircle_locks") so AppLockService can read
 *   it even after a reboot, and "isLockServiceEnabled" reports
 *   whether the user has enabled the Accessibility service.
 *
 * WHAT STILL NEEDS A REAL PHONE (do NOT claim these work until tested):
 * 1. On Android 10+, PhoneStateListener only gives the number when
 *    the app holds READ_PHONE_STATE *and* the number is not withheld
 *    by the carrier. The robust path is CallScreeningService, but that
 *    requires the user to set ApnaCircle as the default dialer /
 *    call-screening role — a big UX + Play-permission decision.
 *    Dual-SIM phones may report the wrong subscription; test both SIMs.
 * 2. AppLockService must be enabled by the user in Settings >
 *    Accessibility (Android shows a warning — that is normal).
 *    The PIN overlay is currently a launch of MainActivity with a
 *    "locked_package" extra; a true SYSTEM_ALERT_WINDOW overlay and
 *    a dedicated LockActivity are still to be built.
 * 3. Device Admin (so a child cannot uninstall ApnaCircle) is NOT
 *    wired yet — it needs a DeviceAdminReceiver + policy XML.
 * iOS cannot do SIM-call distance at all (Apple restriction).
 */
class MainActivity : FlutterActivity() {

    companion object {
        // Live SMS-location channel, set when the engine is ready.
        // SmsReceiver calls deliverSmsLocation() when a location SMS
        // arrives; it is a no-op when the app is not running (the
        // message is still saved in SharedPreferences by the
        // receiver, and Dart reads it on the next start).
        private var smsChannel: MethodChannel? = null

        fun deliverSmsLocation(from: String, body: String) {
            smsChannel?.invokeMethod(
                "onSmsLocation",
                mapOf("from" to from, "body" to body),
            )
        }
    }

    private var lastIncomingNumber: String? = null
    private var phoneListener: PhoneStateListener? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        startCallListener()

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "apnacircle/calls")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Last ringing number recorded by the listener, or null
                    // when there is no incoming call / number withheld.
                    "incomingNumber" -> result.success(lastIncomingNumber)
                    "getLastIncomingNumber" -> result.success(
                        getSharedPreferences("apnacircle", Context.MODE_PRIVATE)
                            .getString("apnacircle_last_caller", null)
                    )
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "apnacircle/applock")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Dart sends {packages: [...], schedule: [{name, package,
                    // mode, window, ...}]}. Persist the schedule so
                    // AppLockService can enforce it after reboot.
                    "applyLocks" -> {
                        val schedule = call.argument<List<Map<String, Any>>>("schedule")
                        val prefs = getSharedPreferences(
                            AppLockService.PREFS_NAME, Context.MODE_PRIVATE
                        )
                        prefs.edit()
                            .putString(
                                AppLockService.KEY_SCHEDULE,
                                org.json.JSONArray(schedule ?: emptyList<Map<String, Any>>()).toString()
                            )
                            .apply()
                        result.success(isLockServiceEnabled())
                    }
                    "isLockServiceEnabled" -> result.success(isLockServiceEnabled())
                    else -> result.notImplemented()
                }
            }

        // Offline SMS location (v0.3): the child phone sends its GPS
        // fix by SMS to the parent when it has no data; the parent
        // phone reads APNACIRCLE LOC: messages saved by SmsReceiver.
        // Dart asks permission_handler for Permission.sms first and
        // only calls sendSms with a parent's number from the same
        // circle. SmsManager throws SecurityException without the
        // permission — caught here, reported as false.
        val sms = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, "apnacircle/sms"
        )
        smsChannel = sms
        sms.setMethodCallHandler { call, result ->
            when (call.method) {
                "sendSms" -> {
                    val to = call.argument<String>("to")
                    val body = call.argument<String>("body")
                    if (to.isNullOrBlank() || body.isNullOrBlank()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    try {
                        SmsManager.getDefault()
                            .sendTextMessage(to, null, body, null, null)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "getPendingSmsLocations" -> result.success(readPendingSms())
                "clearPendingSmsLocations" -> {
                    getSharedPreferences(
                        SmsReceiver.PREFS_NAME, Context.MODE_PRIVATE
                    ).edit().remove(SmsReceiver.KEY_PENDING).apply()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun readPendingSms(): List<Map<String, Any>> {
        val prefs = getSharedPreferences(
            SmsReceiver.PREFS_NAME, Context.MODE_PRIVATE
        )
        val raw = prefs.getString(SmsReceiver.KEY_PENDING, "[]") ?: "[]"
        val out = mutableListOf<Map<String, Any>>()
        val arr = JSONArray(raw)
        for (i in 0 until arr.length()) {
            val obj = arr.optJSONObject(i) ?: continue
            out.add(
                mapOf(
                    "from" to (obj.optString("from")),
                    "body" to (obj.optString("body")),
                    "at" to obj.optLong("at"),
                )
            )
        }
        return out
    }

    private fun startCallListener() {
        if (ContextCompat.checkSelfPermission(
                this, Manifest.permission.READ_PHONE_STATE
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            // Permission is requested from Dart (permission_handler).
            // Without it the listener cannot be registered.
            return
        }
        val tm = getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
        phoneListener = object : PhoneStateListener() {
            @Deprecated("Deprecated in Java")
            override fun onCallStateChanged(state: Int, incomingNumber: String?) {
                if (state == TelephonyManager.CALL_STATE_RINGING && !incomingNumber.isNullOrBlank()) {
                    lastIncomingNumber = incomingNumber
                    getSharedPreferences("apnacircle", Context.MODE_PRIVATE)
                        .edit()
                        .putString("apnacircle_last_caller", incomingNumber)
                        .apply()
                }
                if (state == TelephonyManager.CALL_STATE_IDLE) {
                    lastIncomingNumber = null
                }
            }
        }
        @Suppress("DEPRECATION")
        tm.listen(phoneListener, PhoneStateListener.LISTEN_CALL_STATE)
    }

    private fun isLockServiceEnabled(): Boolean {
        val am = getSystemService(Context.ACCESSIBILITY_SERVICE) as AccessibilityManager
        val enabled = am.getEnabledAccessibilityServiceList(
            android.accessibilityservice.AccessibilityServiceInfo.FEEDBACK_GENERIC
        )
        return enabled.any { it.resolveInfo.serviceInfo.packageName == packageName }
    }

    override fun onDestroy() {
        phoneListener?.let {
            val tm = getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
            @Suppress("DEPRECATION")
            tm.listen(it, PhoneStateListener.LISTEN_NONE)
        }
        super.onDestroy()
    }
}
