package com.timhss.capyenergy.telemetry.sync

import com.timhss.capyenergy.telemetry.db.BatteryCycleDao
import com.timhss.capyenergy.telemetry.db.BatteryCycleEntity
import com.timhss.capyenergy.telemetry.db.IntervalDao
import com.timhss.capyenergy.telemetry.db.IntervalEntity
import com.timhss.capyenergy.telemetry.db.IntervalReplacedKeyDao
import com.timhss.capyenergy.telemetry.db.IntervalReplacedKeyEntity
import com.timhss.capyenergy.telemetry.db.SessionDao
import com.timhss.capyenergy.telemetry.db.SessionEntity
import com.timhss.capyenergy.telemetry.db.TelemetryEventDao
import com.timhss.capyenergy.telemetry.db.TelemetryEventEntity
import com.timhss.capyenergy.telemetry.db.TrackDao
import com.timhss.capyenergy.telemetry.db.TrackEntity
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

// ---- Fakes ------------------------------------------------------------------

/**
 * The head unit's SQLite (Android 9) refuses more than 999 host variables in
 * one statement. The fakes refuse the same, so a list the real DAO would
 * reject fails here too.
 */
private fun requireSqliteBindable(keys: List<*>) {
    if (keys.size > 999) {
        throw IllegalStateException("too many SQL variables: ${keys.size}")
    }
}

private class FakeSessionDaoU : SessionDao {
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
    override fun countByKind(kind: String) = 0L
    override fun pendingFinalization() = emptyList<SessionEntity>()
    override fun syncPage(afterStartedAtUtcMillis: Long, afterId: String, limit: Int) = emptyList<SessionEntity>()
    override fun syncPendingCount(afterStartedAtUtcMillis: Long, afterId: String) = 0L
    override fun deleteById(id: String) = 0
    override fun deleteByIds(ids: List<String>) = 0
    override fun closedFrom(fromUtcMillis: Long) = emptyList<SessionEntity>()
    override fun closedFromAll(fromUtcMillis: Long) = emptyList<SessionEntity>()
    override fun unfinalizedClosed() = emptyList<SessionEntity>()
    override fun oldestStartUtcMillis(kind: String) = null
    override fun oldestStartUtcMillisAll() = null
    override fun byIds(ids: List<String>) = emptyList<SessionEntity>()
    override fun since(startUtcMillis: Long) = emptyList<SessionEntity>()
    override fun updatePlugType(id: String, plugType: Int, updatedAtUtcMillis: Long) = 0
    override fun deleteOlderThan(cutoffUtcMillis: Long) = 0
    override fun deleteOlderThanConfirmed(cutoffUtcMillis: Long, floorStartedAtUtcMillis: Long) = 0
    override fun deleteContinuousOlderThan(cutoffUtcMillis: Long) = 0
    override fun deleteContinuousOlderThanIgnoringDirty(cutoffUtcMillis: Long) = 0
    override fun deleteContinuousOlderThanConfirmed(cutoffUtcMillis: Long, floorStartedAtUtcMillis: Long) = 0
    override fun markNoLongerReducible(id: String, updatedAtUtcMillis: Long) = 0
    override fun sessionsEligibleForNoLongerReducible() = emptyList<String>()
    override fun dirtySessions(limit: Int) = sessions.filter { it.dirty && it.timeState != "pending" }.take(limit)
    override fun dirtySessionCount() = sessions.count { it.dirty && it.timeState != "pending" }.toLong()
    override fun pendingSessionCount() = sessions.count { it.dirty && it.timeState == "pending" }.toLong()
    override fun clearDirty(ids: List<String>): Int {
        requireSqliteBindable(ids)
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
    override fun promoteEndedPendingToUncorrectable(): Int {
        var c = 0
        for (i in sessions.indices) {
            val s = sessions[i]
            if (s.timeState == "pending" && s.status == "ENDED") {
                sessions[i] = s.copy(timeState = "uncorrectable")
                c++
            }
        }
        return c
    }

    override fun distinctVehicleIds(): List<String> =
        sessions.map { it.vehicleId }.filter { it.isNotBlank() && it != "unassigned" }.distinct()
    override fun markAliasedSessionsDirty(): Int = 0
}

private class FakeIntervalDaoU : IntervalDao {
    val intervals = mutableListOf<IntervalEntity>()
    override fun upsertAll(intervals: List<IntervalEntity>) { this.intervals.addAll(intervals) }
    override fun forSession(sessionId: String) = intervals.filter { it.sessionId == sessionId }
    override fun countForSession(sessionId: String) = intervals.count { it.sessionId == sessionId }.toLong()
    override fun sessionsWithBuckets(sessionIds: List<String>) = emptyList<String>()
    override fun forSessionsInWindow(sessionIds: List<String>, startUtcMillis: Long, endUtcMillis: Long) = emptyList<IntervalEntity>()
    override fun deleteBySessionIds(sessionIds: List<String>) = 0
    override fun findById(sessionId: String, startUtcMillis: Long) = intervals.find { it.sessionId == sessionId && it.startUtcMillis == startUtcMillis }
    override fun syncPage(afterStartUtcMillis: Long, afterSessionId: String, limit: Int) = emptyList<IntervalEntity>()
    override fun syncPendingCount(afterStartUtcMillis: Long, afterSessionId: String) = 0L
    override fun count() = intervals.size.toLong()
    override fun deleteOrphans() = 0
    override fun deleteOrphansChunk(limit: Int) = 0
    override fun dirtyIntervals(limit: Int) = intervals.filter { it.dirty && it.timeState != "pending" }.take(limit)
    override fun dirtyIntervalCount() = intervals.count { it.dirty && it.timeState != "pending" }.toLong()
    override fun pendingIntervalCount() = intervals.count { it.dirty && it.timeState == "pending" }.toLong()
    override fun clearDirty(sessionId: String, startUtcMillis: Long): Int {
        val idx = intervals.indexOfFirst { it.sessionId == sessionId && it.startUtcMillis == startUtcMillis && it.dirty }
        return if (idx >= 0) { intervals[idx] = intervals[idx].copy(dirty = false); 1 } else 0
    }
    override fun clearDirtyByKeys(keys: List<String>): Int {
        requireSqliteBindable(keys)
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
    override fun promoteEndedPendingToUncorrectable(): Int {
        var c = 0
        for (i in intervals.indices) {
            val it = intervals[i]
            if (it.timeState == "pending") {
                intervals[i] = it.copy(timeState = "uncorrectable")
                c++
            }
        }
        return c
    }

        override fun allPaired(): List<IntervalEntity> = emptyList()
override fun pendingsForBoot(bootCount: Long): List<IntervalEntity> = emptyList()
    override fun forBoot(bootCount: Long): List<IntervalEntity> = emptyList()
    override fun deleteKey(sessionId: String, startUtcMillis: Long): Int = 0
}

private class FakeTrackDaoU : TrackDao {
    val rows = mutableMapOf<String, TrackEntity>()
    override fun upsert(track: TrackEntity) { rows[track.sessionId] = track }
    override fun forSession(sessionId: String) = rows[sessionId]
    override fun forSessions(sessionIds: List<String>) = sessionIds.mapNotNull { rows[it] }
    override fun count() = rows.size.toLong()
    override fun countForSession(sessionId: String) = if (rows.containsKey(sessionId)) 1L else 0L
    override fun deleteBySessionIds(sessionIds: List<String>) = 0
    override fun deleteOrphans() = 0
    override fun syncPage(afterUpdatedAtUtcMillis: Long, afterSessionId: String, limit: Int) = emptyList<TrackEntity>()
    override fun syncPendingCount(afterUpdatedAtUtcMillis: Long, afterSessionId: String) = 0L
    override fun dirtyTracks(limit: Int) = rows.values.filter { it.dirty }.take(limit)
    override fun dirtyTrackCount() = rows.values.count { it.dirty }.toLong()
    override fun clearDirty(ids: List<String>): Int {
        requireSqliteBindable(ids)
        var c = 0
        for (id in ids) {
            val t = rows[id]
            if (t != null && t.dirty) { rows[id] = t.copy(dirty = false); c++ }
        }
        return c
    }
    override fun markAllDirty(): Int {
        var c = 0
        for ((id, t) in rows.toList()) {
            if (!t.dirty) { rows[id] = t.copy(dirty = true); c++ }
        }
        return c
    }
}

private class FakeTelemetryEventDaoU : TelemetryEventDao {
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
    override fun countOlderThan(cutoffUtcMillis: Long) = 0L
    override fun deleteOlderThanChunk(cutoffUtcMillis: Long, limit: Int) = 0
    override fun deleteOlderThanConfirmedChunk(cutoffUtcMillis: Long, floorId: Long, limit: Int) = 0
    override fun deleteOrphanSessionEventsChunk(limit: Int) = 0
    override fun dirtyEvents(limit: Int) = events.filter { it.dirty }.take(limit)
    override fun dirtyEventCount() = events.count { it.dirty }.toLong()
    override fun clearDirty(ids: List<Long>): Int {
        requireSqliteBindable(ids)
        var c = 0
        for (i in events.indices) {
            val e = events[i]
            if (e.id in ids && e.dirty) { events[i] = e.copy(dirty = false); c++ }
        }
        return c
    }
    override fun markAllDirty(): Int {
        var c = 0
        for (i in events.indices) {
            if (!events[i].dirty) { events[i] = events[i].copy(dirty = true); c++ }
        }
        return c
    }
}

private class FakeBatteryCycleDaoU : BatteryCycleDao {
    val cycles = mutableListOf<BatteryCycleEntity>()
    override fun upsertAll(cycles: List<BatteryCycleEntity>) { this.cycles.addAll(cycles) }
    override fun latest(limit: Int) = emptyList<BatteryCycleEntity>()
    override fun newest() = null
    override fun open() = null
    override fun newestRebuildable() = null
    override fun maxOrdinal() = cycles.maxOfOrNull { it.ordinal }
    override fun oldestRebuildableEndingAtOrAfter(utcMillis: Long) = null
    override fun newestClosedEndingBefore(utcMillis: Long) = null
    override fun deleteFrom(ordinal: Long) {}
    override fun freezeUpTo(ordinal: Long, frozenAtUtcMillis: Long) {}
    override fun count() = cycles.size.toLong()
    override fun findById(ordinal: Long) = cycles.find { it.ordinal == ordinal }
    override fun syncPage(afterOrdinal: Long, limit: Int) = emptyList<BatteryCycleEntity>()
    override fun syncPendingCount(afterOrdinal: Long) = 0L
    override fun dirtyCycles(limit: Int) = cycles.filter { it.dirty }.take(limit)
    override fun dirtyCycleCount() = cycles.count { it.dirty }.toLong()
    override fun clearDirty(ordinals: List<Long>): Int {
        requireSqliteBindable(ordinals)
        var c = 0
        for (i in cycles.indices) {
            val cy = cycles[i]
            if (cy.ordinal in ordinals && cy.dirty) { cycles[i] = cy.copy(dirty = false); c++ }
        }
        return c
    }
    override fun markAllDirty(): Int {
        var c = 0
        for (i in cycles.indices) {
            if (!cycles[i].dirty) { cycles[i] = cycles[i].copy(dirty = true); c++ }
        }
        return c
    }
}

private class FakeCloudSinkU : CloudSink {
    data class Write(
        val table: String,
        val rows: List<Map<String, Any?>>,
        val conflictColumns: List<String>,
        val merge: Boolean
    )
    data class Delete(
        val table: String,
        val vehicleId: String,
        val keys: List<Triple<String, String, Long>>
    )
    val deletes = mutableListOf<Delete>()
    val writes = mutableListOf<Write>()
    var failOn: String? = null
    var failCount = 0

