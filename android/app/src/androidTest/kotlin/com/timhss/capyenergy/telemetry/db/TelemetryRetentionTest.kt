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
 * Retention must never prune a row that has not reached the cloud.
 *
 * Every measurement row is born `dirty = 1` (MIGRATION_42_43) and stays that
 * way until [com.timhss.capyenergy.telemetry.sync.TelemetryCloudUploader]
 * successfully writes its chunk to the sink and then calls `clearDirty`.
 * While `dirty == 1` the row is offline-only and retention must keep it,
 * whatever its age. Once `dirty == 0` the row has been uploaded and normal
 * age-based retention may delete it.
 *
 * Orphan sweeps are the exception: an orphan interval/track/trip segment
 * names a session that is already gone. The parent was itself gated on
 * `dirty = 0`, so the child can never be uploaded (vehicle lookup through
 * the session fails) and would leak forever. Orphans are GC, not retention,
 * and are not gated on dirty.
 */
@RunWith(AndroidJUnit4::class)
class TelemetryRetentionTest {
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

    // --- PARKED -----------------------------------------------------------

    @Test
    fun dirtyParkedSurvivesCutoff_offlineSafety() {
        database.sessionDao().upsert(parked("parked-dirty", startedAt = 1_000L, dirty = true))
        assertEquals(0, database.sessionDao().deleteOlderThan(CUTOFF))
        assertEquals(1L, database.sessionDao().countByKind("PARKED"))
    }

    @Test
    fun cleanParkedIsPruned_whenUploaded() {
        database.sessionDao().upsert(parked("parked-clean", startedAt = 1_000L, dirty = false))
        assertEquals(1, database.sessionDao().deleteOlderThan(CUTOFF))
        assertEquals(0L, database.sessionDao().countByKind("PARKED"))
    }

    @Test
    fun dirtyBecomesCleanThenPruned_endToEnd() {
        database.sessionDao().upsert(parked("parked-e2e", startedAt = 1_000L, dirty = true))
        assertEquals(0, database.sessionDao().deleteOlderThan(CUTOFF))
        // Simulate successful cloud upload clearing the mark.
        database.sessionDao().clearDirty(listOf("parked-e2e"))
        assertEquals(1, database.sessionDao().deleteOlderThan(CUTOFF))
        assertEquals(0L, database.sessionDao().countByKind("PARKED"))
    }

    @Test
    fun dirtyParkedConfirmedSurvivesEvenWithFloor() {
        database.sessionDao().upsert(parked("parked-dirty-conf", startedAt = 1_000L, dirty = true))
        // Even with a floor that would otherwise allow deletion, dirty must hold.
        assertEquals(0, database.sessionDao().deleteOlderThanConfirmed(CUTOFF, floorStartedAtUtcMillis = 10_000L))
        assertEquals(1L, database.sessionDao().countByKind("PARKED"))
    }

    @Test
    fun cleanParkedConfirmedIsPruned() {
        database.sessionDao().upsert(parked("parked-clean-conf", startedAt = 1_000L, dirty = false))
        assertEquals(1, database.sessionDao().deleteOlderThanConfirmed(CUTOFF, floorStartedAtUtcMillis = 10_000L))
        assertEquals(0L, database.sessionDao().countByKind("PARKED"))
    }

    // --- CONTINUOUS -------------------------------------------------------

    @Test
    fun dirtyContinuousSurvivesCutoff() {
        database.sessionDao().upsert(continuous("cont-dirty", startedAt = 1_000L, dirty = true))
        assertEquals(0, database.sessionDao().deleteContinuousOlderThan(CUTOFF))
        assertEquals(1L, database.sessionDao().countByKind("CONTINUOUS"))
    }

    @Test
    fun cleanContinuousIsPruned() {
        database.sessionDao().upsert(continuous("cont-clean", startedAt = 1_000L, dirty = false))
        assertEquals(1, database.sessionDao().deleteContinuousOlderThan(CUTOFF))
        assertEquals(0L, database.sessionDao().countByKind("CONTINUOUS"))
    }

    @Test
    fun dirtyContinuousConfirmedSurvives() {
        database.sessionDao().upsert(continuous("cont-dirty-conf", startedAt = 1_000L, dirty = true))
        assertEquals(0, database.sessionDao().deleteContinuousOlderThanConfirmed(CUTOFF, floorStartedAtUtcMillis = 10_000L))
        assertEquals(1L, database.sessionDao().countByKind("CONTINUOUS"))
    }

    @Test
    fun cleanContinuousConfirmedIsPruned() {
        database.sessionDao().upsert(continuous("cont-clean-conf", startedAt = 1_000L, dirty = false))
        assertEquals(1, database.sessionDao().deleteContinuousOlderThanConfirmed(CUTOFF, floorStartedAtUtcMillis = 10_000L))
        assertEquals(0L, database.sessionDao().countByKind("CONTINUOUS"))
    }

    // --- TELEMETRY EVENTS -------------------------------------------------

    @Test
    fun dirtyEventSurvivesCutoff() {
        database.telemetryEventDao().insert(event(id = 1, occurredAt = 1_000L, dirty = true))
        assertEquals(0, database.telemetryEventDao().deleteOlderThanChunk(CUTOFF, 2_000))
        assertEquals(1L, database.telemetryEventDao().count())
    }

    @Test
    fun cleanEventIsPruned() {
        database.telemetryEventDao().insert(event(id = 1, occurredAt = 1_000L, dirty = false))
        assertEquals(1, database.telemetryEventDao().deleteOlderThanChunk(CUTOFF, 2_000))
        assertEquals(0L, database.telemetryEventDao().count())
    }

    @Test
    fun dirtyEventConfirmedSurvives() {
        database.telemetryEventDao().insert(event(id = 1, occurredAt = 1_000L, dirty = true))
        assertEquals(0, database.telemetryEventDao().deleteOlderThanConfirmedChunk(CUTOFF, floorId = 10L, limit = 2_000))
        assertEquals(1L, database.telemetryEventDao().count())
    }

    @Test
    fun cleanEventConfirmedIsPruned() {
        database.telemetryEventDao().insert(event(id = 1, occurredAt = 1_000L, dirty = false))
        assertEquals(1, database.telemetryEventDao().deleteOlderThanConfirmedChunk(CUTOFF, floorId = 10L, limit = 2_000))
        assertEquals(0L, database.telemetryEventDao().count())
    }

    @Test
    fun dirtyEventBecomesCleanThenPruned() {
        database.telemetryEventDao().insert(event(id = 42, occurredAt = 1_000L, dirty = true))
        assertEquals(0, database.telemetryEventDao().deleteOlderThanChunk(CUTOFF, 2_000))
        database.telemetryEventDao().clearDirty(listOf(42L))
        assertEquals(1, database.telemetryEventDao().deleteOlderThanChunk(CUTOFF, 2_000))
        assertEquals(0L, database.telemetryEventDao().count())
    }

    // --- ORPHAN GC (ungated) ----------------------------------------------

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

    @Test
    fun mixedDirtyAndClean_onlyCleanPruned() {
        database.sessionDao().upsert(parked("parked-dirty-2", startedAt = 1_000L, dirty = true))
        database.sessionDao().upsert(parked("parked-clean-2", startedAt = 1_500L, dirty = false))
        assertEquals(1, database.sessionDao().deleteOlderThan(CUTOFF))
        assertEquals(1L, database.sessionDao().countByKind("PARKED"))
        assertEquals("parked-dirty-2", database.sessionDao().findByKind("PARKED").single().id)
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
