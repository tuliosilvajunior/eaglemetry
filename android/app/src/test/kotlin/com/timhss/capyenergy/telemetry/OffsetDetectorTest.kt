package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.OffsetDetector.BootVerdict
import com.timhss.capyenergy.telemetry.OffsetDetector.ClockSample
import com.timhss.capyenergy.telemetry.OffsetDetector.StructuralFlag
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * The real shape, from the live pull: 15 078 interval rows, ~1% bad, in two
 * dense clusters ~455 days off the healthy mass — 55 backward rows around the
 * frozen-RTC band and ~122 forward rows up to ~475 days ahead — while the
 * healthy ~14 920 rows span the real session window. No wall-date constant
 * appears here: every stamp is built as `offset + elapsed`, so the fixture
 * carries the contamination shape (1% at ±455 days), never a known-bad value.
 *
 * The suite's hard rule, from the plan: a detector that flags a healthy row
 * is worse than none. Every rejection test below also asserts which rows are
 * kept.
 */
class OffsetDetectorTest {
    /** An honest `wall - elapsed` offset; the mass under test agrees on it. */
    private val baseOffset = 1_786_625_634_634L

    /** 455 days back: the backward cluster's distance from the healthy mass. */
    private val backwardGap = 39_312_000_000L

    /** ~474.6 days ahead: the forward cluster's maximum distance. */
    private val forwardGap = 41_000_000_000L

    private fun sample(boot: Long, offset: Long, elapsedSec: Long, jitterMs: Long = 0L): ClockSample {
        val elapsedNanos = elapsedSec * 1_000_000_000L
        return ClockSample(
            bootCount = boot,
            wallMillis = offset + elapsedNanos / 1_000_000L + jitterMs,
            elapsedNanos = elapsedNanos
        )
    }

    /** Healthy boot: [healthy] samples on [baseOffset] with ms jitter. */
    private fun healthyBoot(boot: Long, healthy: Int, fromSec: Long = 60L): List<ClockSample> =
        List(healthy) { i -> sample(boot, baseOffset, fromSec + i * 60L, (i % 8).toLong()) }

    private fun verdictOf(result: OffsetDetector.DetectionResult, boot: Long): BootVerdict =
        result.boots[boot] ?: throw AssertionError("no verdict for boot $boot")

    @Test
    fun backwardClusterRejectedAndHealthyKept() {
        val samples = healthyBoot(boot = 1L, healthy = 100) +
            sample(boot = 1L, offset = baseOffset - backwardGap, elapsedSec = 6_100L)

        val verdict = verdictOf(OffsetDetector.detect(samples), 1L)

        assertEquals(1, verdict.rejected.size)
        assertEquals(baseOffset - backwardGap, OffsetDetector.offsetMillisOf(verdict.rejected[0]))
        assertTrue(verdict.rejected.none { OffsetDetector.offsetMillisOf(it) == baseOffset })
        assertEquals(100, samples.size - verdict.rejected.size)
    }

    @Test
    fun forwardClusterRejectedAndHealthyKept() {
        val samples = healthyBoot(boot = 2L, healthy = 100) +
            sample(boot = 2L, offset = baseOffset + forwardGap, elapsedSec = 6_100L)

        val verdict = verdictOf(OffsetDetector.detect(samples), 2L)

        assertEquals(1, verdict.rejected.size)
        assertEquals(baseOffset + forwardGap, OffsetDetector.offsetMillisOf(verdict.rejected[0]))
        assertEquals(100, samples.size - verdict.rejected.size)
    }

    /**
     * Ladder with step 1 000 s over 12 samples: median sits at +6 000 s,
     * MAD is exactly 3 000 s, so the threshold is `7 * 1.4826 * MAD` and the
     * 15-minute floor never governs. A probe at 27 000 s off-median sits
     * between 5 and 7 normalized MADs: kept under k=7, rejected under k=5.
     */
    @Test
    fun keepsSampleInsideSevenMad() {
        val step = 1_000_000L
        val elapsedSec = 60L
        val elapsedMs = 60_000L
        val ladder = List(12) { i ->
            ClockSample(3L, baseOffset + elapsedMs + i * step, elapsedSec * 1_000_000_000L)
        }
        val probe = ClockSample(3L, baseOffset + elapsedMs + 6 * step + 27 * step, 61L * 1_000_000_000L)

        val verdict = verdictOf(OffsetDetector.detect(ladder + probe), 3L)

        assertEquals(3_000_000L, verdict.madMillis)
        assertTrue(verdict.rejected.none { it == probe })
        assertTrue(verdict.rejected.isEmpty())
    }