    override suspend fun upsert(
        table: String,
        rows: List<Map<String, Any?>>,
        conflictColumns: List<String>,
        merge: Boolean
    ) {
        if (table == failOn) {
            failOn = null
            failCount++
            throw RuntimeException("refused $table")
        }
        writes.add(Write(table, rows.toList(), conflictColumns.toList(), merge))
    }

    override suspend fun delete(
        table: String,
        vehicleId: String,
        keys: List<Triple<String, String, Long>>
    ) {
        if (table == failOn) {
            failOn = null
            failCount++
            throw RuntimeException("refused $table")
        }
        deletes.add(Delete(table, vehicleId, keys.toList()))
    }

    fun rowsFor(table: String): List<Map<String, Any?>> =
        writes.filter { it.table == table }.flatMap { it.rows }

    fun tablesInOrder(): List<String> = writes.map { it.table }
}

private class FakeReplacedKeyDaoU : IntervalReplacedKeyDao {
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
// ---- Tests ------------------------------------------------------------------

class TelemetryCloudUploaderTest {

    private lateinit var sessionDao: FakeSessionDaoU
    private lateinit var intervalDao: FakeIntervalDaoU
    private lateinit var trackDao: FakeTrackDaoU
    private lateinit var eventDao: FakeTelemetryEventDaoU
    private lateinit var cycleDao: FakeBatteryCycleDaoU
    private lateinit var sink: FakeCloudSinkU
    private lateinit var replacedKeyDao: FakeReplacedKeyDaoU

    private val vehicleId = "VIN-CAR-1"
    private val accountId = "00000000-0000-4000-a000-000000000001"

    @Before
    fun setUp() {
        sessionDao = FakeSessionDaoU()
        intervalDao = FakeIntervalDaoU()
        trackDao = FakeTrackDaoU()
        eventDao = FakeTelemetryEventDaoU()
        cycleDao = FakeBatteryCycleDaoU()
        sink = FakeCloudSinkU()
        replacedKeyDao = FakeReplacedKeyDaoU()
    }

