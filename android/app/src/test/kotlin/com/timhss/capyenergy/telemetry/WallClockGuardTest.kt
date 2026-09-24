package com.timhss.capyenergy.telemetry

import org.junit.Assert.assertEquals
import org.junit.Test

class WallClockGuardTest {
    private val anchorWall = 1_787_101_260_000L // 2026-08-18 22:01:00 UTC
    private val anchorElapsed = 100_000_000_000L

    @Test
    fun passesHonestWallClockThrough() {
        val elapsed = anchorElapsed + 60_000_000_000L // 60 s later
        assertEquals(
            anchorWall + 60_000L,
            WallClockGuard.guardedWallMillis(anchorWall + 60_000L, elapsed, anchorWall, anchorElapsed)
        )
    }

    @Test
    fun toleratesSmallNtpCorrection() {
        val elapsed = anchorElapsed + 60_000_000_000L
        // 5 s correction: real NTP behaviour, must not false-positive.
        assertEquals(
            anchorWall + 55_000L,
            WallClockGuard.guardedWallMillis(anchorWall + 55_000L, elapsed, anchorWall, anchorElapsed)
        )
    }

    @Test
    fun projectsForwardJumpOfMonths() {
        val elapsed = anchorElapsed + 2_000_000_000L // 2 s later
        val jumpedWall = anchorWall + 474L * 24L * 3_600_000L // 474 days ahead
        assertEquals(
            anchorWall + 2_000L,
            WallClockGuard.guardedWallMillis(jumpedWall, elapsed, anchorWall, anchorElapsed)
        )
    }

    @Test
    fun projectsBackwardJumpOfMonths() {
        val elapsed = anchorElapsed + 2_000_000_000L
        val jumpedWall = anchorWall - 455L * 24L * 3_600_000L // 455 days back
        assertEquals(
            anchorWall + 2_000L,
            WallClockGuard.guardedWallMillis(jumpedWall, elapsed, anchorWall, anchorElapsed)
        )
    }

    @Test
    fun passesThroughWhenElapsedRanBackwardsAfterReboot() {
        // Elapsed reset: the anchor belongs to the previous boot and must not
        // project onto this one. The caller re-bootstraps instead.
        val wall = anchorWall + 3_600_000L
        assertEquals(
            wall,
            WallClockGuard.guardedWallMillis(wall, 5_000_000_000L, anchorWall, anchorElapsed)
        )
    }

    @Test
    fun passesThroughNonPositiveStamps() {
        assertEquals(0L, WallClockGuard.guardedWallMillis(0L, anchorElapsed, anchorWall, anchorElapsed))
        assertEquals(
            anchorWall,
            WallClockGuard.guardedWallMillis(anchorWall, anchorElapsed, 0L, anchorElapsed)
        )
    }
}
