package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.ClockAnchorStore.Anchor
import com.timhss.capyenergy.telemetry.ClockAnchorStore.Source
import com.timhss.capyenergy.telemetry.db.IntervalDao
import com.timhss.capyenergy.telemetry.db.IntervalEntity
import com.timhss.capyenergy.telemetry.db.IntervalReplacedKeyDao
import com.timhss.capyenergy.telemetry.db.IntervalReplacedKeyEntity
import com.timhss.capyenergy.telemetry.db.SessionEntity
import com.timhss.capyenergy.telemetry.sync.FakeSessionDao
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.concurrent.thread

/**
 * Time authority T5, steps 3-5: the session-close hookup and the no-truth
 * preservation, both against an in-memory interval store no Android needed.
 *
 * The close path is `SessionRepository` -> `SessionFinalizer` ->
 * `ClockBackfillSweeper.sweepOnClose`; the sweeper is what these tests
 * drive, with the same `ClockAnchorStore` singleton the collector and the
 * uploader use, reset around each test (per-boot anchor state, plan 5.1).
 */
class ClockBackfillSweeperTest {

    /** The boot's wall offset while it ran on the boot default. */
    private val defaultOffset = 1_748_048_880_000L

    /** Much later: what a truth source reads. */
    private val truthOffset = defaultOffset + 90 * 24 * 3_600_000L

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

    private class RecordingReplacedKeyDao : IntervalReplacedKeyDao {
        val rows = mutableListOf<IntervalReplacedKeyEntity>()
        override fun upsertAll(keys: List<IntervalReplacedKeyEntity>) {
            for (key in keys) {
                rows.removeAll {
                    it.sessionId == key.sessionId && it.startUtcMillis == key.startUtcMillis
                }
                rows.add(key)
            }
        }
        override fun pending(limit: Int): List<IntervalReplacedKeyEntity> =
            rows.sortedBy { it.startUtcMillis }.take(limit)
        override fun deleteKey(sessionId: String, startUtcMillis: Long): Int {
            val before = rows.size
            rows.removeAll { it.sessionId == sessionId && it.startUtcMillis == startUtcMillis }
            return before - rows.size
        }
    }

    private class RecordingDao : IntervalDao {
        val rows = mutableListOf<IntervalEntity>()
        val deletedKeys = mutableListOf<Pair<String, Long>>()
        val upserted = mutableListOf<IntervalEntity>()

        override fun upsertAll(intervals: List<IntervalEntity>) {
            for (row in intervals) {
                rows.removeAll {
                    it.sessionId == row.sessionId && it.startUtcMillis == row.startUtcMillis
                }
                rows.add(row)
                upserted.add(row)
            }
        }

        override fun forSession(sessionId: String): List<IntervalEntity> =
            rows.filter { it.sessionId == sessionId }.sortedBy { it.startUtcMillis }

        override fun countForSession(sessionId: String): Long =
            rows.count { it.sessionId == sessionId }.toLong()

        override fun sessionsWithBuckets(sessionIds: List<String>): List<String> =
            sessionIds.filter { id -> rows.any { it.sessionId == id } }

        override fun forSessionsInWindow(
            sessionIds: List<String>,
            startUtcMillis: Long,
            endUtcMillis: Long
        ): List<IntervalEntity> = rows.filter {
            it.sessionId in sessionIds && it.startUtcMillis >= startUtcMillis && it.startUtcMillis < endUtcMillis
        }

        override fun deleteBySessionIds(sessionIds: List<String>): Int {
            val before = rows.size
            rows.removeAll { it.sessionId in sessionIds }
            return before - rows.size
        }

        override fun findById(sessionId: String, startUtcMillis: Long): IntervalEntity? =
            rows.firstOrNull { it.sessionId == sessionId && it.startUtcMillis == startUtcMillis }

        override fun syncPage(
            afterStartUtcMillis: Long,
            afterSessionId: String,
            limit: Int
        ): List<IntervalEntity> = emptyList()

