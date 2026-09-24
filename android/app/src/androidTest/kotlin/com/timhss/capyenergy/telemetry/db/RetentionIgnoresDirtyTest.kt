package com.timhss.capyenergy.telemetry.db

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Retention is gated on the pending-upload mark.
 *
 * Once [com.timhss.capyenergy.telemetry.sync.TelemetryCloudUploader] clears
 * `dirty` per successful chunk, age deletes may safely require `dirty = 0`.
 * A row with `dirty = 1` has not reached the cloud and must survive its
 * cutoff (offline safety). See [TelemetryRetentionTest] for the full gate
 * matrix; this file keeps the original 6 cases but now expects the gate.
 *
 * Orphan sweeps stay ungated: an orphan interval/track names a session that
 * is already gone, and the cloud path resolves the vehicle through the
 * session, so the child could never be uploaded.
 */
@RunWith(AndroidJUnit4::class)
class RetentionIgnoresDirtyTest {
    private lateinit var context: Context
    private lateinit var database: TelemetryDatabase

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        database = Room.inMemoryDatabaseBuilder(context, TelemetryDatabase::class.java)
            .allowMainThreadQueries()
            .build()
    }

    @After
    fun tearDown() {
        database.close()
    }

    @Test
    fun aParkedSessionPastItsCutoffIsDeletedWhenClean() {
        database.sessionDao().upsert(parked("parked-clean", startedAt = 1_000L, dirty = false))
        assertEquals(1, database.sessionDao().deleteOlderThan(CUTOFF))
        assertEquals(0L, database.sessionDao().countByKind("PARKED"))
    }

    @Test
    fun aDirtyParkedSessionSurvivesItsCutoff() {
        database.sessionDao().upsert(parked("parked-dirty", startedAt = 1_000L, dirty = true))
        assertEquals(0, database.sessionDao().deleteOlderThan(CUTOFF))
        assertEquals(1L, database.sessionDao().countByKind("PARKED"))
    }

    @Test
    fun aParkedSessionBeforeItsCutoffSurvives() {
        database.sessionDao().upsert(parked("parked-young", startedAt = 1_000L, dirty = false))
        assertEquals(0, database.sessionDao().deleteOlderThan(500L))
        assertEquals(1L, database.sessionDao().countByKind("PARKED"))
    }

    @Test
    fun aContinuousSessionPastItsCutoffIsDeletedWhenClean() {
        database.sessionDao().upsert(continuous("cont-clean", startedAt = 1_000L, dirty = false))
        assertEquals(1, database.sessionDao().deleteContinuousOlderThan(CUTOFF))
        assertEquals(0L, database.sessionDao().countByKind("CONTINUOUS"))
    }

    @Test
    fun aDirtyContinuousSessionSurvivesItsCutoff() {
        database.sessionDao().upsert(continuous("cont-dirty", startedAt = 1_000L, dirty = true))
        assertEquals(0, database.sessionDao().deleteContinuousOlderThan(CUTOFF))
        assertEquals(1L, database.sessionDao().countByKind("CONTINUOUS"))
    }

    @Test
    fun anEventPastItsCutoffIsDeletedWhenClean() {
        database.telemetryEventDao().insert(event(id = 1, occurredAt = 1_000L, dirty = false))
        assertEquals(1, database.telemetryEventDao().deleteOlderThanChunk(CUTOFF, 2_000))
        assertEquals(0L, database.telemetryEventDao().count())
    }

    @Test
    fun aDirtyEventSurvivesItsCutoff() {
        database.telemetryEventDao().insert(event(id = 1, occurredAt = 1_000L, dirty = true))
        assertEquals(0, database.telemetryEventDao().deleteOlderThanChunk(CUTOFF, 2_000))
        assertEquals(1L, database.telemetryEventDao().count())
    }

    @Test
    fun orphanIntervalsAreDeletedEvenWhenDirty() {
        database.intervalDao().upsertAll(
            listOf(IntervalEntity(sessionId = "missing-session", startUtcMillis = 1_000L, dirty = true))
        )
        assertEquals(0L, database.sessionDao().count())
        assertEquals(1, database.intervalDao().deleteOrphans())
        assertEquals(0L, database.intervalDao().count())
    }

    @Test
    fun orphanTracksAreDeletedEvenWhenDirty() {
        database.trackDao().upsert(
            TrackEntity(
                sessionId = "missing-session",
                encodingVersion = 1,
                pointCount = 1,
                t = "[0]",
                path = "abcd",
                speed = "[0]",
                alt = "[0]",
                updatedAtUtcMillis = 1_000L,
                dirty = true
            )
        )
        assertEquals(0L, database.sessionDao().count())
        assertEquals(1, database.trackDao().deleteOrphans())
        assertEquals(0L, database.trackDao().count())
    }

    private fun parked(id: String, startedAt: Long, dirty: Boolean) = SessionEntity(
        id = id,
        vehicleId = "vehicle-under-test",
        kind = "PARKED",
        status = "ENDED",
        startedAtUtcMillis = startedAt,
        startedAtElapsedNanos = startedAt,
        endedAtUtcMillis = startedAt + 100L,
        endedAtElapsedNanos = startedAt + 100L,
        createdAtUtcMillis = startedAt,
        updatedAtUtcMillis = startedAt + 100L,
        dirty = dirty
    )

    private fun continuous(id: String, startedAt: Long, dirty: Boolean) = SessionEntity(
        id = id,
        vehicleId = "vehicle-under-test",
        kind = "CONTINUOUS",
        status = "ENDED",
        startedAtUtcMillis = startedAt,
        startedAtElapsedNanos = startedAt,
        endedAtUtcMillis = startedAt + 100L,
        endedAtElapsedNanos = startedAt + 100L,
        createdAtUtcMillis = startedAt,
        updatedAtUtcMillis = startedAt + 100L,
        dirty = dirty
    )

    private fun event(id: Long, occurredAt: Long, dirty: Boolean) = TelemetryEventEntity(
        id = id,
        type = "TRIP_ARMED",
        occurredAtUtcMillis = occurredAt,
        occurredAtElapsedNanos = occurredAt,
        sourceTimestampNanos = null,
        timestampAccuracy = "ACCURATE",
        uncertaintyMillis = 0,
        signalId = null,
        value = null,
        previousValue = null,
        quality = null,
        source = null,
        details = "{}",
        sessionId = null,
        dirty = dirty
    )

    private companion object {
        const val CUTOFF = 500_000L
    }
}
