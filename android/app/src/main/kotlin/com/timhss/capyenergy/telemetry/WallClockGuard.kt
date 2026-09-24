package com.timhss.capyenergy.telemetry

import kotlin.math.abs

/**
 * Defensive wall-clock plausibility check for telemetry stamps.
 *
 * The head unit's wall clock (`System.currentTimeMillis()`) occasionally
 * jumps by days or months — a bad NTP sync or RTC glitch — while
 * `elapsedRealtimeNanos` keeps ticking monotonically underneath. Field data
 * showed interval rows stamped up to 474 days ahead of their own update time
 * and sessions closed with `endedAt` 455 days before they started.
 *
 * The rule: inside one boot, `wall - elapsed` is a fixed offset (the session
 * anchor). A new wall reading that disagrees with the anchor's projection by
 * more than [TOLERANCE_MILLIS] is a jumped clock, not real time, and the
 * caller stamps the monotonic projection instead of the jumped value.
 *
 * Pure, so it runs on the JVM test rig with no Android clock.
 */
object WallClockGuard {
    /**
     * Generous on purpose: real NTP corrections land in seconds and timezone
     * or DST shifts never move `currentTimeMillis` (UTC has no zones), so a
     * quarter hour only ever fires on a genuinely broken clock.
     */
    const val TOLERANCE_MILLIS = 15 * 60 * 1_000L

    private const val NANOS_PER_MILLISECOND = 1_000_000L

    /**
     * Wall instant to stamp for a reading taken at [wallMillis]/[elapsedNanos].
     *
     * Returns [wallMillis] when it agrees with the anchor's projection within
     * [toleranceMillis], otherwise the projection
     * `anchorWallMillis + (elapsedNanos - anchorElapsedNanos)`. Non-positive
     * stamps or an elapsed reading that ran backwards (reboot: the anchor's
     * boot is over) cannot be projected and pass through untouched — the
     * caller re-bootstraps its anchor from the next honest reading instead.
     */
    fun guardedWallMillis(
        wallMillis: Long,
        elapsedNanos: Long,
        anchorWallMillis: Long,
        anchorElapsedNanos: Long,
        toleranceMillis: Long = TOLERANCE_MILLIS
    ): Long {
        if (wallMillis <= 0L || anchorWallMillis <= 0L) return wallMillis
        if (elapsedNanos <= 0L || anchorElapsedNanos <= 0L) return wallMillis
        val elapsedDeltaNanos = elapsedNanos - anchorElapsedNanos
        if (elapsedDeltaNanos < 0L) return wallMillis
        val projected = anchorWallMillis + elapsedDeltaNanos / NANOS_PER_MILLISECOND
        return if (abs(wallMillis - projected) > toleranceMillis) projected else wallMillis
    }
}