        override fun syncPendingCount(afterStartUtcMillis: Long, afterSessionId: String): Long = 0L

        override fun count(): Long = rows.size.toLong()

        override fun deleteOrphans(): Int = 0

        override fun deleteOrphansChunk(limit: Int): Int = 0

        override fun dirtyIntervals(limit: Int): List<IntervalEntity> =
            rows.filter { it.dirty }.take(limit)

        override fun dirtyIntervalCount(): Long = rows.count { it.dirty }.toLong()

        override fun pendingIntervalCount(): Long = rows.count { it.dirty && it.timeState == "pending" }.toLong()

        override fun clearDirty(sessionId: String, startUtcMillis: Long): Int {
            var changed = 0
            rows.replaceAll {
                if (it.sessionId == sessionId && it.startUtcMillis == startUtcMillis) {
                    changed++
                    it.copy(dirty = false)
                } else it
            }
            return changed
        }

        override fun clearDirtyByKeys(keys: List<String>): Int {
            var changed = 0
            rows.replaceAll {
                if ("${it.sessionId}:${it.startUtcMillis}" in keys) {
                    changed++
                    it.copy(dirty = false)
                } else it
            }
            return changed
        }

        override fun markAllDirty(): Int {
            rows.replaceAll { it.copy(dirty = true) }
            return rows.size
        }

        override fun promoteEndedPendingToUncorrectable(): Int = 0

            override fun allPaired(): List<IntervalEntity> = emptyList()
override fun pendingsForBoot(bootCount: Long): List<IntervalEntity> =
            rows.filter {
                it.startBootCount?.toLong() == bootCount &&
                    it.timeState != "known" &&
                    it.startElapsedNanos != null
            }.sortedBy { it.startElapsedNanos }

        override fun forBoot(bootCount: Long): List<IntervalEntity> = rows.filter {
            it.startBootCount?.toLong() == bootCount && it.startElapsedNanos != null
        }.sortedBy { it.startElapsedNanos }

        override fun deleteKey(sessionId: String, startUtcMillis: Long): Int {
            val before = rows.size
            rows.removeAll { it.sessionId == sessionId && it.startUtcMillis == startUtcMillis }
            deletedKeys.add(Pair(sessionId, startUtcMillis))
            return before - rows.size
        }
    }


    /**
     * Forces the learned state through the store's own public API (the same
     * corroboration path the uploader uses): a reference offset set by the
     * detector plus one Date that agrees.
     */
    private fun forceLearned() {
        val offset = truthOffset
        ClockAnchorStore.setReferenceOffset(offset)
        ClockAnchorStore.offerServerDate(offset + 700_000L, 700L * 1_000_000_000L)
    }

    private fun learnedAnchor(): Anchor = Anchor(
        wallMillis = truthOffset + 644_000L,
        elapsedNanos = 644L * 1_000_000_000L,
        source = Source.GPS_FIX
    )

    @After
    fun resetAnchor() {
        ClockAnchorStore.reset()
    }

    /**
     * THE CAPTAIN'S SCENARIO: car boots on 2025-05-23 22:08 (1_748_048_880_000L),
     * syncs 44 seconds later. The minute recorded during those 44 seconds
     * (pre-truth) is re-anchored onto truthOffset, old key is deleted, new key
     * is inserted as KNOWN and DIRTY.
     */
    @Test
    fun `captain scenario - close sweeps minute recorded at 2025-05-23 22-08 after sync at 44s`() {
        ClockAnchorStore.reset()
        val bootDefaultWall = 1_748_048_880_000L // 2025-05-23 22:08:00
        ClockAnchorStore.setReferenceOffset(truthOffset)
        ClockAnchorStore.offerServerDate(truthOffset + 44_000L, 44L * 1_000_000_000L)
        assertTrue(ClockAnchorStore.isLearned())

        val dao = RecordingDao()
        val preTruthMinute = minute("s1", bootDefaultWall, elapsedSec = 0L, bootCount = 1L, timeState = "pending")
        dao.rows.add(preTruthMinute)
        val sweeper = ClockBackfillSweeper(dao, currentBootCountProvider = { 1L })

        val changed = sweeper.sweepOnClose("s1", sessionBootCount = 1)

        assertEquals("pre-truth minute must be resolved", 1, changed)
        assertEquals(1, dao.rows.size)
        val resolved = dao.rows[0]
        assertEquals("must resolve to true time by exact arithmetic", truthOffset, resolved.startUtcMillis)
        assertEquals("known", resolved.timeState)
        assertTrue(resolved.dirty)
        assertEquals(setOf(Pair("s1", bootDefaultWall)), dao.deletedKeys.toSet())
    }

