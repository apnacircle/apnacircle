package com.apnacircle.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.telephony.PhoneStateListener
import android.telephony.TelephonyManager
import android.view.accessibility.AccessibilityManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * ApnaCircle native bridge.
 *
 * Channels (must match lib/core/constants.dart):
 * - "apnacircle/calls"   : incoming SIM-call number for caller distance.
 * - "apnacircle/applock" : locked-app packages + schedule for AppLockService.
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
