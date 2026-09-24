package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.SessionAggregateSampleRow
import com.timhss.capyenergy.telemetry.db.SessionEntity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionAggregateCalculatorTest {
    @Test
    fun `trip applyFold sets rollups and soc agreement`() {
        val session = tripSession()
        val samples = (1L..61L).map { second ->
            sample(
                second,
                speedKmh = 60f,
                socPercent = 80f - ((second - 1L) / 6L) * 0.1f,
                canPackVoltageV = 400f,
                canPackCurrentA = 59.1f,
                canDrivePowerKw = 22.64f
            )
        }
        val rollup = EnergyRollup(
            tractionWh = 377.33,
            regenWh = 0.0,
            auxiliaryWh = 16.67,
            climateWh = 0.0,
            deliveredWh = 0.0,
            distanceKm = 1.0,
            integratedSeconds = 60.0
        )

        val folded = SessionAggregateCalculator.applyFold(
            session = session,
            rollup = rollup,
            samples = samples
        )

        assertEquals(1.0, folded.rollupDistanceKm!!, 1e-4)
        assertEquals(377.33, folded.rollupTractionWh!!, 0.5)
        assertEquals(0.0, folded.rollupRegenWh!!, 1e-4)
        assertEquals(16.67, folded.rollupAuxiliaryWh!!, 0.5)
        assertEquals("agrees", folded.socAgreesWithIntegral)

        val restored = folded.tripPowerIntegral()!!
        assertEquals(394.0, restored.packWh, 0.5)
        assertEquals(377.33, restored.tractionWh, 0.5)
        assertEquals(16.67, restored.auxiliaryWh, 0.5)
        assertEquals(60.0, restored.integratedSeconds, 1e-3)
    }

    @Test
    fun `trip applyFold flags an integral that contradicts SOC`() {
        val session = tripSession()
        val samples = (1L..61L).map { second ->
            sample(
                second,
                speedKmh = 60f,
                socPercent = 80f - ((second - 1L) / 6L) * 0.1f,
                canPackVoltageV = 400f,
                canPackCurrentA = -59.1f,
                canDrivePowerKw = 22.64f
            )
        }
        val rollup = EnergyRollup(
            tractionWh = 0.0,
            regenWh = 377.33,
            auxiliaryWh = 0.0,
            climateWh = 0.0,
            deliveredWh = 0.0,
            distanceKm = 1.0,
            integratedSeconds = 60.0
        )

        val folded = SessionAggregateCalculator.applyFold(
            session = session,
            rollup = rollup,
            samples = samples
        )

        assertEquals("contradicts", folded.socAgreesWithIntegral)
    }

    @Test
    fun `charge applyFold populates delivered rollup`() {
        val session = chargeSession()
        val samples = (5L..3605L step 5L).map { second ->
            sample(second, powerKw = 7.2f, voltageV = 400f, currentA = -18f)
        }
        val rollup = EnergyRollup(
            tractionWh = 0.0,
            regenWh = 0.0,
            auxiliaryWh = 0.0,
            climateWh = 0.0,
            deliveredWh = 7200.0,
            distanceKm = 0.0,
            integratedSeconds = 3600.0,
            deliveredIntegratedSeconds = 3600.0
        )

        val folded = SessionAggregateCalculator.applyFold(
            session = session,
            rollup = rollup,
            samples = samples
        )

        assertEquals(7200.0, folded.rollupDeliveredWh!!, 1.0)
        assertEquals(3600.0, folded.rollupIntegratedSeconds!!, 1.0)
    }

    private fun sample(
        seconds: Long,
        speedKmh: Float? = null,
        socPercent: Float? = null,
        voltageV: Float? = null,
        currentA: Float? = null,
        powerKw: Float? = null,
        canDrivePowerKw: Float? = null,
        canPackVoltageV: Float? = null,
        canPackCurrentA: Float? = null
    ) = SessionAggregateSampleRow(
        elapsedRealtimeNanos = seconds * 1_000_000_000L,
        speedKmh = speedKmh,
        socPercent = socPercent,
        odometerKm = null,
        voltageV = voltageV,
        currentA = currentA,
        powerKw = powerKw,
        freshnessMask = TelemetryEnergy.FRESH_DC_POWER_MASK or
            TelemetryEnergy.FRESH_VOLTAGE_MASK or
            TelemetryEnergy.FRESH_CURRENT_MASK,
        canDrivePowerKw = canDrivePowerKw,
        canPackVoltageV = canPackVoltageV,
        canPackCurrentA = canPackCurrentA
    )

    private fun tripSession() = SessionEntity(
        id = "trip-1",
        vehicleId = "test-vehicle",
        kind = "TRIP",
        status = "ENDED",
        startedAtUtcMillis = 100L,
        startedAtElapsedNanos = 0L,
        startedAtBootCount = SAME_BOOT,
        movementStartedAtUtcMillis = 100L,
        movementStartedAtElapsedNanos = 0L,
        movementStartedAtBootCount = SAME_BOOT,
        endedAtUtcMillis = 60_100L,
        endedAtElapsedNanos = 60_000_000_000L,
        endedAtBootCount = SAME_BOOT,
        startSocPercent = 80f,
        endSocPercent = 79f,
        startOdometerKm = null,
        endOdometerKm = null,
        startGear = 4,
        endReason = "PARKED",
        createdAtUtcMillis = 100L,
        updatedAtUtcMillis = 200L
    )

    private fun chargeSession() = SessionEntity(
        id = "charge-1",
        vehicleId = "test-vehicle",
        kind = "CHARGE",
        status = "ENDED",
        startedAtUtcMillis = 100L,
        startedAtElapsedNanos = 0L,
        startedAtBootCount = SAME_BOOT,
        chargeStartedAtUtcMillis = 200L,
        chargeStartedAtElapsedNanos = 0L,
        chargeStartedAtBootCount = SAME_BOOT,
        chargeEndedAtUtcMillis = 3_600_200L,
        chargeEndedAtElapsedNanos = 3_600_000_000_000L,
        chargeEndedAtBootCount = SAME_BOOT,
        plugDisconnectedAtUtcMillis = 3_601_000L,
        plugDisconnectedAtElapsedNanos = 3_600_800_000_000L,
        plugDisconnectedAtBootCount = SAME_BOOT,
        startSocPercent = 20f,
        endSocPercent = 30f,
        startOdometerKm = null,
        endOdometerKm = null,
        plugType = 2,
        startPowerKw = 7.2f,
        costPerKwh = null,
        paidAmount = null,
        costCurrency = "BRL",
        startAmbientTempC = null,
        endAmbientTempC = null,
        startLatitude = null,
        startLongitude = null,
        startAltitudeM = null,
        startGpsAccuracyM = null,
        startLocationProvider = null,
        startLocationElapsedRealtimeNanos = null,
        chargeEndReason = null,
        endReason = "removed_after_end",
        createdAtUtcMillis = 100L,
        updatedAtUtcMillis = 3_601_000L
    )

    private companion object {
        const val SAME_BOOT = 1
    }
}