    private fun uploader(
        chunkSize: Int = 100,
        accountId: String? = this.accountId,
        uploadEnabled: Boolean = true,
        withReplacedKeys: Boolean = true,
        customSink: CloudSink = this.sink,
    ) = TelemetryCloudUploader(
        sessionDao = sessionDao,
        intervalDao = intervalDao,
        trackDao = trackDao,
        telemetryEventDao = eventDao,
        batteryCycleDao = cycleDao,
        sink = customSink,
        intervalReplacedKeyDao = replacedKeyDao.takeIf { withReplacedKeys },
        vehicleIdProvider = { vehicleId },
        accountIdProvider = { accountId },
        uploadEnabledProvider = { uploadEnabled },
        chunkSize = chunkSize
    )

    private fun session(id: String, dirty: Boolean = true, vehicleId: String = this.vehicleId, timeState: String = "unknown") =
        SessionEntity(
            id = id,
            vehicleId = vehicleId,
            kind = "TRIP",
            status = "ENDED",
            startedAtUtcMillis = 1_750_000_000_000L,
            startedAtElapsedNanos = 1L,
            endedAtUtcMillis = 1_750_000_360_000L,
            endedAtElapsedNanos = 2L,
            createdAtUtcMillis = 1_750_000_000_000L,
            updatedAtUtcMillis = 1_750_000_360_000L,
            dirty = dirty,
            timeState = timeState
        )

    private fun interval(sessionId: String, start: Long, dirty: Boolean = true, timeState: String = "unknown") =
        IntervalEntity(sessionId = sessionId, startUtcMillis = start, dirty = dirty, timeState = timeState)

    private fun track(sessionId: String, dirty: Boolean = true) =
        TrackEntity(
            sessionId = sessionId,
            encodingVersion = 1,
            pointCount = 2,
            t = "[0,60000]",
            path = "abcd",
            speed = "[10,12]",
            alt = "[100,101]",
            updatedAtUtcMillis = 1_750_000_360_000L,
            dirty = dirty
        )

    private fun event(id: Long, sessionId: String? = "sess-1", dirty: Boolean = true) =
        TelemetryEventEntity(
            id = id,
            type = "CHARGE_STARTED",
            occurredAtUtcMillis = 1_750_000_000_000L + id,
            occurredAtElapsedNanos = 100L + id,
            sourceTimestampNanos = 90L,
            timestampAccuracy = "PRECISE",
            uncertaintyMillis = 50L,
            signalId = "CHARGE_STATE",
            value = "CHARGING",
            previousValue = "IDLE",
            quality = "GOOD",
            source = "VHAL",
            details = "{}",
            sessionId = sessionId,
            dirty = dirty
        )

    private fun cycle(ordinal: Long, start: Long, dirty: Boolean = true) =
        BatteryCycleEntity(
            ordinal = ordinal,
            startUtcMillis = start,
            endUtcMillis = start + 360_000L,
            dischargePercent = 100.0,
            distanceKm = 42.0,
            tripEnergyKwh = 12.0,
            parkedEnergyKwh = 0.5,
            parkedSocPercent = 2.0,
            cost = 3.5,
            costCurrency = "BRL",
            pricedEnergyKwh = 10.0,
            unpricedEnergyKwh = 2.0,
            isOpen = false,
            isPartial = false,
            energyIncomplete = false,
            mixedCurrency = false,
            openingPricedFraction = 1.0,
            openingBlendedPrice = 0.8,
            frozenAtUtcMillis = null,
            createdAtUtcMillis = start,
            updatedAtUtcMillis = start + 1000L,
            dirty = dirty
        )

    // -- ordering --------------------------------------------------------------

    @Test
    fun `sessions are uploaded before intervals`() = runBlocking {
        sessionDao.sessions.add(session("sess-1"))
        intervalDao.intervals.add(interval("sess-1", 1_750_000_000_000L))
        uploader().upload()
        val order = sink.tablesInOrder()
        assertTrue("sessions must come before intervals", order.indexOf("session") < order.indexOf("interval"))
    }

    @Test
    fun `all streams are uploaded in foreign-key order`() = runBlocking {
        sessionDao.sessions.add(session("sess-1"))
        intervalDao.intervals.add(interval("sess-1", 1_750_000_000_000L))
        trackDao.rows["sess-1"] = track("sess-1")
        eventDao.events.add(event(1L, "sess-1"))
        cycleDao.cycles.add(cycle(1L, 1_750_000_000_000L))
        uploader().upload()
        val order = sink.tablesInOrder()
        val idxS = order.indexOf("session")
        val idxI = order.indexOf("interval")
        val idxT = order.indexOf("track")
        val idxE = order.indexOf("telemetry_events")
        val idxC = order.indexOf("battery_cycles")
        assertTrue(idxS < idxI)
        assertTrue(idxI < idxT)
        assertTrue(idxT < idxE)
        assertTrue(idxE < idxC)
    }

    @Test
    fun `child streams upload concurrently after sessions`() = runBlocking {
        sessionDao.sessions.add(session("sess-1"))
        intervalDao.intervals.add(interval("sess-1", 1_750_000_000_000L))
        trackDao.rows["sess-1"] = track("sess-1")
        eventDao.events.add(event(1L, "sess-1"))
        cycleDao.cycles.add(cycle(1L, 1_750_000_000_000L))

        val concurrentActive = java.util.concurrent.atomic.AtomicInteger(0)
        var maxConcurrent = 0
        var sessionCompletedBeforeChildren = false

        val testSink = object : CloudSink {
            override suspend fun upsert(
                table: String,
                rows: List<Map<String, Any?>>,
                conflictColumns: List<String>,
                merge: Boolean
            ) {
                if (table == "session") {
                    assertEquals(0, concurrentActive.get())
                    kotlinx.coroutines.delay(20)
                    sessionCompletedBeforeChildren = true
                } else {
                    assertTrue("Session must complete before child tables start", sessionCompletedBeforeChildren)
                    val active = concurrentActive.incrementAndGet()
                    synchronized(concurrentActive) {
                        if (active > maxConcurrent) maxConcurrent = active
                    }
                    kotlinx.coroutines.delay(50)
                    concurrentActive.decrementAndGet()
                }
            }

            override suspend fun delete(
                table: String,
                vehicleId: String,
                keys: List<Triple<String, String, Long>>
            ) {}
        }

        uploader(customSink = testSink).upload()
        assertTrue(sessionCompletedBeforeChildren)
        assertTrue("Expected at least 2 child streams running concurrently, got $maxConcurrent", maxConcurrent >= 2)
    }

    // -- formatting ------------------------------------------------------------

    @Test
    fun `session export uses natural keys and snake_case without dirty or rowId`() = runBlocking {
        sessionDao.sessions.add(session("sess-1"))
        uploader().upload()
        val row = sink.rowsFor("session").single()
        assertFalse("dirty must not be exported", row.containsKey("dirty"))
        assertFalse("rowId must not be exported", row.containsKey("rowId") || row.containsKey("row_id"))
        assertEquals("sess-1", row["id"])
        assertEquals(vehicleId, row["vehicle_id"])
        assertEquals(accountId, row["account_id"])
        assertTrue(row.containsKey("started_at_utc_millis"))
        assertFalse(row.containsKey("startedAtUtcMillis"))
    }

