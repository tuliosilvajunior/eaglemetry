package com.timhss.capyenergy.telemetry

import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicLong

/** What changed, and the revision at which it changed. */
data class SessionChange(
    val revision: Long,
    val trips: Boolean,
    val charges: Boolean,
    val parked: Boolean,
)

/**
 * Says when the recorded sessions changed, so the lists stop asking.
 *
 * The trip and charge lists polled every 5 and 20 seconds. On a parked car
 * nothing they show can change, so almost every one of those reads was a
 * database query for an answer that was already on screen.
 *
 * This carries no rows. A change event that also carried the list would be a
 * second route to the same data, and the two would answer differently the first
 * time one of them was changed alone.
 *
 * It does not fire per frame either. An open session's newest SOC and odometer
 * come from frames at about 1 Hz; a list showing an open row still polls for
 * those. This fires when a session is written, closed, merged or priced, which
 * is what a list with nothing open is waiting for.
 *
 * Writes arrive from several executors, so the revision is atomic and the
 * listener list tolerates a subscriber arriving during a notification.
 */
class SessionChangeBroadcaster {
    private val revision = AtomicLong(0)
    private val listeners = CopyOnWriteArrayList<(SessionChange) -> Unit>()

    /** The revision as it stands. A late subscriber can tell it missed events. */
    fun currentRevision(): Long = revision.get()

    fun addListener(listener: (SessionChange) -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: (SessionChange) -> Unit) {
        listeners.remove(listener)
    }

    fun tripsChanged() = notify(trips = true, charges = false, parked = false)

    fun chargesChanged() = notify(trips = false, charges = true, parked = false)

    fun parkedChanged() = notify(trips = false, charges = false, parked = true)

    /** A merge touches both: it rewrites charges and reassigns their frames. */
    fun sessionsChanged() = notify(trips = true, charges = true, parked = true)

    private fun notify(trips: Boolean, charges: Boolean, parked: Boolean) {
        if (!trips && !charges && !parked) return
        val change = SessionChange(
            revision = revision.incrementAndGet(),
            trips = trips,
            charges = charges,
            parked = parked,
        )
        // A listener that throws must not stop the others from hearing: one
        // broken subscriber would otherwise freeze every list in the app.
        listeners.forEach { listener -> runCatching { listener(change) } }
    }
}
