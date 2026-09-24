package com.timhss.capyenergy.telemetry

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * Reproduces the 2026-08-14 defect: the trip detail chart claimed the drive
 * started at 22:00 on 2025-05-23 while the car was driving in the afternoon.
 *
 * The numbers are the real ones from trip `dd154409`, 419 frames, one of them
 * stamped with the head unit's stale boot-time clock.
 */
class SessionClockAnchorTest {
    /** Frame 43075: `wall - elapsed` at 2025-05-23 22:09:00, 448 days back. */
    private val staleOffsetMillis = 1_747_946_516_900L

    /** The offset the other 418 frames agree on, to within a millisecond. */
    private val trueOffsetMillis = 1_786_625_634_634L

    private val firstElapsedNanos = 102_371_237_054_016L

    /** `trip_sessions.startedAtUtcMillis`, which the session row got right. */
    private val sessionStartUtcMillis = 1_786_728_005_126L

    private fun realSessionOffsets(): List<Long> =
        List(418) { trueOffsetMillis - it % 2 } + staleOffsetMillis

    @Test
    fun oneStaleFrameDoesNotMoveTheAnchor() {
        val median = SessionClockAnchor.medianOffsetMillis(realSessionOffsets())

        val anchor = SessionClockAnchor.wallAnchorMillis(
            medianOffsetMillis = median,
            firstElapsedNanos = firstElapsedNanos,
            fallbackWallMillis = null
        )!!

        // The reduction this replaced was MIN(wallTimeUtcMillis), which is the
        // stale frame itself and put the whole axis 448 days in the past.
        assertTrue(anchor > staleOffsetMillis + 38_000_000_000L)
        assertTrue(abs(anchor - sessionStartUtcMillis) < 1_000L)
    }

    @Test
    fun anchorAgreesWithTheSessionRowTheReconcilerKept() {
        val anchor = SessionClockAnchor.wallAnchorMillis(
            medianOffsetMillis = trueOffsetMillis,
            firstElapsedNanos = firstElapsedNanos,
            fallbackWallMillis = null
        )

        assertEquals(1_786_728_005_871L, anchor)
    }

    @Test
    fun picksAnOffsetSomeFrameReportedRatherThanAveragingTwo() {
        assertEquals(30L, SessionClockAnchor.medianOffsetMillis(listOf(10L, 30L)))
        assertEquals(20L, SessionClockAnchor.medianOffsetMillis(listOf(30L, 10L, 20L)))
    }

    @Test
    fun readsNothingFromNoFrames() {
        assertNull(SessionClockAnchor.medianOffsetMillis(emptyList()))
    }

    @Test
    fun fallsBackWhenNoOffsetCouldBeRead() {
        val anchor = SessionClockAnchor.wallAnchorMillis(
            medianOffsetMillis = null,
            firstElapsedNanos = firstElapsedNanos,
            fallbackWallMillis = 1_786_728_005_126L
        )

        assertEquals(1_786_728_005_126L, anchor)
    }
}
