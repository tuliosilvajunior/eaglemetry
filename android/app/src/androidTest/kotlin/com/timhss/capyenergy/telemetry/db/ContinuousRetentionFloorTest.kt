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
 * Issue 199/206: `CONTINUOUS` is disposable the same way `PARKED` already is
 * (rule 2.7) — a session no device has confirmed is not deleted, whatever its
 * age. See [SyncCursorRetentionFloorTest] for the `PARKED` original; this
 * mirrors it for the fourth kind.
 */
@RunWith(AndroidJUnit4::class)
class ContinuousRetentionFloorTest {
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
    fun withNoCursorEveryExpiredContinuousSessionGoes() {
        seedThreeExpiredContinuousSessions()

        assertEquals(3, database.sessionDao().deleteContinuousOlderThan(CUTOFF))
        assertEquals(0L, database.sessionDao().countByKind("CONTINUOUS"))
    }

    @Test
    fun aConfirmedCursorHoldsBackEverythingAfterIt() {
        seedThreeExpiredContinuousSessions()
        confirmSessions("phone-a", "continuous-2")

        val floor = database.sessionDao().findById("continuous-2")!!.startedAtUtcMillis
        assertEquals(2, database.sessionDao().deleteContinuousOlderThanConfirmed(CUTOFF, floor))

        val left = database.sessionDao().findByKind("CONTINUOUS").map { it.id }
        assertEquals(listOf("continuous-3"), left)
    }

    @Test
    fun theLeastAdvancedDeviceSetsTheFloor() {
        seedThreeExpiredContinuousSessions()
        confirmSessions("phone-a", "continuous-3")
        confirmSessions("phone-b", "continuous-1")

        val ids = database.syncCursorDao().confirmedRecordIdsForStream("sessions")
        assertEquals(setOf("continuous-3", "continuous-1"), ids.toSet())

        val floor = ids.mapNotNull { database.sessionDao().findById(it)?.startedAtUtcMillis }.min()
        assertEquals(
            "only what phone-b confirmed may go",
            1,
            database.sessionDao().deleteContinuousOlderThanConfirmed(CUTOFF, floor)
        )
        assertEquals(
            "the phone that is behind governs",
            listOf("continuous-2", "continuous-3"),
            database.sessionDao().findByKind("CONTINUOUS").map { it.id }.sorted()
        )
    }

    @Test
    fun intervalsOrphanedByTheDeleteAreSwept() {
        database.sessionDao().upsert(continuous("continuous-1", startedAt = 1_000L))
        // Children uploaded (dirty = false): the parent is deletable and the
        // orphans sweep. Dirty children hold the parent back (Finding 5).
        database.intervalDao().upsertAll(
            listOf(
                IntervalEntity(sessionId = "continuous-1", startUtcMillis = 1_000L, tractionWh = 1.0, dirty = false),
                IntervalEntity(sessionId = "continuous-1", startUtcMillis = 61_000L, tractionWh = 1.0, dirty = false)
            )
        )

        assertEquals(1, database.sessionDao().deleteContinuousOlderThan(CUTOFF))
        assertEquals(2, database.intervalDao().deleteOrphans())
        assertEquals(0L, database.intervalDao().countForSession("continuous-1"))
    }

    @Test
    fun aDirtySessionSurvivesThePurge() {
        // Finding 13b: every seed before this was dirty = false, so dropping
        // the `AND dirty = 0` gate would still pass the whole file. A session
        // that has not reached the cloud yet must survive whatever its age.
        database.sessionDao().upsert(continuous("continuous-dirty", startedAt = 1_000L, dirty = true))

        assertEquals(0, database.sessionDao().deleteContinuousOlderThan(CUTOFF))
        assertEquals(1L, database.sessionDao().countByKind("CONTINUOUS"))
    }

    @Test
    fun aCleanSessionWithDirtyIntervalsSurvives() {
        // Finding 5: session uploaded, children not yet. Deleting the parent
        // would orphan dirty rows into the ungated deleteOrphans sweep.
        database.sessionDao().upsert(continuous("continuous-1", startedAt = 1_000L))
        database.intervalDao().upsertAll(
            listOf(
                IntervalEntity(sessionId = "continuous-1", startUtcMillis = 1_000L, tractionWh = 1.0, dirty = true),
                IntervalEntity(sessionId = "continuous-1", startUtcMillis = 61_000L, tractionWh = 1.0, dirty = false)
            )
        )

        assertEquals(0, database.sessionDao().deleteContinuousOlderThan(CUTOFF))
        assertEquals(1L, database.sessionDao().countByKind("CONTINUOUS"))
        assertEquals(2L, database.intervalDao().countForSession("continuous-1"))
    }


    @Test
    fun aSessionStillOpenKeepsItsIntervals() {
        // Not yet ended, so it must never be swept by age alone.
        database.sessionDao().upsert(
            continuous("continuous-open", startedAt = 1_000L).copy(
                endedAtUtcMillis = null,
                endedAtElapsedNanos = null
            )
        )
        database.intervalDao().upsertAll(
            listOf(IntervalEntity(sessionId = "continuous-open", startUtcMillis = 1_000L, tractionWh = 1.0))
        )

        assertEquals(0, database.sessionDao().deleteContinuousOlderThan(CUTOFF))
        assertEquals(0, database.intervalDao().deleteOrphans())
        assertEquals(1L, database.intervalDao().countForSession("continuous-open"))
    }

    @Test
    fun onlyContinuousRowsAreRemoved() {
        seedThreeExpiredContinuousSessions()
        database.sessionDao().upsert(
            SessionEntity(
                id = "trip-1",
                vehicleId = "vehicle-under-test",
                kind = "TRIP",
                status = "ENDED",
                startedAtUtcMillis = 1_000L,
                startedAtElapsedNanos = 1_000L,
                endedAtUtcMillis = 1_100L,
                endedAtElapsedNanos = 1_100L,
                createdAtUtcMillis = 1_000L,
                updatedAtUtcMillis = 1_100L
            )
        )

        database.sessionDao().deleteContinuousOlderThan(CUTOFF)

        assertEquals(1L, database.sessionDao().countByKind("TRIP"))
    }

    /** Three closed continuous sessions, all older than the cutoff, in order. */
    private fun seedThreeExpiredContinuousSessions() {
        database.sessionDao().upsertAll(
            listOf(
                continuous("continuous-1", startedAt = 1_000L),
                continuous("continuous-2", startedAt = 2_000L),
                continuous("continuous-3", startedAt = 3_000L)
            )
        )
    }

    private fun confirmSessions(deviceId: String, sessionId: String) {
        database.syncCursorDao().upsert(
            SyncCursorEntity(
                deviceId = deviceId,
                streamType = "sessions",
                lastConfirmedRecordId = sessionId,
                lastConfirmedHlcMillis = 10_000L,
                lastConfirmedHlcCounter = 0,
                lastConfirmedHlcDeviceId = deviceId,
                updatedAtUtcMillis = 10_000L
            )
        )
    }

    private fun continuous(id: String, startedAt: Long, dirty: Boolean = false) = SessionEntity(
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

    private companion object {
        /** Every seeded session ended long before this. */
        const val CUTOFF = 500_000L
    }
}
