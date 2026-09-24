package com.timhss.capyenergy.telemetry.sync

import com.timhss.capyenergy.telemetry.db.BatteryCycleDao
import com.timhss.capyenergy.telemetry.db.BatteryCycleEntity
import com.timhss.capyenergy.telemetry.db.IntervalDao
import com.timhss.capyenergy.telemetry.db.IntervalEntity
import com.timhss.capyenergy.telemetry.db.SessionDao
import com.timhss.capyenergy.telemetry.db.SessionEntity
import com.timhss.capyenergy.telemetry.db.TelemetryEventDao
import com.timhss.capyenergy.telemetry.db.TelemetryEventEntity
import com.timhss.capyenergy.telemetry.db.TrackDao
import com.timhss.capyenergy.telemetry.db.TrackEntity
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

// ---------------------------------------------------------------------------
// In-memory fakes that honour the dirty gate exactly as the Room queries do.
// ---------------------------------------------------------------------------

private class FakeSessionDaoI : SessionDao {
    val sessions = mutableListOf<SessionEntity>()
    override fun upsert(session: SessionEntity) {
        val idx = sessions.indexOfFirst { it.id == session.id }
        if (idx >= 0) sessions[idx] = session else sessions.add(session)
    }
    override fun upsertAll(sessions: List<SessionEntity>) { sessions.forEach { upsert(it) } }
    override fun findById(id: String): SessionEntity? = sessions.find { it.id == id }
    override fun listSessionsFiltered(kind: String?, status: String?, fromUtcMillis: Long?, toUtcMillis: Long?, limit: Int, offset: Int) = emptyList<SessionEntity>()
    override fun countSessionsFiltered(kind: String?, status: String?, fromUtcMillis: Long?, toUtcMillis: Long?) = 0L
    override fun listSessionsSatisfyingAccount(accountId: String?, kind: String?, status: String?, fromUtcMillis: Long?, toUtcMillis: Long?, limit: Int, offset: Int) = emptyList<SessionEntity>()
    override fun countSessionsSatisfyingAccount(accountId: String?, kind: String?, status: String?, fromUtcMillis: Long?, toUtcMillis: Long?) = 0L
    override fun findByKind(kind: String) = emptyList<SessionEntity>()
    override fun inWindow(kind: String, startUtcMillis: Long, endUtcMillis: Long) = emptyList<SessionEntity>()
    override fun inWindowAll(startUtcMillis: Long, endUtcMillis: Long) = emptyList<SessionEntity>()
    override fun rangeWindow(startUtcMillis: Long, endUtcMillis: Long) = emptyList<SessionEntity>()
    override fun latest(kind: String, limit: Int) = emptyList<SessionEntity>()
    override fun latestAll(limit: Int) = emptyList<SessionEntity>()
    override fun countListed(kind: String) = 0L
    override fun countListedAll() = 0L
    override fun latestOpen(kind: String) = null
    override fun closeOpenSessions(kind: String, endedAtUtcMillis: Long, endedAtElapsedNanos: Long, reason: String, updatedAtUtcMillis: Long) = 0
    override fun count() = sessions.size.toLong()
    override fun countByKind(kind: String) = sessions.count { it.kind == kind }.toLong()
    override fun pendingFinalization() = emptyList<SessionEntity>()
    override fun syncPage(afterStartedAtUtcMillis: Long, afterId: String, limit: Int) = emptyList<SessionEntity>()
    override fun syncPendingCount(afterStartedAtUtcMillis: Long, afterId: String) = 0L
    override fun deleteById(id: String): Int { return if (sessions.removeIf { it.id == id }) 1 else 0 }
    override fun deleteByIds(ids: List<String>): Int { val n = sessions.count { it.id in ids }; sessions.removeIf { it.id in ids }; return n }
    override fun closedFrom(fromUtcMillis: Long) = emptyList<SessionEntity>()
    override fun closedFromAll(fromUtcMillis: Long) = emptyList<SessionEntity>()
    override fun unfinalizedClosed() = emptyList<SessionEntity>()
    override fun oldestStartUtcMillis(kind: String) = null
    override fun oldestStartUtcMillisAll() = null
    override fun byIds(ids: List<String>) = emptyList<SessionEntity>()
    override fun since(startUtcMillis: Long) = emptyList<SessionEntity>()
    override fun updatePlugType(id: String, plugType: Int, updatedAtUtcMillis: Long) = 0
    // Dirty-gated retention deletes: only dirty == false may be pruned.
    override fun deleteOlderThan(cutoffUtcMillis: Long): Int {
        val toDelete = sessions.filter { it.kind == "PARKED" && (it.endedAtUtcMillis ?: it.updatedAtUtcMillis) < cutoffUtcMillis && it.endedAtUtcMillis != null && !it.dirty }
        sessions.removeAll(toDelete)
        return toDelete.size
    }
    override fun deleteOlderThanConfirmed(cutoffUtcMillis: Long, floorStartedAtUtcMillis: Long): Int {
        val toDelete = sessions.filter { it.kind == "PARKED" && (it.endedAtUtcMillis ?: it.updatedAtUtcMillis) < cutoffUtcMillis && it.endedAtUtcMillis != null && !it.dirty && it.startedAtUtcMillis <= floorStartedAtUtcMillis }
        sessions.removeAll(toDelete)
        return toDelete.size
    }
    override fun deleteContinuousOlderThan(cutoffUtcMillis: Long): Int {
        val toDelete = sessions.filter { it.kind == "CONTINUOUS" && (it.endedAtUtcMillis ?: it.updatedAtUtcMillis) < cutoffUtcMillis && it.endedAtUtcMillis != null && !it.dirty }
        sessions.removeAll(toDelete)
        return toDelete.size
    }
    override fun deleteContinuousOlderThanIgnoringDirty(cutoffUtcMillis: Long): Int {
        val toDelete = sessions.filter { it.kind == "CONTINUOUS" && (it.endedAtUtcMillis ?: it.updatedAtUtcMillis) < cutoffUtcMillis && it.endedAtUtcMillis != null }
        sessions.removeAll(toDelete)
        return toDelete.size
    }
    override fun deleteContinuousOlderThanConfirmed(cutoffUtcMillis: Long, floorStartedAtUtcMillis: Long): Int {
        val toDelete = sessions.filter { it.kind == "CONTINUOUS" && (it.endedAtUtcMillis ?: it.updatedAtUtcMillis) < cutoffUtcMillis && it.endedAtUtcMillis != null && !it.dirty && it.startedAtUtcMillis <= floorStartedAtUtcMillis }
        sessions.removeAll(toDelete)
        return toDelete.size
    }
    override fun markNoLongerReducible(id: String, updatedAtUtcMillis: Long) = 0
    override fun sessionsEligibleForNoLongerReducible() = emptyList<String>()
    override fun dirtySessions(limit: Int) = sessions.filter { it.dirty }.take(limit)
    override fun dirtySessionCount() = sessions.count { it.dirty }.toLong()
    override fun pendingSessionCount() = sessions.count { it.dirty && it.timeState == "pending" }.toLong()
    override fun clearDirty(ids: List<String>): Int {
        var c = 0
        for (i in sessions.indices) {
            val s = sessions[i]
            if (s.id in ids && s.dirty) { sessions[i] = s.copy(dirty = false); c++ }
        }
        return c
    }
    override fun markAllDirty(): Int {
        var c = 0
        for (i in sessions.indices) {
            if (!sessions[i].dirty) { sessions[i] = sessions[i].copy(dirty = true); c++ }
        }
        return c
    }
    override fun promoteEndedPendingToUncorrectable(): Int = 0
    override fun distinctVehicleIds(): List<String> =
        sessions.map { it.vehicleId }.filter { it.isNotBlank() && it != "unassigned" }.distinct()
    override fun markAliasedSessionsDirty(): Int = 0
}

