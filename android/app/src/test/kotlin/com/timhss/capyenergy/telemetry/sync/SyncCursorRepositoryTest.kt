package com.timhss.capyenergy.telemetry.sync

import com.timhss.capyenergy.telemetry.db.BatteryCycleDao
import com.timhss.capyenergy.telemetry.db.BatteryCycleEntity
import com.timhss.capyenergy.telemetry.db.IntervalDao
import com.timhss.capyenergy.telemetry.db.IntervalEntity
import com.timhss.capyenergy.telemetry.db.SessionDao
import com.timhss.capyenergy.telemetry.db.SessionEntity
import com.timhss.capyenergy.telemetry.db.SyncCursorDao
import com.timhss.capyenergy.telemetry.db.SyncCursorEntity
import com.timhss.capyenergy.telemetry.db.TelemetryEventDao
import com.timhss.capyenergy.telemetry.db.TelemetryEventEntity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class InMemorySyncCursorDao : SyncCursorDao {
    private val cursors = mutableMapOf<Pair<String, String>, SyncCursorEntity>()

    override fun upsert(cursor: SyncCursorEntity) {
        cursors[Pair(cursor.deviceId, cursor.streamType)] = cursor
    }

    override fun upsertAll(cursors: List<SyncCursorEntity>) {
        cursors.forEach { upsert(it) }
    }

    override fun getCursor(deviceId: String, streamType: String): SyncCursorEntity? =
        cursors[Pair(deviceId, streamType)]

    override fun getCursorsForDevice(deviceId: String): List<SyncCursorEntity> =
        cursors.values.filter { it.deviceId == deviceId }

    override fun getCursorsForStream(streamType: String): List<SyncCursorEntity> =
        cursors.values.filter { it.streamType == streamType }

    override fun getAllCursors(): List<SyncCursorEntity> = cursors.values.toList()

    override fun confirmedRecordIdsForStream(streamType: String): List<String> =
        cursors.values
            .filter { it.streamType == streamType }
            .mapNotNull { it.lastConfirmedRecordId }

    override fun deleteForDevice(deviceId: String): Int {
        val keysToRemove = cursors.keys.filter { it.first == deviceId }
        keysToRemove.forEach { cursors.remove(it) }
        return keysToRemove.size
    }

    override fun deleteCursor(deviceId: String, streamType: String): Int {
        return if (cursors.remove(Pair(deviceId, streamType)) != null) 1 else 0
    }

    override fun clearAll(): Int {
        val size = cursors.size
        cursors.clear()
        return size
    }
}

class SyncCursorRepositoryTest {
    private lateinit var dao: InMemorySyncCursorDao
    private lateinit var pairedDevices: MutableSet<String>
    private lateinit var repository: SyncCursorRepository

    private val existingSessions = mutableSetOf("session-100", "session-101", "session-102")
    private val existingEventIds = mutableSetOf(1L, 2L, 3L)
    private var maxCycleOrdinal: Long = 5

    @Before
    fun setUp() {
        dao = InMemorySyncCursorDao()
        pairedDevices = mutableSetOf("phone-1", "phone-2")

        val fakeSessionDao = FakeSessionDao().apply {
            existingSessions.forEach { add(createFakeSession(it)) }
        }

        val fakeCycleDao = object : BatteryCycleDao {
            override fun upsertAll(cycles: List<BatteryCycleEntity>) {}
            override fun latest(limit: Int): List<BatteryCycleEntity> = emptyList()
            override fun newest(): BatteryCycleEntity? = null
            override fun open(): BatteryCycleEntity? = null
            override fun newestRebuildable(): BatteryCycleEntity? = null
            override fun maxOrdinal(): Long? = maxCycleOrdinal
            override fun oldestRebuildableEndingAtOrAfter(utcMillis: Long): BatteryCycleEntity? = null
            override fun newestClosedEndingBefore(utcMillis: Long): BatteryCycleEntity? = null
            override fun deleteFrom(ordinal: Long) {}
            override fun freezeUpTo(ordinal: Long, frozenAtUtcMillis: Long) {}
            override fun count(): Long = maxCycleOrdinal
            override fun findById(ordinal: Long): BatteryCycleEntity? = null
            override fun syncPage(afterOrdinal: Long, limit: Int): List<BatteryCycleEntity> = emptyList()
            override fun syncPendingCount(afterOrdinal: Long): Long = 0
            override fun dirtyCycles(limit: Int): List<BatteryCycleEntity> = emptyList()
            override fun dirtyCycleCount(): Long = 0
            override fun clearDirty(ordinals: List<Long>): Int = 0
            override fun markAllDirty(): Int = 0
        }

        val fakeIntervalDao = FakeIntervalDao()

        val fakeEventDao = FakeTelemetryEventDao().apply {
            existingEventIds.forEach {
                add(
                    TelemetryEventEntity(
                        id = it,
                        type = "TRIP_ARMED",
                        occurredAtUtcMillis = 1000L,
                        occurredAtElapsedNanos = 1000000L,
                        sourceTimestampNanos = null,
                        timestampAccuracy = "INFERRED",
                        uncertaintyMillis = 0L,
                        signalId = "GEAR",
                        value = "4",
                        previousValue = null,
                        quality = null,
                        source = "VHAL_POLLING",
                        details = "gear=4"
                    )
                )
            }
        }

        repository = SyncCursorRepository(
            syncCursorDao = dao,
            isDevicePaired = { pairedDevices.contains(it) },
            sessionDao = fakeSessionDao,
            intervalDao = fakeIntervalDao,
            batteryCycleDao = fakeCycleDao,
            telemetryEventDao = fakeEventDao
        )
    }

