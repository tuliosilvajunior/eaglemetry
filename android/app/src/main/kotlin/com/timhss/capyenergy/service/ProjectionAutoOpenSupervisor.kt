package com.timhss.capyenergy.service

import android.content.Context
import com.timhss.capyenergy.projection.PresenceState
import com.timhss.capyenergy.projection.ProjectionPresenceMonitor
import com.timhss.capyenergy.projection.ProjectionPresenceSnapshot

/**
 * Opens this app on the phone's tab when a phone arrives.
 *
 * This exists because the app suppresses the factory CarPlay and Android Auto
 * screens. Suppressing them and putting nothing in their place leaves the
 * driver with a head unit that does nothing when they plug a phone in.
 *
 * It lives in the **service**, not in the activity, and that is the whole
 * point of it. `AppShellV2` already moves to the phone's tab on the same edge,
 * but it can only do that inside an app that is already open, and the presence
 * monitor it reads is built in `MainActivity.configureFlutterEngine`. With the
 * app closed, nothing was watching the phone at all — so nothing could open
 * anything. This runs for as long as `TelemetryCollectorService` runs.
 *
 * The two of them overlap on purpose and cannot disagree: they read the same
 * monitor class over the same edge rule, and they ask for the same tab. The
 * shell selects it; this one also brings the app forward.
 *
 * Nothing here starts while the beta switch is off. The first call over each
 * probe is what makes the platform bind the OEM service, so an untouched
 * monitor leaves both stacks unstarted rather than started and ignored.
 */
internal class ProjectionAutoOpenSupervisor private constructor(context: Context) {
    private val appContext = context.applicationContext
    private val lock = Any()

    private var monitor: ProjectionPresenceMonitor? = null
    private var previous: ProjectionPresenceSnapshot = ProjectionPresenceSnapshot.unknown

    /**
     * One launcher per protocol, so each keeps its own debounce. A phone that
     * arrives while the other stack is settling must not be refused for it.
     *
     * Neither passes a resting mode, and that is a decision rather than an
     * omission. The charging half refuses to light the display for a person
     * asleep in the car, because a wall box switches itself on. A phone does
     * not: somebody connected it. And since the factory screen is suppressed,
     * refusing here would leave that person with no projection at all until
     * they found the tab by hand.
     */
    private val carplayLauncher = AutoOpenLauncher(
        context = appContext,
        tag = AutoOpenLauncher.TAG_PROJECTION,
        destination = AutoOpenLauncher.DESTINATION_CARPLAY,
        enabled = { enabled }
    )

    private val androidAutoLauncher = AutoOpenLauncher(
        context = appContext,
        tag = AutoOpenLauncher.TAG_PROJECTION,
        destination = AutoOpenLauncher.DESTINATION_ANDROID_AUTO,
        enabled = { enabled }
    )

    @Volatile
    private var enabled = false

    /**
     * Starts or stops watching, and is the only way to do either.
     *
     * Idempotent, because two callers reach it: the service at start, and the
     * bridge when the reader moves the beta switch.
     */
    fun setEnabled(enabled: Boolean) {
        val toDispose: ProjectionPresenceMonitor?
        val toStart: ProjectionPresenceMonitor?
        synchronized(lock) {
            if (this.enabled == enabled && (monitor != null) == enabled) return
            this.enabled = enabled
            if (enabled) {
                toDispose = null
                // A phone that was already connected must not count as an
                // arrival, so the run starts from what it does not know yet.
                previous = ProjectionPresenceSnapshot.unknown
                val created = ProjectionPresenceMonitor(
                    context = appContext,
                    onSnapshot = { snapshot -> onSnapshot(snapshot) }
                )
                monitor = created
                toStart = created
            } else {
                toDispose = monitor
                monitor = null
                toStart = null
                previous = ProjectionPresenceSnapshot.unknown
            }
        }
        toDispose?.dispose()
        toStart?.start()
    }

    private fun onSnapshot(snapshot: ProjectionPresenceSnapshot) {
        val destination = synchronized(lock) {
            val arrived = arrivalDestination(previous, snapshot)
            previous = snapshot
            arrived
        }
        when (destination) {
            AutoOpenLauncher.DESTINATION_CARPLAY -> carplayLauncher.requestOpen()
            AutoOpenLauncher.DESTINATION_ANDROID_AUTO -> androidAutoLauncher.requestOpen()
            else -> {}
        }
    }

    companion object {
        @Volatile
        private var instance: ProjectionAutoOpenSupervisor? = null

        fun get(context: Context): ProjectionAutoOpenSupervisor {
            instance?.let { return it }
            return synchronized(this) {
                instance ?: ProjectionAutoOpenSupervisor(context).also { instance = it }
            }
        }

        /**
         * Which tab an arrival earns, or null for no arrival.
         *
         * Only a step **from a known disconnected state** counts. Presence
         * starts unknown, so a first reading that says "connected" describes a
         * phone that was already there — at a boot, or when the beta was
         * switched on — and taking the display for it would be a claim that
         * something just happened.
         *
         * The same rule, in the same words, is `AppShellV2._arrivedTab`. The
         * two must agree, because they act on one event.
         */
        internal fun arrivalDestination(
            previous: ProjectionPresenceSnapshot,
            next: ProjectionPresenceSnapshot
        ): String? {
            if (previous.carplay == PresenceState.DISCONNECTED &&
                next.carplay == PresenceState.CONNECTED
            ) {
                return AutoOpenLauncher.DESTINATION_CARPLAY
            }
            if (previous.androidAuto == PresenceState.DISCONNECTED &&
                next.androidAuto == PresenceState.CONNECTED
            ) {
                return AutoOpenLauncher.DESTINATION_ANDROID_AUTO
            }
            return null
        }
    }
}
