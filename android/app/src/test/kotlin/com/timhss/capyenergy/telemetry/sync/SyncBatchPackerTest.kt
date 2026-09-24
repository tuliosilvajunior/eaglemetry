package com.timhss.capyenergy.telemetry.sync

import com.timhss.capyenergy.telemetry.VehicleIdAliasStore
import com.timhss.capyenergy.telemetry.db.BatteryCycleDao
import com.timhss.capyenergy.telemetry.db.BatteryCycleEntity
import com.timhss.capyenergy.telemetry.db.IntervalDao
import com.timhss.capyenergy.telemetry.db.IntervalEntity
import com.timhss.capyenergy.telemetry.db.SessionDao
import com.timhss.capyenergy.telemetry.db.SessionEntity
import com.timhss.capyenergy.telemetry.db.TelemetryEventDao
import com.timhss.capyenergy.telemetry.db.TelemetryEventEntity
import com.timhss.capyenergy.telemetry.db.TelemetryFrameDao
import com.timhss.capyenergy.telemetry.db.TelemetryFrameEntity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

private class InMemoryAliasStore(private val aliases: Map<String, String>) : VehicleIdAliasStore {
    override fun record(aliasId: String, canonicalId: String, atUtcMillis: Long) = Unit

    override fun canonicalFor(aliasId: String): String? = aliases[aliasId]
}

class FakeSessionDao : SessionDao {
    private val sessions = mutableListOf<SessionEntity>()

    fun add(session: SessionEntity) {
        sessions.add(session)
    }

    override fun upsert(session: SessionEntity) {
        val index = sessions.indexOfFirst { it.id == session.id }
        if (index >= 0) sessions[index] = session else sessions.add(session)
    }

    override fun upsertAll(sessions: List<SessionEntity>) {
        sessions.forEach { upsert(it) }
    }

    override fun findById(id: String): SessionEntity? = sessions.find { it.id == id }

    override fun listSessionsFiltered(
        kind: String?,
        status: String?,
        fromUtcMillis: Long?,
        toUtcMillis: Long?,
        limit: Int,
        offset: Int
    ): List<SessionEntity> =
        sessions.asSequence()
            .filter { kind == null || it.kind == kind }
            .filter { status == null || it.status == status }
            .filter { fromUtcMillis == null || it.startedAtUtcMillis >= fromUtcMillis }
            .filter { toUtcMillis == null || it.startedAtUtcMillis <= toUtcMillis }
            .sortedByDescending { it.startedAtUtcMillis }
            .drop(offset)
            .take(limit)
            .toList()

    override fun countSessionsFiltered(
        kind: String?,
        status: String?,
        fromUtcMillis: Long?,
        toUtcMillis: Long?
    ): Long =
        sessions.asSequence()
            .filter { kind == null || it.kind == kind }
            .filter { status == null || it.status == status }
            .filter { fromUtcMillis == null || it.startedAtUtcMillis >= fromUtcMillis }
            .filter { toUtcMillis == null || it.startedAtUtcMillis <= toUtcMillis }
            .count()
            .toLong()
    override fun listSessionsSatisfyingAccount(
        accountId: String?,
        kind: String?,
        status: String?,
        fromUtcMillis: Long?,
        toUtcMillis: Long?,
        limit: Int,
        offset: Int
    ): List<SessionEntity> = emptyList()

    override fun countSessionsSatisfyingAccount(
        accountId: String?,
        kind: String?,
        status: String?,
        fromUtcMillis: Long?,
        toUtcMillis: Long?
    ): Long = 0L

    override fun inWindow(kind: String, startUtcMillis: Long, endUtcMillis: Long): List<SessionEntity> =
        sessions.filter { it.kind == kind && it.timeState != "pending" && it.startedAtUtcMillis in startUtcMillis..endUtcMillis }

    override fun latest(kind: String, limit: Int): List<SessionEntity> =
        sessions.filter { it.kind == kind }.sortedByDescending { it.startedAtUtcMillis }.take(limit)

    override fun latestAll(limit: Int): List<SessionEntity> =
        sessions.sortedByDescending { it.startedAtUtcMillis }.take(limit)

    override fun latestOpen(kind: String): SessionEntity? =
        sessions.find { it.kind == kind && it.endedAtUtcMillis == null }
    override fun closeOpenSessions(kind: String, endedAtUtcMillis: Long, endedAtElapsedNanos: Long, reason: String, updatedAtUtcMillis: Long): Int = 0

    override fun byIds(ids: List<String>): List<SessionEntity> = sessions.filter { it.id in ids }

    override fun updatePlugType(id: String, plugType: Int, updatedAtUtcMillis: Long): Int = 0
    override fun findByKind(kind: String): List<SessionEntity> =
        sessions.filter { it.kind == kind }.sortedByDescending { it.startedAtUtcMillis }

    override fun inWindowAll(startUtcMillis: Long, endUtcMillis: Long): List<SessionEntity> =
        sessions.filter {
            it.status != "FINALIZATION_PENDING" &&
                it.timeState != "pending" &&
                it.startedAtUtcMillis < endUtcMillis &&
                (it.endedAtUtcMillis ?: it.updatedAtUtcMillis) > startUtcMillis
        }.sortedByDescending { it.startedAtUtcMillis }

