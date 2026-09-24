package com.timhss.capyenergy.telemetry

/**
 * That an annotation changed, not what it now is.
 *
 * The same shape as [SessionChange]: a reader re-reads the surface it shows.
 * Annotations change rarer than sessions and never per frame, so a push from
 * the phone is worth one event.
 */
data class AnnotationChange(
    val revision: Long,
    val places: Boolean,
    val preferences: Boolean,
    val sessionCosts: Boolean,
    val proposals: Boolean,
    val journeys: Boolean
)

class AnnotationChangeBroadcaster {
    private val revision = java.util.concurrent.atomic.AtomicLong(0)
    private val listeners =
        java.util.concurrent.CopyOnWriteArrayList<(AnnotationChange) -> Unit>()

    fun currentRevision(): Long = revision.get()

    fun addListener(listener: (AnnotationChange) -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: (AnnotationChange) -> Unit) {
        listeners.remove(listener)
    }

    fun placesChanged() = notify(places = true)

    fun preferencesChanged() = notify(preferences = true)

    fun sessionCostsChanged() = notify(sessionCosts = true)

    fun proposalsChanged() = notify(proposals = true)

    fun journeysChanged() = notify(journeys = true)

    private fun notify(
        places: Boolean = false,
        preferences: Boolean = false,
        sessionCosts: Boolean = false,
        proposals: Boolean = false,
        journeys: Boolean = false
    ) {
        if (!places && !preferences && !sessionCosts && !proposals && !journeys) return
        val change = AnnotationChange(
            revision = revision.incrementAndGet(),
            places = places,
            preferences = preferences,
            sessionCosts = sessionCosts,
            proposals = proposals,
            journeys = journeys
        )
        listeners.forEach { listener -> runCatching { listener(change) } }
    }
}
