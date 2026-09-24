package com.timhss.capyenergy.service

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.timhss.capyenergy.MainActivity
import com.timhss.capyenergy.bridge.TelemetryBridge

/**
 * Opens this app on one tab, in place of a factory screen it suppresses.
 *
 * Two of these exist, one per suppressed screen: the charge plug, wired in
 * `TelemetryGraph`, and a projected phone, wired in
 * [ProjectionAutoOpenSupervisor]. They share this class because they share
 * every rule about **taking the display**, which is the part that can annoy a
 * driver. What they do not share is how the car is read, and neither of them
 * reads it here: each is told by the object that already holds the state
 * machine for its own signal.
 *
 * The charging half learned that the hard way. Its first version subscribed to
 * `0x24130200` on its own `CarPropertyManager` and never fired. Two reasons,
 * and either one alone was enough: that id is an **ECARX logical id**, which
 * `CarPropertyManager` cannot resolve — the VHAL property is
 * `GeelyProperties.ChargingPlugState` (`557871753`) — and the `Car.createCar`
 * overload it used to connect does not exist on this Android 9 head unit.
 */
internal class AutoOpenLauncher(
    private val context: Context,
    /** Log tag, one per half, so a filter on the car shows only that half. */
    private val tag: String,
    /** The tab the app opens on. Must match a `AppNavigationController` id. */
    private val destination: String,
    /** The reader's switch for this half. Read at the moment of the event. */
    private val enabled: () -> Boolean,
    /**
     * Whether a person is resting in the car. Read at the moment of the event,
     * from the signals the engine already polls at 1 Hz.
     */
    private val restingModeActive: () -> Boolean = { false },
    private val nowMillis: () -> Long = SystemClock::elapsedRealtime
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val startedAtMillis: Long = nowMillis()
    private var lastLaunchAtMillis: Long? = null

    /**
     * Called when the thing this half watches has happened — a charge that
     * begins, or a phone that arrives.
     *
     * Runs on the caller's thread, and returns at once: the launch itself is
     * posted to the main thread.
     */
    @Synchronized
    fun requestOpen() {
        val now = nowMillis()
        val refusal = refusalFor(
            enabled = enabled(),
            resting = restingModeActive(),
            now = now,
            startedAt = startedAtMillis,
            lastLaunchAt = lastLaunchAtMillis
        )
        // Logged on every branch, and each refusal names itself. A refusal and
        // a broken signal path look the same from outside, and on the car a log
        // after the fact is the only evidence available.
        if (refusal != null) {
            Log.i(tag, "Asked to open $destination; ${refusal.reason}")
            return
        }
        lastLaunchAtMillis = now
        launch()
    }

    private fun launch() {
        Log.i(tag, "Opening the app on $destination")
        mainHandler.post {
            try {
                val intent = Intent(context, MainActivity::class.java).apply {
                    action = Intent.ACTION_MAIN
                    addCategory(Intent.CATEGORY_LAUNCHER)
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP
                    putExtra(TelemetryBridge.EXTRA_DESTINATION, destination)
                }
                context.startActivity(intent)
            } catch (e: Exception) {
                Log.e(tag, "Failed to open the app on $destination", e)
            }
        }
    }

    /** Why the app stayed where it was. The text is what the log line says. */
    internal enum class Refusal(val reason: String) {
        SETTING_OFF("the setting is off"),
        SOMEBODY_IS_RESTING("somebody is resting in the car"),
        SETTLE_WINDOW("the engine had just started"),
        DEBOUNCE("this arrival already opened the app")
    }

    companion object {
        const val TAG_CHARGING = "ChargingAutoOpen"
        const val TAG_PROJECTION = "ProjectionAutoOpen"

        /** The tabs something outside the app can ask for. */
        const val DESTINATION_CHARGING = "charging"
        const val DESTINATION_CARPLAY = "carplay"
        const val DESTINATION_ANDROID_AUTO = "androidAuto"

        /**
         * One arrival opens the app once.
         *
         * A charge arrival reports two beginnings a few seconds apart: the plug
         * goes in, then the charge starts. The window must therefore be wider
         * than that gap, not merely wider than a bouncing contact. A phone that
         * negotiates a wireless session reports its own repeats.
         */
        internal const val DEBOUNCE_MILLIS = 60_000L
        internal const val STARTUP_SETTLE_MILLIS = 20_000L

        /**
         * Why an event does not earn a screen.
         *
         * Four refusals, and each answers a different question, which is why
         * each one names itself in the log:
         *
         * - **the setting.** The reader turned this half off;
         * - **a person resting in the car.** Camping and nap mode keep the car
         *   awake with somebody inside, and a wall box that switches on at
         *   night must not light the display. Only the charging half passes
         *   this; see [ProjectionAutoOpenSupervisor] for why a phone does not;
         * - **the settle window** from the start of the engine. A first reading
         *   of a run describes what was already true, not an arrival, so a car
         *   that boots with the cable in — or with a phone paired — would
         *   otherwise take the display from whatever the driver opened;
         * - **the debounce**, for one arrival reported twice.
         *
         * Pure, and the whole decision: the object around it holds no rule that
         * a test cannot reach.
         */
        internal fun refusalFor(
            enabled: Boolean,
            resting: Boolean,
            now: Long,
            startedAt: Long,
            lastLaunchAt: Long?
        ): Refusal? {
            if (!enabled) return Refusal.SETTING_OFF
            if (resting) return Refusal.SOMEBODY_IS_RESTING
            if (now - startedAt < STARTUP_SETTLE_MILLIS) return Refusal.SETTLE_WINDOW
            val last = lastLaunchAt ?: return null
            if (now - last <= DEBOUNCE_MILLIS) return Refusal.DEBOUNCE
            return null
        }
    }
}
