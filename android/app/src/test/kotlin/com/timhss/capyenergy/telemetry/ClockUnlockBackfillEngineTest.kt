package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.ClockAnchorStore.Anchor
import com.timhss.capyenergy.telemetry.ClockAnchorStore.Source
import com.timhss.capyenergy.telemetry.db.IntervalEntity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Time authority T5: the unlock-and-backfill engine. This suite carries the
 * captain's scenario verbatim — the car boots on the factory default
 * (2025-05-23 22:08 local), keeps recording there, and a truth source lands
 * 44 s later (here: elapsed 644 s in a streak that started at elapsed 0) —
 * and asserts that the pre-truth minutes written BEFORE the truth arrived go
 * from PENDING to KNOWN by exact arithmetic.
 *
 * Every stamp is composed as `offset + elapsed`, per the plan's no-constants
 * rule; no wall date appears in any assertion, only the offsets.
 *
 * Mutation contract: make `clockUnlock` return an empty list and every test
 * here must fail. A test that still passes with the rule deleted tests its
 * own harness, not the rule.
 */
class ClockUnlockBackfillEngineTest {

    /** The streak's wall offset while the clock ran on the factory default. */
    private val defaultOffset = 1_748_048_880_000L

    /** The streak's wall offset once the truth source landed. */
    private val truthOffset = defaultOffset + 2 * 24 * 3_600_000L

    private fun minute(
        sessionId: String,
        offset: Long,
        elapsedSec: Long,
        bootCount: Long = 1L,
        timeState: String = "pending"
    ): IntervalEntity = IntervalEntity(
        sessionId = sessionId,
        startUtcMillis = offset + elapsedSec * 1_000L,
        widthMillis = 60_000L,
        startElapsedNanos = elapsedSec * 1_000_000_000L,
        startBootCount = bootCount.toInt(),
        timeState = timeState,
        dirty = false
    )

    /**
     * THE CAPTAIN'S SCENARIO: car boots on factory default 2025-05-23 22:08:00
     * (1_748_048_880_000L), syncs 44 seconds later at elapsed 44 s.
     * The minute recorded before truth arrived (covering elapsed 0..44 s)
     * transitions from PENDING to KNOWN with the exact corrected wall key.
     */
    @Test
    fun `captain scenario - boot on 2025-05-23 22-08, sync 44 seconds later, pre-truth minute resolves to known`() {
        val bootDefaultWall = 1_748_048_880_000L // 2025-05-23 22:08:00
        val preTruthMinute = minute("s1", bootDefaultWall, elapsedSec = 0L, bootCount = 1L, timeState = "pending")
        val anchor44s = Anchor(
            wallMillis = truthOffset + 44_000L,
            elapsedNanos = 44L * 1_000_000_000L,
            source = Source.GPS_FIX
        )

        val resolved = ClockUnlockBackfillEngine.clockUnlock(
            candidates = listOf(preTruthMinute),
            anchor = anchor44s,
            anchorBootCount = 1L
        )

        assertEquals("the pre-truth minute must resolve", 1, resolved.size)
        val corrected = resolved[0]
        assertEquals("startUtcMillis must resolve by exact subtraction", truthOffset, corrected.startUtcMillis)
        assertEquals("known", corrected.timeState)
        assertTrue("corrected row must be marked dirty to trigger upload", corrected.dirty)
        assertEquals(0L, corrected.startElapsedNanos)
        assertEquals(1, corrected.startBootCount)
    }

    /**
     * Pre-truth minutes move onto the trusted line; post-truth pending minutes
     * are promoted to KNOWN; already known minutes need no rewrite.
     */
    @Test
    fun `pre-truth minutes resolve from pending to known after unlock`() {
        val anchor = Anchor(
            wallMillis = truthOffset + 644_000L,
            elapsedNanos = 644L * 1_000_000_000L,
            source = Source.GPS_FIX
        )
        val pre = (0 until 10).map { i -> minute("s1", defaultOffset, i * 60L, timeState = "pending") }
        val post = (10 until 16).map { i -> minute("s1", truthOffset, i * 60L, timeState = "known") }

        val resolved = ClockUnlockBackfillEngine.clockUnlock(
            candidates = pre + post,
            anchor = anchor
        )
        assertEquals("only the 10 pre-truth pending buckets rewrite", 10, resolved.size)
        for (i in resolved.indices) {
            val row = resolved[i]
            assertEquals("bucket $i must resolve onto the trusted minutes", truthOffset + i * 60_000L, row.startUtcMillis)
            assertEquals("known", row.timeState)
            assertTrue("corrected rows must re-upload", row.dirty)
        }
    }