    override fun rangeWindow(startUtcMillis: Long, endUtcMillis: Long): List<SessionEntity> =
        sessions.filter {
            it.kind == "TRIP" &&
                it.status != "FINALIZATION_PENDING" &&
                it.timeState != "pending" &&
                it.endedAtUtcMillis != null &&
                it.endedAtUtcMillis >= startUtcMillis &&
                it.endedAtUtcMillis <= endUtcMillis
        }.sortedByDescending { it.endedAtUtcMillis }

    override fun count(): Long = sessions.size.toLong()
    override fun countByKind(kind: String): Long = sessions.count { it.kind == kind }.toLong()
    override fun countListed(kind: String): Long = sessions.count { it.kind == kind && it.status != "FINALIZATION_PENDING" }.toLong()
    override fun countListedAll(): Long = sessions.count { it.status != "FINALIZATION_PENDING" }.toLong()
    override fun pendingFinalization(): List<SessionEntity> = emptyList()
    override fun closedFrom(fromUtcMillis: Long): List<SessionEntity> = sessions.filter { it.timeState != "pending" && it.startedAtUtcMillis >= fromUtcMillis && it.endedAtUtcMillis != null }
    override fun closedFromAll(fromUtcMillis: Long): List<SessionEntity> = sessions.filter { it.timeState != "pending" && it.startedAtUtcMillis >= fromUtcMillis && it.endedAtUtcMillis != null }
    override fun since(startUtcMillis: Long): List<SessionEntity> = sessions.filter { it.startedAtUtcMillis >= startUtcMillis }
    override fun unfinalizedClosed(): List<SessionEntity> = emptyList()
    override fun oldestStartUtcMillis(kind: String): Long? = sessions.filter { it.kind == kind }.minOfOrNull { it.startedAtUtcMillis }
    override fun oldestStartUtcMillisAll(): Long? = sessions.minOfOrNull { it.startedAtUtcMillis }
    override fun markNoLongerReducible(id: String, updatedAtUtcMillis: Long): Int = 0
    override fun sessionsEligibleForNoLongerReducible(): List<String> = emptyList()

    override fun syncPendingCount(afterStartedAtUtcMillis: Long, afterId: String): Long =
        syncPage(afterStartedAtUtcMillis, afterId, Int.MAX_VALUE).size.toLong()

    override fun syncPage(afterStartedAtUtcMillis: Long, afterId: String, limit: Int): List<SessionEntity> {
        return sessions
            .filter { it.endedAtUtcMillis != null && it.status != "FINALIZATION_PENDING" && it.kind != "CONTINUOUS" }
            .filter {
                it.startedAtUtcMillis > afterStartedAtUtcMillis ||
                    (it.startedAtUtcMillis == afterStartedAtUtcMillis && it.id > afterId)
            }
            .sortedWith(compareBy({ it.startedAtUtcMillis }, { it.id }))
            .take(limit)
    }

    override fun deleteById(id: String): Int = if (sessions.removeIf { it.id == id }) 1 else 0
    override fun deleteByIds(ids: List<String>): Int = sessions.count { it.id in ids }.also { sessions.removeIf { it.id in ids } }
    override fun deleteOlderThan(cutoffUtcMillis: Long): Int = 0
    override fun deleteOlderThanConfirmed(cutoffUtcMillis: Long, floorStartedAtUtcMillis: Long): Int = 0
    override fun deleteContinuousOlderThan(cutoffUtcMillis: Long): Int = 0
    override fun deleteContinuousOlderThanIgnoringDirty(cutoffUtcMillis: Long): Int = 0
    override fun deleteContinuousOlderThanConfirmed(cutoffUtcMillis: Long, floorStartedAtUtcMillis: Long): Int = 0

    override fun dirtySessions(limit: Int): List<SessionEntity> = sessions.filter { it.dirty }.take(limit)
    override fun dirtySessionCount(): Long = sessions.count { it.dirty }.toLong()
    override fun pendingSessionCount(): Long = sessions.count { it.dirty && it.timeState == "pending" }.toLong()
    override fun clearDirty(ids: List<String>): Int {
        var cleared = 0
        for (i in sessions.indices) {
            val s = sessions[i]
            if (s.id in ids && s.dirty) {
                sessions[i] = s.copy(dirty = false)
                cleared++
            }
        }
        return cleared
    }
    override fun markAllDirty(): Int {
        var marked = 0
        for (i in sessions.indices) {
            if (!sessions[i].dirty) { sessions[i] = sessions[i].copy(dirty = true); marked++ }
        }
        return marked
    }
    override fun promoteEndedPendingToUncorrectable(): Int = 0
    override fun distinctVehicleIds(): List<String> =
        sessions.map { it.vehicleId }.filter { it.isNotBlank() && it != "unassigned" }.distinct()
    override fun markAliasedSessionsDirty(): Int = 0
}

class FakeIntervalDao : IntervalDao {
    private val intervals = mutableListOf<IntervalEntity>()

    /**
     * Stands in for the real DAO's `JOIN session` clause. Set from the test to
     * the session fake's lookup so `syncPage` can exclude `CONTINUOUS` the same
     * way the real query does.
     */
    var sessionKindOf: (String) -> String? = { null }

    fun add(interval: IntervalEntity) {
        intervals.add(interval)
    }

    override fun upsertAll(intervals: List<IntervalEntity>) {
        for (interval in intervals) {
            val index = this.intervals.indexOfFirst {
                it.sessionId == interval.sessionId && it.startUtcMillis == interval.startUtcMillis
            }
            if (index >= 0) this.intervals[index] = interval else this.intervals.add(interval)
        }
    }