    /**
     * MAD is zero on identical offsets, so the 15-minute floor governs: a
     * sample exactly on the floor is kept, one millisecond past it is bad.
     * The probes sit past the healthy run on the elapsed axis, so the jump
     * between them never trips the plateau arm either.
     */
    @Test
    fun floorBoundaryKeepsAtFifteenMinutesRejectsPastIt() {
        val floor = WallClockGuard.TOLERANCE_MILLIS
        // Identical offsets: wall tracks elapsed, so MAD is exactly zero.
        val samples = List(8) { i ->
            val elapsedSec = 60L + i
            ClockSample(5L, baseOffset + elapsedSec * 1_000L, elapsedSec * 1_000_000_000L)
        } +
            ClockSample(5L, baseOffset + 70_000L + floor, 70L * 1_000_000_000L) +
            ClockSample(5L, baseOffset + 71_000L + floor + 1L, 71L * 1_000_000_000L)

        val verdict = verdictOf(OffsetDetector.detect(samples), 5L)

        assertEquals(0L, verdict.madMillis)
        assertEquals(baseOffset, verdict.medianOffsetMillis)
        assertEquals(1, verdict.rejected.size)
        assertEquals(baseOffset + floor + 1L, OffsetDetector.offsetMillisOf(verdict.rejected[0]))
        assertTrue(verdict.flags.none { it == StructuralFlag.START_PLATEAU })
    }

    /**
     * Seven paired samples with one 455-day row: the median is one bad row
     * from poisoned, so the MAD arm abstains — the bad row is NOT rejected
     * and the verdict says so. An abstaining boot is unattested, never clean.
     */
    @Test
    fun belowMinimumAbstainsAndFlags() {
        val samples = healthyBoot(boot = 6L, healthy = 6) +
            sample(boot = 6L, offset = baseOffset - backwardGap, elapsedSec = 500L)

        val verdict = verdictOf(OffsetDetector.detect(samples), 6L)

        assertTrue(verdict.rejected.isEmpty())
        assertNull(verdict.medianOffsetMillis)
        assertTrue(verdict.flags.contains(StructuralFlag.BELOW_MINIMUM_SAMPLES))
    }

    /** Eight paired samples: the minimum that lets the MAD arm run. */
    @Test
    fun atMinimumRuns() {
        val samples = healthyBoot(boot = 7L, healthy = 7) +
            sample(boot = 7L, offset = baseOffset - backwardGap, elapsedSec = 500L)

        val verdict = verdictOf(OffsetDetector.detect(samples), 7L)

        assertEquals(1, verdict.rejected.size)
        assertFalse(verdict.flags.contains(StructuralFlag.BELOW_MINIMUM_SAMPLES))
    }

    /**
     * One wall stamp recorded under two boots: the census names it and both
     * verdicts carry the flag — but census alone rejects nothing, because two
     * honest boots can re-record one minute across a reboot.
     */
    @Test
    fun duplicateStampFlagsButNeverRejectsAlone() {
        val sharedWall = baseOffset + 120_000L
        val bootA = List(8) { i -> sample(8L, baseOffset, 60L + i * 60L) } +
            sample(8L, baseOffset, 700L).copy(wallMillis = sharedWall)
        val bootB = healthyBoot(boot = 9L, healthy = 8) +
            sample(9L, baseOffset, 700L).copy(wallMillis = sharedWall)

        val result = OffsetDetector.detect(bootA + bootB)

        assertEquals(setOf(8L, 9L), result.duplicateStamps[sharedWall])
        for (boot in listOf(8L, 9L)) {
            val verdict = verdictOf(result, boot)
            assertTrue(verdict.flags.contains(StructuralFlag.DUPLICATE_STAMP))
            assertTrue(verdict.rejected.isEmpty())
        }
    }

