package com.timhss.capyenergy.telemetry

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SessionTimeReconcilerTest {
    @Test
    fun rebasesStartWhenWallClockJumpsBackByHundredsOfDays() {
        val endUtcMillis = 1_785_536_036_910L
        val startElapsedNanos = 96_288_833_352_617L
        val endElapsedNanos = 96_473_487_350_780L

        val result = SessionTimeReconciler.reconcileStartUtcMillis(
            startUtcMillis = 1_748_048_890_192L,
            startElapsedNanos = startElapsedNanos,
            startBootCount = 42,
            endUtcMillis = endUtcMillis,
            endElapsedNanos = endElapsedNanos,
            endBootCount = 42
        )

        assertEquals(1_785_535_852_256L, result)
    }

    @Test
    fun preservesStartWhenWallAndMonotonicDurationsAgree() {
        val result = SessionTimeReconciler.reconcileStartUtcMillis(
            startUtcMillis = 1_700_000_000_000L,
            startElapsedNanos = 10_000_000_000L,
            startBootCount = 7,
            endUtcMillis = 1_700_000_180_000L,
            endElapsedNanos = 190_000_000_000L,
            endBootCount = 7
        )

        assertEquals(1_700_000_000_000L, result)
    }

    @Test
    fun doesNotCompareMonotonicValuesFromDifferentBoots() {
        val result = SessionTimeReconciler.durationMillis(
            startElapsedNanos = 90_000_000_000L,
            startBootCount = 7,
            endElapsedNanos = 120_000_000_000L,
            endBootCount = 8
        )

        assertNull(result)
    }

    @Test
    fun rejectsImplausibleWallFallbackInsteadOfReturningHugeDuration() {
        val result = SessionTimeReconciler.canonicalDurationMillis(
            startUtcMillis = 1_700_000_000_000L,
            startElapsedNanos = 90_000_000_000L,
            startBootCount = 7,
            endUtcMillis = 1_785_536_036_910L,
            endElapsedNanos = 120_000_000_000L,
            endBootCount = 8,
            maxWallDurationMillis = 48 * 60 * 60 * 1_000L
        )

        assertNull(result)
    }

    @Test
    fun projectsEndForwardWhenCloseStampJumpsBackByHundredsOfDays() {
        val startUtcMillis = 1_785_536_036_910L
        val startElapsedNanos = 96_288_833_352_617L
        val endElapsedNanos = 96_473_487_350_780L

        val result = SessionTimeReconciler.reconcileEndUtcMillis(
            startUtcMillis = startUtcMillis,
            startElapsedNanos = startElapsedNanos,
            startBootCount = 42,
            endUtcMillis = startUtcMillis - 455L * 24L * 3_600_000L,
            endElapsedNanos = endElapsedNanos,
            endBootCount = 42
        )

        assertEquals(startUtcMillis + 184_653L, result)
    }

    @Test
    fun projectsEndBackWhenCloseStampJumpsForwardByHundredsOfDays() {
        val startUtcMillis = 1_785_536_036_910L
        val startElapsedNanos = 96_288_833_352_617L
        val endElapsedNanos = 96_473_487_350_780L

        val result = SessionTimeReconciler.reconcileEndUtcMillis(
            startUtcMillis = startUtcMillis,
            startElapsedNanos = startElapsedNanos,
            startBootCount = 42,
            endUtcMillis = startUtcMillis + 474L * 24L * 3_600_000L,
            endElapsedNanos = endElapsedNanos,
            endBootCount = 42
        )

        assertEquals(startUtcMillis + 184_653L, result)
    }

    @Test
    fun passesHonestEndStampThrough() {
        val result = SessionTimeReconciler.reconcileEndUtcMillis(
            startUtcMillis = 1_700_000_000_000L,
            startElapsedNanos = 10_000_000_000L,
            startBootCount = 7,
            endUtcMillis = 1_700_000_180_000L,
            endElapsedNanos = 190_000_000_000L,
            endBootCount = 7
        )

        assertEquals(1_700_000_180_000L, result)
    }

    @Test
    fun passesEndThroughAcrossBoots() {
        val jumpedEnd = 1_700_000_000_000L - 455L * 24L * 3_600_000L
        val result = SessionTimeReconciler.reconcileEndUtcMillis(
            startUtcMillis = 1_700_000_000_000L,
            startElapsedNanos = 90_000_000_000L,
            startBootCount = 7,
            endUtcMillis = jumpedEnd,
            endElapsedNanos = 120_000_000_000L,
            endBootCount = 8
        )

        assertEquals(jumpedEnd, result)
    }
}
