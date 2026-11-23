package com.apnacircle.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.telephony.TelephonyManager

/**
 * Real SIM-call distance overlay (v0.6.5) — manifest-registered so it
 * works even when the app process is dead.
 *
 * INCOMING: PHONE_STATE RINGING carries the number in
 * TelephonyManager.EXTRA_INCOMING_NUMBER — on Android 10+ that extra
 * is only filled when the app holds READ_CALL_LOG (Android rule, same
 * as the in-app PhoneStateListener in MainActivity). The number is
 * matched against the circle-member cache (CallMemberCache); a
 * non-member caller shows NOTHING — never an overlay for a stranger.
 *
 * OUTGOING: NEW_OUTGOING_CALL carries the dialled number in
 * Intent.EXTRA_PHONE_NUMBER and needs PROCESS_OUTGOING_CALLS. The
 * broadcast is deprecated on Android 10+ (replaced by
 * CallRedirectionService, which needs a system role grant — a bigger
 * UX + Play decision, NOT taken in v0.6.5), but it is still delivered
 * to holders of the permission for *observing* the number; on
 * Android 15+ it is no longer an ordered broadcast and receivers
 * cannot launch background activities — we show a WindowManager
 * overlay, not an activity, so it still works. If Android ever stops
 * delivering it, the fallback is the call-screening role (see
 * README "v0.6.5 honest limits").
 *
 * LIFECYCLE: show on RINGING / NEW_OUTGOING_CALL, keep showing while
 * the call is answered (OFFHOOK), hide on IDLE (ended / missed /
 * declined). Dual SIM: the broadcast carries no SIM slot, so the
 * overlay cannot say which SIM the call is on — the distance is the
 * same either way.
 */
class CallStateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            TelephonyManager.ACTION_PHONE_STATE_CHANGED -> {
                val state = intent.getStringExtra(TelephonyManager.EXTRA_STATE)
                when (state) {
                    TelephonyManager.EXTRA_STATE_RINGING -> {
                        val number = intent.getStringExtra(
                            TelephonyManager.EXTRA_INCOMING_NUMBER
                        )
                        if (!number.isNullOrBlank()) {
                            showFor(context, number, "Incoming call")
                        }
                    }
                    TelephonyManager.EXTRA_STATE_IDLE -> {
                        CallOverlayManager.hide(context)
                    }
                    TelephonyManager.EXTRA_STATE_OFFHOOK -> {
                        // Call answered — keep the overlay up during
                        // the call; it hides on IDLE.
                    }
                }
            }
            Intent.ACTION_NEW_OUTGOING_CALL -> {
                val number = intent.getStringExtra(Intent.EXTRA_PHONE_NUMBER)
                if (!number.isNullOrBlank()) {
                    showFor(context, number, "Outgoing call")
                }
            }
        }
    }

    private fun showFor(context: Context, rawNumber: String, direction: String) {
        // No overlay permission = no overlay. The Settings screen
        // shows this plainly; we never pretend it appeared.
        if (!CallOverlayManager.canDrawOverlays(context)) return
        val hit = CallMemberCache.lookup(context, rawNumber) ?: return
        val distanceText =
            if (hit.lat != null && hit.lon != null &&
                hit.myLat != null && hit.myLon != null
            ) {
                CallMemberCache.formatKm(
                    CallMemberCache.distanceKm(hit.myLat, hit.myLon, hit.lat, hit.lon)
                ) + " away"
            } else {
                // Member found but no location on either side yet —
                // still show the name, honestly labelled.
                "Location unknown"
            }
        CallOverlayManager.show(context, hit.name, distanceText, direction)
    }
}