    override fun forSession(sessionId: String): List<IntervalEntity> =
        intervals.filter { it.sessionId == sessionId }.sortedBy { it.startUtcMillis }

    override fun countForSession(sessionId: String): Long =
        intervals.count { it.sessionId == sessionId }.toLong()

    override fun sessionsWithBuckets(sessionIds: List<String>): List<String> =
        intervals.map { it.sessionId }.distinct().filter { it in sessionIds }

    override fun forSessionsInWindow(
        sessionIds: List<String>,
        startUtcMillis: Long,
        endUtcMillis: Long
    ): List<IntervalEntity> =
        intervals.filter {
            it.sessionId in sessionIds &&
                it.startUtcMillis >= startUtcMillis &&
                it.startUtcMillis < endUtcMillis
        }.sortedBy { it.startUtcMillis }

    override fun deleteBySessionIds(sessionIds: List<String>): Int {
        val count = intervals.count { it.sessionId in sessionIds }
        intervals.removeIf { it.sessionId in sessionIds }
        return count
    }

    override fun findById(sessionId: String, startUtcMillis: Long): IntervalEntity? =
        intervals.find { it.sessionId == sessionId && it.startUtcMillis == startUtcMillis }

    override fun syncPendingCount(afterStartUtcMillis: Long, afterSessionId: String): Long =
        syncPage(afterStartUtcMillis, afterSessionId, Int.MAX_VALUE).size.toLong()

    override fun syncPage(afterStartUtcMillis: Long, afterSessionId: String, limit: Int): List<IntervalEntity> {
        return intervals
            .filter { sessionKindOf(it.sessionId) != "CONTINUOUS" }
            .filter {
                it.startUtcMillis > afterStartUtcMillis ||
                    (it.startUtcMillis == afterStartUtcMillis && it.sessionId > afterSessionId)
            }
            .sortedWith(compareBy({ it.startUtcMillis }, { it.sessionId }))
            .take(limit)
    }

    override fun count(): Long = intervals.size.toLong()
    override fun deleteOrphans(): Int = 0
    override fun deleteOrphansChunk(limit: Int) = 0

    override fun dirtyIntervals(limit: Int): List<IntervalEntity> = intervals.filter { it.dirty }.take(limit)
    override fun dirtyIntervalCount(): Long = intervals.count { it.dirty }.toLong()
    override fun pendingIntervalCount(): Long = intervals.count { it.dirty && it.timeState == "pending" }.toLong()
    override fun clearDirty(sessionId: String, startUtcMillis: Long): Int {
        val idx = intervals.indexOfFirst { it.sessionId == sessionId && it.startUtcMillis == startUtcMillis && it.dirty }
        return if (idx >= 0) {
            intervals[idx] = intervals[idx].copy(dirty = false)
            1
        } else 0
    }
    override fun clearDirtyByKeys(keys: List<String>): Int {
        var cleared = 0
        for (i in intervals.indices) {
            val it = intervals[i]
            val key = "${it.sessionId}:${it.startUtcMillis}"
            if (key in keys && it.dirty) {
                intervals[i] = it.copy(dirty = false)
                cleared++
            }
        }
        return cleared
    }
    override fun markAllDirty(): Int {
        var marked = 0
        for (i in intervals.indices) {
            if (!intervals[i].dirty) { intervals[i] = intervals[i].copy(dirty = true); marked++ }
        }
        return marked
    }
    override fun promoteEndedPendingToUncorrectable(): Int = 0

        override fun allPaired(): List<IntervalEntity> = emptyList()
override fun pendingsForBoot(bootCount: Long): List<IntervalEntity> = emptyList()
    override fun forBoot(bootCount: Long): List<IntervalEntity> = emptyList()
    override fun deleteKey(sessionId: String, startUtcMillis: Long): Int = 0
}

class FakeTelemetryFrameDao : TelemetryFrameDao {
    private val frames = mutableListOf<TelemetryFrameEntity>()

    fun add(frame: TelemetryFrameEntity) {
        frames.add(frame)
    }

    override fun insert(frame: TelemetryFrameEntity) { frames.add(frame) }
    override fun insertAll(frames: List<TelemetryFrameEntity>) { this.frames.addAll(frames) }
    override fun latest(limit: Int): List<TelemetryFrameEntity> = frames.takeLast(limit)
    override fun latestForSession(sessionId: String, limit: Int): List<TelemetryFrameEntity> =
        frames.filter { it.sessionId == sessionId }.take(limit)
    override fun lastForSession(sessionId: String): TelemetryFrameEntity? =
        frames.filter { it.sessionId == sessionId }.lastOrNull()
    override fun count(): Long = frames.size.toLong()
    override fun countForSession(sessionId: String): Long = frames.count { it.sessionId == sessionId }.toLong()
    override fun reassignSessions(sourceSessionIds: List<String>, targetSessionId: String): Int = 0

    override fun aggregatePage(
        sessionId: String,
        afterElapsedNanos: Long,
        afterId: Long,
        limit: Int
    ): List<com.timhss.capyenergy.telemetry.db.SessionAggregateSampleRow> = emptyList()

    override fun aggregatePageByInsertion(
        sessionId: String,
        afterId: Long,
        limit: Int
    ): List<com.timhss.capyenergy.telemetry.db.SessionAggregateSampleRow> = emptyList()

