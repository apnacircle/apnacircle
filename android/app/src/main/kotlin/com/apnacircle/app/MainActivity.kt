package com.apnacircle.app

import android.Manifest
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import android.telephony.PhoneStateListener
import android.telephony.SmsManager
import android.telephony.TelephonyManager
import android.view.accessibility.AccessibilityManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

/**
 * ApnaCircle native bridge.
 *
 * Channels (must match lib/core/constants.dart):
 * - "apnacircle/calls"   : incoming SIM-call number for caller distance.
 * - "apnacircle/applock" : locked-app packages + schedule for AppLockService.
 * - "apnacircle/sms"     : offline SMS location (v0.3) — send a GPS fix
 *   by SMS to a parent number when the phone has no data, and read
 *   incoming APNACIRCLE LOC: messages saved by SmsReceiver.
 * - "apnacircle/device"  : stable device id for the 7-day free trial
 *   (23 Nov 2026) — "getAndroidId" returns Settings.Secure.ANDROID_ID.
 *   Dart hashes it (SHA-256) before storing; the raw id never leaves
 *   the phone. No permission needed.
 * - "apnacircle/deviceadmin" (v0.5): Device Admin status / enable /
 *   remove — uninstall takes an extra deactivation step + alert.
 * - "apnacircle/sim" (v0.5): SIM fingerprint hash + pending SIM-change
 *   event left by BootReceiver; pending admin-disabled alert.
 *
 * WHAT IS IMPLEMENTED HERE (v0.2, 22 Nov 2026 — code written, NOT
 * yet tested on a real phone):
 * - Calls: a TelephonyManager PhoneStateListener records the ringing
 *   number in memory + SharedPreferences ("apnacircle_last_caller")
 *   and "incomingNumber" returns it. v0.5: the number is only
 *   delivered by Android 10+ when the app ALSO holds READ_CALL_LOG,
 *   so Dart asks for both permissions with a plain explanation
 *   first ("requestCallPermissions") and the listener restarts
 *   after the grant. Without READ_CALL_LOG the listener still runs
 *   but the number comes back empty — that is an Android rule, not
 *   a bug in this code.
 * - AppLock: "applyLocks" persists the full schedule JSON
 *   (packages + per-app mode/time-window, from Dart) to
 *   SharedPreferences ("apnacircle_locks") so AppLockService can read
 *   it even after a reboot, and "isLockServiceEnabled" reports
 *   whether the user has enabled the Accessibility service.
 *
 * WHAT STILL NEEDS A REAL PHONE (do NOT claim these work until tested):
 * 1. SIM-call number on Android 10+ with READ_CALL_LOG granted, on
 *    both SIMs of a dual-SIM phone. CallScreeningService would be
 *    more robust but requires the call-screening role — a big UX +
 *    Play-permission decision, NOT taken in v0.5.
 * 2. AppLockService must be enabled by the user in Settings >
 *    Accessibility (Android shows a warning — that is normal).
 *    The PIN overlay is currently a launch of MainActivity with a
 *    "locked_package" extra; a true SYSTEM_ALERT_WINDOW overlay and
 *    a dedicated LockActivity are still to be built.
 * 3. Device Admin (v0.5): enabling must be tested end-to-end —
 *    system admin screen, uninstall blocked while active, alert on
 *    deactivation. Honest limit: admin cannot truly BLOCK uninstall,
 *    it only forces deactivation first + alerts (see
 *    ApnaCircleDeviceAdminReceiver).
 * 4. SIM-change alert (v0.5): BootReceiver + fingerprint are wired,
 *    but a same-carrier SIM swap is NOT detectable (Android 10+
 *    hides ICCID/IMSI from normal apps — see SimFingerprint).
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

        // Request code for READ_PHONE_STATE + READ_CALL_LOG (v0.5).
        private const val CALL_PERMISSIONS_REQUEST_CODE = 1001

        fun deliverSmsLocation(from: String, body: String) {
            smsChannel?.invokeMethod(
                "onSmsLocation",
                mapOf("from" to from, "body" to body),
            )
        }
    }

    private var lastIncomingNumber: String? = null
    private var phoneListener: PhoneStateListener? = null

    // One permission request at a time (v0.5): the pending Dart
    // result is answered from onRequestPermissionsResult.
    private var pendingCallPermissionResult: MethodChannel.Result? = null

    private fun adminComponent(): ComponentName =
        ComponentName(this, ApnaCircleDeviceAdminReceiver::class.java)

    private fun devicePolicyManager(): DevicePolicyManager =
        getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager

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
                    // Android 10+ only hands the ringing number to apps
                    // holding READ_CALL_LOG. Dart shows a plain
                    // explanation first, then calls this.
                    "hasCallLogPermission" -> result.success(
                        ContextCompat.checkSelfPermission(
                            this, Manifest.permission.READ_CALL_LOG
                        ) == PackageManager.PERMISSION_GRANTED
                    )
                    "requestCallPermissions" -> requestCallPermissions(result)
                    // Re-register the listener after a permission
                    // grant (the listener registered before the grant
                    // keeps delivering empty numbers).
                    "refreshCallListener" -> {
                        startCallListener()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // Device Admin — uninstall protection (v0.5). Enabling is
        // always the user's own tap on Android's system screen;
        // the app never enables admin silently.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, "apnacircle/deviceadmin"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isAdminActive" -> result.success(
                    devicePolicyManager().isAdminActive(adminComponent())
                )
                "requestAdmin" -> {
                    val intent =
                        Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN)
                    intent.putExtra(
                        DevicePolicyManager.EXTRA_DEVICE_ADMIN,
                        adminComponent(),
                    )
                    intent.putExtra(
                        DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                        "ApnaCircle protects your family: as a device " +
                            "admin it cannot be uninstalled without " +
                            "deactivating it first, and your parent is " +
                            "alerted if that happens.",
                    )
                    startActivity(intent)
                    result.success(null)
                }
                "removeAdmin" -> {
                    try {
                        devicePolicyManager().removeActiveAdmin(adminComponent())
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                // Pending alert left by the receiver when admin was
                // deactivated (epoch ms), or null.
                "getPendingAdminDisabled" -> result.success(
                    getSharedPreferences(
                        ApnaCircleDeviceAdminReceiver.PREFS_NAME,
                        Context.MODE_PRIVATE,
                    ).getLong(
                        ApnaCircleDeviceAdminReceiver.KEY_PENDING_DISABLED, 0L
                    ).takeIf { it != 0L }
                )
                "clearPendingAdminDisabled" -> {
                    getSharedPreferences(
                        ApnaCircleDeviceAdminReceiver.PREFS_NAME,
                        Context.MODE_PRIVATE,
                    ).edit().remove(
                        ApnaCircleDeviceAdminReceiver.KEY_PENDING_DISABLED
                    ).apply()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // SIM-change detection (v0.5, see SimFingerprint): only the
        // SHA-256 hash is ever stored or returned — never raw SIM data.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, "apnacircle/sim"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSimFingerprint" -> result.success(
                    SimFingerprint.currentHash(this)
                )
                // Pending SIM-change event left by BootReceiver
                // (JSON string), or null.
                "getPendingSimChange" -> result.success(
                    getSharedPreferences(
                        SimFingerprint.PREFS_NAME, Context.MODE_PRIVATE
                    ).getString(SimFingerprint.KEY_PENDING_CHANGE, null)
                )
                "clearPendingSimChange" -> {
                    getSharedPreferences(
                        SimFingerprint.PREFS_NAME, Context.MODE_PRIVATE
                    ).edit().remove(SimFingerprint.KEY_PENDING_CHANGE).apply()
                    result.success(null)
                }
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

        // Stable device id for the 7-day free trial (23 Nov 2026):
        // one trial per PHONE, not per account. ANDROID_ID is stable
        // across reinstalls on the same phone; a factory reset changes
        // it (accepted limit — see DeviceIdService). Dart hashes the
        // id (SHA-256) before storing; the raw id never leaves here.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, "apnacircle/device"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getAndroidId" -> result.success(
                    Settings.Secure.getString(
                        contentResolver, Settings.Secure.ANDROID_ID
                    )
                )
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

    private fun requestCallPermissions(result: MethodChannel.Result) {
        if (pendingCallPermissionResult != null) {
            result.error("BUSY", "A permission request is already running.", null)
            return
        }
        pendingCallPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(
                Manifest.permission.READ_PHONE_STATE,
                Manifest.permission.READ_CALL_LOG,
            ),
            CALL_PERMISSIONS_REQUEST_CODE,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != CALL_PERMISSIONS_REQUEST_CODE) return
        val pending = pendingCallPermissionResult ?: return
        pendingCallPermissionResult = null
        var phoneState = false
        var callLog = false
        for (i in permissions.indices) {
            val granted = i < grantResults.size &&
                grantResults[i] == PackageManager.PERMISSION_GRANTED
            when (permissions[i]) {
                Manifest.permission.READ_PHONE_STATE -> phoneState = granted
                Manifest.permission.READ_CALL_LOG -> callLog = granted
            }
        }
        if (phoneState) startCallListener()
        pending.success(mapOf("phoneState" to phoneState, "callLog" to callLog))
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
