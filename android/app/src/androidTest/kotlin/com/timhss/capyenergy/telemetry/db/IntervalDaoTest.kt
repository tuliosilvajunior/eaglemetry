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
 * `deleteOrphans` proves an interval against one table now.
 *
 * Before the baseline it had to prove the session against three, and a kind it
 * forgot to name lost its intervals. The unified `session` makes the query one
 * `NOT IN`, and these cases keep every kind covered by it.
 */
@RunWith(AndroidJUnit4::class)
class IntervalDaoTest {
    private lateinit var context: Context
    private lateinit var database: TelemetryDatabase
    private lateinit var intervalDao: IntervalDao

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        database = Room.inMemoryDatabaseBuilder(context, TelemetryDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        intervalDao = database.intervalDao()
    }

    @After
    fun tearDown() {
        database.close()
    }

    @Test
    fun keepsIntervalsBelongingToChargeSessions() {
        database.sessionDao().upsert(
            session(
                id = "charge-1",
                kind = "CHARGE",
                status = "COMPLETED"
            ).copy(
                chargeStartedAtUtcMillis = 1_000L,
                chargeStartedAtElapsedNanos = 1L,
                chargeStartedAtBootCount = 1,
                chargeEndedAtUtcMillis = 2_000L,
                chargeEndedAtElapsedNanos = 2L,
                chargeEndedAtBootCount = 1,
                plugDisconnectedAtUtcMillis = 2_000L,
                plugDisconnectedAtElapsedNanos = 2L,
                plugDisconnectedAtBootCount = 1,
                startSocPercent = 50f,
                endSocPercent = 80f,
                plugType = 1,
                startPowerKw = 7f,
                chargeEndReason = "TARGET_REACHED",
                endReason = "UNPLUGGED"
            )
        )

        intervalDao.upsertAll(
            listOf(
                IntervalEntity(
                    sessionId = "charge-1",
                    startUtcMillis = 0L,
                    deliveredWh = 150.0,
                    deliveredCoveredSeconds = 60.0,
                    updatedAtUtcMillis = 1_060L
                )
            )
        )

        assertEquals(0, intervalDao.deleteOrphans())
        assertEquals(1L, intervalDao.countForSession("charge-1"))
    }

    @Test
    fun keepsIntervalsBelongingToParkedSessions() {
        database.sessionDao().upsert(
            session(
                id = "parked-1",
                kind = "PARKED",
                status = "ENDED"
            ).copy(
                startSocPercent = 80f,
                endSocPercent = 79.5f,
                lastSoc = 79.5f,
                endReason = "GEAR_LEFT_P",
                updatedAtElapsedNanos = 2_000_000_000L
            )
        )

        intervalDao.upsertAll(
            listOf(
                IntervalEntity(
                    sessionId = "parked-1",
                    startUtcMillis = 0L,
                    auxiliaryWh = 12.0,
                    coveredSeconds = 60.0,
                    speedCoveredSeconds = 60.0,
                    updatedAtUtcMillis = 1_060L
                )
            )
        )

        assertEquals(0, intervalDao.deleteOrphans())
        assertEquals(1L, intervalDao.countForSession("parked-1"))
    }

    @Test
    fun deletesIntervalsWhoseSessionDoesNotExist() {
        intervalDao.upsertAll(
            listOf(
                IntervalEntity(
                    sessionId = "non-existent-session",
                    startUtcMillis = 0L,
                    tractionWh = 10.0,
                    auxiliaryWh = 5.0,
                    distanceKm = 0.5,
                    coveredSeconds = 60.0,
                    speedCoveredSeconds = 60.0,
                    updatedAtUtcMillis = 1_060L
                )
            )
        )

        assertEquals(1, intervalDao.deleteOrphans())
        assertEquals(0L, intervalDao.countForSession("non-existent-session"))
    }

    private fun session(id: String, kind: String, status: String) = SessionEntity(
        id = id,
        vehicleId = VEHICLE_ID,
        kind = kind,
        status = status,
        startedAtUtcMillis = 1_000L,
        startedAtElapsedNanos = 1L,
        startedAtBootCount = 1,
        endedAtUtcMillis = 2_000L,
        endedAtElapsedNanos = 2L,
        endedAtBootCount = 1,
        startOdometerKm = 1_000f,
        endOdometerKm = 1_000f,
        startAmbientTempC = 25f,
        endAmbientTempC = 25f,
        createdAtUtcMillis = 1_000L,
        updatedAtUtcMillis = 2_000L
    )

    private companion object {
        const val VEHICLE_ID = "vehicle-under-test"
    }
}