    override fun sessionFrameBounds(sessionId: String): com.timhss.capyenergy.telemetry.db.SessionFrameBounds =
        com.timhss.capyenergy.telemetry.db.SessionFrameBounds(0L, null, null)

    override fun sessionWallBounds(sessionId: String): com.timhss.capyenergy.telemetry.db.SessionWallBounds =
        com.timhss.capyenergy.telemetry.db.SessionWallBounds(0L, null, null)

    override fun tripDetailPage(
        sessionId: String,
        afterElapsedNanos: Long,
        afterId: Long,
        limit: Int
    ): List<com.timhss.capyenergy.telemetry.db.TripDetailFrameRow> = emptyList()

    override fun tripDetailPageByInsertion(
        sessionId: String,
        afterId: Long,
        limit: Int
    ): List<com.timhss.capyenergy.telemetry.db.TripDetailFrameRow> = emptyList()

    override fun chargeDetailPage(
        sessionId: String,
        afterElapsedNanos: Long,
        afterId: Long,
        limit: Int
    ): List<com.timhss.capyenergy.telemetry.db.ChargeDetailFrameRow> = emptyList()

    override fun chargeDetailPageByInsertion(
        sessionId: String,
        afterId: Long,
        limit: Int
    ): List<com.timhss.capyenergy.telemetry.db.ChargeDetailFrameRow> = emptyList()

    override fun maxId(): Long? = frames.maxOfOrNull { it.id }
    override fun hasGps(maxId: Long): Boolean = false
    override fun sessionsEligibleForNoLongerReducible(cutoffUtcMillis: Long, limit: Int): List<String> = emptyList()
    override fun sessionMedianClockOffsetMillis(sessionId: String): Long? = null

    override fun framesSyncPendingCount(sessionId: String, afterWallTimeUtcMillis: Long, afterId: Long): Long =
        framesSyncPage(sessionId, afterWallTimeUtcMillis, afterId, Int.MAX_VALUE).size.toLong()

    override fun framesSyncPage(sessionId: String, afterWallTimeUtcMillis: Long, afterId: Long, limit: Int): List<TelemetryFrameEntity> {
        return frames
            .filter { it.sessionId == sessionId }
            .filter {
                it.wallTimeUtcMillis > afterWallTimeUtcMillis ||
                    (it.wallTimeUtcMillis == afterWallTimeUtcMillis && it.id > afterId)
            }
            .sortedWith(compareBy({ it.wallTimeUtcMillis }, { it.id }))
            .take(limit)
    }

    override fun countOlderThan(cutoffUtcMillis: Long): Long = 0L
    override fun deleteForSession(sessionId: String): Int {
        val count = frames.count { it.sessionId == sessionId }
        frames.removeIf { it.sessionId == sessionId }
        return count
    }
    override fun deleteOrphanSessionFramesChunk(limit: Int): Int = 0
    override fun deleteOlderThanChunk(cutoffUtcMillis: Long, limit: Int): Int = 0
    override fun sessionsBlockingRetention(cutoffUtcMillis: Long, limit: Int): List<String> = emptyList()
}

class FakeBatteryCycleDao : BatteryCycleDao {
    private val cycles = mutableListOf<BatteryCycleEntity>()

    fun add(cycle: BatteryCycleEntity) {
        cycles.add(cycle)
    }

    override fun upsertAll(cycles: List<BatteryCycleEntity>) {
        this.cycles.addAll(cycles)
    }

    override fun latest(limit: Int): List<BatteryCycleEntity> = emptyList()
    override fun newest(): BatteryCycleEntity? = null
    override fun open(): BatteryCycleEntity? = null
    override fun newestRebuildable(): BatteryCycleEntity? = null
    override fun maxOrdinal(): Long? = cycles.maxOfOrNull { it.ordinal }
    override fun oldestRebuildableEndingAtOrAfter(utcMillis: Long): BatteryCycleEntity? = null
    override fun newestClosedEndingBefore(utcMillis: Long): BatteryCycleEntity? = null
    override fun deleteFrom(ordinal: Long) {}
    override fun freezeUpTo(ordinal: Long, frozenAtUtcMillis: Long) {}
    override fun count(): Long = cycles.size.toLong()
    override fun findById(ordinal: Long): BatteryCycleEntity? = cycles.find { it.ordinal == ordinal }

    override fun syncPendingCount(afterOrdinal: Long): Long =
        syncPage(afterOrdinal, Int.MAX_VALUE).size.toLong()

    override fun syncPage(afterOrdinal: Long, limit: Int): List<BatteryCycleEntity> {
        return cycles
            .filter { it.ordinal > afterOrdinal && !it.isOpen }
            .sortedBy { it.ordinal }
            .take(limit)
    }

    override fun dirtyCycles(limit: Int): List<BatteryCycleEntity> = cycles.filter { it.dirty }.take(limit)
    override fun dirtyCycleCount(): Long = cycles.count { it.dirty }.toLong()
    override fun clearDirty(ordinals: List<Long>): Int {
        var cleared = 0
        for (i in cycles.indices) {
            val c = cycles[i]
            if (c.ordinal in ordinals && c.dirty) {
                cycles[i] = c.copy(dirty = false)
                cleared++
            }
        }
        return cleared
    }
    override fun markAllDirty(): Int {
        var marked = 0
        for (i in cycles.indices) {
            if (!cycles[i].dirty) { cycles[i] = cycles[i].copy(dirty = true); marked++ }
        }
        return marked
    }

}