    @Test
    fun `pending rows already on trusted minute are promoted to known`() {
        val anchor = Anchor(
            wallMillis = truthOffset + 120_000L,
            elapsedNanos = 120L * 1_000_000_000L,
            source = Source.SERVER_DATE
        )
        val pendingOnTruth = minute("s1", truthOffset, 120L, timeState = "pending")

        val resolved = ClockUnlockBackfillEngine.clockUnlock(listOf(pendingOnTruth), anchor)

        assertEquals(1, resolved.size)
        assertEquals("known", resolved[0].timeState)
        assertEquals(truthOffset + 120_000L, resolved[0].startUtcMillis)
        assertTrue(resolved[0].dirty)
    }

    @Test
    fun `collisions between pending minutes mapping to the same minute merge by summation`() {
        val anchor = Anchor(
            wallMillis = truthOffset + 44_000L,
            elapsedNanos = 44L * 1_000_000_000L,
            source = Source.GPS_FIX
        )
        // Two rows that map to minute 0: one at elapsed 0s, another at elapsed 20s
        val row1 = minute("s1", defaultOffset, 0L).copy(tractionWh = 5.0, distanceKm = 0.5, coveredSeconds = 20.0)
        val row2 = minute("s1", defaultOffset, 20L).copy(tractionWh = 7.0, distanceKm = 0.7, coveredSeconds = 24.0)

        val resolved = ClockUnlockBackfillEngine.clockUnlock(listOf(row1, row2), anchor)

        assertEquals("colliding minutes must merge into a single row", 1, resolved.size)
        val merged = resolved[0]
        assertEquals(truthOffset, merged.startUtcMillis)
        assertEquals(12.0, merged.tractionWh, 0.001)
        assertEquals(1.2, merged.distanceKm, 0.001)
        assertEquals(44.0, merged.coveredSeconds, 0.001)
        assertEquals("known", merged.timeState)
    }

    /**
     * The resolution is subtraction, not estimation: for every row the
     * rewritten wall is `anchorWall + (rowElapsed - anchorElapsed)` floored
     * to the minute — exactly, down to the second.
     */
    @Test
    fun `resolution is exact arithmetic against the anchor`() {
        val anchor = Anchor(
            wallMillis = truthOffset + 44_000L,
            elapsedNanos = 44L * 1_000_000_000L,
            source = Source.SERVER_DATE
        )
        val candidates = (0 until 8).map { i -> minute("s1", defaultOffset, i * 60L) }

        val resolved = ClockUnlockBackfillEngine.clockUnlock(candidates, anchor)

        for (i in resolved.indices) {
            assertEquals(truthOffset + i * 60_000L, resolved[i].startUtcMillis)
            assertEquals(candidates[i].startElapsedNanos, resolved[i].startElapsedNanos)
            assertEquals(candidates[i].startBootCount, resolved[i].startBootCount)
        }
    }

    /**
     * The truth never arrived: with no anchor the sweep touches nothing.
     * These rows stay PENDING for the session close to mark UNCORRECTABLE —
     * never deleted, never guessed.
     */
    @Test
    fun `without an anchor the sweep leaves every row pending`() {
        val candidates = (0 until 4).map { i -> minute("s1", defaultOffset, i * 60L) }

        val resolved = ClockUnlockBackfillEngine.clockUnlock(candidates, null)

        assertTrue(resolved.isEmpty())
        for (row in candidates) {
            assertEquals("pending", row.timeState)
            assertEquals(false, row.dirty)
        }
    }