    @Test
    fun `acknowledge unknown device returns Rejected`() {
        val ack = SyncAckRequest("unknown-phone", "sessions", "session-100", 1000L, 0, "p1", true)
        val result = repository.acknowledge(ack, nowUtcMillis = 1000L)
        assertTrue(result is SyncAckResult.Rejected)
    }

    @Test
    fun `acknowledge unknown stream returns Rejected`() {
        val ack = SyncAckRequest("phone-1", "nonExistentStream", "rec-1", 1000L, 0, "p1", true)
        val result = repository.acknowledge(ack, nowUtcMillis = 1000L)
        assertTrue(result is SyncAckResult.Rejected)
    }

    @Test
    fun `acknowledge nonexistent session record returns Rejected`() {
        val ack = SyncAckRequest("phone-1", "sessions", "non-existent-session", 1000L, 0, "p1", true)
        val result = repository.acknowledge(ack, nowUtcMillis = 1000L)
        assertTrue(result is SyncAckResult.Rejected)
    }

    @Test
    fun `acknowledge valid session updates cursor`() {
        val ack = SyncAckRequest("phone-1", "sessions", "session-100", 1000L, 0, "p1", true)
        val result = repository.acknowledge(ack, nowUtcMillis = 1000L)
        assertTrue(result is SyncAckResult.Applied)

        val cursor = repository.getCursor("phone-1", "sessions")
        assertNotNull(cursor)
        assertEquals("session-100", cursor?.lastConfirmedRecordId)
    }

    @Test
    fun `acknowledge valid event updates cursor`() {
        val ack = SyncAckRequest("phone-1", "events", "2", 1000L, 0, "p1", true)
        val result = repository.acknowledge(ack, nowUtcMillis = 1000L)
        assertTrue(result is SyncAckResult.Applied)

        val cursor = repository.getCursor("phone-1", "events")
        assertNotNull(cursor)
        assertEquals("2", cursor?.lastConfirmedRecordId)
    }

    @Test
    fun `acknowledge nonexistent event returns Rejected`() {
        val ack = SyncAckRequest("phone-1", "events", "999", 1000L, 0, "p1", true)
        val result = repository.acknowledge(ack, nowUtcMillis = 1000L)
        assertTrue(result is SyncAckResult.Rejected)
    }

    @Test
    fun `clearForDevice removes only that device's cursors`() {
        repository.acknowledge(
            SyncAckRequest("phone-1", "sessions", "session-100", 1000L, 0, "p1", true),
            nowUtcMillis = 1000L
        )
        repository.acknowledge(
            SyncAckRequest("phone-2", "sessions", "session-100", 1000L, 0, "p2", true),
            nowUtcMillis = 1000L
        )

        assertEquals(1, repository.getCursorsForDevice("phone-1").size)
        assertEquals(1, repository.getCursorsForDevice("phone-2").size)

        val deleted = repository.clearForDevice("phone-1")
        assertEquals(1, deleted)
        assertTrue(repository.getCursorsForDevice("phone-1").isEmpty())
        assertEquals(1, repository.getCursorsForDevice("phone-2").size)
    }

    private fun createFakeSession(id: String) = SessionEntity(
        id = id,
        vehicleId = "test-vehicle",
        kind = "TRIP",
        status = "ENDED",
        startedAtUtcMillis = 1000L,
        startedAtElapsedNanos = 1000L,
        startedAtBootCount = 1,
        endedAtUtcMillis = 2000L,
        endedAtElapsedNanos = 2000L,
        endedAtBootCount = 1,
        startSocPercent = 80f,
        endSocPercent = 70f,
        startOdometerKm = 100f,
        endOdometerKm = 120f,
        startGear = null,
        endReason = null,
        createdAtUtcMillis = 1000L,
        updatedAtUtcMillis = 2000L
    )
}
