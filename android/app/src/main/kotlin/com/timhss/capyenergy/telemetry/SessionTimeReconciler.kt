package com.timhss.capyenergy.telemetry

import kotlin.math.abs

/**
 * Keeps session duration independent from Android's adjustable wall clock.
 *
 * `elapsedRealtimeNanos` is monotonic inside one boot, while
 * `System.currentTimeMillis()` can jump when the head unit receives a new time
 * source. Boot counts make the monotonic comparison explicit: values from two
 * boots must never be subtracted from each other.
 */
object SessionTimeReconciler {
    private const val WALL_DRIFT_TOLERANCE_MILLIS = 10_000L
    private const val NANOS_PER_MILLISECOND = 1_000_000L

    /**
     * Boot count that may honestly be claimed for [elapsedNanos].
     *
     * Elapsed nanos only mean something inside the boot that read them. A
     * session surviving a reboot replays the timestamps it was restored with,
     * so stamping the current boot onto those nanos asserts that two boots are
     * one — and [reconcileStartUtcMillis] reads equal boot counts as licence to
     * rebuild the wall clock from the elapsed delta, collapsing everything
     * before the reboot. Nanos that did not move keep the boot recorded for
     * them; only a fresh reading earns the current one.
     */
    fun boundBootCount(
        existing: Int?,
        existingElapsedNanos: Long?,
        elapsedNanos: Long,
        current: Int?
    ): Int? = if (existing != null && existingElapsedNanos == elapsedNanos) existing else current

    fun durationMillis(
        startElapsedNanos: Long,
        startBootCount: Int?,
        endElapsedNanos: Long,
        endBootCount: Int?
    ): Long? {
        if (startBootCount == null || endBootCount == null || startBootCount != endBootCount) {
            return null
        }
        val deltaNanos = endElapsedNanos - startElapsedNanos
        if (startElapsedNanos <= 0L || deltaNanos < 0L) return null
        return (deltaNanos + NANOS_PER_MILLISECOND / 2L) / NANOS_PER_MILLISECOND
    }

    /**
     * Wall instant to close a session with.
     *
     * Mirrors [reconcileStartUtcMillis]: the session-open stamp is ground
     * truth, so a close stamp that disagrees with start + elapsed delta by
     * more than [WallClockGuard.TOLERANCE_MILLIS] is a jumped clock, and the
     * monotonic projection is stored instead of a close dated months before
     * (or after) the session started. With the end projected, the wall and
     * monotonic durations agree and [reconcileStartUtcMillis] keeps the
     * start — the reconciler can no longer drag a good start onto a bad end.
     *
     * Across boots there is no shared monotonic clock and nothing to project
     * from: the raw end passes through, as does any stamp missing its
     * elapsed half.
     */
    fun reconcileEndUtcMillis(
        startUtcMillis: Long,
        startElapsedNanos: Long,
        startBootCount: Int?,
        endUtcMillis: Long,
        endElapsedNanos: Long,
        endBootCount: Int?
    ): Long {
        if (startBootCount == null || endBootCount == null || startBootCount != endBootCount) {
            return endUtcMillis
        }
        if (startElapsedNanos <= 0L || endElapsedNanos <= 0L) return endUtcMillis
        if (endElapsedNanos < startElapsedNanos) return endUtcMillis
        return WallClockGuard.guardedWallMillis(
            wallMillis = endUtcMillis,
            elapsedNanos = endElapsedNanos,
            anchorWallMillis = startUtcMillis,
            anchorElapsedNanos = startElapsedNanos
        )
    }

    fun reconcileStartUtcMillis(
        startUtcMillis: Long,
        startElapsedNanos: Long,
        startBootCount: Int?,
        endUtcMillis: Long,
        endElapsedNanos: Long,
        endBootCount: Int?
    ): Long {
        val monotonicDuration = durationMillis(
            startElapsedNanos = startElapsedNanos,
            startBootCount = startBootCount,
            endElapsedNanos = endElapsedNanos,
            endBootCount = endBootCount
        ) ?: return startUtcMillis
        val wallDuration = endUtcMillis - startUtcMillis
        return if (abs(wallDuration - monotonicDuration) > WALL_DRIFT_TOLERANCE_MILLIS) {
            endUtcMillis - monotonicDuration
        } else {
            startUtcMillis
        }
    }

    fun canonicalDurationMillis(
        startUtcMillis: Long,
        startElapsedNanos: Long,
        startBootCount: Int?,
        endUtcMillis: Long,
        endElapsedNanos: Long,
        endBootCount: Int?,
        maxWallDurationMillis: Long
    ): Long? {
        durationMillis(
            startElapsedNanos = startElapsedNanos,
            startBootCount = startBootCount,
            endElapsedNanos = endElapsedNanos,
            endBootCount = endBootCount
        )?.let { return it }

        return (endUtcMillis - startUtcMillis).takeIf { it in 0..maxWallDurationMillis }
    }
}