    /**
     * Cross-boot isolation: an anchor learned in boot 2 must NEVER be used to
     * re-anchor rows of an earlier boot (boot 1) across a reboot.
     */
    @Test
    fun `an anchor from a different boot never rewrites an earlier boot across reboot`() {
        ClockAnchorStore.reset()
        forceLearned() // in-memory anchor for current boot (boot 2)
        val dao = RecordingDao()
        dao.rows.addAll((0 until 4).map { i -> minute("s1", defaultOffset, i * 60L, bootCount = 1L) })
        // sweeper running in boot 2 closing a recovered session from boot 1
        val sweeper = ClockBackfillSweeper(dao, currentBootCountProvider = { 2L })

        val changed = sweeper.sweepOnClose("s1", sessionBootCount = 1)

        assertEquals("foreign boot session must never be rewritten with current boot anchor", 0, changed)
        assertTrue("no keys may be deleted", dao.deletedKeys.isEmpty())
        assertTrue("no rows may be upserted", dao.upserted.isEmpty())
        for (row in dao.rows) {
            assertEquals("pending", row.timeState)
            assertEquals(defaultOffset, row.startUtcMillis - (row.startElapsedNanos!! / 1_000_000L))
        }
    }

    /** Colliding minutes in sweeper merge by summation without data loss. */
    @Test
    fun `colliding minutes in sweeper merge by summation without data loss`() {
        ClockAnchorStore.reset()
        forceLearned()
        val dao = RecordingDao()
        val row1 = minute("s1", defaultOffset, 0L).copy(tractionWh = 10.0, distanceKm = 1.0)
        val row2 = minute("s1", defaultOffset, 20L).copy(tractionWh = 15.0, distanceKm = 1.5)
        dao.rows.addAll(listOf(row1, row2))
        val sweeper = ClockBackfillSweeper(dao)

        val changed = sweeper.sweepOnClose("s1", 1)

        assertEquals(1, changed)
        assertEquals(1, dao.rows.size)
        val merged = dao.rows[0]
        assertEquals(truthOffset, merged.startUtcMillis)
        assertEquals(25.0, merged.tractionWh, 0.001)
        assertEquals(2.5, merged.distanceKm, 0.001)
        assertEquals("known", merged.timeState)
    }

    /**
     * The close path end to end: boot learned truth at elapsed 644 s, rows of
     * the boot recorded at elapsed 0..600 s wait pending, the close sweeps,
     * and they land on the trusted minutes with the key replaced — not
     * duplicated. The post-644 rows already sit on truth and are untouched.
     */
    @Test
    fun `close with a learned anchor reanchors pending minutes in place`() {
        ClockAnchorStore.reset()
        // Force the learned state directly: the store's sources were proven
        // in ClockAnchorStoreTest; this suite exercises the sweeper, not the
        // corroboration rule.
        forceLearned()
        val dao = RecordingDao()
        val pre = (0 until 10).map { i -> minute("s1", defaultOffset, i * 60L, timeState = "pending") }
        val post = (10 until 16).map { i -> minute("s1", truthOffset, i * 60L, timeState = "known") }
        dao.rows.addAll(pre + post)
        val sweeper = ClockBackfillSweeper(dao)

        val changed = sweeper.sweepOnClose("s1", sessionBootCount = 1)

        assertEquals(10, changed)
        // Each old wrong key was deleted exactly once and replaced on the
        // trusted minute: total rows still 16, no duplication.
        assertEquals(16, dao.rows.size)
        for (i in 0 until 10) {
            val row = dao.rows.first { it.startElapsedNanos == (i * 60L) * 1_000_000_000L }
            assertEquals(truthOffset + i * 60_000L, row.startUtcMillis)
            assertEquals("known", row.timeState)
            assertTrue(row.dirty)
        }
        // The deleted keys were the 10 wrong keys, not the good ones.
        assertEquals(
            pre.map { Pair(it.sessionId, it.startUtcMillis) }.toSet(),
            dao.deletedKeys.toSet()
        )
    }

