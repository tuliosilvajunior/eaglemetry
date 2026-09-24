package com.timhss.capyenergy.telemetry

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.timhss.capyenergy.telemetry.db.IntervalEntity
import com.timhss.capyenergy.telemetry.db.SessionEntity
import com.timhss.capyenergy.telemetry.db.TelemetryDatabase
import java.io.IOException
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Finalization writes the terminal status and the rollup in one transaction.
 *
 * A process that dies in the middle must leave neither: the row stays
 * `FINALIZATION_PENDING` with no rollup, and the next boot finds it through
 * `pendingFinalization()` and completes it. The rollback is the whole point,
 * and only a real database can prove a transaction rolled back.
 */
@RunWith(AndroidJUnit4::class)
class SessionFinalizerInstrumentedTest {
    private lateinit var context: Context
    private lateinit var database: TelemetryDatabase

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        context.deleteDatabase(DATABASE_NAME)
        database = openDatabase()
    }

    @After
    fun tearDown() {
        database.close()
        context.deleteDatabase(DATABASE_NAME)
    }

    @Test
    fun interruptedTripFinalizationRollsBackAndRecoversAfterReopen() {
        database.sessionDao().upsert(pendingTrip())
        database.intervalDao().upsertAll(tripIntervals())
        val interrupted = SessionFinalizer(database, { 60_000.0 }) {
            throw IOException("simulated process interruption")
        }

        assertThrows(IOException::class.java) {
            interrupted.finalizeTrip(database.sessionDao().findById(TRIP_ID)!!)
        }
        val rolledBack = database.sessionDao().findById(TRIP_ID)
        assertEquals(SessionFinalizer.FINALIZATION_PENDING, rolledBack?.status)
        assertNull("the rollup must not survive a rolled-back commit", rolledBack?.rollupTractionWh)

        reopenDatabase()
        val pending = database.sessionDao().pendingFinalization().single()
        SessionFinalizer(database, { 60_000.0 }).finalizeTrip(pending)

        val finalized = database.sessionDao().findById(TRIP_ID)
        assertEquals("ENDED", finalized?.status)
        assertEquals(TRIP_TRACTION_WH, finalized?.rollupTractionWh!!, 0.001)
        assertEquals(TRIP_REGEN_WH, finalized.rollupRegenWh!!, 0.001)
        assertEquals(TRIP_DISTANCE_KM, finalized.rollupDistanceKm!!, 0.001)
    }

    @Test
    fun interruptedChargeFinalizationRollsBackAndRecoversAfterReopen() {
        database.sessionDao().upsert(pendingCharge())
        database.intervalDao().upsertAll(chargeIntervals())
        val interrupted = SessionFinalizer(database, { null }) {
            throw IOException("simulated process interruption")
        }

        assertThrows(IOException::class.java) {
            interrupted.finalizeCharge(database.sessionDao().findById(CHARGE_ID)!!)
        }
        val rolledBack = database.sessionDao().findById(CHARGE_ID)
        assertEquals(SessionFinalizer.FINALIZATION_PENDING, rolledBack?.status)
        assertNull("the rollup must not survive a rolled-back commit", rolledBack?.rollupDeliveredWh)

        reopenDatabase()
        val pending = database.sessionDao().pendingFinalization().single()
        SessionFinalizer(database, { null }).finalizeCharge(pending)

        val finalized = database.sessionDao().findById(CHARGE_ID)
        assertEquals("DISCONNECTED", finalized?.status)
        assertEquals(CHARGE_DELIVERED_WH, finalized?.rollupDeliveredWh!!, 0.001)
    }

    private fun reopenDatabase() {
        database.close()
        database = openDatabase()
    }

    private fun openDatabase(): TelemetryDatabase = Room.databaseBuilder(
        context,
        TelemetryDatabase::class.java,
        DATABASE_NAME
    ).allowMainThreadQueries().build()

    private fun pendingTrip() = SessionEntity(
        id = TRIP_ID,
        vehicleId = VEHICLE_ID,
        kind = "TRIP",
        status = SessionFinalizer.FINALIZATION_PENDING,
        startedAtUtcMillis = 100L,
        startedAtElapsedNanos = 1L,
        startedAtBootCount = SAME_BOOT,
        movementStartedAtUtcMillis = 100L,
        movementStartedAtElapsedNanos = 1L,
        movementStartedAtBootCount = SAME_BOOT,
        endedAtUtcMillis = 60_100L,
        endedAtElapsedNanos = 60_000_000_001L,
        endedAtBootCount = SAME_BOOT,
        startSocPercent = 80f,
        endSocPercent = 79f,
        startOdometerKm = 1_000f,
        endOdometerKm = 1_001f,
        startGear = 4,
        endReason = TripEndReason.PARK_CONFIRMED.name,
        createdAtUtcMillis = 100L,
        updatedAtUtcMillis = 60_100L
    )

    /** Two closed minutes. The fold of these is what the row must end up with. */
    private fun tripIntervals() = listOf(
        IntervalEntity(
            sessionId = TRIP_ID,
            startUtcMillis = 0L,
            tractionWh = 300.0,
            regenWh = 40.0,
            auxiliaryWh = 10.0,
            distanceKm = 0.6,
            coveredSeconds = 60.0,
            speedCoveredSeconds = 60.0
        ),
        IntervalEntity(
            sessionId = TRIP_ID,
            startUtcMillis = 60_000L,
            tractionWh = 200.0,
            regenWh = 25.0,
            auxiliaryWh = 5.0,
            distanceKm = 0.4,
            coveredSeconds = 60.0,
            speedCoveredSeconds = 60.0
        )
    )

    private fun pendingCharge() = SessionEntity(
        id = CHARGE_ID,
        vehicleId = VEHICLE_ID,
        kind = "CHARGE",
        status = SessionFinalizer.FINALIZATION_PENDING,
        startedAtUtcMillis = 100L,
        startedAtElapsedNanos = 1L,
        startedAtBootCount = SAME_BOOT,
        chargeStartedAtUtcMillis = 200L,
        chargeStartedAtElapsedNanos = 2L,
        chargeStartedAtBootCount = SAME_BOOT,
        chargeEndedAtUtcMillis = 3_600_200L,
        chargeEndedAtElapsedNanos = 3_600_000_000_002L,
        chargeEndedAtBootCount = SAME_BOOT,
        endedAtUtcMillis = 3_601_000L,
        endedAtElapsedNanos = 3_600_800_000_002L,
        endedAtBootCount = SAME_BOOT,
        plugDisconnectedAtUtcMillis = 3_601_000L,
        plugDisconnectedAtElapsedNanos = 3_600_800_000_002L,
        plugDisconnectedAtBootCount = SAME_BOOT,
        startSocPercent = 20f,
        endSocPercent = 30f,
        startOdometerKm = 1_000f,
        endOdometerKm = 1_000f,
        plugType = 2,
        startPowerKw = 7.2f,
        costCurrency = "BRL",
        endReason = "removed_after_end",
        createdAtUtcMillis = 100L,
        updatedAtUtcMillis = 3_601_000L
    )

    /** A charge folds the delivered term only. The four drive terms stay at zero. */
    private fun chargeIntervals() = listOf(
        IntervalEntity(
            sessionId = CHARGE_ID,
            startUtcMillis = 0L,
            deliveredWh = 1_200.0,
            deliveredCoveredSeconds = 60.0
        ),
        IntervalEntity(
            sessionId = CHARGE_ID,
            startUtcMillis = 60_000L,
            deliveredWh = 800.0,
            deliveredCoveredSeconds = 60.0
        )
    )

    private companion object {
        /** These fixtures live inside one boot, so no timeline repair applies. */
        const val SAME_BOOT = 1
        const val DATABASE_NAME = "session-finalizer-instrumented.db"
        const val VEHICLE_ID = "vehicle-under-test"
        const val TRIP_ID = "trip-pending"
        const val CHARGE_ID = "charge-pending"
        const val TERMINAL_FRAME_ELAPSED_NANOS = 3_600_800_000_002L
        const val TRIP_TRACTION_WH = 500.0
        const val TRIP_REGEN_WH = 65.0
        const val TRIP_DISTANCE_KM = 1.0
        const val CHARGE_DELIVERED_WH = 2_000.0
    }
}