private class FakeIntervalDaoI : IntervalDao {
    val intervals = mutableListOf<IntervalEntity>()
    override fun upsertAll(intervals: List<IntervalEntity>) {
        for (e in intervals) {
            val idx = this.intervals.indexOfFirst { it.sessionId == e.sessionId && it.startUtcMillis == e.startUtcMillis }
            if (idx >= 0) this.intervals[idx] = e else this.intervals.add(e)
        }
    }
    override fun forSession(sessionId: String) = intervals.filter { it.sessionId == sessionId }
    override fun countForSession(sessionId: String) = intervals.count { it.sessionId == sessionId }.toLong()
    override fun sessionsWithBuckets(sessionIds: List<String>) = emptyList<String>()
    override fun forSessionsInWindow(sessionIds: List<String>, startUtcMillis: Long, endUtcMillis: Long) = emptyList<IntervalEntity>()
    override fun deleteBySessionIds(sessionIds: List<String>): Int { val n = intervals.count { it.sessionId in sessionIds }; intervals.removeIf { it.sessionId in sessionIds }; return n }
    override fun findById(sessionId: String, startUtcMillis: Long) = intervals.find { it.sessionId == sessionId && it.startUtcMillis == startUtcMillis }
    override fun syncPage(afterStartUtcMillis: Long, afterSessionId: String, limit: Int) = emptyList<IntervalEntity>()
    override fun syncPendingCount(afterStartUtcMillis: Long, afterSessionId: String) = 0L
    override fun count() = intervals.size.toLong()
    override fun deleteOrphans(): Int { return 0 }
    override fun deleteOrphansChunk(limit: Int) = 0
    override fun dirtyIntervals(limit: Int) = intervals.filter { it.dirty }.take(limit)
    override fun dirtyIntervalCount() = intervals.count { it.dirty }.toLong()
    override fun pendingIntervalCount() = intervals.count { it.dirty && it.timeState == "pending" }.toLong()
    override fun clearDirty(sessionId: String, startUtcMillis: Long): Int {
        val idx = intervals.indexOfFirst { it.sessionId == sessionId && it.startUtcMillis == startUtcMillis && it.dirty }
        return if (idx >= 0) { intervals[idx] = intervals[idx].copy(dirty = false); 1 } else 0
    }
    override fun clearDirtyByKeys(keys: List<String>): Int {
        var c = 0
        for (i in intervals.indices) {
            val it = intervals[i]
            val key = "${it.sessionId}:${it.startUtcMillis}"
            if (key in keys && it.dirty) { intervals[i] = it.copy(dirty = false); c++ }
        }
        return c
    }
    override fun markAllDirty(): Int {
        var c = 0
        for (i in intervals.indices) {
            if (!intervals[i].dirty) { intervals[i] = intervals[i].copy(dirty = true); c++ }
        }
        return c
    }
    override fun promoteEndedPendingToUncorrectable(): Int = 0