    /** Sanity: after the sweep a second close changes nothing (idempotent). */
    @Test
    fun `a second close does not rewrite anything`() {
        ClockAnchorStore.reset()
        forceLearned()
        val dao = RecordingDao()
        dao.rows.addAll((0 until 10).map { i -> minute("s1", defaultOffset, i * 60L) })
        val sweeper = ClockBackfillSweeper(dao)
        sweeper.sweepOnClose("s1", 1)
        val snapshot = dao.rows.toList()

        assertEquals(0, sweeper.sweepOnClose("s1", 1))
        assertEquals(snapshot, dao.rows)
    }

    /**
     * The truth never arrives: the close writes NOTHING and deletes
     * NOTHING. The rows stay pending for a later close — and the UNCOR-
     * RECTABLE label exists for the case the boot itself ends without
     * truth, where marking preserves instead of erasing (the captain's
     * no-silent-loss rule).
     */
    @Test
    fun `close without truth preserves pending rows untouched`() {
        ClockAnchorStore.reset()
        val dao = RecordingDao()
        dao.rows.addAll((0 until 4).map { i -> minute("s1", defaultOffset, i * 60L) })
        val sweeper = ClockBackfillSweeper(dao)

        assertEquals(0, sweeper.sweepOnClose("s1", 1))

        assertEquals(4, dao.rows.size)
        assertTrue(dao.deletedKeys.isEmpty())
        assertTrue(dao.upserted.isEmpty())
        for (row in dao.rows) {
            assertEquals("pending", row.timeState)
        }

        // When the boot closes with no truth anywhere, the label is applied
        // in place: same key, same sums, state names the loss.
        val marked = ClockUnlockBackfillEngine.markUncorrectable(dao.rows)
        for (row in marked) {
            assertEquals("uncorrectable", row.timeState)
            assertEquals(60_000L, row.widthMillis)
        }
        assertNull(marked[0].startSoc)
    }

    /**
     * A session without a boot count (legacy row) is not swept: no boot, no
     * axis, no arithmetic.
     */
    @Test
    fun `a session without a boot count is not swept`() {
        ClockAnchorStore.reset()
        forceLearned()
        val dao = RecordingDao()

        assertEquals(0, ClockBackfillSweeper(dao).sweepOnClose("s1", null))
    }

    // ---- T9: the corrected re-upload queue -----------------------------------

    @Test
    fun `the sweep queues the exact old key and marks the corrected row`() {
        ClockAnchorStore.reset()
        forceLearned()
        val dao = RecordingDao()
        val replacedDao = RecordingReplacedKeyDao()
        val wrong = minute("s1", defaultOffset, elapsedSec = 0L)
        dao.rows.add(wrong)

        val sweeper = ClockBackfillSweeper(
            dao,
            replacedKeyDao = replacedDao,
            currentBootCountProvider = { 1L }
        )
        sweeper.sweepOnClose("s1", 1)

        assertEquals(
            listOf(wrong.startUtcMillis),
            replacedDao.rows.map { it.startUtcMillis }
        )
        assertEquals(truthOffset, replacedDao.rows.single().replacedByUtcMillis)
        assertEquals(wrong.startUtcMillis, dao.rows.single().correctedFromUtcMillis)
    }

