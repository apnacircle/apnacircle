package com.apnacircle.app

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.view.accessibility.AccessibilityEvent
import org.json.JSONArray
import java.util.Calendar

/**
 * App Lock enforcement — PARTIALLY implemented in v0.2 (22 Nov 2026).
 * Code written, NOT yet tested on a real phone. Do not ship as-is
 * without the real-phone checklist in README / FIREBASE_SETUP.md.
 *
 * What this file DOES now:
 * 1. Reads the lock schedule persisted by MainActivity ("applyLocks")
 *    from SharedPreferences: a JSON array of {package, locked, mode,
 *    window:{start, end, days}}. "mode" is "always" or "time".
 * 2. On every TYPE_WINDOW_STATE_CHANGED event it checks the
 *    foreground package. The time-window logic mirrors Dart
 *    (lib/core/time_lock.dart): Always-mode blocks whenever locked;
 *    Time-mode blocks only inside its scheduled window on a
 *    scheduled day (overnight windows, e.g. 22:00–06:00, supported).
 * 3. If a locked app comes to the foreground, it launches
 *    MainActivity with a "locked_package" extra (the app's PIN-gate
 *    screen) and stores the event in SharedPreferences so the
 *    parent can see which app was blocked and when.
 *
 * What is STILL missing (honest list — see README):
 * - A true overlay: currently the user is bounced to MainActivity.
 *   A real lock screen needs a dedicated LockActivity shown over
 *   the locked app (SYSTEM_ALERT_WINDOW) with the parent PIN entry.
 * - Device Admin: a DeviceAdminReceiver + res/xml/device_admin.xml
 *   so a child cannot uninstall ApnaCircle. Not wired yet.
 * - Custom apps stored as "custom:<name>" have no package name
 *   until the child's phone resolves the name to an installed
 *   package (PackageManager query) — name-matching is not done here.
 * - Play Store: QUERY_ALL_PACKAGES + Accessibility use for app
 *   locking needs a declaration + video justification; Google
 *   reviews this strictly and may refuse it.
 * - Real-phone test: enable the service in Settings > Accessibility,
 *   lock an app, open it, confirm the block; test time windows
 *   across midnight and across a day boundary.
 */
class AppLockService : AccessibilityService() {

    companion object {
        const val PREFS_NAME = "apnacircle_locks"
        const val KEY_SCHEDULE = "schedule_json"
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

    override fun onServiceConnected() {
        super.onServiceConnected()
        loadRules()
    }

    private fun loadRules() {
        val raw = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(KEY_SCHEDULE, null) ?: return
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
    }

    /** Mirrors Dart TimeWindow.isActiveAt for one rule. */
    internal fun isRuleActive(rule: Rule, now: Calendar): Boolean {
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
        if (rules.isEmpty()) loadRules()
        val now = Calendar.getInstance()
        val blocked = rules.firstOrNull { it.pkg == pkg && isRuleActive(it, now) }
            ?: return
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit()
            .putString(KEY_LAST_BLOCKED, "${blocked.pkg}|${System.currentTimeMillis()}")
            .apply()
        // Bounce to the app's PIN-gate screen (see class doc — a true
        // overlay LockActivity is still to be built).
        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            putExtra("locked_package", blocked.pkg)
        }
        startActivity(intent)
    }

    override fun onInterrupt() {
        // No-op.
    }
}
