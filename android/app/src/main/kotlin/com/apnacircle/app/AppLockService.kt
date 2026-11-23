package com.apnacircle.app

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.view.accessibility.AccessibilityEvent
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar

/**
 * App Lock enforcement — WIRED in v0.6.3 (23 Nov 2026).
 *
 * ROOT CAUSE of "App lock nhi ho rhi" (user, 23 Nov 2026): this
 * file existed since v0.2, but it was NEVER declared in
 * AndroidManifest.xml and had no accessibility_service_config.xml —
 * so Android could never bind it, it never appeared in Settings →
 * Accessibility, and no locked app was ever blocked. The v0.6.3
 * fix declares the service + config, adds LockActivity (the real
 * PIN screen), makes Dart subscribe to locks at Home (not only
 * when the Locks tab opens), and reloads rules whenever the parent
 * changes them.
 *
 * How it works now:
 * 1. MainActivity ("applyLocks") persists the lock schedule from
 *    Dart to SharedPreferences, with a version timestamp. Custom
 *    apps added by name are resolved to real package names there.
 * 2. On every TYPE_WINDOW_STATE_CHANGED event this service checks
 *    the foreground package against the rules (reloading them when
 *    the version changed, so a parent's change takes effect
 *    without restarting anything). Time windows are evaluated at
 *    enforcement time and mirror Dart (lib/core/time_lock.dart):
 *    Always-mode blocks whenever locked; Time-mode blocks only
 *    inside its scheduled window on a scheduled day (overnight
 *    windows, e.g. 22:00–06:00, supported).
 * 3. If a locked app comes to the foreground (and no unexpired
 *    5-minute PIN grant exists for it), LockActivity is shown over
 *    it. A correct parent PIN grants 5 minutes for that app only.
 * 4. The user MUST enable this service once in Settings →
 *    Accessibility → ApnaCircle App Lock. The app's Locks screen
 *    shows whether it is ON and opens those settings. Nothing in
 *    the app can enable it silently — that is an Android rule.
 *
 * HONEST LIMITS (keep these in the README too):
 * - The child can turn this service OFF in Settings → Accessibility
 *   (Android lets the user do that; no app can prevent it). Device
 *   Admin + the deactivation alert are the tripwire, not a lock.
 * - It cannot block uninstall, and it cannot block an app that is
 *   already open when a grant expires — it only blocks (re-)entry.
 * - Custom apps stored as "custom:<name>" have no package name
 *   until the child's phone resolves the name to an installed
 *   package (PackageManager query in MainActivity.applyLocks) —
 *   an app that is not installed yet cannot be blocked.
 * - Play Store: QUERY_ALL_PACKAGES + Accessibility use for app
 *   locking needs a declaration + video justification; Google
 *   reviews this strictly and may refuse it.
 */
class AppLockService : AccessibilityService() {

    companion object {
        const val PREFS_NAME = "apnacircle_locks"
        const val KEY_SCHEDULE = "schedule_json"

        /** Written by MainActivity.applyLocks on every change. */
        const val KEY_SCHEDULE_VERSION = "schedule_version"

        /** PIN grants: JSON object package -> expiry epoch ms. */
        const val KEY_GRANTS = "grants_json"
        const val KEY_LAST_BLOCKED = "last_blocked"
    }

    private data class Rule(
        val pkg: String,
        val locked: Boolean,
        val mode: String,
        val start: Int,
        val end: Int,
        val days: Set<Int>,
    )

    private var rules: List<Rule> = emptyList()
    private var lastLoadedVersion: Long = -1L

    override fun onServiceConnected() {
        super.onServiceConnected()
        loadRules()
    }