    @Test
    fun `a second sweep queues nothing new - the correction is idempotent`() {
        ClockAnchorStore.reset()
        forceLearned()
        val dao = RecordingDao()
        val replacedDao = RecordingReplacedKeyDao()
        dao.rows.add(minute("s1", defaultOffset, elapsedSec = 0L))

        val sweeper = ClockBackfillSweeper(
            dao,
            replacedKeyDao = replacedDao,
            currentBootCountProvider = { 1L }
        )
        sweeper.sweepOnClose("s1", 1)
        val queuedBefore = replacedDao.rows.toList()

        assertEquals(0, sweeper.sweepOnClose("s1", 1))

        // The corrected row is KNOWN on the trusted minute: the second pass
        // rewrites nothing and re-queues nothing — the second run must never
        // delete the corrected row (that is the idempotency guard).
        assertEquals(queuedBefore, replacedDao.rows)
        assertEquals(truthOffset, dao.rows.single().startUtcMillis)
        assertEquals(1, dao.rows.size)
    }
    // ---- G1: anchor learned after close, no later close -----------------------

    private fun closedPendingSession(
        sessionId: String = "s1",
        bootCount: Int = 1,
        startElapsedSec: Long = 88L,
        endElapsedSec: Long = 587L
    ): SessionEntity = SessionEntity(
        id = sessionId,
        vehicleId = "v",
        kind = "TRIP",
        status = "ENDED",
        startedAtUtcMillis = defaultOffset + startElapsedSec * 1_000L,
        startedAtElapsedNanos = startElapsedSec * 1_000_000_000L,
        startedAtBootCount = bootCount,
        endedAtUtcMillis = defaultOffset + endElapsedSec * 1_000L,
        endedAtElapsedNanos = endElapsedSec * 1_000_000_000L,
        endedAtBootCount = bootCount,
        timeState = "pending",
        dirty = false
    )

    private fun g1Rig(currentBoot: Long = 1L): Triple<RecordingDao, FakeSessionDao, ClockBackfillSweeper> {
        val intervals = RecordingDao()
        val sessions = FakeSessionDao()
        sessions.add(closedPendingSession())
        intervals.rows.addAll((0 until 10).map { i -> minute("s1", defaultOffset, i * 60L) })
        val sweeper = ClockBackfillSweeper(
            intervals,
            sessionDao = sessions,
            currentBootCountProvider = { currentBoot }
        )
        return Triple(intervals, sessions, sweeper)
    }

    private fun learnTruth() {
        ClockAnchorStore.setReferenceOffset(truthOffset)
        ClockAnchorStore.offerServerDate(truthOffset + 700_000L, 700L * 1_000_000_000L)
        assertTrue(ClockAnchorStore.isLearned())
    }

    /**
     * THE INCIDENT: boot on birth clock, trip closes with no truth
     * (`sweepOnClose` = 0, session `pending`), truth lands minutes later,
     * and no later close ever happens. Today the minutes stay `pending`;
     * G1 corrects them by arithmetic and promotes the session to `known`.
     */
    @Test
    fun `anchor learned after a truthless close sweeps the boot with no later close`() {
        ClockAnchorStore.reset()
        val (dao, sessions, sweeper) = g1Rig()

        assertEquals(0, sweeper.sweepOnClose("s1", 1))
        assertEquals("pending", sessions.findById("s1")?.timeState)

        learnTruth()

        assertEquals(10, sweeper.sweepBoot(1L))

        for (i in 0 until 10) {
            val row = dao.rows.first { it.startElapsedNanos == (i * 60L) * 1_000_000_000L }
            assertEquals(truthOffset + i * 60_000L, row.startUtcMillis)
            assertEquals("known", row.timeState)
            assertTrue(row.dirty)
        }
        val session = sessions.findById("s1")!!
        assertEquals("known", session.timeState)
        assertEquals(truthOffset + 88_000L, session.startedAtUtcMillis)
        assertEquals(truthOffset + 587_000L, session.endedAtUtcMillis)
        assertTrue(session.dirty)
    }