class FakeTelemetryEventDao : TelemetryEventDao {
    private val events = mutableListOf<TelemetryEventEntity>()

    fun add(event: TelemetryEventEntity) {
        events.add(event)
    }

    override fun insert(event: TelemetryEventEntity) { events.add(event) }
    override fun latest(limit: Int): List<TelemetryEventEntity> = events.takeLast(limit)
    override fun forSession(sessionId: String): List<TelemetryEventEntity> =
        events.filter { it.sessionId == sessionId }
    override fun orphansInWindow(fromUtcMillis: Long, toUtcMillis: Long): List<TelemetryEventEntity> =
        events.filter {
            it.sessionId == null && it.occurredAtUtcMillis in fromUtcMillis..toUtcMillis
        }
    override fun backStampSession(sessionId: String, eventIds: List<Long>): Int = 0
    override fun findById(id: Long): TelemetryEventEntity? = events.find { it.id == id }
    override fun byTypeInWindow(type: String, fromUtcMillis: Long, toUtcMillis: Long): List<TelemetryEventEntity> =
        events.filter { it.type == type && it.occurredAtUtcMillis in fromUtcMillis..toUtcMillis }
    override fun count(): Long = events.size.toLong()
    override fun maxId(): Long? = events.maxOfOrNull { it.id }
    override fun syncPage(afterId: Long, limit: Int): List<TelemetryEventEntity> =
        events.filter { it.id > afterId }.sortedBy { it.id }.take(limit)
    override fun syncPendingCount(afterId: Long): Long =
        syncPage(afterId, Int.MAX_VALUE).size.toLong()
    override fun countOlderThan(cutoffUtcMillis: Long): Long = 0L
    override fun deleteOlderThanChunk(cutoffUtcMillis: Long, limit: Int): Int = 0
    override fun deleteOlderThanConfirmedChunk(cutoffUtcMillis: Long, floorId: Long, limit: Int): Int = 0
    override fun deleteOrphanSessionEventsChunk(limit: Int): Int = 0

    override fun dirtyEvents(limit: Int): List<TelemetryEventEntity> = events.filter { it.dirty }.take(limit)
    override fun dirtyEventCount(): Long = events.count { it.dirty }.toLong()
    override fun clearDirty(ids: List<Long>): Int {
        var cleared = 0
        for (i in events.indices) {
            val e = events[i]
            if (e.id in ids && e.dirty) {
                events[i] = e.copy(dirty = false)
                cleared++
            }
        }
        return cleared
    }
    override fun markAllDirty(): Int {
        var marked = 0
        for (i in events.indices) {
            if (!events[i].dirty) { events[i] = events[i].copy(dirty = true); marked++ }
        }
        return marked
    }
}

class SyncBatchPackerTest {

    private lateinit var sessionDao: FakeSessionDao
    private lateinit var intervalDao: FakeIntervalDao
    private lateinit var telemetryFrameDao: FakeTelemetryFrameDao
    private lateinit var batteryCycleDao: FakeBatteryCycleDao
    private lateinit var telemetryEventDao: FakeTelemetryEventDao
    private lateinit var packer: SyncBatchPacker

    private val fixedNow = 1700000000000L

    @Before
    fun setUp() {
        sessionDao = FakeSessionDao()
        intervalDao = FakeIntervalDao().apply {
            sessionKindOf = { id -> sessionDao.findById(id)?.kind }
        }
        telemetryFrameDao = FakeTelemetryFrameDao()
        batteryCycleDao = FakeBatteryCycleDao()
        telemetryEventDao = FakeTelemetryEventDao()

        packer = SyncBatchPacker(
            sessionDao = sessionDao,
            intervalDao = intervalDao,
            telemetryFrameDao = telemetryFrameDao,
            batteryCycleDao = batteryCycleDao,
            telemetryEventDao = telemetryEventDao,
            eventsStreamEnabled = true,
            nowUtcMillisProvider = { fixedNow }
        )
    }

    @Test
    fun `packBatch throws on unknown stream name`() {
        assertThrows(IllegalArgumentException::class.java) {
            packer.packBatch("unknownStream")
        }
    }

    @Test
    fun `remaining counts what is left after the page, and is recounted per page`() {
        sessionDao.add(createSession("s-1", startedAt = 1000L, endedAt = 2000L))
        sessionDao.add(createSession("s-2", startedAt = 3000L, endedAt = 4000L))
        sessionDao.add(createSession("s-3", startedAt = 5000L, endedAt = 6000L))
        sessionDao.add(createSession("s-4", startedAt = 7000L, endedAt = 8000L))

        val first = packer.packBatch(SyncStreamType.SESSIONS.wireName, after = null, limit = 2)
        assertEquals(2, first.remaining)

        sessionDao.add(createSession("s-5", startedAt = 9000L, endedAt = 10000L))

        val second = packer.packBatch(SyncStreamType.SESSIONS.wireName, after = first.nextCursor, limit = 2)
        assertEquals(1, second.remaining)
        assertTrue(second.hasMore)

        val third = packer.packBatch(SyncStreamType.SESSIONS.wireName, after = second.nextCursor, limit = 2)
        assertEquals(0, third.remaining)
        assertFalse(third.hasMore)
    }

