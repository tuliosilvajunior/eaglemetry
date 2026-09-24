package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.ClockBadSignatureDao
import com.timhss.capyenergy.telemetry.db.ClockBadSignatureEntity
import com.timhss.capyenergy.telemetry.db.IntervalDao
import com.timhss.capyenergy.telemetry.db.IntervalEntity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Time authority T5, step 4: the `clock_bad_signatures` ledger.
 *
 * The ledger records only what the detector PROVED by structure — the
 * census-plus-plateau override on a boot-default prefix. Distribution alone
 * (one honest outlier rejected by MAD) must NEVER ban a value fleet-wide.
 * Nothing here is a date: every stamp is composed, per plan section 9.
 */
class ClockBadSignatureLedgerTest {

    private val baseOffset = 1_786_625_634_634L
    private val backwardGap = 39_312_000_000L

    private class SigDao : ClockBadSignatureDao {
        val rows = mutableListOf<ClockBadSignatureEntity>()

        override fun upsert(signature: ClockBadSignatureEntity) {
            rows.removeAll { it.wallUtcMillis == signature.wallUtcMillis }
            rows.add(signature)
        }

        override fun countByWall(wallMillis: Long): Int =
            rows.count { it.wallUtcMillis == wallMillis }
    }

    private class FixedBootDao(private val samples: List<IntervalEntity>) : IntervalDao {
        override fun upsertAll(intervals: List<IntervalEntity>) = Unit
        override fun forSession(sessionId: String): List<IntervalEntity> = emptyList()
        override fun countForSession(sessionId: String): Long = 0L
        override fun sessionsWithBuckets(sessionIds: List<String>): List<String> = emptyList()
        override fun forSessionsInWindow(
            sessionIds: List<String>,
            startUtcMillis: Long,
            endUtcMillis: Long
        ): List<IntervalEntity> = emptyList()
        override fun deleteBySessionIds(sessionIds: List<String>): Int = 0
        override fun findById(sessionId: String, startUtcMillis: Long): IntervalEntity? = null
        override fun syncPage(
            afterStartUtcMillis: Long,
            afterSessionId: String,
            limit: Int
        ): List<IntervalEntity> = emptyList()
        override fun syncPendingCount(afterStartUtcMillis: Long, afterSessionId: String): Long = 0L
        override fun count(): Long = 0L
        override fun deleteOrphans(): Int = 0
        override fun deleteOrphansChunk(limit: Int): Int = 0
        override fun dirtyIntervals(limit: Int): List<IntervalEntity> = emptyList()
        override fun dirtyIntervalCount(): Long = 0L
        override fun pendingIntervalCount(): Long = 0L
        override fun clearDirty(sessionId: String, startUtcMillis: Long): Int = 0
        override fun clearDirtyByKeys(keys: List<String>): Int = 0
        override fun markAllDirty(): Int = 0
        override fun promoteEndedPendingToUncorrectable(): Int = 0
        override fun pendingsForBoot(bootCount: Long): List<IntervalEntity> = emptyList()
        override fun forBoot(bootCount: Long): List<IntervalEntity> = samples
        override fun allPaired(): List<IntervalEntity> = samples
        override fun deleteKey(sessionId: String, startUtcMillis: Long): Int = 0
    }

    private fun row(bootCount: Long, offset: Long, elapsedSec: Long): IntervalEntity =
        IntervalEntity(
            sessionId = "s$bootCount",
            startUtcMillis = offset + elapsedSec * 1_000L,
            widthMillis = 60_000L,
            startElapsedNanos = elapsedSec * 1_000_000_000L,
            startBootCount = bootCount.toInt()
        )

    /**
     * The proven case (the trap shape): one boot jumps from a frozen default
     * prefix (10 stamps) to truth (10 more), and the census names the prefix
     * because another boot repeats those stamps. The 10 prefix stamps become
     * signatures; the truth-tail stamps never do.
     */
    @Test
    fun `proven default stamps join the ledger`() {
        val frozenRows = List(10) { i -> row(10L, baseOffset - backwardGap, (i + 1L)) }
        val truthRows = (0 until 10).map { i -> row(10L, baseOffset, 100L + i * 60L) }
        val censusWitness = List(8) { i -> row(11L, baseOffset, 60L + i * 60L) } +
            listOf(row(11L, baseOffset - backwardGap, 1L))
        val sigDao = SigDao()
        val ledger = ClockBadSignatureLedger(sigDao, FixedBootDao(frozenRows + truthRows + censusWitness))

        val recorded = ledger.learnFromBoot(10L)

        assertEquals(10, recorded)
        assertEquals(10, sigDao.rows.size)
        val frozenWalls = frozenRows.map { it.startUtcMillis }.toSet()
        assertEquals(frozenWalls, sigDao.rows.map { it.wallUtcMillis }.toSet())
    }

    /**
     * The guard: an outlier on a clean boot is rejected by distribution
     * alone, with no census, no plateau-confirmed prefix — ambiguity is not
     * evidence, and one honest outlier must never become a banned value.
     */
    @Test
    fun `distribution-only rejection never bans a value`() {
        val outlierRow = row(20L, baseOffset - backwardGap, 6_100L)
        val rows = (0 until 100).map { i -> row(20L, baseOffset, 60L + i * 60L) } +
            listOf(outlierRow)
        val sigDao = SigDao()
        val ledger = ClockBadSignatureLedger(sigDao, FixedBootDao(rows))

        assertEquals(0, ledger.learnFromBoot(20L))
        assertEquals(0, sigDao.rows.size)
    }

    /** Readback: a recorded value is known-bad; an unrelated one is not. */
    @Test
    fun `isKnownBad reads back what was recorded`() {
        val frozenWall = baseOffset - backwardGap + 1_000L
        val frozenRows = List(10) { i -> row(30L, baseOffset - backwardGap, (i + 1L)) }
        val truthRows = (0 until 10).map { i -> row(30L, baseOffset, 100L + i * 60L) }
        val censusWitness = List(8) { i -> row(31L, baseOffset, 60L + i * 60L) } +
            listOf(row(31L, baseOffset - backwardGap, 1L))
        val sigDao = SigDao()
        val ledger = ClockBadSignatureLedger(sigDao, FixedBootDao(frozenRows + truthRows + censusWitness))
        ledger.learnFromBoot(30L)

        assertTrue(ledger.isKnownBad(frozenWall))
        assertFalse(ledger.isKnownBad(baseOffset + 300_000L))
    }
}
