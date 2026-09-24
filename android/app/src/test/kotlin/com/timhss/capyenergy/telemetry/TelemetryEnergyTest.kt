package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.SessionAggregateSampleRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The SOC energy model was removed on 2026-08-19 (decision 5), and its eight
 * cases went with it. A trip's energy is the CAN power integral, specified by
 * `testdata/interval_cases.json`, so what is left here is the integral itself
 * and the SOC **direction** check that guards its sign.
 */
class TelemetryEnergyTest {
    @Test
    fun `the integral splits traction, regeneration and auxiliary`() {
        // 400 V, a 20 kW drive leg and a 5 A (2 kW) auxiliary draw, for 60 s.
        val samples = (0L..60L step 10L).map { second ->
            canSample(second, voltageV = 400f, currentA = 20_000f / 400f + 5f, driveKw = 20f)
        }

        val integral = TelemetryEnergy.tripPowerIntegral(samples)!!

        assertEquals(60.0, integral.integratedSeconds, 1e-9)
        assertEquals(22_000.0 / 1_000.0 * (60.0 / 3_600.0) * 1_000.0, integral.packWh, 1e-6)
        assertEquals(20.0 * (60.0 / 3_600.0) * 1_000.0, integral.tractionWh, 1e-6)
        assertEquals(0.0, integral.regeneratedWh, 1e-9)
        assertEquals(2.0 * (60.0 / 3_600.0) * 1_000.0, integral.auxiliaryWh, 1e-6)
        // The identity the split is built on.
        assertEquals(
            integral.packWh,
            integral.tractionWh - integral.regeneratedWh + integral.auxiliaryWh,
            1e-9
        )
    }

    @Test
    fun `a regeneration leg lands in the regenerated term`() {
        val samples = (0L..60L step 10L).map { second ->
            canSample(second, voltageV = 400f, currentA = -20_000f / 400f, driveKw = -20f)
        }

        val integral = TelemetryEnergy.tripPowerIntegral(samples)!!

        assertEquals(0.0, integral.tractionWh, 1e-9)
        assertEquals(20.0 * (60.0 / 3_600.0) * 1_000.0, integral.regeneratedWh, 1e-6)
    }

    @Test
    fun `the integral is null without the whole triple`() {
        val samples = (0L..60L step 10L).map { second ->
            canSample(second, voltageV = 400f, currentA = 50f, driveKw = null)
        }
        assertNull(TelemetryEnergy.tripPowerIntegral(samples))
    }

    @Test
    fun `the sign check agrees when the pack fell and the integral discharged`() {
        assertEquals(
            true,
            TelemetryEnergy.integralAgreesWithSoc(
                integralWh = 394.0,
                startSoc = 80.0,
                endSoc = 79.0
            )
        )
    }

    /** The pre-2026-08-02 current sign inverts the integral, and it is caught. */
    @Test
    fun `the sign check contradicts a reversed pack current`() {
        assertEquals(
            false,
            TelemetryEnergy.integralAgreesWithSoc(
                integralWh = -394.0,
                startSoc = 80.0,
                endSoc = 79.0
            )
        )
    }

    @Test
    fun `the sign check is unconfirmed when soc did not move`() {
        assertNull(
            TelemetryEnergy.integralAgreesWithSoc(
                integralWh = 394.0,
                startSoc = 80.0,
                endSoc = 80.0
            )
        )
        assertNull(
            TelemetryEnergy.integralAgreesWithSoc(
                integralWh = 394.0,
                startSoc = null,
                endSoc = 79.0
            )
        )
    }

    @Test
    fun `efficiency is gated on distance alone`() {
        val energy = TripEnergyBreakdown(
            tractionKwh = 1.4,
            regeneratedKwh = 0.5,
            auxiliaryKwh = 0.6
        )
        // net = 1.4 - 0.5 + 0.6 = 1.5 kWh over 10 km.
        assertEquals(150.0, TelemetryEnergy.efficiencyWhPerKm(energy, 10.0)!!, 1e-9)
        assertEquals(10.0 / 1.5, TelemetryEnergy.kmPerKwh(energy, 10.0)!!, 1e-9)
        // Below a kilometre the figure is mostly quantization error.
        assertNull(TelemetryEnergy.efficiencyWhPerKm(energy, 0.5))
        // A trip that gave back everything it took has no efficiency to report.
        assertNull(TelemetryEnergy.efficiencyWhPerKm(TripEnergyBreakdown(), 10.0))
    }

    private fun canSample(
        seconds: Long,
        voltageV: Float?,
        currentA: Float?,
        driveKw: Float?
    ) = SessionAggregateSampleRow(
        elapsedRealtimeNanos = (seconds + 1) * 1_000_000_000L,
        speedKmh = null,
        socPercent = null,
        odometerKm = null,
        voltageV = null,
        currentA = null,
        powerKw = null,
        freshnessMask = 0,
        canDrivePowerKw = driveKw,
        canPackVoltageV = voltageV,
        canPackCurrentA = currentA
    )

}