        override fun allPaired(): List<IntervalEntity> = emptyList()
override fun pendingsForBoot(bootCount: Long): List<IntervalEntity> = emptyList()
    override fun forBoot(bootCount: Long): List<IntervalEntity> = emptyList()
    override fun deleteKey(sessionId: String, startUtcMillis: Long): Int = 0
}

private class FakeTrackDaoI : TrackDao {
    val rows = mutableMapOf<String, TrackEntity>()
    override fun upsert(track: TrackEntity) { rows[track.sessionId] = track }
    override fun forSession(sessionId: String) = rows[sessionId]
    override fun forSessions(sessionIds: List<String>) = sessionIds.mapNotNull { rows[it] }
    override fun count() = rows.size.toLong()
    override fun countForSession(sessionId: String) = if (rows.containsKey(sessionId)) 1L else 0L
    override fun deleteBySessionIds(sessionIds: List<String>): Int { var n=0; for(id in sessionIds) if(rows.remove(id)!=null) n++; return n }
    override fun deleteOrphans(): Int = 0
    override fun syncPage(afterUpdatedAtUtcMillis: Long, afterSessionId: String, limit: Int) = emptyList<TrackEntity>()
    override fun syncPendingCount(afterUpdatedAtUtcMillis: Long, afterSessionId: String) = 0L
    override fun dirtyTracks(limit: Int) = rows.values.filter { it.dirty }.take(limit)
    override fun dirtyTrackCount() = rows.values.count { it.dirty }.toLong()
    override fun clearDirty(ids: List<String>): Int {
        var c = 0
        for (id in ids) { val t = rows[id]; if (t!=null && t.dirty) { rows[id]=t.copy(dirty=false); c++ } }
        return c
    }
    override fun markAllDirty(): Int {
        var c = 0
        for ((id, t) in rows.toList()) { if (!t.dirty) { rows[id] = t.copy(dirty = true); c++ } }
        return c
    }
}

private class FakeTelemetryEventDaoI : TelemetryEventDao {
    val events = mutableListOf<TelemetryEventEntity>()
    override fun insert(event: TelemetryEventEntity) { events.add(event) }
    override fun latest(limit: Int) = events.takeLast(limit)
    override fun forSession(sessionId: String) = events.filter { it.sessionId == sessionId }
    override fun orphansInWindow(fromUtcMillis: Long, toUtcMillis: Long) = emptyList<TelemetryEventEntity>()
    override fun backStampSession(sessionId: String, eventIds: List<Long>) = 0
    override fun findById(id: Long) = events.find { it.id == id }
    override fun byTypeInWindow(type: String, fromUtcMillis: Long, toUtcMillis: Long) = emptyList<TelemetryEventEntity>()
    override fun count() = events.size.toLong()
    override fun maxId() = events.maxOfOrNull { it.id }
    override fun syncPage(afterId: Long, limit: Int) = events.filter { it.id > afterId }.sortedBy { it.id }.take(limit)
    override fun syncPendingCount(afterId: Long) = syncPage(afterId, Int.MAX_VALUE).size.toLong()
    override fun countOlderThan(cutoffUtcMillis: Long) = events.count { it.occurredAtUtcMillis < cutoffUtcMillis }.toLong()
    override fun deleteOlderThanChunk(cutoffUtcMillis: Long, limit: Int): Int {
        val candidates = events.filter { it.occurredAtUtcMillis < cutoffUtcMillis && !it.dirty }.take(limit)
        events.removeAll(candidates)
        return candidates.size
    }
    override fun deleteOlderThanConfirmedChunk(cutoffUtcMillis: Long, floorId: Long, limit: Int): Int {
        val candidates = events.filter { it.occurredAtUtcMillis < cutoffUtcMillis && !it.dirty && it.id <= floorId }.take(limit)
        events.removeAll(candidates)
        return candidates.size
    }
    override fun deleteOrphanSessionEventsChunk(limit: Int): Int = 0
    override fun dirtyEvents(limit: Int) = events.filter { it.dirty }.take(limit)
    override fun dirtyEventCount() = events.count { it.dirty }.toLong()
    override fun clearDirty(ids: List<Long>): Int {
        var c=0
        for(i in events.indices){ val e=events[i]; if(e.id in ids && e.dirty){ events[i]=e.copy(dirty=false); c++ } }
        return c
    }
    override fun markAllDirty(): Int {
        var c = 0
        for (i in events.indices) { if (!events[i].dirty) { events[i] = events[i].copy(dirty = true); c++ } }
        return c
    }
}

