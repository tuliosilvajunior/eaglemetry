package com.timhss.capyenergy.roadcast

/**
 * Collects new observations for short, named windows without adding another
 * Roadcast subscription. A caller opens a window after a triggering event;
 * only samples whose source change timestamp is inside that window are kept.
 * Unlike a watcher, a window retains every distinct change, so a caller can
 * search the history for a particular value before its timer expires.
 *
 * A single instance is safe to share across unrelated providers and rules.
 * Its methods synchronize access so each window keeps an independent signal
 * set and lifecycle, and one consumer cannot consume another consumer's
 * observation.
 */
class RoadcastSignalObservationPool {
    class Window internal constructor(
        internal val id: Long,
        internal val signalNames: Set<String>,
        internal val openedAtElapsedNanos: Long,
        internal val expiresAtElapsedNanos: Long,
    )

    private var nextWindowId = 0L
    private val windows = mutableMapOf<Long, Window>()
    private val observations = mutableMapOf<Long, MutableMap<String, MutableList<RoadcastSample>>>()

    @Synchronized
    fun open(
        signalNames: Set<String>,
        openedAtElapsedNanos: Long,
        durationNanos: Long,
    ): Window {
        require(signalNames.isNotEmpty()) { "An observation window needs at least one signal" }
        require(durationNanos > 0L) { "An observation window duration must be positive" }
        return Window(
            id = ++nextWindowId,
            signalNames = signalNames.toSet(),
            openedAtElapsedNanos = openedAtElapsedNanos,
            expiresAtElapsedNanos = openedAtElapsedNanos + durationNanos,
        ).also {
            windows[it.id] = it
            observations[it.id] = mutableMapOf()
        }
    }

    /** Feeds one atomic snapshot to every open window. */
    @Synchronized
    fun observe(snapshot: RoadcastSnapshot) {
        windows.values.toList().forEach { observe(it, snapshot) }
    }

    @Synchronized
    fun observe(window: Window, snapshot: RoadcastSnapshot) {
        val stored = observations[window.id] ?: return
        if (snapshot.receivedAtElapsedNanos > window.expiresAtElapsedNanos) {
            return
        }
        window.signalNames.forEach { name ->
            val sample = snapshot.sample(name) ?: return@forEach
            if (!sample.valid) return@forEach
            if (sample.lastChangeNanos !in window.openedAtElapsedNanos..window.expiresAtElapsedNanos) {
                return@forEach
            }
            val changes = stored.getOrPut(name) { mutableListOf() }
            if (changes.lastOrNull()?.lastChangeNanos != sample.lastChangeNanos) {
                changes += sample
            }
        }
    }

    @Synchronized
    fun sample(window: Window, signalName: String, nowElapsedNanos: Long): RoadcastSample? {
        if (nowElapsedNanos > window.expiresAtElapsedNanos) {
            return null
        }
        return observations[window.id]?.get(signalName)?.lastOrNull()
    }

    /** All distinct source changes captured for [signalName], in arrival order. */
    @Synchronized
    fun changes(window: Window, signalName: String, nowElapsedNanos: Long): List<RoadcastSample> {
        if (nowElapsedNanos > window.expiresAtElapsedNanos) {
            return emptyList()
        }
        return observations[window.id]?.get(signalName)?.toList().orEmpty()
    }

    @Synchronized
    fun status(window: Window?, nowElapsedNanos: Long): Status? {
        window ?: return null
        val stored = observations[window.id] ?: return null
        val remainingNanos = (window.expiresAtElapsedNanos - nowElapsedNanos).coerceAtLeast(0L)
        return Status(
            active = remainingNanos > 0L,
            remainingMillis = remainingNanos / NANOS_PER_MILLISECOND,
            capturedChanges = stored.values.sumOf { it.size },
        )
    }

    @Synchronized
    fun close(window: Window) {
        windows.remove(window.id)
        observations.remove(window.id)
    }

    data class Status(
        val active: Boolean,
        val remainingMillis: Long,
        val capturedChanges: Int,
    )

    private companion object {
        const val NANOS_PER_MILLISECOND = 1_000_000L
    }
}
