package com.apnacircle.app

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.os.Build
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Small floating distance card shown OVER the system call screen
 * (v0.6.5) — a WindowManager overlay, NOT an Activity.
 *
 * Why a window overlay and not the Flutter CallOverlayScreen: a call
 * can arrive while the app process is dead, and Android 10+ forbids
 * launching activities from the background. A TYPE_APPLICATION_OVERLAY
 * window from a BroadcastReceiver is allowed as long as the user
 * granted "Display over other apps" (SYSTEM_ALERT_WINDOW) — without
 * that grant [show] silently does nothing, and the Settings screen
 * says so instead of pretending otherwise.
 *
 * The card is deliberately small and sits at the TOP of the screen so
 * it never covers the call screen's Answer / End buttons. Tap it to
 * dismiss it; it is also removed automatically when the call ends
 * (CallStateReceiver hides it on IDLE).
 */
object CallOverlayManager {
    private var overlayView: View? = null

    fun canDrawOverlays(context: Context): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(context)
        } else {
            true
        }

    fun show(context: Context, name: String, distanceText: String, direction: String) {
        if (!canDrawOverlays(context)) return
        val appContext = context.applicationContext
        val wm = appContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        hide(appContext)
        val card = LinearLayout(appContext).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#004B22"))
            setPadding(36, 28, 36, 28)
        }
        val caption = TextView(appContext).apply {
            text = "ApnaCircle · $direction"
            textSize = 13f
            setTextColor(Color.parseColor("#BFE8C8"))
        }
        val nameView = TextView(appContext).apply {
            text = name
            textSize = 24f
            setTextColor(Color.WHITE)
        }
        val distanceView = TextView(appContext).apply {
            text = distanceText
            textSize = 32f
            setTextColor(Color.WHITE)
        }
        card.addView(caption)
        card.addView(nameView)
        card.addView(distanceView)
        // Tap the card to dismiss it (it must never trap the user
        // away from the call screen's own buttons).
        card.setOnClickListener { hide(appContext) }
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            },
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            y = 120
        }
        try {
            wm.addView(card, params)
            overlayView = card
        } catch (e: Exception) {
            overlayView = null
        }
    }

    fun hide(context: Context) {
        val view = overlayView ?: return
        overlayView = null
        try {
            val wm = context.applicationContext
                .getSystemService(Context.WINDOW_SERVICE) as WindowManager
            wm.removeView(view)
        } catch (e: Exception) {
            // Already gone (e.g. process died with it) — nothing to do.
        }
    }

    fun isShowing(): Boolean = overlayView != null
}