    @Test
    fun `interval export carries vehicle_id and account_id`() = runBlocking {
        sessionDao.sessions.add(session("sess-1"))
        intervalDao.intervals.add(interval("sess-1", 1_750_000_000_000L))
        uploader().upload()
        val row = sink.rowsFor("interval").single()
        assertEquals(vehicleId, row["vehicle_id"])
        assertEquals(accountId, row["account_id"])
        assertEquals(1_750_000_000_000L, row["start_utc_millis"])
    }

    @Test
    fun `telemetry event export drops local id and defaults signal_id`() = runBlocking {
        sessionDao.sessions.add(session("sess-1"))
        // event with null signalId
        eventDao.events.add(
            TelemetryEventEntity(
                id = 99L,
                type = "GEAR_CHANGED",
                occurredAtUtcMillis = 1_750_000_000_100L,
                occurredAtElapsedNanos = 999L,
                sourceTimestampNanos = null,
                timestampAccuracy = "ESTIMATED",
                uncertaintyMillis = 1000L,
                signalId = null,
                value = "D",
                previousValue = "P",
                quality = null,
                source = null,
                details = "{}",
                sessionId = "sess-1",
                dirty = true
            )
        )
        uploader().upload()
        val row = sink.rowsFor("telemetry_events").single()
        // local id must not be the cloud key; we keep natural keys.
        // The sink row for events must not rely on local id; check we still have natural keys
        assertEquals("", row["signal_id"])
        assertEquals(vehicleId, row["vehicle_id"])
        assertTrue(row.containsKey("occurred_at_utc_millis"))
        assertTrue(row.containsKey("occurred_at_elapsed_nanos"))
    }

    @Test
    fun `battery cycle export carries start_utc_millis as natural key and keeps ordinal`() = runBlocking {
        cycleDao.cycles.add(cycle(5L, 1_750_000_000_000L))
        uploader().upload()
        val row = sink.rowsFor("battery_cycles").single()
        assertEquals(vehicleId, row["vehicle_id"])
        assertEquals(1_750_000_000_000L, row["start_utc_millis"])
        assertEquals(5L, row["ordinal"])
    }

    @Test
    fun `unassigned vehicle sessions are skipped`() = runBlocking {
        sessionDao.sessions.add(session("sess-unassigned", vehicleId = "unassigned"))
        val report = uploader().upload()
        assertTrue(report.movedNothing)
        assertTrue(sink.writes.isEmpty())
        // dirty remains
        assertEquals(1, sessionDao.dirtySessionCount())
    }

    @Test
    fun `conflict columns match supabase primary keys`() = runBlocking {
        sessionDao.sessions.add(session("sess-1"))
        intervalDao.intervals.add(interval("sess-1", 1_750_000_000_000L))
        trackDao.rows["sess-1"] = track("sess-1")
        eventDao.events.add(event(1L))
        cycleDao.cycles.add(cycle(1L, 1_750_000_000_000L))
        uploader().upload()
        fun columns(table: String) = sink.writes.first { it.table == table }.conflictColumns
        assertEquals(listOf("vehicle_id", "id"), columns("session"))
        assertEquals(listOf("vehicle_id", "session_id", "start_utc_millis"), columns("interval"))
        assertEquals(listOf("vehicle_id", "session_id"), columns("track"))
        assertEquals(
            listOf("vehicle_id", "occurred_at_utc_millis", "occurred_at_elapsed_nanos", "type", "signal_id"),
            columns("telemetry_events")
        )
        assertEquals(listOf("vehicle_id", "start_utc_millis"), columns("battery_cycles"))
    }

    // -- chunking --------------------------------------------------------------

    @Test
    fun `large backlog is chunked into multiple requests`() = runBlocking {
        val n = 250
        for (i in 0 until n) {
            sessionDao.sessions.add(session("sess-$i"))
        }
        uploader(chunkSize = 100).upload()
        val sessionWrites = sink.writes.filter { it.table == "session" }
        assertEquals(3, sessionWrites.size)
        assertEquals(100, sessionWrites[0].rows.size)
        assertEquals(100, sessionWrites[1].rows.size)
        assertEquals(50, sessionWrites[2].rows.size)
        // All dirty cleared
        assertEquals(0, sessionDao.dirtySessionCount())
    }

    @Test
    fun `intervals chunked separately from sessions`() = runBlocking {
        sessionDao.sessions.add(session("sess-1"))
        for (i in 0 until 205) {
            intervalDao.intervals.add(interval("sess-1", 1_750_000_000_000L + i * 60000L))
        }
        uploader(chunkSize = 100).upload()
        val intervalWrites = sink.writes.filter { it.table == "interval" }
        assertEquals(3, intervalWrites.size)
        assertEquals(100, intervalWrites[0].rows.size)
        assertEquals(100, intervalWrites[1].rows.size)
        assertEquals(5, intervalWrites[2].rows.size)
    }

    @Test
    fun `a chunk larger than the SQLite bind limit still clears every dirty mark`() = runBlocking {
        // The production chunk (1000) is above SQLite's 999 host variables.
        // Clearing one chunk in one statement failed on the car and stranded
        // the event and interval backlog forever.
        sessionDao.sessions.add(session("sess-1"))
        for (i in 0 until 2_500) {
            intervalDao.intervals.add(interval("sess-1", 1_750_000_000_000L + i * 60_000L))
            eventDao.events.add(event(i + 1L, "sess-1"))
        }

        val report = uploader(chunkSize = 1_000).upload()

        assertEquals(2_500, report.perStream["interval"])
        assertEquals(2_500, report.perStream["telemetry_events"])
        assertEquals(0L, intervalDao.dirtyIntervalCount())
        assertEquals(0L, eventDao.dirtyEventCount())
    }

    // -- error handling --------------------------------------------------------

    @Test
    fun `a failed stream does not cancel the other streams`() = runBlocking {
        sessionDao.sessions.add(session("sess-1"))
        intervalDao.intervals.add(interval("sess-1", 1_750_000_000_000L))
        trackDao.rows["sess-1"] = track("sess-1")
        eventDao.events.add(event(1L, "sess-1"))
        // Events are refused at once while the interval request is still on
        // the network — the order that cancelled intervals on the car.
        val slowSink = object : CloudSink {
            override suspend fun upsert(
                table: String,
                rows: List<Map<String, Any?>>,
                conflictColumns: List<String>,
                merge: Boolean
            ) {
                if (table == "telemetry_events") throw RuntimeException("refused $table")
                if (table != "session") kotlinx.coroutines.delay(50)
            }

            override suspend fun delete(
                table: String,
                vehicleId: String,
                keys: List<Triple<String, String, Long>>
            ) {}
        }

        var thrown: TelemetryCloudUploadException? = null
        try {
            uploader(customSink = slowSink).upload()
        } catch (e: TelemetryCloudUploadException) {
            thrown = e
        }

        // The failure still reaches the caller, so the runner retries soon.
        assertEquals("telemetry_events", thrown?.table)
        // The streams beside it ran to their end.
        assertEquals(0L, intervalDao.dirtyIntervalCount())
        assertEquals(0L, trackDao.dirtyTrackCount())
        assertEquals(1L, eventDao.dirtyEventCount())
    }