    /**
     * The trap from the plan: ten samples on a frozen stamp the census knows
     * repeats across boots, then four on truth. The frozen prefix outweighs
     * the tail, so median+MAD alone would bless the default and reject the
     * truth. Census plus start-plateau overrides: the prefix is rejected, the
     * tail is kept, and the verdict's offset never describes the default mass
     * (the 4-sample tail cannot attest it, so the median stays unknown).
     */
    @Test
    fun poisonedMajorityLosesToCensusPlusPlateau() {
        val frozenWall = baseOffset - backwardGap + 60_000L
        val prefix = List(10) { i ->
            ClockSample(10L, frozenWall, (i + 1L) * 1_000_000_000L)
        }
        val tail = List(4) { i -> sample(10L, baseOffset, 100L + i * 60L) }
        // Legacy row on another boot, same stamp, no pairing: census-only.
        val witness = listOf(
            ClockSample(11L, frozenWall, null),
            *healthyBoot(boot = 11L, healthy = 8).toTypedArray()
        )

        val result = OffsetDetector.detect(prefix + tail + witness)
        val verdict = verdictOf(result, 10L)

        assertEquals(prefix.toSet(), verdict.rejected.toSet())
        assertTrue(verdict.rejected.none { it in tail })
        assertNull(verdict.medianOffsetMillis)
        assertTrue(verdict.flags.containsAll(setOf(StructuralFlag.DUPLICATE_STAMP, StructuralFlag.START_PLATEAU)))
        assertEquals(setOf(10L, 11L), result.duplicateStamps[frozenWall])
    }

    /**
     * Same jump shape, no census hit: the shape alone cannot say which side
     * ran on the default, so it stays a flag and the verdict is untouched —
     * the MAD arm still rejects the minority tail by distribution.
     */
    @Test
    fun plateauWithoutCensusStaysFlagOnly() {
        val prefix = List(8) { i -> sample(12L, baseOffset, 1L + i) }
        val tail = List(4) { i -> sample(12L, baseOffset - backwardGap, 100L + i * 60L) }

        val verdict = verdictOf(OffsetDetector.detect(prefix + tail), 12L)

        assertTrue(verdict.flags.contains(StructuralFlag.START_PLATEAU))
        assertFalse(verdict.flags.contains(StructuralFlag.DUPLICATE_STAMP))
        assertEquals(tail.toSet(), verdict.rejected.toSet())
        assertEquals(baseOffset, verdict.medianOffsetMillis)
    }

    /**
     * Legacy rows lost their pairing (`elapsedNanos = null`): they skip the
     * offset arms entirely, join only the census, and are never rejected —
     * an unreadable pair is unattested, not bad.
     */
    @Test
    fun unpairedLegacyRowsJoinCensusOnly() {
        val legacyWall = baseOffset + forwardGap + 60_000L
        // Identical offsets, so the median is exactly baseOffset.
        val evenBoot = { boot: Long, startSec: Long ->
            List(8) { i ->
                val elapsedSec = startSec + i
                ClockSample(boot, baseOffset + elapsedSec * 1_000L, elapsedSec * 1_000_000_000L)
            }
        }
        val bootA = evenBoot(13L, 60L) + ClockSample(13L, legacyWall, null)
        // Same stamp on another boot with a healthy pairing: the census link.
        val bootB = evenBoot(14L, 120L) +
            ClockSample(14L, legacyWall, 60L * 1_000_000_000L + forwardGap * 1_000_000L)

        val result = OffsetDetector.detect(bootA + bootB)
        val verdict = verdictOf(result, 13L)

        assertEquals(setOf(13L, 14L), result.duplicateStamps[legacyWall])
        assertTrue(verdict.flags.contains(StructuralFlag.DUPLICATE_STAMP))
        assertTrue(verdict.rejected.isEmpty())
        assertEquals(baseOffset, verdict.medianOffsetMillis)
        assertEquals(0L, verdict.madMillis)
    }

    @Test
    fun emptyInputDetectsNothing() {
        val result = OffsetDetector.detect(emptyList())

        assertTrue(result.boots.isEmpty())
        assertTrue(result.duplicateStamps.isEmpty())
    }

    @Test
    fun unreadablePairsHaveNoOffset() {
        val good = sample(15L, baseOffset, 60L)

        assertNull(OffsetDetector.offsetMillisOf(good.copy(elapsedNanos = null)))
        assertNull(OffsetDetector.offsetMillisOf(good.copy(elapsedNanos = 0L)))
        assertNull(OffsetDetector.offsetMillisOf(good.copy(wallMillis = 0L)))
    }

