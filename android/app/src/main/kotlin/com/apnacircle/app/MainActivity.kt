package com.apnacircle.app

import android.Manifest
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.telephony.PhoneStateListener
import android.telephony.SmsManager
import android.telephony.TelephonyManager
import android.util.Base64
import android.view.accessibility.AccessibilityManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest
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
 *   v0.6.3: "applyLocks" also resolves custom apps added by name
 *   ("custom:<name>") to real package names via PackageManager, and
 *   stamps a version so the service reloads changed rules live.
 *   "openAccessibilitySettings" opens Settings → Accessibility —
 *   the service can only be enabled by the user's own tap there.
 *
 * WHAT STILL NEEDS A REAL PHONE (do NOT claim these work until tested):
 * 1. SIM-call number on Android 10+ with READ_CALL_LOG granted, on
 *    both SIMs of a dual-SIM phone. v0.6.5: the real distance overlay
 *    is now wired — CallStateReceiver (manifest-registered, so it
 *    works with the app dead) matches the number against the member
 *    cache Dart keeps in SharedPreferences and shows a WindowManager
 *    overlay (CallOverlayManager) over the call screen; it hides on
 *    IDLE. It needs, on the phone: READ_CALL_LOG (incoming number),
 *    PROCESS_OUTGOING_CALLS (dialled number) and "Display over other
 *    apps" (the overlay itself). Test both directions on a real
 *    phone; outgoing delivery is deprecated-but-working (see
 *    CallStateReceiver for the limits).
 * 2. AppLockService (v0.6.3: declared in the manifest + config,
 *    LockActivity PIN screen, Dart subscribes to locks at Home):
 *    enable it in Settings > Accessibility (Android shows a
 *    warning — that is normal); the Locks screen shows ON/OFF.
 *    The child can still turn it OFF in Settings (Android rule);
 *    Device Admin + the deactivation alert are the tripwire.
 *    Test on a real phone: lock an app, open it, PIN screen must
 *    appear; correct PIN = 5-minute grant; time windows across
 *    midnight and across a day boundary.
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

    /**
     * Base64 SHA-256 of this app's signing certificate (v0.6.13) —
     * the value the Device Owner QR checksum must carry. The
     * provisioning wizard downloads the APK from the URL in the QR
     * and refuses it when the checksum does not match the APK's
     * own certificate. CI builds are debug-signed with a FRESH key
     * per run, so the QR is only valid for the exact APK build it
     * was generated from. Null when the certificate cannot be read.
     */
    private fun signingChecksum(): String? {
        return try {
            val certs = if (android.os.Build.VERSION.SDK_INT >=
                android.os.Build.VERSION_CODES.P
            ) {
                val info = packageManager.getPackageInfo(
                    packageName,
                    PackageManager.GET_SIGNING_CERTIFICATES,
                )
                info.signingInfo?.apkContentsSigners
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(
                    packageName,
                    PackageManager.GET_SIGNATURES,
                ).signatures
            }
            val cert = certs?.firstOrNull() ?: return null
            val digest = MessageDigest.getInstance("SHA-256")
                .digest(cert.toByteArray())
            Base64.encodeToString(digest, Base64.NO_WRAP)
        } catch (e: Exception) {
            null
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        forwardLockedPackage(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        forwardLockedPackage(intent)
    }

    /**
     * Compatibility: if MainActivity is ever launched with a
     * "locked_package" extra (old service builds did that), hand it
     * to the dedicated LockActivity instead of showing Home.
     */
    private fun forwardLockedPackage(intent: Intent?) {
        val pkg = intent?.getStringExtra("locked_package") ?: return
        val lock = Intent(this, LockActivity::class.java).apply {
            putExtra(LockActivity.EXTRA_PACKAGE, pkg)
            intent.getStringExtra("locked_app_name")?.let {
                putExtra(LockActivity.EXTRA_APP_NAME, it)
            }
        }
        startActivity(lock)
    }

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
                    // v0.6.5 — call distance overlay permission.
                    // "Display over other apps": without it the
                    // overlay cannot appear over the call screen.
                    // Only the user's own tap on Android's system
                    // page can grant it — no app can grant it itself.
                    "canDrawOverlays" -> result.success(
                        if (android.os.Build.VERSION.SDK_INT >=
                            android.os.Build.VERSION_CODES.M
                        ) {
                            Settings.canDrawOverlays(this)
                        } else {
                            true
                        }
                    )
                    "openOverlaySettings" -> {
                        startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName"),
                            )
                        )
                        result.success(null)
                    }
                    // Outgoing-call number (NEW_OUTGOING_CALL) needs
                    // PROCESS_OUTGOING_CALLS — requested together
                    // with the call permissions below.
                    "hasOutgoingCallPermission" -> result.success(
                        ContextCompat.checkSelfPermission(
                            this, Manifest.permission.PROCESS_OUTGOING_CALLS
                        ) == PackageManager.PERMISSION_GRANTED
                    )
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

        // Device Owner — the only truly non-uninstallable protection
        // (v0.6.13). A device-owner app has NO working uninstall in
        // Settings. Setup is a one-time QR provisioning on a fresh /
        // factory-reset phone (see DeviceOwnerService + the setup
        // screen); removal is PIN-gated clearDeviceOwnerApp from
        // inside the app, so the parent is never locked out of
        // their own phone by this protection.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, "apnacircle/deviceowner"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isDeviceOwner" -> result.success(
                    devicePolicyManager().isDeviceOwnerApp(packageName)
                )
                // Base64 SHA-256 of this app's signing certificate —
                // the QR checksum the provisioning wizard verifies
                // against the APK at the download URL. Null when it
                // cannot be read (the setup screen then refuses to
                // show a QR rather than showing a wrong one).
                "getSigningChecksum" -> result.success(signingChecksum())
                // Parent-controlled removal (PIN-gated in Dart):
                // only the device owner app itself can call this.
                // The app stays installed, but loses owner status.
                "clearDeviceOwner" -> {
                    try {
                        devicePolicyManager().clearDeviceOwnerApp(packageName)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
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
                    // v0.6.3: custom apps added by name ("custom:<name>")
                    // are resolved to real package names here, and a
                    // version timestamp is stamped so the service
                    // reloads changed rules without restarting.
                    "applyLocks" -> {
                        val schedule = call.argument<List<Map<String, Any>>>("schedule")
                        val resolved = (schedule ?: emptyList()).map { entry ->
                            val pkg = entry["package"] as? String ?: ""
                            if (pkg.startsWith("custom:")) {
                                val real = resolvePackageForName(
                                    pkg.removePrefix("custom:")
                                )
                                if (real != null) entry + ("package" to real) else entry
                            } else {
                                entry
                            }
                        }
                        val prefs = getSharedPreferences(
                            AppLockService.PREFS_NAME, Context.MODE_PRIVATE
                        )
                        prefs.edit()
                            .putString(
                                AppLockService.KEY_SCHEDULE,
                                org.json.JSONArray(resolved).toString()
                            )
                            .putLong(
                                AppLockService.KEY_SCHEDULE_VERSION,
                                System.currentTimeMillis()
                            )
                            .apply()
                        result.success(isLockServiceEnabled())
                    }
                    "isLockServiceEnabled" -> result.success(isLockServiceEnabled())
                    // Open Settings → Accessibility. Only the user's own
                    // tap there can enable the service — no app can
                    // enable an AccessibilityService by itself.
                    "openAccessibilitySettings" -> {
                        startActivity(
                            Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                        )
                        result.success(null)
                    }
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
                // v0.6.5: the dialled number for the outgoing-call
                // overlay (NEW_OUTGOING_CALL). Same Play CALL_LOG
                // declaration as READ_CALL_LOG.
                Manifest.permission.PROCESS_OUTGOING_CALLS,
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
        var outgoingCall = false
        for (i in permissions.indices) {
            val granted = i < grantResults.size &&
                grantResults[i] == PackageManager.PERMISSION_GRANTED
            when (permissions[i]) {
                Manifest.permission.READ_PHONE_STATE -> phoneState = granted
                Manifest.permission.READ_CALL_LOG -> callLog = granted
                Manifest.permission.PROCESS_OUTGOING_CALLS ->
                    outgoingCall = granted
            }
        }
        if (phoneState) startCallListener()
        pending.success(
            mapOf(
                "phoneState" to phoneState,
                "callLog" to callLog,
                "outgoingCall" to outgoingCall,
            )
        )
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
        // ALL_MASK (not FEEDBACK_GENERIC): our service declares
        // feedbackGeneric, but the check must not depend on it.
        val enabled = am.getEnabledAccessibilityServiceList(
            android.accessibilityservice.AccessibilityServiceInfo.FEEDBACK_ALL_MASK
        )
        return enabled.any { it.resolveInfo.serviceInfo.packageName == packageName }
    }

    /**
     * Resolve a parent-typed app name ("Snapchat") to its real
     * package name on THIS phone. v0.6.8: matching is tolerant —
     * labels are compared normalized (lowercase, no spaces or
     * punctuation), so "Playstore" finds "Play Store", and a small
     * alias map covers short forms the parent actually types
     * ("WA Business" -> WhatsApp Business — no normalization can
     * bridge that one, the real label is "WhatsApp Business").
     * Order: known alias, exact label, normalized exact, then a
     * "contains" match (raw or normalized). Null when the app is
     * not installed — the entry stays "custom:<name>" and can
     * resolve on a later call.
     */
    private fun resolvePackageForName(name: String): String? {
        val wanted = name.trim().lowercase()
        if (wanted.isEmpty()) return null
        knownPackageForName(wanted)?.let { return it }
        val wantedNorm = normalizeAppName(wanted)
        if (wantedNorm.isEmpty()) return null
        val apps = try {
            packageManager.getInstalledApplications(PackageManager.GET_META_DATA)
        } catch (e: Exception) {
            return null
        }
        var contains: String? = null
        for (app in apps) {
            val label = try {
                packageManager.getApplicationLabel(app)?.toString()?.lowercase()
                    ?: ""
            } catch (e: Exception) {
                ""
            }
            if (label == wanted) return app.packageName
            val labelNorm = normalizeAppName(label)
            if (labelNorm == wantedNorm) return app.packageName
            if (contains == null &&
                (label.contains(wanted) || labelNorm.contains(wantedNorm))
            ) {
                contains = app.packageName
            }
        }
        return contains
    }

    /** Lowercase, letters/digits only: "Play Store" -> "playstore". */
    private fun normalizeAppName(s: String): String =
        s.lowercase().filter { it.isLetterOrDigit() }

    /**
     * Well-known short forms (v0.6.8) — mirrors Dart
     * AppLockService.knownPackageForName. Keep this list tiny and
     * exact-package only.
     */
    private fun knownPackageForName(wanted: String): String? =
        when (normalizeAppName(wanted)) {
            "wabusiness", "whatsappbusiness" -> "com.whatsapp.w4b"
            "playstore", "googleplaystore" -> "com.android.vending"
            else -> null
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