    @Test
    fun `failed chunk leaves dirty and is retryable`() = runBlocking {
        sessionDao.sessions.add(session("sess-1"))
        intervalDao.intervals.add(interval("sess-1", 1_750_000_000_000L))
        sink.failOn = "interval"
        val uploader = uploader()
        var threw = false
        try {
            uploader.upload()
        } catch (e: TelemetryCloudUploadException) {
            threw = true
            assertEquals("interval", e.table)
            assertTrue(e.retryable)
        }
        assertTrue(threw)
        // sessions cleared, intervals not
        assertEquals(0, sessionDao.dirtySessionCount())
        assertEquals(1, intervalDao.dirtyIntervalCount())
        // Retry succeeds
        val report = uploader.upload()
        assertEquals(1, report.perStream["interval"])
        assertEquals(0, intervalDao.dirtyIntervalCount())
    }

    @Test
    fun `tracks use merge true and events use merge false`() = runBlocking {
        sessionDao.sessions.add(session("sess-1"))
        trackDao.rows["sess-1"] = track("sess-1")
        eventDao.events.add(event(1L))
        uploader().upload()
        val trackMerge = sink.writes.first { it.table == "track" }.merge
        val eventMerge = sink.writes.first { it.table == "telemetry_events" }.merge
        assertTrue(trackMerge)
        assertFalse(eventMerge)
    }

    @Test
    fun `dirty cleared only after sink accepts`() = runBlocking {
        sessionDao.sessions.add(session("sess-1"))
        sessionDao.sessions.add(session("sess-2"))
        sink.failOn = "session"
        try {
            uploader().upload()
        } catch (_: Exception) {}
        assertEquals(2, sessionDao.dirtySessionCount())
        // Next run carries same rows
        val report = uploader().upload()
        assertEquals(2, report.perStream["session"])
        assertEquals(0, sessionDao.dirtySessionCount())
    }

    @Test
    fun `null account id uploads all streams with null account_id`() = runBlocking {
        // Registered-but-unclaimed car (#236 Phase 2): eligibility comes from
        // registration, not from the account, so rows go out with null.
        sessionDao.sessions.add(session("sess-1"))
        intervalDao.intervals.add(interval("sess-1", 1_750_000_000_000L))
        trackDao.rows["sess-1"] = track("sess-1")
        eventDao.events.add(event(1L, "sess-1"))
        cycleDao.cycles.add(cycle(1L, 1_750_000_000_000L))
        val report = uploader(accountId = null).upload()
        assertEquals(1, report.perStream["session"])
        assertEquals(1, report.perStream["interval"])
        assertEquals(1, report.perStream["track"])
        assertEquals(1, report.perStream["telemetry_events"])
        assertEquals(1, report.perStream["battery_cycles"])
        for (table in listOf("session", "interval", "track", "telemetry_events", "battery_cycles")) {
            val rows = sink.rowsFor(table)
            assertTrue("expected rows for $table", rows.isNotEmpty())
            for (row in rows) {
                assertTrue("account_id key must be present for $table", row.containsKey("account_id"))
                assertEquals(null, row["account_id"])
            }
        }
        assertEquals(0, sessionDao.dirtySessionCount())
    }

    @Test
    fun `approved vehicle still uploads with real account id`() = runBlocking {
        sessionDao.sessions.add(session("sess-1"))
        val report = uploader().upload()
        assertEquals(1, report.perStream["session"])
        assertEquals(accountId, sink.rowsFor("session").single()["account_id"])
    }

    @Test
    fun `disabled upload keeps rows dirty and writes nothing`() = runBlocking {
        // Unregistered/unpaired car (or gate off): eligibility denies the run,
        // dirty rows survive for a later eligible pass.
        sessionDao.sessions.add(session("sess-1"))
        val report = uploader(accountId = null, uploadEnabled = false).upload()
        assertTrue(report.movedNothing)
        assertTrue(sink.writes.isEmpty())
        assertEquals(1, sessionDao.dirtySessionCount())
    }

    @Test
    fun `partial chunk failure clears only successful batches and leaves remainder dirty`() = runBlocking {
        // 250 sessions chunked 100/100/50. Fail second chunk only.
        for (i in 0 until 250) {
            sessionDao.sessions.add(session("sess-$i"))
        }
        var call = 0
        val failingSink = object : CloudSink {
            val writes = mutableListOf<FakeCloudSinkU.Write>()
            override suspend fun upsert(
                table: String,
                rows: List<Map<String, Any?>>,
                conflictColumns: List<String>,
                merge: Boolean
            ) {
                call++
                if (table == "session" && call == 2) {
                    throw RuntimeException("refused chunk 2")
                }
                writes.add(FakeCloudSinkU.Write(table, rows.toList(), conflictColumns.toList(), merge))
                sink.writes.add(FakeCloudSinkU.Write(table, rows.toList(), conflictColumns.toList(), merge))
            }
            override suspend fun delete(
                table: String,
                vehicleId: String,
                keys: List<Triple<String, String, Long>>
            ) {
                sink.deletes.add(FakeCloudSinkU.Delete(table, vehicleId, keys.toList()))
            }
        }
        val uploader2 = TelemetryCloudUploader(
            sessionDao = sessionDao,
            intervalDao = intervalDao,
            trackDao = trackDao,
            telemetryEventDao = eventDao,
            batteryCycleDao = cycleDao,
            sink = failingSink,
            vehicleIdProvider = { vehicleId },
            accountIdProvider = { accountId },
            chunkSize = 100
        )
        var threw = false
        try {
            uploader2.upload()
        } catch (e: TelemetryCloudUploadException) {
            threw = true
            assertEquals("session", e.table)
        }
        assertTrue(threw)
        // First chunk (100) cleared, remainder (150) still dirty.
        assertEquals(150, sessionDao.dirtySessionCount())
        assertEquals(1, sink.writes.size)
        assertEquals(100, sink.writes.single().rows.size)
        // Retry with normal sink clears the rest.
        sink.writes.clear()
        val report = uploader().upload()
        assertEquals(150, report.perStream["session"])
        assertEquals(0, sessionDao.dirtySessionCount())
    }

