package com.timhss.capyenergy.telemetry

/**
 * The wall-clock instant to put on a session's elapsed-nanos axis.
 *
 * Inside one boot `elapsedRealtimeNanos` is monotonic and orders the frames.
 * The wall stamp is a label on that order, and it is the fragile half: this
 * head unit boots with no time reference, shows the MCU firmware time, and is
 * corrected later by `AutoTimeService` from the MCU, SNTP or GPS. A frame
 * written before the correction lands keeps its stale stamp for good.
 *
 * In the field data that is a lone frame carrying a cached instant while its
 * neighbours are right: three trips on 2026-08-14 each hold one frame stamped
 * 2025-05-23 22:09:00, 448 days back, between frames one second apart.
 *
 * Inside one boot a session has a single clock offset, `wall - elapsed`, so the
 * honest anchor is the middle of the offsets its frames reported.
 * `MIN(wallTimeUtcMillis)` was the one reduction that hands the axis to the
 * worst sample in the session: one frame in 419 moved it by 448 days, while a
 * median needs 210 of them to move as far.
 *
 * This applies only where elapsed nanos are comparable. A session that spans a
 * reboot has no shared monotonic clock and is rebased on wall time instead —
 * see `SessionTimeline.spansReboot`.
 *
 * This holds the rule for callers that already have the offsets in memory. The
 * database computes the same median in SQL — see
 * `TelemetryFrameDao.sessionMedianClockOffsetMillis` — because paging a whole
 * session to place one label would be its own defect.
 */
object SessionClockAnchor {
    private const val NANOS_PER_MILLISECOND = 1_000_000L

    /**
     * Middle offset of [offsetsMillis], or null when there is nothing to read.
     *
     * For an even count this is the upper of the two middle values, which is
     * what `LIMIT 1 OFFSET COUNT(*) / 2` returns. Averaging the two middles
     * would invent an offset that no frame reported.
     */
    fun medianOffsetMillis(offsetsMillis: List<Long>): Long? {
        if (offsetsMillis.isEmpty()) return null
        return offsetsMillis.sorted()[offsetsMillis.size / 2]
    }

    /**
     * Wall instant of [firstElapsedNanos] under [medianOffsetMillis].
     *
     * [fallbackWallMillis] answers when no offset could be read, so a caller
     * that used to pass the stored minimum keeps its old behaviour rather than
     * losing the axis label entirely.
     */
    fun wallAnchorMillis(
        medianOffsetMillis: Long?,
        firstElapsedNanos: Long,
        fallbackWallMillis: Long?
    ): Long? {
        if (medianOffsetMillis == null) return fallbackWallMillis
        return medianOffsetMillis + firstElapsedNanos / NANOS_PER_MILLISECOND
    }
}