    @Test
    fun `an empty page reports what is still pending at the cursor it was given`() {
        val batch = packer.packBatch(SyncStreamType.SESSIONS.wireName, after = null, limit = 2)
        assertEquals(0, batch.items.size)
        assertEquals(0, batch.remaining)
    }

    @Test
    fun `packBatch packages sessions with closed sessions, nextCursor and hasMore`() {
        sessionDao.add(createSession("s-1", startedAt = 1000L, endedAt = 2000L))
        sessionDao.add(createSession("s-2", startedAt = 3000L, endedAt = 4000L))
        sessionDao.add(createSession("s-3", startedAt = 5000L, endedAt = 6000L))

        val batch = packer.packBatch(SyncStreamType.SESSIONS.wireName, after = null, limit = 2)

        assertEquals(2, batch.protocolVersion)
        assertEquals("sessions", batch.streamType)
        assertEquals(2, batch.items.size)
        assertEquals("s-1", batch.items[0]["id"])
        assertEquals("s-2", batch.items[1]["id"])
        assertEquals("s-2", batch.nextCursor)
        assertTrue(batch.hasMore)
        assertEquals(fixedNow, batch.generatedAtUtcMillis)
    }

    @Test
    fun `packBatch resolves retired vehicle ids through the alias store`() {
        val packerWithAliases = SyncBatchPacker(
            sessionDao = sessionDao,
            intervalDao = intervalDao,
            telemetryFrameDao = telemetryFrameDao,
            batteryCycleDao = batteryCycleDao,
            telemetryEventDao = telemetryEventDao,
            aliases = InMemoryAliasStore(mapOf("retired-uuid" to "WBA-123456")),
            eventsStreamEnabled = true,
            nowUtcMillisProvider = { fixedNow }
        )
        sessionDao.add(
            createSession("s-1", startedAt = 1000L, endedAt = 2000L)
                .copy(vehicleId = "retired-uuid")
        )
        sessionDao.add(createSession("s-2", startedAt = 3000L, endedAt = 4000L))

        val batch = packerWithAliases.packBatch(SyncStreamType.SESSIONS.wireName, after = null, limit = 10)

        assertEquals("WBA-123456", batch.items[0]["vehicleId"])
        assertEquals("test-vehicle", batch.items[1]["vehicleId"])
    }

    /**
     * Issue 199: the sessions and intervals streams are cursor-based and do
     * not otherwise filter by kind, so a `CONTINUOUS` session must be excluded
     * explicitly or it doubles the companion's interval volume.
     */
    @Test
    fun `packBatch never sends a CONTINUOUS session`() {
        sessionDao.add(createSession("trip-1", startedAt = 1000L, endedAt = 2000L))
        sessionDao.add(createSession("continuous-1", startedAt = 1500L, endedAt = 2500L, kind = "CONTINUOUS"))
        sessionDao.add(createSession("trip-2", startedAt = 3000L, endedAt = 4000L))

        val batch = packer.packBatch(SyncStreamType.SESSIONS.wireName, after = null, limit = 10)

        assertEquals(listOf("trip-1", "trip-2"), batch.items.map { it["id"] })
        assertEquals(0, batch.remaining)
    }

    @Test
    fun `a CONTINUOUS session does not hold back the sessions cursor`() {
        sessionDao.add(createSession("trip-1", startedAt = 1000L, endedAt = 2000L))
        sessionDao.add(createSession("continuous-1", startedAt = 1500L, endedAt = 2500L, kind = "CONTINUOUS"))

        val batch = packer.packBatch(SyncStreamType.SESSIONS.wireName, after = null, limit = 10)

        assertEquals(listOf("trip-1"), batch.items.map { it["id"] })
        assertFalse(batch.hasMore)
        assertEquals(0, batch.remaining)
    }

    @Test
    fun `packBatch packages intervals and sets composite cursor`() {
        intervalDao.add(createInterval("trip-1", 1000L))
        intervalDao.add(createInterval("trip-1", 2000L))
        intervalDao.add(createInterval("trip-2", 3000L))

        val batch = packer.packBatch("intervals", after = null, limit = 2)

        assertEquals(2, batch.protocolVersion)
        assertEquals("intervals", batch.streamType)
        assertEquals(2, batch.items.size)
        assertTrue(batch.hasMore)
        assertEquals("trip-1:2000", batch.nextCursor)
        assertEquals(1L, batch.remaining)

        val nextBatch = packer.packBatch("intervals", after = batch.nextCursor, limit = 2)
        assertEquals(1, nextBatch.items.size)
        assertFalse(nextBatch.hasMore)
        assertEquals("trip-2:3000", nextBatch.nextCursor)
        assertEquals(0L, nextBatch.remaining)
    }

    @Test
    fun `packBatch never sends the minutes of a CONTINUOUS session`() {
        sessionDao.add(createSession("trip-1", startedAt = 1000L, endedAt = 2000L))
        sessionDao.add(createSession("continuous-1", startedAt = 1000L, endedAt = 2000L, kind = "CONTINUOUS"))
        intervalDao.add(createInterval("trip-1", 1000L))
        intervalDao.add(createInterval("continuous-1", 1000L))
        intervalDao.add(createInterval("continuous-1", 2000L))

        val batch = packer.packBatch(SyncStreamType.INTERVALS.wireName, after = null, limit = 10)

        assertEquals(listOf("trip-1"), batch.items.map { it["sessionId"] })
        assertEquals(0, batch.remaining)
    }

