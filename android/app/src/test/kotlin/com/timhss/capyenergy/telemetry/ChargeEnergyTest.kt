package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.ChargeSampleRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ChargeEnergyTest {

    private fun frame(
        elapsedSeconds: Long,
        powerKw: Float? = null,
        voltageV: Float? = null,
        currentA: Float? = null
    ): ChargeSampleRow = ChargeSampleRow(
        elapsedRealtimeNanos = elapsedSeconds * 1_000_000_000L,
        socPercent = null,
        voltageV = voltageV,
        currentA = currentA,
        powerKw = powerKw,
        freshnessMask = 0
    )

    @Test
    fun `frame power prefers explicit power and takes absolute value`() {
        assertEquals(7.2, ChargeEnergy.framePowerKw(frame(0, powerKw = -7.2f))!!, 1e-6)
    }

    @Test
    fun `frame power derives from voltage and current when absent`() {
        val derived = ChargeEnergy.framePowerKw(frame(0, voltageV = 400f, currentA = -18f))
        assertEquals(7.2, derived!!, 1e-6)
    }

    @Test
    fun `frame power is null without any power source`() {
        assertNull(ChargeEnergy.framePowerKw(frame(0)))
        assertNull(ChargeEnergy.framePowerKw(frame(0, voltageV = 400f)))
    }

    @Test
    fun `zero AC readings are absent from historical DC electrical series`() {
        val frame = frame(0, powerKw = 80f, voltageV = 0f, currentA = 0f)

        assertNull(ChargeEnergy.chartVoltageV(frame))
        assertNull(ChargeEnergy.chartCurrentA(frame))
        assertEquals(80.0, ChargeEnergy.framePowerKw(frame)!!, 1e-6)
    }

    @Test
    fun `historical electrical series keep positive voltage and current magnitude`() {
        val frame = frame(0, voltageV = 402.7f, currentA = -120f)

        assertEquals(402.7, ChargeEnergy.chartVoltageV(frame)!!, 1e-3)
        assertEquals(120.0, ChargeEnergy.chartCurrentA(frame)!!, 1e-6)
    }

    @Test
    fun `energy integrates constant power over time`() {
        val frames = (0L..3600L step 5L).map { frame(it, powerKw = 7.0f) }
        assertEquals(7.0, ChargeEnergy.estimatedEnergyKwh(frames)!!, 0.01)
    }

    @Test
    fun `energy skips gaps longer than sixty seconds`() {
        val frames = listOf(
            frame(0, powerKw = 7.0f),
            frame(30, powerKw = 7.0f),
            frame(3600, powerKw = 7.0f)
        )
        assertEquals(7.0 * 30 / 3600, ChargeEnergy.estimatedEnergyKwh(frames)!!, 1e-6)
    }

    @Test
    fun `energy requires at least two powered frames`() {
        assertNull(ChargeEnergy.estimatedEnergyKwh(listOf(frame(0, powerKw = 7.0f))))
        assertNull(ChargeEnergy.estimatedEnergyKwh(emptyList()))
    }

    @Test
    fun `average power ignores frames without power`() {
        val frames = listOf(
            frame(0, powerKw = 6.0f),
            frame(1),
            frame(2, powerKw = 8.0f)
        )
        assertEquals(7.0, ChargeEnergy.averagePowerKw(frames)!!, 1e-6)
    }

    @Test
    fun `projection rows integrate to the same energy as full frames`() {
        val frames = listOf(
            frame(0, voltageV = 402.7f, currentA = 2.1f),
            frame(30, voltageV = 402.7f, currentA = 2.1f),
            frame(60, powerKw = 7.2f),
            frame(90, powerKw = 7.4f)
        )

        assertEquals(
            ChargeEnergy.estimatedEnergyKwh(frames)!!,
            ChargeEnergy.estimatedEnergyKwh(frames)!!,
            1e-9
        )
        assertEquals(
            ChargeEnergy.averagePowerKw(frames)!!,
            ChargeEnergy.averagePowerKw(frames)!!,
            1e-9
        )
    }
}
