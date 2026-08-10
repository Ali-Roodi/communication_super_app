package com.example.communication_super_app.call

import android.content.Context
import android.os.PowerManager
import android.telecom.CallAudioState
import android.util.Log

/**
 * Blanks the screen while the phone is held to the ear.
 *
 * This is the **default dialer's own job**: the system does not do it for the
 * app that owns the in-call UI. Without it the call screen stays lit against
 * the cheek for the whole call, and «بی‌صدا» / «پایان» are exactly where an ear
 * lands — every call is a chance to mute or hang itself up.
 *
 * `PROXIMITY_SCREEN_OFF_WAKE_LOCK` is the only API that does this: it turns the
 * display off while the sensor is covered and back on when it clears, without
 * counting as user inactivity (so the call is never locked out from under the
 * user).
 *
 * Held only while a call is live **and** the audio is coming out of the
 * earpiece. On speaker, a wired headset or bluetooth the phone is not at the
 * ear and blanking the screen would be wrong — that is Google Phone's rule and
 * the reason [refresh] is also called from `onCallAudioStateChanged`.
 */
object ProximityGate {
    private const val TAG = "ProximityGate"

    private var lock: PowerManager.WakeLock? = null

    /** Last route telecom reported; the sensor only applies to the earpiece. */
    @Volatile
    private var earpieceRoute = true

    fun onAudioRouteChanged(state: CallAudioState, context: Context) {
        earpieceRoute = state.route == CallAudioState.ROUTE_EARPIECE
        refresh(context)
    }

    /**
     * Re-derives whether the lock should be held. Safe to call on every call
     * event — acquiring an already-held lock and releasing a free one are both
     * no-ops here.
     */
    fun refresh(context: Context) {
        val wanted = earpieceRoute && CallInCallService.topLevelCalls().isNotEmpty()
        if (wanted) acquire(context) else release()
    }

    /** Call ended (or the service died): always let go of the screen. */
    fun release() {
        try {
            lock?.takeIf { it.isHeld }?.release()
        } catch (e: Exception) {
            Log.e(TAG, "release failed: ${e.message}")
        }
        lock = null
    }

    private fun acquire(context: Context) {
        if (lock?.isHeld == true) return
        try {
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            // Not every device has the sensor wired to this wake-lock level;
            // asking for an unsupported one throws.
            if (!pm.isWakeLockLevelSupported(
                    PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
                )
            ) {
                Log.w(TAG, "proximity wake lock unsupported on this device")
                return
            }
            val wl = pm.newWakeLock(
                PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
                "hamrasan:incall_proximity",
            ).apply { setReferenceCounted(false) }
            wl.acquire(EXPIRY_MS)
            lock = wl
        } catch (e: Exception) {
            // A screen that will not blank is far better than a crashed call UI.
            Log.e(TAG, "acquire failed: ${e.message}")
            lock = null
        }
    }

    /** Safety valve: a leaked lock must not blank the phone for ever. Four
     *  hours is longer than any call and short enough to be a real bound. */
    private const val EXPIRY_MS = 4L * 60 * 60 * 1000
}
