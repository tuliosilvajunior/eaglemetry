package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.CanPowerSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TripPowerIntegralTest {

    @Test
    fun balancesTractionRegenerationAndAuxiliaryAgainstPackEnergy() {
        // 600 s at a steady 10 kW of traction over a 1 kW auxiliary load.
        val integral = TelemetryEnergy.tripPowerIntegral(
            steady(seconds = 600, packKw = 11.0, driveKw = 10.0)
        )!!

        assertEquals(600.0, integral.integratedSeconds, 0.001)
        assertEquals(11.0 * 1_000.0 * 600.0 / 3_600.0, integral.packWh, 0.001)
        assertEquals(10.0 * 1_000.0 * 600.0 / 3_600.0, integral.tractionWh, 0.001)
        assertEquals(0.0, integral.regeneratedWh, 0.001)
        assertEquals(1.0 * 1_000.0 * 600.0 / 3_600.0, integral.auxiliaryWh, 0.001)
    }

    @Test
    fun regenerationIsMeasuredEnergyReturned() {
        // 100 s pulling 20 kW, then 100 s returning 5 kW, over a 1 kW auxiliary
        // load throughout.
        val integral = TelemetryEnergy.tripPowerIntegral(
            steady(seconds = 100, packKw = 21.0, driveKw = 20.0) +
                steady(seconds = 100, packKw = -4.0, driveKw = -5.0, startSecond = 101)
        )!!

        assertEquals(20.0 * 1_000.0 * 100.0 / 3_600.0, integral.tractionWh, 5.0)
        assertEquals(5.0 * 1_000.0 * 100.0 / 3_600.0, integral.regeneratedWh, 5.0)
        assertEquals(0.25, integral.regenerationRatio!!, 0.02)
        // The breakdown balances by construction, not by coincidence.
        assertEquals(
            integral.packWh,
            integral.tractionWh - integral.regeneratedWh + integral.auxiliaryWh,
            0.001
        )
    }

    @Test
    fun skipsDataGapsInsteadOfIntegratingAcrossThem() {
        val integral = TelemetryEnergy.tripPowerIntegral(
            steady(seconds = 2, packKw = 10.0, driveKw = 10.0) +
                steady(seconds = 2, packKw = 10.0, driveKw = 10.0, startSecond = 3_600)
        )!!

        // Two seconds on each side of the hour-long hole; the hole itself is
        // missing data, not a plateau to integrate across.
        assertEquals(4.0, integral.integratedSeconds, 0.001)
        assertEquals(10.0 * 1_000.0 * 4.0 / 3_600.0, integral.packWh, 0.001)
    }

    @Test
    fun needsTheWholeTripleAndTwoUsableFrames() {
        assertNull(TelemetryEnergy.tripPowerIntegral(emptyList()))
        assertNull(TelemetryEnergy.tripPowerIntegral(steady(seconds = 0, packKw = 10.0, driveKw = 10.0)))
        // Pack current never recorded: voltage and drive power alone cannot say
        // what the battery delivered. This was every trip frame until 2026-08-02.
        assertNull(
            TelemetryEnergy.tripPowerIntegral(
                listOf(
                    CanFrame(0L, 400f, null, 10f),
                    CanFrame(1_000_000_000L, 400f, null, 10f)
                )
            )
        )
    }

    /**
     * Twelve consecutive frames recorded on 2026-08-02, covering one
     * acceleration, a lift into regeneration and a second acceleration.
     *
     * Synthetic constants cannot catch a units or sign slip the way real signal
     * shapes do, and these carry the real cadence too — the frames land 1.0 to
     * 1.6 s apart, not on a tidy grid. Pack current is negated from what the
     * database holds, because those rows predate the DBC sign fix.
     *
     * The auxiliary term comes out slightly negative over a window this short.
     * That is the timing skew between `VCU_DrvPwrAct` and the voltage/current
     * pair, not a load: it is why the split is only published over a whole trip.
     */
    @Test
    fun reproducesTheRecordedDriveIncludingItsCadenceJitter() {
        val integral = TelemetryEnergy.tripPowerIntegral(
            listOf(
                realFrame(0, 15.90, 396.0, 38.5),
                realFrame(1108, 9.30, 397.2, 21.6),
                realFrame(2155, 8.70, 397.1, 20.4),
                realFrame(3199, 2.30, 398.4, 6.3),
                realFrame(4247, -4.30, 400.5, -23.2),
                realFrame(5256, -8.30, 400.7, -18.3),
                realFrame(6297, -7.10, 400.7, -16.4),
                realFrame(7301, -6.70, 400.7, -15.0),
                realFrame(8308, -8.60, 401.1, -20.7),
                realFrame(9926, 1.30, 399.4, 2.8),
                realFrame(10926, 9.70, 398.0, 27.8),
                realFrame(11926, 22.50, 395.4, 59.5)
            )
        )!!

        // Expected values carry the Float precision of the database columns:
        // 15.90 stored as a Float is 15.899999618530273, and over twelve frames
        // that is worth 0.08 % of the pack energy.
        assertEquals(11.926, integral.integratedSeconds, 0.0001)
        assertEquals(3.428925, integral.packWh, 0.000001)
        assertEquals(14.717417, integral.tractionWh, 0.000001)
        assertEquals(10.615042, integral.regeneratedWh, 0.000001)
        assertEquals(-0.673450, integral.auxiliaryWh, 0.000001)
        assertEquals(
            integral.packWh,
            integral.tractionWh - integral.regeneratedWh + integral.auxiliaryWh,
            0.0001
        )
    }

    /**
     * Numbers from the calibration drive of 2026-08-02, 155 frames: the integral
     * gave 92 Wh over a trip whose SOC fell 0.30 %. The check reads the two
     * directions, not the two magnitudes — decision 5 removed the second energy
     * this used to be compared against.
     */
    @Test
    fun acceptsTheMeasuredDriveAndRejectsAnInvertedIntegral() {
        assertTrue(
            TelemetryEnergy.integralAgreesWithSoc(
                integralWh = 92.0,
                startSoc = 62.30,
                endSoc = 62.00
            )!!
        )
        // The same trip with the pre-2026-08-02 current sign.
        assertFalse(
            TelemetryEnergy.integralAgreesWithSoc(
                integralWh = -92.0,
                startSoc = 62.30,
                endSoc = 62.00
            )!!
        )
    }

    /**
     * A 1 Hz run of constant power, the cadence trip frames actually arrive at.
     *
     * Starts at one second, not zero: an elapsed timestamp of zero means the
     * frame never got one, and the integral drops such rows on purpose.
     */
    private fun steady(
        seconds: Int,
        packKw: Double,
        driveKw: Double,
        startSecond: Int = 1
    ): List<CanPowerSample> = (0..seconds).map { offset ->
        val volts = 400.0f
        CanFrame(
            elapsedRealtimeNanos = (startSecond + offset).toLong() * 1_000_000_000L,
            canPackVoltageV = volts,
            canPackCurrentA = (packKw * 1_000.0 / volts).toFloat(),
            canDrivePowerKw = driveKw.toFloat()
        )
    }

    private fun realFrame(
        millis: Long,
        driveKw: Double,
        volts: Double,
        amps: Double
    ): CanPowerSample = CanFrame(
        // Offset off zero so the frames look like what the collector records.
        elapsedRealtimeNanos = (millis + 1_000L) * 1_000_000L,
        canPackVoltageV = volts.toFloat(),
        canPackCurrentA = amps.toFloat(),
        canDrivePowerKw = driveKw.toFloat()
    )

    private data class CanFrame(
        override val elapsedRealtimeNanos: Long,
        override val canPackVoltageV: Float?,
        override val canPackCurrentA: Float?,
        override val canDrivePowerKw: Float?
    ) : CanPowerSample
}