private class FakeBatteryCycleDaoI : BatteryCycleDao {
    val cycles = mutableListOf<BatteryCycleEntity>()
    override fun upsertAll(cycles: List<BatteryCycleEntity>) {
        for(c in cycles){ val idx=this.cycles.indexOfFirst{ it.ordinal==c.ordinal}; if(idx>=0) this.cycles[idx]=c else this.cycles.add(c) }
    }
    override fun latest(limit: Int) = emptyList<BatteryCycleEntity>()
    override fun newest() = null
    override fun open() = null
    override fun newestRebuildable() = null
    override fun maxOrdinal() = cycles.maxOfOrNull { it.ordinal }
    override fun oldestRebuildableEndingAtOrAfter(utcMillis: Long) = null
    override fun newestClosedEndingBefore(utcMillis: Long) = null
    override fun deleteFrom(ordinal: Long) { cycles.removeIf{ it.ordinal >= ordinal} }
    override fun freezeUpTo(ordinal: Long, frozenAtUtcMillis: Long) {}
    override fun count() = cycles.size.toLong()
    override fun findById(ordinal: Long) = cycles.find { it.ordinal == ordinal }
    override fun syncPage(afterOrdinal: Long, limit: Int) = emptyList<BatteryCycleEntity>()
    override fun syncPendingCount(afterOrdinal: Long) = 0L
    override fun dirtyCycles(limit: Int) = cycles.filter { it.dirty }.take(limit)
    override fun dirtyCycleCount() = cycles.count { it.dirty }.toLong()
    override fun clearDirty(ordinals: List<Long>): Int {
        var c=0
        for(i in cycles.indices){ val cy=cycles[i]; if(cy.ordinal in ordinals && cy.dirty){ cycles[i]=cy.copy(dirty=false); c++ } }
        return c
    }
    override fun markAllDirty(): Int {
        var c = 0
        for (i in cycles.indices) { if (!cycles[i].dirty) { cycles[i] = cycles[i].copy(dirty = true); c++ } }
        return c
    }
}

private class FakeCloudSinkI : CloudSink {
    data class Write(val table: String, val rows: List<Map<String, Any?>>, val conflictColumns: List<String>, val merge: Boolean)
    val writes = mutableListOf<Write>()
    override suspend fun upsert(table: String, rows: List<Map<String, Any?>>, conflictColumns: List<String>, merge: Boolean) {
        writes.add(Write(table, rows.map { it.toMap() }, conflictColumns.toList(), merge))
    }
    override suspend fun delete(
        table: String,
        vehicleId: String,
        keys: List<Triple<String, String, Long>>
    ) {
        // The durability harness never drives the T9 delete path.
    }
    fun tablesInOrder(): List<String> = writes.map { it.table }
    fun rowsFor(table: String): List<Map<String, Any?>> = writes.filter { it.table==table }.flatMap { it.rows }
    fun keysFor(table: String): Set<String> = rowsFor(table).map { row -> conflictKey(row, writes.first { it.table==table }.conflictColumns) }.toSet()
    private fun conflictKey(row: Map<String, Any?>, cols: List<String>): String = cols.joinToString("|") { c -> "${c}=${row[c]}" }
}

/**
 * Phase 1 end-to-end queue durability integration test.
 *
 * Verifies the full lifecycle:
 * 1. Offline accumulation seeds dirty=1.
 * 2. Retention floor/aging pruning deletes 0 dirty=1 rows.
 * 3. TelemetryCloudUploader uploads all 5 streams in FK order.
 * 4. Dirty marks flip to 0.
 * 5. Retention now deletes expired clean rows.
 * 6. Double-write idempotency: car direct + companion pull identical keys.
 */
class Phase1DurabilityIntegrationTest {

    private lateinit var sessionDao: FakeSessionDaoI
    private lateinit var intervalDao: FakeIntervalDaoI
    private lateinit var trackDao: FakeTrackDaoI
    private lateinit var eventDao: FakeTelemetryEventDaoI
    private lateinit var cycleDao: FakeBatteryCycleDaoI
    private lateinit var sink: FakeCloudSinkI

    private val vehicleId = "VIN-DURABILITY-1"
    private val accountId = "00000000-0000-4000-a000-000000000099"

    @Before
    fun setUp() {
        sessionDao = FakeSessionDaoI()
        intervalDao = FakeIntervalDaoI()
        trackDao = FakeTrackDaoI()
        eventDao = FakeTelemetryEventDaoI()
        cycleDao = FakeBatteryCycleDaoI()
        sink = FakeCloudSinkI()
    }

    private fun uploader() = TelemetryCloudUploader(
        sessionDao = sessionDao,
        intervalDao = intervalDao,
        trackDao = trackDao,
        telemetryEventDao = eventDao,
        batteryCycleDao = cycleDao,
        sink = sink,
        vehicleIdProvider = { vehicleId },
        accountIdProvider = { accountId }
    )

