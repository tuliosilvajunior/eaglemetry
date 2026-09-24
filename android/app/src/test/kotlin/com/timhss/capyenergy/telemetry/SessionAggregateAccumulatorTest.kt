package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.SessionAggregateSampleRow
import com.timhss.capyenergy.telemetry.db.SessionEntity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionAggregateAccumulatorTest {

    @Test
    fun `trip energy matches the list reference integral`() {
        val samples = tripSeries()

        val streamed = SessionAggregateAccumulator().also { accumulator ->
            samples.forEach(accumulator::add)
        }.tripPowerIntegral()
        val reference = TelemetryEnergy.tripPowerIntegral(samples)

        assertNotNull(reference)
        assertEquals(reference!!.packWh, streamed!!.packWh, 1e-9)
        assertEquals(reference.tractionWh, streamed.tractionWh, 1e-9)
        assertEquals(reference.regeneratedWh, streamed.regeneratedWh, 1e-9)
        assertEquals(reference.auxiliaryWh, streamed.auxiliaryWh, 1e-9)
        assertEquals(reference.integratedSeconds, streamed.integratedSeconds, 1e-9)
        assertTrue("expected a regen leg", streamed.regeneratedWh > 0.0)
    }

    @Test
    fun `the breakdown is the integral, in kWh, and balances`() {
        val integral = TelemetryEnergy.tripPowerIntegral(tripSeries())!!
        val energy = integral.toBreakdown()

        assertEquals(integral.tractionWh / 1_000.0, energy.tractionKwh, 1e-12)
        assertEquals(integral.regeneratedWh / 1_000.0, energy.regeneratedKwh, 1e-12)
        assertEquals(integral.auxiliaryWh / 1_000.0, energy.auxiliaryKwh, 1e-12)
        assertEquals(integral.packWh / 1_000.0, energy.netKwh, 1e-12)
    }

    @Test
    fun `charge integrals match their list references`() {
        val samples = chargeSeries()

        val accumulator = SessionAggregateAccumulator()
        samples.forEach(accumulator::add)

        assertEquals(
            TelemetryEnergy.chargeEnergyKwh(samples)!!,
            accumulator.durableChargeEnergyKwh()!!,
            1e-9
        )
        assertEquals(
            ChargeEnergy.estimatedEnergyKwh(samples)!!,
            accumulator.displayChargeEnergyKwh()!!,
            1e-9
        )
    }

    @Test
    fun `applyFold is identical however the sweep is paged`() {
        val samples = tripSeries()
        val session = tripSession()
        val rollup = EnergyRollup(
            tractionWh = 377.33,
            regenWh = 0.0,
            auxiliaryWh = 16.67,
            climateWh = 0.0,
            deliveredWh = 0.0,
            distanceKm = 1.0,
            integratedSeconds = 60.0
        )

        val whole = SessionAggregateCalculator.applyFold(
            session = session,
            rollup = rollup,
            samples = samples
        )

        listOf(1, 2, 7, samples.size, samples.size + 3).forEach { pageSize ->
            val paged = SessionAggregateCalculator.applyFold(
                session = session,
                rollup = rollup,
                sweep = SessionSampleSweep { consume -> samples.chunked(pageSize).forEach { it.forEach(consume) } }
            )
            assertEquals("page size $pageSize changed the session", whole.startSocPercent, paged.startSocPercent)
            assertEquals("page size $pageSize changed the session", whole.endSocPercent, paged.endSocPercent)
            assertEquals("page size $pageSize changed the session", whole.minSocPercent, paged.minSocPercent)
        }
    }

    @Test
    fun `long series still reports energy where the old buffer gave up`() {
        val samples = (0 until 6_000).map { index ->
            row(
                seconds = index * 5L,
                socPercent = (80.0 - index * 0.005).toFloat(),
                speedKmh = 55f,
                voltageV = 400f,
                currentA = 30f,
                drivePowerKw = 10f
            )
        }

        val streamed = SessionAggregateAccumulator().also { accumulator ->
            samples.forEach(accumulator::add)
        }.tripPowerIntegral()
        val reference = TelemetryEnergy.tripPowerIntegral(samples)

        assertNotNull("a long trip must still report energy", streamed)
        assertEquals(reference!!.packWh, streamed!!.packWh, 1e-9)
        assertEquals(reference.tractionWh, streamed.tractionWh, 1e-9)
        assertTrue("expected a non-trivial consumption", streamed.packWh > 0.0)
    }

    private fun tripSeries(): List<SessionAggregateSampleRow> {
        val driveTrack = listOf(
            18.0f, 22.0f, 25.0f, 24.0f, 20.0f, 19.0f, 17.0f, 16.0f,
            -8.0f, -12.0f, -10.0f, -6.0f,
            14.0f, 18.0f, 21.0f, 20.0f, 17.0f
        )
        return driveTrack.mapIndexed { index, driveKw ->
            row(
                seconds = index * 5L,
                socPercent = 80.0f - index * 0.5f,
                speedKmh = 40f + (index % 5) * 8f,
                voltageV = 400f,
                currentA = driveKw * 1_000f / 400f + 5f,
                drivePowerKw = driveKw
            )
        }
    }

    private fun chargeSeries(): List<SessionAggregateSampleRow> =
        (0..40).map { index ->
            row(
                seconds = index * 15L,
                powerKw = 6.8f + (index % 4) * 0.35f,
                voltageV = 398f + (index % 3),
                currentA = -17.5f - (index % 5)
            )
        }

    private fun row(
        seconds: Long,
        socPercent: Float? = null,
        speedKmh: Float? = null,
        powerKw: Float? = null,
        voltageV: Float? = null,
        currentA: Float? = null,
        drivePowerKw: Float? = null
    ) = SessionAggregateSampleRow(
        id = seconds,
        elapsedRealtimeNanos = (seconds + 1) * 1_000_000_000L,
        speedKmh = speedKmh,
        socPercent = socPercent,
        odometerKm = null,
        voltageV = voltageV,
        currentA = currentA,
        powerKw = powerKw,
        canPackVoltageV = voltageV,
        canPackCurrentA = currentA,
        canDrivePowerKw = drivePowerKw,
        freshnessMask = TelemetryEnergy.FRESH_DC_POWER_MASK or
            TelemetryEnergy.FRESH_VOLTAGE_MASK or
            TelemetryEnergy.FRESH_CURRENT_MASK
    )

    private fun tripSession() = SessionEntity(
        id = "trip-stream",
        vehicleId = "test-vehicle",
        kind = "TRIP",
        status = "ENDED",
        startedAtUtcMillis = 100L,
        startedAtElapsedNanos = 0L,
        startedAtBootCount = SAME_BOOT,
        movementStartedAtUtcMillis = 100L,
        movementStartedAtElapsedNanos = 0L,
        movementStartedAtBootCount = SAME_BOOT,
        endedAtUtcMillis = 400L,
        endedAtElapsedNanos = 90_000_000_000L,
        endedAtBootCount = SAME_BOOT,
        startSocPercent = null,
        endSocPercent = null,
        startOdometerKm = null,
        endOdometerKm = null,
        startGear = 4,
        endReason = "PARKED",
        createdAtUtcMillis = 100L,
        updatedAtUtcMillis = 400L
    )

    private companion object {
        const val SAME_BOOT = 1
    }
}