    /**
     * Half the boots err to the same factory default timestamp and never jump:
     * the entire boot consists of duplicate stamps across boots. The detector
     * must reject those un-anchored bad boots, keeping every healthy boot intact.
     */
    @Test
    fun halfTheBootsErrorToSameValueEntireBoot() {
        val frozenWall = baseOffset - backwardGap + 60_000L
        val healthyBoots = (1L..5L).flatMap { boot -> healthyBoot(boot, 10, fromSec = boot * 1_000L) }
        val badBoots = (6L..10L).flatMap { boot ->
            List(10) { i ->
                ClockSample(boot, frozenWall, (i + 1L) * 1_000_000_000L)
            }
        }
        val result = OffsetDetector.detect(healthyBoots + badBoots)

        // All 5 healthy boots are clean
        for (boot in 1L..5L) {
            val verdict = verdictOf(result, boot)
            assertTrue(verdict.rejected.isEmpty())
            assertTrue(abs(verdict.medianOffsetMillis!! - baseOffset) < 10L)
            assertFalse(verdict.flags.contains(StructuralFlag.BELOW_MINIMUM_SAMPLES))
        }

        // All 5 bad boots are rejected and have null medians
        for (boot in 6L..10L) {
            val verdict = verdictOf(result, boot)
            assertEquals(10, verdict.rejected.size)
            assertNull(verdict.medianOffsetMillis)
            assertTrue(verdict.flags.contains(StructuralFlag.DUPLICATE_STAMP))
            assertTrue(verdict.flags.contains(StructuralFlag.BELOW_MINIMUM_SAMPLES))
        }
    }

    /**
     * Half the boots have a 50/50 split (10 samples on default, 10 on truth):
     * MAD inflates on equal contamination, but jumpScale using tolerance detects
     * the jump, census confirms the prefix, the bad prefix is rejected, and
     * the healthy tail is kept with the true offset.
     */
    @Test
    fun halfTheBootsErrorWithPlateauAndJump() {
        val frozenWall = baseOffset - backwardGap + 60_000L
        val healthyBoots = (1L..5L).flatMap { boot -> healthyBoot(boot, 10, fromSec = boot * 1_000L) }
        val badBoots = (6L..10L).flatMap { boot ->
            val prefix = List(10) { i ->
                ClockSample(boot, frozenWall, (i + 1L) * 1_000_000_000L)
            }
            val tail = List(10) { i ->
                sample(boot, baseOffset, 100L + i * 60L)
            }
            prefix + tail
        }
        val result = OffsetDetector.detect(healthyBoots + badBoots)

        for (boot in 1L..5L) {
            val verdict = verdictOf(result, boot)
            assertTrue(verdict.rejected.isEmpty())
            assertTrue(abs(verdict.medianOffsetMillis!! - baseOffset) < 10L)
        }

        for (boot in 6L..10L) {
            val verdict = verdictOf(result, boot)
            assertEquals(10, verdict.rejected.size)
            assertTrue(verdict.rejected.all { it.wallMillis == frozenWall })
            assertEquals(baseOffset, verdict.medianOffsetMillis)
            assertTrue(verdict.flags.containsAll(setOf(StructuralFlag.DUPLICATE_STAMP, StructuralFlag.START_PLATEAU)))
        }
    }

    /**
     * Boot default identified on one boot's plateau prefix propagates to other
     * boots in the batch that ran on that same default without jumping.
     */
    @Test
    fun provenDefaultPrefixPropagatesToUnjumpedBoots() {
        val frozenWall = baseOffset - backwardGap + 60_000L
        // Boot 10 jumps from frozenWall to baseOffset
        val jumpingBoot = List(10) { i ->
            ClockSample(10L, frozenWall, (i + 1L) * 1_000_000_000L)
        } + List(10) { i ->
            sample(10L, baseOffset, 100L + i * 60L)
        }
        // Boot 11 ran on frozenWall without jumping (no intra-boot jump)
        val witness = List(4) { i ->
            ClockSample(11L, frozenWall, (i + 1L) * 1_000_000_000L)
        } + List(4) { i ->
            ClockSample(11L, frozenWall + (i + 1L) * 1_000L, (10L + i) * 1_000_000_000L)
        }

        val result = OffsetDetector.detect(jumpingBoot + witness)

        val verdict10 = verdictOf(result, 10L)
        assertEquals(10, verdict10.rejected.size)
        assertEquals(baseOffset, verdict10.medianOffsetMillis)

        val verdict11 = verdictOf(result, 11L)
        assertEquals(4, verdict11.rejected.size)
        assertTrue(verdict11.rejected.all { it.wallMillis == frozenWall })
        assertNull(verdict11.medianOffsetMillis)
        assertTrue(verdict11.flags.contains(StructuralFlag.BELOW_MINIMUM_SAMPLES))
    }
}