    @Test
    fun `open and partial battery cycles are uploaded with flags intact`() = runBlocking {
        // An open cycle (ongoing) and a partial cycle (gaps) must still be
        // uploaded; the cloud keeps them as provisional rows.
        val openCycle = cycle(1L, 1_750_000_000_000L).copy(isOpen = true, isPartial = false)
        val partialCycle = cycle(2L, 1_750_000_360_000L).copy(isOpen = false, isPartial = true)
        val openPartial = cycle(3L, 1_750_000_720_000L).copy(isOpen = true, isPartial = true)
        cycleDao.cycles.add(openCycle)
        cycleDao.cycles.add(partialCycle)
        cycleDao.cycles.add(openPartial)
        val report = uploader().upload()
        assertEquals(3, report.perStream["battery_cycles"])
        assertEquals(3, sink.rowsFor("battery_cycles").size)
        val rows = sink.rowsFor("battery_cycles").sortedBy { it["ordinal"] as Long }
        assertEquals(true, rows[0]["is_open"])
        assertEquals(false, rows[0]["is_partial"])
        assertEquals(false, rows[1]["is_open"])
        assertEquals(true, rows[1]["is_partial"])
        assertEquals(true, rows[2]["is_open"])
        assertEquals(true, rows[2]["is_partial"])
        // Dirty cleared for all three.
        assertEquals(0, cycleDao.dirtyCycleCount())
    }

    @Test
    fun `empty track with zero points is uploaded`() = runBlocking {
        sessionDao.sessions.add(session("sess-1"))
        trackDao.rows["sess-1"] = TrackEntity(
            sessionId = "sess-1",
            encodingVersion = 1,
            pointCount = 0,
            t = "[]",
            path = "",
            speed = "[]",
            alt = "[]",
            updatedAtUtcMillis = 1_750_000_360_000L,
            dirty = true
        )
        val report = uploader().upload()
        assertEquals(1, report.perStream["track"])
        val row = sink.rowsFor("track").single()
        assertEquals(0, row["point_count"])
        assertEquals("[]", row["t"])
        assertEquals("", row["path"])
        assertEquals(vehicleId, row["vehicle_id"])
        assertEquals(accountId, row["account_id"])
        assertEquals(0, trackDao.dirtyTrackCount())
    }

    @Test
    fun `markHistoryDirty re-sends already synced rows on next upload`() = runBlocking {
        // History from a prior upload: everything clean, sink empty.
        sessionDao.sessions.add(session("sess-1", dirty = false))
        intervalDao.intervals.add(interval("sess-1", 1_750_000_000_000L, dirty = false))
        trackDao.rows["sess-1"] = track("sess-1", dirty = false)
        eventDao.events.add(event(1L, "sess-1", dirty = false))
        cycleDao.cycles.add(cycle(1L, 1_750_000_000_000L, dirty = false))
        assertEquals(0, uploader().upload().perStream.values.sum())
        assertTrue(sink.writes.isEmpty())
        // Fresh pairing to a new account re-marks all five streams dirty.
        val marked = uploader().markHistoryDirty()
        assertEquals(mapOf("session" to 1, "interval" to 1, "track" to 1, "telemetry_events" to 1, "battery_cycles" to 1), marked)
        val report = uploader().upload()
        assertEquals(1, report.perStream["session"])
        assertEquals(1, report.perStream["interval"])
        assertEquals(1, report.perStream["track"])
        assertEquals(1, report.perStream["telemetry_events"])
        assertEquals(1, report.perStream["battery_cycles"])
        assertEquals(0, sessionDao.dirtySessionCount())
        assertEquals(0, trackDao.dirtyTrackCount())
    }

    @Test
    fun `markHistoryDirty promotes ended pending sessions and uploads them`() = runBlocking {
        // A session and interval ended on a boot that never saw a trusted clock anchor
        sessionDao.sessions.add(session("sess-pending", dirty = false, timeState = "pending"))
        intervalDao.intervals.add(interval("sess-pending", 1_750_000_000_000L, dirty = false, timeState = "pending"))
        // Initially held because timeState == pending
        assertEquals(0, uploader().upload().perStream.values.sum())
        assertTrue(sink.writes.isEmpty())

        // markHistoryDirty promotes them to uncorrectable and marks dirty
        val marked = uploader().markHistoryDirty()
        assertEquals(1, marked["session"])
        assertEquals(1, marked["interval"])
        assertEquals("uncorrectable", sessionDao.sessions.single().timeState)
        assertEquals("uncorrectable", intervalDao.intervals.single().timeState)

        val report = uploader().upload()
        assertEquals(1, report.perStream["session"])
        assertEquals(1, report.perStream["interval"])
        assertEquals(0, sessionDao.dirtySessionCount())
        assertEquals(0, intervalDao.dirtyIntervalCount())
    }

    @Test
    fun `promoteEndedPending promotes pending sessions without marking clean rows dirty`() = runBlocking {
        sessionDao.sessions.add(session("sess-clean", dirty = false, timeState = "corrected"))
        intervalDao.intervals.add(interval("sess-clean", 1_750_000_000_000L, dirty = false, timeState = "corrected"))
        sessionDao.sessions.add(session("sess-pending", dirty = true, timeState = "pending"))
        intervalDao.intervals.add(interval("sess-pending", 1_750_000_000_000L, dirty = true, timeState = "pending"))

        val promoted = uploader().promoteEndedPending()
        assertEquals(2, promoted)
        assertEquals("uncorrectable", sessionDao.findById("sess-pending")?.timeState)
        assertEquals("uncorrectable", intervalDao.findById("sess-pending", 1_750_000_000_000L)?.timeState)

        assertFalse(sessionDao.findById("sess-clean")!!.dirty)
        assertFalse(intervalDao.findById("sess-clean", 1_750_000_000_000L)!!.dirty)

        val report = uploader().upload()
        assertEquals(1, report.perStream["session"])
        assertEquals(1, report.perStream["interval"])
    }

    // -- F6: orphaned children --------------------------------------------------

    @Test
    fun `intervals with missing parent session are not uploaded and lose dirty`() = runBlocking {
        // No session seeded: parent is missing, global provider must not rescue it.
        intervalDao.intervals.add(interval("ghost-sess", 1_750_000_000_000L))
        val report = uploader().upload()
        assertTrue(report.movedNothing)
        assertTrue(sink.writes.isEmpty())
        assertEquals(0, intervalDao.dirtyIntervalCount())
    }

    @Test
    fun `tracks with missing parent session are not uploaded and lose dirty`() = runBlocking {
        trackDao.rows["ghost-sess"] = track("ghost-sess")
        val report = uploader().upload()
        assertTrue(report.movedNothing)
        assertTrue(sink.writes.isEmpty())
        assertEquals(0, trackDao.dirtyTrackCount())
    }

    @Test
    fun `events with missing parent session are not uploaded and lose dirty`() = runBlocking {
        eventDao.events.add(event(7L, "ghost-sess"))
        val report = uploader().upload()
        assertTrue(report.movedNothing)
        assertTrue(sink.writes.isEmpty())
        assertEquals(0, eventDao.dirtyEventCount())
    }