    /** A later close of the same boot with truth keeps resolving. */
    @Test
    fun `a later close of the same boot with truth still resolves`() {
        ClockAnchorStore.reset()
        val (dao, sessions, sweeper) = g1Rig()

        assertEquals(0, sweeper.sweepOnClose("s1", 1))
        learnTruth()

        assertEquals(10, sweeper.sweepOnClose("s1", 1))

        assertEquals(10, dao.rows.count { it.timeState == "known" })
        val session = sessions.findById("s1")!!
        assertEquals("known", session.timeState)
        assertEquals(truthOffset + 88_000L, session.startedAtUtcMillis)
        assertEquals(truthOffset + 587_000L, session.endedAtUtcMillis)
    }

    /** A second anchor sweep rewrites and re-queues nothing. */
    @Test
    fun `a second anchor sweep changes nothing`() {
        ClockAnchorStore.reset()
        val replacedDao = RecordingReplacedKeyDao()
        val intervals = RecordingDao()
        val sessions = FakeSessionDao()
        sessions.add(closedPendingSession())
        intervals.rows.addAll((0 until 10).map { i -> minute("s1", defaultOffset, i * 60L) })
        val sweeper = ClockBackfillSweeper(
            intervals,
            replacedKeyDao = replacedDao,
            sessionDao = sessions,
            currentBootCountProvider = { 1L }
        )
        learnTruth()

        assertEquals(10, sweeper.sweepBoot(1L))
        val rowsAfter = intervals.rows.toList()
        val queuedAfter = replacedDao.rows.toList()
        val sessionAfter = sessions.findById("s1")
        assertEquals(0, sweeper.sweepBoot(1L))
        assertEquals(rowsAfter, intervals.rows)
        assertEquals(queuedAfter, replacedDao.rows)
        assertEquals(sessionAfter, sessions.findById("s1"))
    }

    /** After a reboot the old boot stays refused, even with truth. */
    @Test
    fun `anchor sweep refuses an old boot after reboot`() {
        ClockAnchorStore.reset()
        val (dao, sessions, sweeper) = g1Rig(currentBoot = 2L)
        learnTruth()

        assertEquals(0, sweeper.sweepBoot(1L))

        assertTrue(dao.deletedKeys.isEmpty())
        assertTrue(dao.upserted.isEmpty())
        assertEquals("pending", sessions.findById("s1")?.timeState)
        for (row in dao.rows) {
            assertEquals("pending", row.timeState)
        }
    }

    /** A learned anchor with no pendings writes nothing. */
    @Test
    fun `learned anchor with no pendings sweeps nothing`() {
        ClockAnchorStore.reset()
        val sweeper = ClockBackfillSweeper(
            RecordingDao(),
            sessionDao = FakeSessionDao(),
            currentBootCountProvider = { 1L }
        )
        learnTruth()

        assertEquals(0, sweeper.sweepBoot(1L))
    }

    /**
     * The anchor sweep and a session close serialized on the same single
     * writer never duplicate nor lose a row: one wins, the other is a no-op.
     */
    @Test
    fun `concurrent anchor sweep and close neither duplicate nor lose rows`() {
        ClockAnchorStore.reset()
        val (dao, sessions, sweeper) = g1Rig()
        learnTruth()
        val writer = ObservedWriteExecutor("g1-race")
        val results = java.util.concurrent.ConcurrentLinkedQueue<Int>()
        val t1 = thread {
            writer.executeWrite("anchor_sweep") { results.add(sweeper.sweepBoot(1L)) }
        }
        val t2 = thread {
            writer.executeWrite("session_close") { results.add(sweeper.sweepOnClose("s1", 1)) }
        }
        t1.join()
        t2.join()
        writer.awaitIdle()

        assertEquals(10, results.sum())
        assertEquals(10, dao.rows.size)
        assertEquals(10, dao.rows.map { Pair(it.sessionId, it.startUtcMillis) }.toSet().size)
        assertEquals(10, dao.deletedKeys.toSet().size)
        val session = sessions.findById("s1")!!
        assertEquals("known", session.timeState)
        assertEquals(truthOffset + 88_000L, session.startedAtUtcMillis)
    }
}
