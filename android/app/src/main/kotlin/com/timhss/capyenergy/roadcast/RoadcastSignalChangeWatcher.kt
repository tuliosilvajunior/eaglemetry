package com.timhss.capyenergy.roadcast

/**
 * Waits for the first valid source change of one signal after a known baseline.
 * It is deliberately separate from [RoadcastSignalObservationPool]: a watcher
 * completes on the first eligible change; a pool preserves a window history.
 */
class RoadcastSignalChangeWatcher(
    private val defaultTimeoutNanos: Long = DEFAULT_TIMEOUT_NANOS,
) {
    class Watch internal constructor(
        internal val id: Long,
        internal val signalName: String,
        internal val baselineChangeNanos: Long,
        internal val expiresAtElapsedNanos: Long,
    )

    sealed interface Result {
        data object Pending : Result
        data class Changed(val sample: RoadcastSample) : Result
        data object TimedOut : Result
    }

    data class Status(
        val active: Boolean,
        val remainingMillis: Long,
        val result: String,
    )

    private var nextWatchId = 0L
    private val watches = mutableMapOf<Long, Watch>()
    private val results = mutableMapOf<Long, Result>()

    @Synchronized
    fun watch(
        signalName: String,
        baselineChangeNanos: Long,
        openedAtElapsedNanos: Long,
        timeoutNanos: Long = defaultTimeoutNanos,
    ): Watch {
        require(timeoutNanos > 0L) { "A change watcher timeout must be positive" }
        return Watch(
            id = ++nextWatchId,
            signalName = signalName,
            baselineChangeNanos = baselineChangeNanos,
            expiresAtElapsedNanos = openedAtElapsedNanos + timeoutNanos,
        ).also { watches[it.id] = it }
    }

    @Synchronized
    fun poll(watch: Watch, snapshot: RoadcastSnapshot): Result =
        poll(watch, snapshot, snapshot.receivedAtElapsedNanos)

    @Synchronized
    fun poll(watch: Watch, snapshot: RoadcastSnapshot, nowElapsedNanos: Long): Result {
        results[watch.id]?.let { return it }
        if (nowElapsedNanos > watch.expiresAtElapsedNanos) return complete(watch, Result.TimedOut)
        val sample = snapshot.sample(watch.signalName)
        if (sample != null && sample.valid && sample.lastChangeNanos > watch.baselineChangeNanos) {
            return complete(watch, Result.Changed(sample))
        }
        return Result.Pending
    }

    @Synchronized
    fun status(watch: Watch?, nowElapsedNanos: Long): Status? {
        watch ?: return null
        val result = results[watch.id]
        val remainingNanos = (watch.expiresAtElapsedNanos - nowElapsedNanos).coerceAtLeast(0L)
        val resultLabel = when (result) {
            null -> if (remainingNanos > 0L) "PENDING" else "TIMED_OUT"
            is Result.Changed -> "CHANGED"
            Result.TimedOut -> "TIMED_OUT"
            Result.Pending -> "PENDING"
        }
        return Status(
            active = result == null && remainingNanos > 0L,
            remainingMillis = remainingNanos / NANOS_PER_MILLISECOND,
            result = resultLabel,
        )
    }

    @Synchronized
    fun close(watch: Watch) {
        watches.remove(watch.id)
        results.remove(watch.id)
    }

    private fun complete(watch: Watch, result: Result): Result {
        watches.remove(watch.id)
        results[watch.id] = result
        return result
    }

    private companion object {
        const val NANOS_PER_MILLISECOND = 1_000_000L
        const val DEFAULT_TIMEOUT_NANOS = 5_000_000_000L
    }
}