    /**
     * Two streaks of one session across a reboot are different boots, and the
     * anchor belongs to exactly one of them: the other streak's rows are not
     * resolved — re-anchoring with a foreign boot's reference would defeat
     * the monotonic restart (plan section 2, the per-boot rule).
     */
    @Test
    fun `an anchor only resolves rows of its own boot`() {
        val anchor = Anchor(
            wallMillis = truthOffset + 644_000L,
            elapsedNanos = 644L * 1_000_000_000L,
            source = Source.GPS_FIX
        )
        val own = (0 until 4).map { i -> minute("s1", defaultOffset, i * 60L, bootCount = 7L) }
        val foreign = (0 until 4).map { i -> minute("s1", defaultOffset, i * 60L, bootCount = 8L) }

        val resolved = ClockUnlockBackfillEngine.clockUnlock(
            candidates = own + foreign,
            anchor = anchor,
            anchorBootCount = 7L
        )

        assertEquals(4, resolved.size)
        assertTrue(resolved.all { it.startBootCount == 7 })
    }

    // ---- T9: the replaced-keys ledger + corrected marker ---------------------

    @Test
    fun `a moved row records its old key and carries the corrected marker`() {
        val anchor = Anchor(
            wallMillis = truthOffset + 44_000L,
            elapsedNanos = 44L * 1_000_000_000L,
            source = Source.GPS_FIX
        )
        val wrong = minute("s1", defaultOffset, elapsedSec = 0L)

        val outcome = ClockUnlockBackfillEngine.clockUnlockWithKeys(
            candidates = listOf(wrong),
            anchor = anchor,
            anchorBootCount = 1L
        )

        assertEquals(1, outcome.rows.size)
        val row = outcome.rows.single()
        assertEquals(truthOffset, row.startUtcMillis)
        assertEquals(wrong.startUtcMillis, row.correctedFromUtcMillis)
        assertEquals(
            listOf(ReplacedIntervalKey("s1", wrong.startUtcMillis, truthOffset)),
            outcome.replacedKeys
        )
    }

    @Test
    fun `an in-place resolution writes no replaced key and no marker`() {
        val anchor = Anchor(
            wallMillis = truthOffset + 44_000L,
            elapsedNanos = 44L * 1_000_000_000L,
            source = Source.GPS_FIX
        )
        // This row's resolved minute equals its own stamp: pending -> known
        // in place. Nothing left the cloud, so nothing may be deleted.
        val onTruth = minute("s1", truthOffset, elapsedSec = 0L, timeState = "pending")

        val outcome = ClockUnlockBackfillEngine.clockUnlockWithKeys(
            candidates = listOf(onTruth),
            anchor = anchor,
            anchorBootCount = 1L
        )

        assertEquals(1, outcome.rows.size)
        assertEquals("known", outcome.rows.single().timeState)
        assertTrue(outcome.replacedKeys.isEmpty())
        assertEquals(null, outcome.rows.single().correctedFromUtcMillis)
    }

    @Test
    fun `a collision ledger names BOTH old keys for one corrected row`() {
        val anchor = Anchor(
            wallMillis = truthOffset + 44_000L,
            elapsedNanos = 44L * 1_000_000_000L,
            source = Source.GPS_FIX
        )
        // Two pending minutes mapping onto the SAME corrected minute.
        val row1 = minute("s1", defaultOffset, elapsedSec = 0L)
        val row2 = minute("s1", defaultOffset, elapsedSec = 20L)

        val outcome = ClockUnlockBackfillEngine.clockUnlockWithKeys(
            candidates = listOf(row1, row2),
            anchor = anchor,
            anchorBootCount = 1L
        )

        assertEquals(1, outcome.rows.size)
        val merged = outcome.rows.single()
        assertEquals(truthOffset, merged.startUtcMillis)
        assertEquals(
            setOf(row1.startUtcMillis, row2.startUtcMillis),
            outcome.replacedKeys.map { it.oldStartUtcMillis }.toSet()
        )
        assertTrue(
            "both old keys must point at the corrected minute",
            outcome.replacedKeys.all { it.correctedStartUtcMillis == truthOffset }
        )
    }
}