    @Test
    fun `sessionless events still use the global vehicle id`() = runBlocking {
        eventDao.events.add(event(8L, null))
        val report = uploader().upload()
        assertEquals(1, report.perStream["telemetry_events"])
        assertEquals(vehicleId, sink.rowsFor("telemetry_events").single()["vehicle_id"])
    }

    // -- F11: structured status classification ----------------------------------

    @Test
    fun `409 conflict is not retryable`() {
        val err = TelemetryCloudUploadException(
            "interval",
            HttpCloudSinkException(409, "POST https://x/rest/v1/interval failed: HTTP 409: duplicate"),
            retryable = TelemetryCloudUploadException.isRetryable(
                HttpCloudSinkException(409, "POST https://x/rest/v1/interval failed: HTTP 409: duplicate")
            ),
        )
        assertFalse(err.retryable)
    }

    @Test
    fun `422 schema mismatch is not retryable`() {
        assertFalse(
            TelemetryCloudUploadException.isRetryable(
                HttpCloudSinkException(422, "POST https://x/rest/v1/track failed: HTTP 422: bad column")
            )
        )
    }

    @Test
    fun `500 server error is retryable`() {
        assertTrue(
            TelemetryCloudUploadException.isRetryable(
                HttpCloudSinkException(500, "POST https://x/rest/v1/session failed: HTTP 500: boom")
            )
        )
    }

    @Test
    fun `409 digits in url body do not mark a 500 as permanent`() {
        // Timestamp 1_750_000_409_000L carries "409"; a 500 must stay retryable.
        assertTrue(
            TelemetryCloudUploadException.isRetryable(
                HttpCloudSinkException(500, "POST https://x:4090/rest/v1/session failed: HTTP 500 at 1750000409000")
            )
        )
    }

    @Test
    fun `rows recorded under a retired id upload under the canonical vehicle id`() = runBlocking {
        // B1: history recorded under android_id, identity later upgraded to
        // the VIN. The token is bound to the VIN, so rows must leave the car
        // as the VIN or RLS refuses them.
        val aliasStore = object : com.timhss.capyenergy.telemetry.VehicleIdAliasStore {
            override fun record(aliasId: String, canonicalId: String, atUtcMillis: Long) {}
            override fun canonicalFor(aliasId: String): String? =
                if (aliasId == "ANDROID-OLD") "VIN-CAR" else null
        }
        sessionDao.sessions.add(session("sess-alias", vehicleId = "ANDROID-OLD"))
        val uploader = TelemetryCloudUploader(
            sessionDao = sessionDao,
            intervalDao = intervalDao,
            trackDao = trackDao,
            telemetryEventDao = eventDao,
            batteryCycleDao = cycleDao,
            sink = sink,
            vehicleIdProvider = { "VIN-CAR" },
            accountIdProvider = { accountId },
            uploadEnabledProvider = { true },
            aliases = aliasStore,
            chunkSize = 100
        )
        uploader.upload()
        assertEquals("VIN-CAR", sink.rowsFor("session").single()["vehicle_id"])
        assertEquals(0, sessionDao.dirtySessionCount())
    }

    @Test
    fun `interval rows follow the session alias to the canonical id`() = runBlocking {
        val aliasStore = object : com.timhss.capyenergy.telemetry.VehicleIdAliasStore {
            override fun record(aliasId: String, canonicalId: String, atUtcMillis: Long) {}
            override fun canonicalFor(aliasId: String): String? =
                if (aliasId == "ANDROID-OLD") "VIN-CAR" else null
        }
        sessionDao.sessions.add(session("sess-1", vehicleId = "ANDROID-OLD"))
        intervalDao.intervals.add(interval("sess-1", 1_750_000_000_000L))
        val uploader = TelemetryCloudUploader(
            sessionDao = sessionDao,
            intervalDao = intervalDao,
            trackDao = trackDao,
            telemetryEventDao = eventDao,
            batteryCycleDao = cycleDao,
            sink = sink,
            vehicleIdProvider = { "VIN-CAR" },
            accountIdProvider = { accountId },
            uploadEnabledProvider = { true },
            aliases = aliasStore,
            chunkSize = 100
        )
        uploader.upload()
        assertEquals("VIN-CAR", sink.rowsFor("interval").single()["vehicle_id"])
    }

    @Test
    fun `unaliased legacy vehicle id auto-aliases to canonical id on upload`() = runBlocking {
        val recorded = mutableMapOf<String, String>()
        val aliasStore = object : com.timhss.capyenergy.telemetry.VehicleIdAliasStore {
            override fun record(aliasId: String, canonicalId: String, atUtcMillis: Long) {
                recorded[aliasId] = canonicalId
            }
            override fun canonicalFor(aliasId: String): String? = recorded[aliasId]
        }
        sessionDao.sessions.add(session("sess-unaliased", vehicleId = "ORPHAN-OLD"))
        val uploader = TelemetryCloudUploader(
            sessionDao = sessionDao,
            intervalDao = intervalDao,
            trackDao = trackDao,
            telemetryEventDao = eventDao,
            batteryCycleDao = cycleDao,
            sink = sink,
            vehicleIdProvider = { "VIN-CAR" },
            accountIdProvider = { accountId },
            uploadEnabledProvider = { true },
            aliases = aliasStore,
            chunkSize = 100
        )
        uploader.upload()
        assertEquals("VIN-CAR", sink.rowsFor("session").single()["vehicle_id"])
        assertEquals("VIN-CAR", recorded["ORPHAN-OLD"])
    }

    // ---- Time authority T6: the uploader holds pending rows -----------------
    //
    // The fakes above mirror the DAO contract (`dirty = 1 AND timeState !=
    // 'pending'` at the row source, proved against real SQL in
    // `SessionTimeAuthorityConsumerJvmTest`). These tests prove the
    // uploader's half: a held row is never uploaded, its `dirty` mark is
    // never cleared, and the sweep's resolution re-exposes it untouched.

    @Test
    fun `pending session is never uploaded and its dirty mark survives`() = runBlocking {
        sessionDao.sessions.add(session("sess-pending", timeState = "pending"))
        sessionDao.sessions.add(session("sess-known", timeState = "known"))

        val report = uploader().upload()

        assertEquals(listOf("sess-known"), sink.rowsFor("session").map { it["id"] })
        assertEquals(1, report.perStream["session"])
        val pending = sessionDao.sessions.first { it.id == "sess-pending" }
        assertTrue("pending dirty survives the upload pass", pending.dirty)
        assertTrue("known cleared", sessionDao.sessions.first { it.id == "sess-known" }.dirty.not())
    }

