package com.apnacircle.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.text.InputFilter
import android.text.InputType
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONObject
import java.security.MessageDigest

/**
 * Dedicated PIN lock screen (v0.6.3) — shown OVER a locked app by
 * [AppLockService] when the child opens an app the parent locked.
 *
 * Why a native Activity and not a Flutter screen: the old path
 * (v0.2–v0.6.2) bounced to MainActivity, whose Flutter engine takes
 * a second or two to start — the locked app stayed visible and
 * usable meanwhile, and Back/Recents led straight back into it.
 * This Activity starts instantly, covers the locked app, and Back
 * goes HOME (never back into the locked app).
 *
 * PIN check: the parent PIN is stored only as a SHA-256 hash
 * ("apnacircle:<pin>") in Flutter SharedPreferences — the same hash
 * Dart's PinService writes (key "parent_pin_sha256"). This Activity
 * reads that hash (Flutter stores it under file
 * "FlutterSharedPreferences", key "flutter.parent_pin_sha256") and
 * compares hashes. The PIN itself is never stored or logged.
 *
 * Correct PIN = 5-minute grant for THAT app only (stored in the
 * "apnacircle_locks" prefs, key "grants_json"): the child can use
 * the app for 5 minutes; re-opening it after the grant expires
 * locks it again. A grant expiring while the app is already open
 * does not kick the child out mid-use — it only blocks re-entry.
 *
 * No PIN hash on this phone (demo mode / PIN never set): the screen
 * says so and offers only "Go home" — it never unlocks blind.
 */
class LockActivity : Activity() {

    companion object {
        const val EXTRA_PACKAGE = "locked_package"
        const val EXTRA_APP_NAME = "locked_app_name"

        /** How long one correct PIN entry unlocks an app. */
        const val GRANT_MS = 5 * 60 * 1000L
    }

    private var lockedPkg: String = ""
    private var lockedLabel: String = ""
    private lateinit var pinInput: EditText
    private lateinit var errorText: TextView
    private lateinit var unlockButton: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!readExtras(intent)) {
            finish()
            return
        }
        buildUi()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (!readExtras(intent)) {
            finish()
            return
        }
        // New locked app while this screen is already up (singleTop):
        // reset the PIN field and the label.
        if (::pinInput.isInitialized) {
            pinInput.text.clear()
            errorText.visibility = TextView.INVISIBLE
        }
        title = lockedLabel
    }

    private fun readExtras(intent: Intent?): Boolean {
        lockedPkg = intent?.getStringExtra(EXTRA_PACKAGE).orEmpty()
        if (lockedPkg.isEmpty()) return false
        lockedLabel = intent?.getStringExtra(EXTRA_APP_NAME)?.takeIf { it.isNotBlank() }
            ?: appLabelFor(lockedPkg)
        return true
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

    private fun buildUi() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setBackgroundColor(Color.parseColor("#7A0C0C"))
            setPadding(64, 160, 64, 64)
        }
        val title = TextView(this).apply {
            text = "🔒 $lockedLabel"
            textSize = 26f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
        }
        val subtitle = TextView(this).apply {
            text = "This app is locked by your parent."
            textSize = 17f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            setPadding(0, 24, 0, 8)
        }
        val hint = TextView(this).apply {
            text = "Enter the parent PIN to open it."
            textSize = 15f
            setTextColor(Color.parseColor("#FFD9D9"))
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, 48)
        }
        errorText = TextView(this).apply {
            text = "Wrong PIN — try again."
            textSize = 15f
            setTextColor(Color.parseColor("#FFEB3B"))
            gravity = Gravity.CENTER
            visibility = TextView.INVISIBLE
            setPadding(0, 0, 0, 24)
        }
        pinInput = EditText(this).apply {
            hint = "Parent PIN"
            inputType = InputType.TYPE_CLASS_NUMBER or
                InputType.TYPE_NUMBER_VARIATION_PASSWORD
            filters = arrayOf(InputFilter.LengthFilter(12))
            textSize = 22f
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            setHintTextColor(Color.parseColor("#FFAAAA"))
            setBackgroundColor(Color.parseColor("#5C0808"))
            setPadding(24, 24, 24, 24)
        }
        unlockButton = Button(this).apply {
            text = "Unlock"
            textSize = 18f
            setOnClickListener { tryUnlock() }
        }
        val homeButton = Button(this).apply {
            text = "Go home"
            setOnClickListener { goHome() }
        }

        val pinHash = storedPinHash()
        root.addView(title)
        root.addView(subtitle)
        if (pinHash == null) {
            // No PIN on this phone — never unlock blind.
            hint.text = "No parent PIN is set on this phone yet. " +
                "Ask your parent to open ApnaCircle and set a PIN first."
            root.addView(hint)
            root.addView(homeButton)
        } else {
            root.addView(hint)
            root.addView(errorText)
            root.addView(
                pinInput,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ),
            )
            root.addView(unlockButton)
            root.addView(homeButton)
        }
        setContentView(root)
    }

    /** PIN hash as Dart's PinService stored it, or null. */
    private fun storedPinHash(): String? {
        // Flutter's shared_preferences plugin: file
        // "FlutterSharedPreferences", keys prefixed "flutter.".
        val flutterPrefs = getSharedPreferences(
            "FlutterSharedPreferences", Context.MODE_PRIVATE
        )
        flutterPrefs.getString("flutter.parent_pin_sha256", null)?.let { return it }
        // Fallback: plain key, in case storage ever changes shape.
        flutterPrefs.getString("parent_pin_sha256", null)?.let { return it }
        return null
    }

    private fun tryUnlock() {
        val pin = pinInput.text.toString()
        val hash = storedPinHash()
        if (pin.isBlank() || hash == null) return
        if (hashPin(pin) == hash) {
            grantAccess(lockedPkg)
            openLockedApp()
            finish()
        } else {
            errorText.visibility = TextView.VISIBLE
            pinInput.text.clear()
        }
    }

    private fun hashPin(pin: String): String {
        // Must match Dart PinService.hashPin: SHA-256 of "apnacircle:<pin>".
        val digest = MessageDigest.getInstance("SHA-256")
        val bytes = digest.digest("apnacircle:$pin".toByteArray(Charsets.UTF_8))
        return bytes.joinToString("") { "%02x".format(it) }
    }

    private fun grantAccess(pkg: String) {
        val prefs = getSharedPreferences(
            AppLockService.PREFS_NAME, Context.MODE_PRIVATE
        )
        val grants = try {
            JSONObject(prefs.getString(AppLockService.KEY_GRANTS, "{}") ?: "{}")
        } catch (e: Exception) {
            JSONObject()
        }
        grants.put(pkg, System.currentTimeMillis() + GRANT_MS)
        prefs.edit().putString(AppLockService.KEY_GRANTS, grants.toString()).apply()
    }

    private fun openLockedApp() {
        val launch = packageManager.getLaunchIntentForPackage(lockedPkg)
        if (launch != null) {
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            try {
                startActivity(launch)
            } catch (e: Exception) {
                // Grant is stored already — the child can open the app
                // by hand and the service will not block it.
            }
        }
    }

    private fun goHome() {
        val home = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_HOME)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(home)
        finish()
    }

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        // Back must NEVER return into the locked app.
        goHome()
    }
}