    /**
     * Reload rules when the schedule changed (v0.6.3): the old code
     * loaded once in onServiceConnected and never again, so a
     * parent's change did nothing until the service restarted.
     * MainActivity.applyLocks bumps KEY_SCHEDULE_VERSION on every
     * change; this reloads only when the version moved.
     */
    private fun loadRules() {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val version = prefs.getLong(KEY_SCHEDULE_VERSION, 0L)
        if (version == lastLoadedVersion && rules.isNotEmpty()) return
        val raw = prefs.getString(KEY_SCHEDULE, null) ?: return
        val parsed = mutableListOf<Rule>()
        val arr = JSONArray(raw)
        for (i in 0 until arr.length()) {
            val obj = arr.getJSONObject(i)
            val window = if (obj.isNull("window")) null else obj.getJSONObject("window")
            val days = mutableSetOf<Int>()
            window?.optJSONArray("days")?.let { d ->
                for (j in 0 until d.length()) days.add(d.getInt(j))
            }
            parsed.add(
                Rule(
                    pkg = obj.optString("package"),
                    locked = obj.optBoolean("locked", true),
                    mode = obj.optString("mode", "always"),
                    start = window?.optInt("start", 0) ?: 0,
                    end = window?.optInt("end", 0) ?: 0,
                    days = days.ifEmpty { (1..7).toSet() },
                )
            )
        }
        rules = parsed
        lastLoadedVersion = version
    }

    /**
     * A correct parent PIN grants ONE app for 5 minutes
     * (LockActivity writes package -> expiry epoch ms). A grant
     * expiring while the app is already open does not kick the
     * child out — it only blocks re-entry (see class doc).
     */
    private fun hasGrant(pkg: String, nowMs: Long): Boolean {
        val raw = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(KEY_GRANTS, null) ?: return false
        return try {
            val grants = JSONObject(raw)
            grants.optLong(pkg, 0L) > nowMs
        } catch (e: Exception) {
            false
        }
    }

    /** Mirrors Dart TimeWindow.isActiveAt for one rule. */
    // private (not internal): Rule is a private class, and Kotlin 2.1
    // rejects an internal function exposing a private-in-class type
    // (Run #27 compile error, 22 Nov 2026). Only used inside this class.
    private fun isRuleActive(rule: Rule, now: Calendar): Boolean {
        if (!rule.locked) return false
        if (rule.mode != "time") return true
        val mins = now.get(Calendar.HOUR_OF_DAY) * 60 + now.get(Calendar.MINUTE)
        // Calendar.SUNDAY=1..SATURDAY=7; Dart Monday=1..Sunday=7.
        val dartWeekday = when (now.get(Calendar.DAY_OF_WEEK)) {
            Calendar.SUNDAY -> 7
            else -> now.get(Calendar.DAY_OF_WEEK) - 1
        }
        val prevWeekday = if (dartWeekday == 1) 7 else dartWeekday - 1
        val overnight = rule.end <= rule.start
        return if (!overnight) {
            rule.days.contains(dartWeekday) && mins >= rule.start && mins < rule.end
        } else {
            (rule.days.contains(dartWeekday) && mins >= rule.start) ||
                (rule.days.contains(prevWeekday) && mins < rule.end)
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event?.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        val pkg = event.packageName?.toString() ?: return
        if (pkg == packageName) return // Never block ourselves.
        loadRules()
        val now = Calendar.getInstance()
        val blocked = rules.firstOrNull { it.pkg == pkg && isRuleActive(it, now) }
            ?: return
        if (hasGrant(pkg, System.currentTimeMillis())) return
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit()
            .putString(KEY_LAST_BLOCKED, "${blocked.pkg}|${System.currentTimeMillis()}")
            .apply()
        // Dedicated native PIN screen (v0.6.3) — NOT MainActivity:
        // it opens instantly and Back goes Home, never back into
        // the locked app.
        val label = appLabelFor(pkg)
        val intent = Intent(this, LockActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
            putExtra(LockActivity.EXTRA_PACKAGE, blocked.pkg)
            putExtra(LockActivity.EXTRA_APP_NAME, label)
        }
        startActivity(intent)
    }

    private fun appLabelFor(pkg: String): String {
        return try {
            packageManager.getApplicationInfo(pkg, 0)
                ?.let { packageManager.getApplicationLabel(it)?.toString() }
                ?: pkg
        } catch (e: Exception) {
            pkg
        }
    }

    override fun onInterrupt() {
        // No-op.
    }
}