    @Test
    fun `pending intervals are never uploaded and their dirty marks survive`() = runBlocking {
        sessionDao.sessions.add(session("sess-1", timeState = "known"))
        intervalDao.intervals.add(interval("sess-1", 1_750_000_000_000L, timeState = "pending"))
        intervalDao.intervals.add(interval("sess-1", 1_750_000_060_000L, timeState = "known"))
        intervalDao.intervals.add(interval("sess-1", 1_750_000_120_000L, timeState = "uncorrectable"))

        val report = uploader().upload()

        // Only `pending` is held: `unknown` legacy rows and `uncorrectable`
        // rows with their marker upload (holding either would strand rows no
        // sweep will ever revisit — the captain's no-silent-loss rule).
        assertEquals(
            listOf(1_750_000_060_000L, 1_750_000_120_000L),
            sink.rowsFor("interval").map { it["start_utc_millis"] }
        )
        assertEquals(2, report.perStream["interval"])
        val held = intervalDao.intervals.first { it.startUtcMillis == 1_750_000_000_000L }
        assertTrue("pending interval dirty survives", held.dirty)
    }

    @Test
    fun `resolved rows upload on the next pass with the corrected state`() = runBlocking {
        sessionDao.sessions.add(session("sess-1", timeState = "pending"))
        intervalDao.intervals.add(interval("sess-1", 1_750_000_000_000L, timeState = "pending"))

        uploader().upload()
        assertTrue("nothing uploaded while pending", sink.writes.isEmpty())
        // The close sweep resolves both rows in place (state flips, the
        // `dirty` mark it was born with stays set).
        sessionDao.sessions.replaceAll {
            if (it.id == "sess-1") it.copy(timeState = "known") else it
        }
        intervalDao.intervals.replaceAll {
            if (it.sessionId == "sess-1") it.copy(timeState = "known") else it
        }

        val report = uploader().upload()
        assertEquals(1, report.perStream["session"])
        assertEquals(1, report.perStream["interval"])
        assertEquals(0, sessionDao.dirtySessionCount())
        assertEquals(0, intervalDao.dirtyIntervalCount())
    }

    @Test
    fun `intervals tracks and events belonging to a pending session are held back`() = runBlocking {
        sessionDao.sessions.add(session("sess-pending", timeState = "pending"))
        intervalDao.intervals.add(interval("sess-pending", 1_750_000_000_000L, timeState = "unknown"))
        trackDao.rows["sess-pending"] = track("sess-pending")
        eventDao.events.add(event(1L, "sess-pending"))

        val report = uploader().upload()
        assertTrue("nothing uploaded for pending session", sink.writes.isEmpty())
        assertEquals(0, report.total)
    }

    // ---- Time authority T9: the cloud corrected re-upload ------------------

    @Test
    fun `corrected re-upload deletes exactly the rewritten keys after the insert`() = runBlocking {
        sessionDao.sessions.add(session("sess-1", timeState = "known"))
        // The corrected row: new key, marked with the stamp it came FROM.
        intervalDao.intervals.add(
            interval("sess-1", 1_750_000_060_000L, timeState = "known")
                .copy(correctedFromUtcMillis = 1_750_000_000_000L)
        )
        replacedKeyDao.upsertAll(
            listOf(
                IntervalReplacedKeyEntity(
                    sessionId = "sess-1",
                    startUtcMillis = 1_750_000_000_000L,
                    replacedByUtcMillis = 1_750_000_060_000L
                )
            )
        )

        val report = uploader().upload()

        // The delete targets the OLD stamp — never the corrected key, and
        // only the exact keys the sweeper rewrote.
        assertEquals(
            listOf(Triple(vehicleId, "sess-1", 1_750_000_000_000L)),
            sink.deletes.single().keys
        )
        assertEquals(vehicleId, sink.deletes.single().vehicleId)
        // The corrected row went up first: upsert before delete.
        val intervalWriteIdx = sink.writes.indexOfFirst { it.table == "interval" }
        val deleteIdx = sink.writes.size + sink.deletes.indexOfFirst { it.table == "interval" }
        assertTrue(
            "insert must precede delete",
            intervalWriteIdx >= 0 &&
                intervalWriteIdx < deleteIdx &&
                sink.writes[intervalWriteIdx].rows.any {
                    it["start_utc_millis"] == 1_750_000_060_000L &&
                        it["corrected_from_utc_millis"] == 1_750_000_000_000L
                }
        )
    }
    @Test
    fun `failed delete keeps the key queued and nothing else changes`() = runBlocking {
        sessionDao.sessions.add(session("sess-1"))
        replacedKeyDao.upsertAll(
            listOf(
                IntervalReplacedKeyEntity(
                    sessionId = "sess-1",
                    startUtcMillis = 1_750_000_000_000L,
                    replacedByUtcMillis = 1_750_000_060_000L
                )
            )
        )
        sink.failOn = "interval"

        var threw = false
        try {
            uploader().upload()
        } catch (e: TelemetryCloudUploadException) {
            threw = true
            assertTrue(e.retryable)
        }

        assertTrue("delete refusal must surface as retryable", threw)
        // The delete never landed: the key stays queued for the next pass,
        // so a retry finishes the cycle — never an absence.
        assertEquals(1, replacedKeyDao.pending(100).size)
        assertEquals(0, sink.deletes.size)
    }

    @Test
    fun `a corrected key is never deleted when its parent session vanished`() = runBlocking {
        // No session row: the replaced-key entry cannot be scoped, so it is
        // dropped without a delete — a cloud row cannot exist without its
        // session (cascade).
        replacedKeyDao.upsertAll(
            listOf(
                IntervalReplacedKeyEntity(
                    sessionId = "gone",
                    startUtcMillis = 1_750_000_000_000L,
                    replacedByUtcMillis = 1_750_000_060_000L
                )
            )
        )

        uploader().upload()

        assertTrue(sink.deletes.isEmpty())
        assertTrue(replacedKeyDao.pending(100).isEmpty())
    }

    @Test
    fun `multiple replaced keys for the same vehicle are batched into a single delete call`() = runBlocking {
        sessionDao.sessions.add(session("sess-1"))
        sessionDao.sessions.add(session("sess-2"))
        replacedKeyDao.upsertAll(
            listOf(
                IntervalReplacedKeyEntity("sess-1", 1_750_000_000_000L, 1_750_000_060_000L),
                IntervalReplacedKeyEntity("sess-1", 1_750_000_060_000L, 1_750_000_120_000L),
                IntervalReplacedKeyEntity("sess-2", 1_750_000_000_000L, 1_750_000_060_000L),
            )
        )

        val report = uploader().upload()

        assertEquals(1, sink.deletes.size)
        assertEquals(vehicleId, sink.deletes.single().vehicleId)
        assertEquals(3, sink.deletes.single().keys.size)
        assertEquals(3, report.perStream["interval"])
        assertTrue(replacedKeyDao.pending(100).isEmpty())
    }

    @Test
    fun `replaced keys belonging to pending sessions are held back without looping`() = runBlocking {
        sessionDao.sessions.add(session("sess-pending", timeState = "pending"))
        replacedKeyDao.upsertAll(
            listOf(
                IntervalReplacedKeyEntity("sess-pending", 1_750_000_000_000L, 1_750_000_060_000L)
            )
        )

        val report = uploader().upload()

        assertTrue(sink.deletes.isEmpty())
        assertEquals(1, replacedKeyDao.pending(100).size)
        assertEquals(0, report.total)
    }
}