    @Test
    fun `countStream counts intervals accurately`() {
        intervalDao.add(createInterval("trip-1", 1000L))
        intervalDao.add(createInterval("trip-1", 2000L))
        intervalDao.add(createInterval("trip-2", 3000L))

        val initial = packer.countStream("intervals", after = null)
        assertEquals(3L, initial.total)
        assertEquals(3L, initial.remaining)

        val afterFirst = packer.countStream("intervals", after = "trip-1:1000")
        assertEquals(3L, afterFirst.total)
        assertEquals(2L, afterFirst.remaining)
    }

    private fun createSession(
        id: String,
        startedAt: Long,
        endedAt: Long?,
        kind: String = "TRIP"
    ): SessionEntity {
        return SessionEntity(
            id = id,
            vehicleId = "test-vehicle",
            kind = kind,
            status = if (endedAt != null) "ENDED" else "ACTIVE",
            startedAtUtcMillis = startedAt,
            startedAtElapsedNanos = 100L,
            startedAtBootCount = 1,
            movementStartedAtUtcMillis = null,
            movementStartedAtElapsedNanos = null,
            movementStartedAtBootCount = null,
            endedAtUtcMillis = endedAt,
            endedAtElapsedNanos = if (endedAt != null) 200L else null,
            endedAtBootCount = if (endedAt != null) 1 else null,
            startSocPercent = 80.0f,
            endSocPercent = 75.0f,
            startOdometerKm = 1000.0f,
            endOdometerKm = 1010.0f,
            startGear = 1,
            endReason = if (endedAt != null) "PARK" else null,
            createdAtUtcMillis = startedAt,
            updatedAtUtcMillis = endedAt ?: startedAt
        )
    }

    private fun createInterval(sessionId: String, startUtcMillis: Long): IntervalEntity {
        return IntervalEntity(
            sessionId = sessionId,
            startUtcMillis = startUtcMillis,
            tractionWh = 200.0,
            regenWh = 20.0,
            auxiliaryWh = 30.0,
            climateWh = 10.0,
            deliveredWh = 0.0,
            distanceKm = 1.0,
            coveredSeconds = 60.0,
            climateCoveredSeconds = 60.0,
            deliveredCoveredSeconds = 0.0,
            updatedAtUtcMillis = startUtcMillis + 60000
        )
    }

    private fun createEvent(id: Long, sessionId: String? = null, occurredAt: Long = 1000L): TelemetryEventEntity {
        return TelemetryEventEntity(
            id = id,
            type = "TRIP_ARMED",
            occurredAtUtcMillis = occurredAt,
            occurredAtElapsedNanos = occurredAt * 1_000_000L,
            sourceTimestampNanos = null,
            timestampAccuracy = "INFERRED",
            uncertaintyMillis = 0L,
            signalId = "GEAR",
            value = "4",
            previousValue = null,
            quality = null,
            source = "VHAL_POLLING",
            details = "gear=4",
            sessionId = sessionId
        )
    }
    private fun createCycle(ordinal: Long, startUtcMillis: Long = ordinal * 1000L): BatteryCycleEntity {
        return BatteryCycleEntity(
            ordinal = ordinal,
            startUtcMillis = startUtcMillis,
            endUtcMillis = startUtcMillis + 60_000L,
            dischargePercent = 20.0,
            distanceKm = 10.0,
            tripEnergyKwh = 2.0,
            parkedEnergyKwh = 0.5,
            parkedSocPercent = 60.0,
            cost = null,
            costCurrency = null,
            pricedEnergyKwh = 2.0,
            unpricedEnergyKwh = 0.5,
            isOpen = false,
            isPartial = false,
            energyIncomplete = false,
            mixedCurrency = false,
            openingPricedFraction = 1.0,
            openingBlendedPrice = 0.5,
            frozenAtUtcMillis = null,
            createdAtUtcMillis = startUtcMillis,
            updatedAtUtcMillis = startUtcMillis
        )
    }

    @Test
    fun `packBatch with EVENTS stream paginates and reports remaining`() {
        telemetryEventDao.add(createEvent(1, sessionId = "s-1", occurredAt = 1000L))
        telemetryEventDao.add(createEvent(2, sessionId = "s-1", occurredAt = 2000L))
        telemetryEventDao.add(createEvent(3, sessionId = "s-2", occurredAt = 3000L))
        telemetryEventDao.add(createEvent(4, sessionId = null, occurredAt = 4000L))

        val page1 = packer.packBatch(SyncStreamType.EVENTS.wireName, after = null, limit = 2)
        assertEquals(SyncStreamType.EVENTS.wireName, page1.streamType)
        assertEquals(2, page1.items.size)
        assertEquals("2", page1.nextCursor)
        assertTrue(page1.hasMore)
        assertEquals(2L, page1.remaining)

        val page2 = packer.packBatch(SyncStreamType.EVENTS.wireName, after = page1.nextCursor, limit = 2)
        assertEquals(2, page2.items.size)
        assertEquals("4", page2.nextCursor)
        assertFalse(page2.hasMore)
        assertEquals(0L, page2.remaining)
    }

    @Test
    fun `countedStreams includes EVENTS`() {
        assertTrue(packer.countedStreams.contains(SyncStreamType.EVENTS))
    }