    // Helpers ---------------------------------------------------------------

    private fun oldSession(id: String, kind: String = "PARKED"): SessionEntity = SessionEntity(
        id = id,
        vehicleId = vehicleId,
        kind = kind,
        status = "ENDED",
        startedAtUtcMillis = 1_000L,
        startedAtElapsedNanos = 1L,
        endedAtUtcMillis = 2_000L,
        endedAtElapsedNanos = 2L,
        createdAtUtcMillis = 1_000L,
        updatedAtUtcMillis = 2_000L,
        dirty = true
    )

    private fun youngSession(id: String, kind: String = "TRIP"): SessionEntity = SessionEntity(
        id = id,
        vehicleId = vehicleId,
        kind = kind,
        status = "ENDED",
        startedAtUtcMillis = 20_000_000_000L,
        startedAtElapsedNanos = 10L,
        endedAtUtcMillis = 20_000_360_000L,
        endedAtElapsedNanos = 11L,
        createdAtUtcMillis = 20_000_000_000L,
        updatedAtUtcMillis = 20_000_360_000L,
        dirty = true
    )

    @Test
    fun `full Phase 1 lifecycle offline accumulation retention upload prune idempotency`() = runBlocking {
        // ----------------------------------------------------------------
        // 1. Offline accumulation: seed all 5 streams with dirty = 1
        // ----------------------------------------------------------------
        // Sessions: 2 expired PARKED (eligible for retention) + 1 young TRIP + 1 CONTINUOUS expired
        val expiredParked1 = oldSession("parked-old-1", "PARKED")
        val expiredParked2 = oldSession("parked-old-2", "PARKED")
        val youngTrip = youngSession("trip-young-1", "TRIP")
        val expiredContinuous = oldSession("cont-old-1", "CONTINUOUS")
        sessionDao.upsert(expiredParked1)
        sessionDao.upsert(expiredParked2)
        sessionDao.upsert(youngTrip)
        sessionDao.upsert(expiredContinuous)
        // TRIP sessions are not age-pruned but must still be uploaded
        val expiredTrip = SessionEntity(
            id = "trip-old-1",
            vehicleId = vehicleId,
            kind = "TRIP",
            status = "ENDED",
            startedAtUtcMillis = 1_000L,
            startedAtElapsedNanos = 1L,
            endedAtUtcMillis = 2_000L,
            endedAtElapsedNanos = 2L,
            createdAtUtcMillis = 1_000L,
            updatedAtUtcMillis = 2_000L,
            dirty = true
        )
        sessionDao.upsert(expiredTrip)

        // Intervals: two for young trip + one for old trip (all dirty)
        intervalDao.upsertAll(listOf(
            IntervalEntity(sessionId = "trip-young-1", startUtcMillis = 20_000_000_000L, dirty = true),
            IntervalEntity(sessionId = "trip-young-1", startUtcMillis = 20_000_060_000L, dirty = true),
            IntervalEntity(sessionId = "trip-old-1", startUtcMillis = 1_500L, dirty = true)
        ))

        // Tracks: one per trip session
        trackDao.upsert(TrackEntity(sessionId = "trip-young-1", encodingVersion = 1, pointCount = 2, t = "[0,60000]", path = "abcd", speed = "[10,12]", alt = "[100,101]", updatedAtUtcMillis = 20_000_360_000L, dirty = true))
        trackDao.upsert(TrackEntity(sessionId = "trip-old-1", encodingVersion = 1, pointCount = 2, t = "[0,60000]", path = "wxyz", speed = "[8,9]", alt = "[50,51]", updatedAtUtcMillis = 2_000L, dirty = true))
        trackDao.upsert(TrackEntity(sessionId = "parked-old-1", encodingVersion = 1, pointCount = 1, t = "[0]", path = "aaaa", speed = "[0]", alt = "[10]", updatedAtUtcMillis = 2_000L, dirty = true))

        // Events: 2 old expired + 1 young
        eventDao.insert(TelemetryEventEntity(id = 1L, type = "TRIP_ARMED", occurredAtUtcMillis = 1_100L, occurredAtElapsedNanos = 10L, sourceTimestampNanos = 5L, timestampAccuracy = "PRECISE", uncertaintyMillis = 0L, signalId = "GEAR", value = "D", previousValue = "P", quality = "GOOD", source = "VHAL", details = "{}", sessionId = "parked-old-1", dirty = true))
        eventDao.insert(TelemetryEventEntity(id = 2L, type = "TRIP_ARMED", occurredAtUtcMillis = 1_200L, occurredAtElapsedNanos = 11L, sourceTimestampNanos = 6L, timestampAccuracy = "PRECISE", uncertaintyMillis = 0L, signalId = "GEAR", value = "D", previousValue = "P", quality = "GOOD", source = "VHAL", details = "{}", sessionId = "parked-old-2", dirty = true))
        eventDao.insert(TelemetryEventEntity(id = 3L, type = "TRIP_ARMED", occurredAtUtcMillis = 20_000_000_100L, occurredAtElapsedNanos = 12L, sourceTimestampNanos = 7L, timestampAccuracy = "PRECISE", uncertaintyMillis = 0L, signalId = "GEAR", value = "R", previousValue = "D", quality = "GOOD", source = "VHAL", details = "{}", sessionId = "trip-young-1", dirty = true))

        // Cycles: one old, one young
        cycleDao.upsertAll(listOf(
            BatteryCycleEntity(ordinal = 1L, startUtcMillis = 1_000L, endUtcMillis = 2_000L, dischargePercent = 20.0, distanceKm = 5.0, tripEnergyKwh = 1.0, parkedEnergyKwh = 0.1, parkedSocPercent = 1.0, cost = null, costCurrency = null, pricedEnergyKwh = 1.0, unpricedEnergyKwh = 0.0, isOpen = false, isPartial = false, energyIncomplete = false, mixedCurrency = false, openingPricedFraction = 1.0, openingBlendedPrice = 0.5, frozenAtUtcMillis = null, createdAtUtcMillis = 1_000L, updatedAtUtcMillis = 2_000L, dirty = true),
            BatteryCycleEntity(ordinal = 2L, startUtcMillis = 20_000_000_000L, endUtcMillis = 20_000_360_000L, dischargePercent = 30.0, distanceKm = 10.0, tripEnergyKwh = 2.0, parkedEnergyKwh = 0.2, parkedSocPercent = 2.0, cost = 1.0, costCurrency = "BRL", pricedEnergyKwh = 2.0, unpricedEnergyKwh = 0.0, isOpen = false, isPartial = false, energyIncomplete = false, mixedCurrency = false, openingPricedFraction = 1.0, openingBlendedPrice = 0.5, frozenAtUtcMillis = null, createdAtUtcMillis = 20_000_000_000L, updatedAtUtcMillis = 20_000_360_000L, dirty = true)
        ))

        // Assert all seeded dirty
        assertEquals(5, sessionDao.dirtySessionCount())
        assertEquals(3, intervalDao.dirtyIntervalCount())
        assertEquals(3, trackDao.dirtyTrackCount())
        assertEquals(3, eventDao.dirtyEventCount())
        assertEquals(2, cycleDao.dirtyCycleCount())

        // ----------------------------------------------------------------
        // 2. Retention safety: pruning must delete 0 dirty=1 rows
        // ----------------------------------------------------------------
        val cutoff = 5_000_000_000L
        // Session age deletes are dirty-gated
        assertEquals(0, sessionDao.deleteOlderThan(cutoff))
        assertEquals(0, sessionDao.deleteContinuousOlderThan(cutoff))
        assertEquals(0, eventDao.deleteOlderThanChunk(cutoff, 10_000))
        // Confirmed floor variant also gated
        assertEquals(0, sessionDao.deleteOlderThanConfirmed(cutoff, Long.MAX_VALUE))
        assertEquals(0, eventDao.deleteOlderThanConfirmedChunk(cutoff, Long.MAX_VALUE, 10_000))
        // Nothing removed despite being expired
        assertEquals(5L, sessionDao.count())
        assertEquals(3L, eventDao.count())
        assertEquals(3L, intervalDao.count())
        assertEquals(3L, trackDao.count())
        assertEquals(2L, cycleDao.count())

        // ----------------------------------------------------------------
        // 3. Cloud upload: all 5 streams in FK order
        // ----------------------------------------------------------------
        val report = uploader().upload()
        assertEquals(5, report.perStream["session"])
        assertEquals(3, report.perStream["interval"])
        assertEquals(3, report.perStream["track"])
        assertEquals(3, report.perStream["telemetry_events"])
        assertEquals(2, report.perStream["battery_cycles"])
        // Valid FK order: session -> interval -> track -> telemetry_events -> battery_cycles
        val order = sink.tablesInOrder()
        val sIdx = order.indexOf("session")
        val iIdx = order.indexOf("interval")
        val tIdx = order.indexOf("track")
        val eIdx = order.indexOf("telemetry_events")
        val cIdx = order.indexOf("battery_cycles")
        assertTrue("sessions before intervals", sIdx < iIdx)
        assertTrue("intervals before tracks", tIdx.let { iIdx < it })
        assertTrue("tracks before events", tIdx < eIdx)
        assertTrue("events before cycles", eIdx < cIdx)
        // Conflict columns are natural keys
        fun cols(table: String) = sink.writes.first { it.table == table }.conflictColumns
        assertEquals(listOf("vehicle_id", "id"), cols("session"))
        assertEquals(listOf("vehicle_id", "session_id", "start_utc_millis"), cols("interval"))
        assertEquals(listOf("vehicle_id", "session_id"), cols("track"))
        assertEquals(listOf("vehicle_id", "occurred_at_utc_millis", "occurred_at_elapsed_nanos", "type", "signal_id"), cols("telemetry_events"))
        assertEquals(listOf("vehicle_id", "start_utc_millis"), cols("battery_cycles"))

        // ----------------------------------------------------------------
        // 4. Dirty clear: all uploaded records flipped to dirty = 0
        // ----------------------------------------------------------------
        assertEquals(0, sessionDao.dirtySessionCount())
        assertEquals(0, intervalDao.dirtyIntervalCount())
        assertEquals(0, trackDao.dirtyTrackCount())
        assertEquals(0, eventDao.dirtyEventCount())
        assertEquals(0, cycleDao.dirtyCycleCount())
        // No dirty rows remain yet young data still present
        assertTrue(sessionDao.sessions.none { it.dirty })
        assertTrue(intervalDao.intervals.none { it.dirty })
        assertTrue(trackDao.rows.values.none { it.dirty })
        assertTrue(eventDao.events.none { it.dirty })
        assertTrue(cycleDao.cycles.none { it.dirty })

        // ----------------------------------------------------------------
        // 5. Retention execution: expired clean rows now safely deleted
        // ----------------------------------------------------------------
        // Parked/continuous expired clean rows are pruned; young trip survives; TRIP old is not PARKED so not pruned
        val parkedDeleted = sessionDao.deleteOlderThan(cutoff)
        assertEquals(2, parkedDeleted)
        assertEquals(0L, sessionDao.countByKind("PARKED"))
        // trip-old-1 is TRIP not PARKED, so remains (retention only prunes PARKED/CONTINUOUS)
        assertTrue(sessionDao.findById("trip-old-1") != null)
        assertTrue(sessionDao.findById("trip-young-1") != null)
        val contDeleted = sessionDao.deleteContinuousOlderThan(cutoff)
        assertEquals(1, contDeleted)
        assertEquals(0L, sessionDao.countByKind("CONTINUOUS"))

        val eventsDeleted = eventDao.deleteOlderThanChunk(cutoff, 10_000)
        assertEquals(2, eventsDeleted)
        assertEquals(1L, eventDao.count()) // young survives
        assertEquals(3L, eventDao.events.single().id)

        // Intervals/tracks for deleted parked sessions become orphans but retention does not auto-delete them here;
        // verify they still exist (orphan GC is separate and ungated). The key check is they were not deleted while dirty.
        assertEquals(3L, intervalDao.count())
        assertEquals(3L, trackDao.count())

        // ----------------------------------------------------------------
        // 6. Double-write idempotency: car direct + companion pull identical keys
        // ----------------------------------------------------------------
        // Capture cloud payload keys from first upload (before pruning re-seed young rows for idempotency)
        // Re-seed identical logical rows via companion channel: same natural keys, same field values.
        // For sessions, companion upserts same id/vehicle; for intervals same sessionId+start; for tracks same sessionId;
        // for events same vehicle+occurred_at+type+signalId; for cycles same vehicle+start_utc_millis.

        // Reset sink and re-dirty surviving young rows to simulate companion's identical write arriving concurrently.
        sink.writes.clear()
        // Companion path re-writes same youngTrip with identical content but marks dirty again (REPLACE semantics)
        val companionTrip = youngTrip.copy(dirty = true, updatedAtUtcMillis = youngTrip.updatedAtUtcMillis)
        sessionDao.upsert(companionTrip)
        // Companion interval re-write identical keys
        intervalDao.upsertAll(listOf(
            IntervalEntity(sessionId = "trip-young-1", startUtcMillis = 20_000_000_000L, dirty = true),
            IntervalEntity(sessionId = "trip-young-1", startUtcMillis = 20_000_060_000L, dirty = true)
        ))
        trackDao.upsert(TrackEntity(sessionId = "trip-young-1", encodingVersion = 1, pointCount = 2, t = "[0,60000]", path = "abcd", speed = "[10,12]", alt = "[100,101]", updatedAtUtcMillis = 20_000_360_000L, dirty = true))
        // Event with same natural key as existing young event (vehicle+time+type+signal)
        eventDao.events.removeIf { it.id == 99L }
        // Re-insert young event with a different local id but same natural key – uploader drops local id so keys collide identically
        eventDao.insert(TelemetryEventEntity(id = 99L, type = "TRIP_ARMED", occurredAtUtcMillis = 20_000_000_100L, occurredAtElapsedNanos = 12L, sourceTimestampNanos = 7L, timestampAccuracy = "PRECISE", uncertaintyMillis = 0L, signalId = "GEAR", value = "R", previousValue = "D", quality = "GOOD", source = "VHAL", details = "{}", sessionId = "trip-young-1", dirty = true))
        // Cycle with same natural key (vehicle+start_utc_millis) but different ordinal is same cycle identity – we reuse ordinal 2
        cycleDao.upsertAll(listOf(
            BatteryCycleEntity(ordinal = 2L, startUtcMillis = 20_000_000_000L, endUtcMillis = 20_000_360_000L, dischargePercent = 30.0, distanceKm = 10.0, tripEnergyKwh = 2.0, parkedEnergyKwh = 0.2, parkedSocPercent = 2.0, cost = 1.0, costCurrency = "BRL", pricedEnergyKwh = 2.0, unpricedEnergyKwh = 0.0, isOpen = false, isPartial = false, energyIncomplete = false, mixedCurrency = false, openingPricedFraction = 1.0, openingBlendedPrice = 0.5, frozenAtUtcMillis = null, createdAtUtcMillis = 20_000_000_000L, updatedAtUtcMillis = 20_000_360_000L, dirty = true)
        ))

        // Record what car direct would send vs companion direct: both must produce same natural-key sets.
        // First, run uploader (car writer) and capture keys.
        val carWritesBefore = sink.writes.size
        val reportCar = uploader().upload()
        assertTrue(reportCar.perStream.isNotEmpty())
        val carKeys = sink.writes.associate { w -> w.table to w.rows.map { row -> w.conflictColumns.joinToString("|") { c -> "$c=${row[c]}" } }.toSet() }

        // Simulate simultaneous companion upload: re-dirty same young rows again and run concurrent uploads.
        // Re-dirty for second writer
        sessionDao.upsert(companionTrip.copy(dirty = true))
        intervalDao.upsertAll(listOf(IntervalEntity(sessionId = "trip-young-1", startUtcMillis = 20_000_000_000L, dirty = true)))
        trackDao.upsert(TrackEntity(sessionId = "trip-young-1", encodingVersion = 1, pointCount = 2, t = "[0,60000]", path = "abcd", speed = "[10,12]", alt = "[100,101]", updatedAtUtcMillis = 20_000_360_000L, dirty = true))
        // Need to re-insert another event with same natural key but new local id to simulate companion re-creation
        eventDao.insert(TelemetryEventEntity(id = 100L, type = "TRIP_ARMED", occurredAtUtcMillis = 20_000_000_100L, occurredAtElapsedNanos = 12L, sourceTimestampNanos = 7L, timestampAccuracy = "PRECISE", uncertaintyMillis = 0L, signalId = "GEAR", value = "R", previousValue = "D", quality = "GOOD", source = "VHAL", details = "{}", sessionId = "trip-young-1", dirty = true))
        cycleDao.upsertAll(listOf(BatteryCycleEntity(ordinal = 2L, startUtcMillis = 20_000_000_000L, endUtcMillis = 20_000_360_000L, dischargePercent = 30.0, distanceKm = 10.0, tripEnergyKwh = 2.0, parkedEnergyKwh = 0.2, parkedSocPercent = 2.0, cost = 1.0, costCurrency = "BRL", pricedEnergyKwh = 2.0, unpricedEnergyKwh = 0.0, isOpen = false, isPartial = false, energyIncomplete = false, mixedCurrency = false, openingPricedFraction = 1.0, openingBlendedPrice = 0.5, frozenAtUtcMillis = null, createdAtUtcMillis = 20_000_000_000L, updatedAtUtcMillis = 20_000_360_000L, dirty = true)))

        // Concurrent double-write: two uploads racing on same dirty set must not conflict and must produce identical keys
        sink.writes.clear()
        val writesBeforeConcurrent = sink.writes.size
        // Launch two concurrent uploads sharing same DAOs/sink
        val def1 = async { uploader().upload() }
        val def2 = async { uploader().upload() }
        val r1 = def1.await()
        val r2 = def2.await()
        // At least one must have moved rows; the second may be empty if first cleared dirty, but neither should throw PK conflict.
        assertTrue(r1.total + r2.total > 0)
        // If both wrote, their keys must be identical (idempotency) – collect all writes that happened
        val c2Keys = sink.writes.groupBy { it.table }.mapValues { (_, ws) -> ws.flatMap { it.rows }.map { row -> ws.first().conflictColumns.joinToString("|") { c -> "$c=${row[c]}" } }.toSet() }
        // All keys must be subsets of carKeys (no new divergent keys) – companion wrote same natural keys as car
        for ((table, keys) in c2Keys) {
            val expected = carKeys[table]
            if (expected != null) {
                for (k in keys) {
                    assertTrue("Double-write for $table produced divergent key $k not in car payload", k in expected)
                }
            }
        }
        // No exception means no PK conflict; verify sink accepted duplicate natural keys without divergence
        // Additionally verify that re-upserting same session via REPLACE does not throw and dirty clears
        sessionDao.upsert(youngTrip.copy(dirty = true))
        assertEquals(1, sessionDao.dirtySessionCount())
        val finalReport = uploader().upload()
        assertEquals(1, finalReport.perStream["session"])
        assertEquals(0, sessionDao.dirtySessionCount())
        // Payload for same session id must be byte-identical between car and companion writes (vehicle_id+id same, account_id same)
        val sessionRows = sink.rowsFor("session").filter { it["id"] == "trip-young-1" }
        if (sessionRows.size >= 2) {
            val first = sessionRows[sessionRows.size - 2].filterKeys { it != "account_id" }
            val second = sessionRows.last().filterKeys { it != "account_id" }
            // Compare without account_id (same) and ensure no data divergence on core fields
            assertEquals(first.filterKeys { it != "updated_at_utc_millis" }, second.filterKeys { it != "updated_at_utc_millis" })
        }
    }
}