    @Test
    fun `the events stream answers empty while gated, echoing the cursor back`() {
        telemetryEventDao.add(createEvent(7, sessionId = "s-1", occurredAt = 1000L))
        val gated = SyncBatchPacker(
            sessionDao = sessionDao,
            intervalDao = intervalDao,
            telemetryFrameDao = telemetryFrameDao,
            batteryCycleDao = batteryCycleDao,
            telemetryEventDao = telemetryEventDao,
            eventsStreamEnabled = false,
            nowUtcMillisProvider = { fixedNow }
        )

        val batch = gated.packBatch(SyncStreamType.EVENTS.wireName, after = "7", limit = 2)

        assertEquals(SyncStreamType.EVENTS.wireName, batch.streamType)
        assertEquals(0, batch.items.size)
        assertEquals("7", batch.nextCursor)
        assertFalse(batch.hasMore)
        assertEquals(0, batch.remaining)
    }

    @Test
    fun `countStream reports zero for events while gated`() {
        telemetryEventDao.add(createEvent(7, sessionId = "s-1", occurredAt = 1000L))
        val gated = SyncBatchPacker(
            sessionDao = sessionDao,
            intervalDao = intervalDao,
            telemetryFrameDao = telemetryFrameDao,
            batteryCycleDao = batteryCycleDao,
            telemetryEventDao = telemetryEventDao,
            eventsStreamEnabled = false,
            nowUtcMillisProvider = { fixedNow }
        )

        val count = gated.countStream(SyncStreamType.EVENTS.wireName, after = null)

        assertEquals(SyncStreamType.EVENTS.wireName, count.streamType)
        assertEquals(0, count.total)
        assertEquals(0, count.remaining)
    }

    @Test
    fun `packBatch with INTERVALS stream packs startSoc and endSoc correctly`() {
        intervalDao.add(
            IntervalEntity(
                sessionId = "s-1",
                startUtcMillis = 1000L,
                tractionWh = 50.0,
                startSoc = 80.0,
                endSoc = 79.5
            )
        )
        intervalDao.add(
            IntervalEntity(
                sessionId = "s-1",
                startUtcMillis = 61000L,
                tractionWh = 60.0,
                startSoc = null,
                endSoc = null
            )
        )

        val batch = packer.packBatch(SyncStreamType.INTERVALS.wireName, after = null, limit = 10)
        assertEquals(SyncStreamType.INTERVALS.wireName, batch.streamType)
        assertEquals(2, batch.items.size)
        assertEquals(80.0, batch.items[0]["startSoc"])
        assertEquals(79.5, batch.items[0]["endSoc"])
        assertNull(batch.items[1]["startSoc"])
        assertNull(batch.items[1]["endSoc"])
    }
    @Test
    fun `packBatch with BATTERY_CYCLES throws SyncCursorNotFoundException for a stale cursor`() {
        batteryCycleDao.add(createCycle(1))
        batteryCycleDao.add(createCycle(2))
        batteryCycleDao.add(createCycle(3))

        assertThrows(SyncCursorNotFoundException::class.java) {
            packer.packBatch(SyncStreamType.BATTERY_CYCLES.wireName, after = "120", limit = 10)
        }
    }

    @Test
    fun `packBatch with BATTERY_CYCLES packs normally from a valid cursor`() {
        batteryCycleDao.add(createCycle(1))
        batteryCycleDao.add(createCycle(2))
        batteryCycleDao.add(createCycle(3))

        val batch = packer.packBatch(SyncStreamType.BATTERY_CYCLES.wireName, after = "2", limit = 10)

        assertEquals(SyncStreamType.BATTERY_CYCLES.wireName, batch.streamType)
        assertEquals(1, batch.items.size)
        assertEquals(3L, batch.items[0]["ordinal"])
        assertEquals("3", batch.nextCursor)
        assertFalse(batch.hasMore)
        assertEquals(0L, batch.remaining)
    }

    @Test
    fun `countStream and packBatch agree that an unparseable battery cycle cursor is corrupt`() {
        batteryCycleDao.add(createCycle(1))

        assertThrows(SyncCursorCorruptException::class.java) {
            packer.countStream(SyncStreamType.BATTERY_CYCLES.wireName, after = "not-a-number")
        }
        assertThrows(SyncCursorCorruptException::class.java) {
            packer.packBatch(SyncStreamType.BATTERY_CYCLES.wireName, after = "not-a-number", limit = 10)
        }
    }

    @Test
    fun `countStream counts battery cycles from the front when the cursor parses but is missing`() {
        batteryCycleDao.add(createCycle(1))
        batteryCycleDao.add(createCycle(2))
        batteryCycleDao.add(createCycle(3))

        val count = packer.countStream(SyncStreamType.BATTERY_CYCLES.wireName, after = "120")

        assertEquals(SyncStreamType.BATTERY_CYCLES.wireName, count.streamType)
        assertEquals(3L, count.total)
        assertEquals(3L, count.remaining)
    }

    @Test
    fun `countStream counts battery cycles from a valid cursor`() {
        batteryCycleDao.add(createCycle(1))
        batteryCycleDao.add(createCycle(2))
        batteryCycleDao.add(createCycle(3))

        val count = packer.countStream(SyncStreamType.BATTERY_CYCLES.wireName, after = "2")

        assertEquals(3L, count.total)
        assertEquals(1L, count.remaining)
    }
}
