package com.timhss.capyenergy.telemetry

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FrameCadenceTest {

    private val second = 1_000_000_000L
    private val trip = ActiveFrameSession(id = "trip-1", type = "TRIP")
    private val charge = ActiveFrameSession(id = "charge-1", type = "CHARGE")

    private fun FrameCadence.persistAt(nanos: Long, signature: String = "4|1|2", powerKw: Float? = null) {
        onPersisted(nanos, signature, powerKw)
    }

    @Test
    fun `first frame always persists`() {
        val cadence = FrameCadence()
        assertTrue(cadence.shouldPersist(second, "4|1|2", trip, null))
    }

    @Test
    fun `trip frames respect the one second interval`() {
        val cadence = FrameCadence()
        cadence.persistAt(10 * second)
        assertFalse(cadence.shouldPersist(10 * second + second / 2, "4|1|2", trip, null))
        assertTrue(cadence.shouldPersist(11 * second, "4|1|2", trip, null))
    }

    @Test
    fun `discrete transition bypasses the interval`() {
        val cadence = FrameCadence()
        cadence.persistAt(10 * second, signature = "4|1|2")
        assertTrue(cadence.shouldPersist(10 * second + second / 10, "2|1|2", trip, null))
    }

    @Test
    fun `charge ramp-up keeps one second cadence`() {
        val cadence = FrameCadence()
        cadence.shouldPersist(10 * second, "4|1|2", charge, 7.0f)
        cadence.persistAt(10 * second, powerKw = 7.0f)
        assertTrue(cadence.shouldPersist(11 * second, "4|1|2", charge, 7.0f))
    }

    @Test
    fun `stable charge drops to five second cadence`() {
        val cadence = FrameCadence()
        val start = 10 * second
        cadence.shouldPersist(start, "4|1|2", charge, 7.0f)
        cadence.persistAt(start, powerKw = 7.0f)
        val afterRamp = start + FrameCadence.CHARGE_RAMP_NANOS
        cadence.persistAt(afterRamp, powerKw = 7.0f)
        assertFalse(cadence.shouldPersist(afterRamp + second, "4|1|2", charge, 7.1f))
        assertFalse(cadence.shouldPersist(afterRamp + 4 * second, "4|1|2", charge, 7.1f))
        assertTrue(cadence.shouldPersist(afterRamp + 5 * second, "4|1|2", charge, 7.1f))
    }

    @Test
    fun `power swing restores one second cadence`() {
        val cadence = FrameCadence()
        val start = 10 * second
        cadence.shouldPersist(start, "4|1|2", charge, 7.0f)
        cadence.persistAt(start, powerKw = 7.0f)
        val afterRamp = start + FrameCadence.CHARGE_RAMP_NANOS
        cadence.persistAt(afterRamp, powerKw = 7.0f)
        assertTrue(cadence.shouldPersist(afterRamp + second, "4|1|2", charge, 3.0f))
    }

    @Test
    fun `new charge session restarts the ramp window`() {
        val cadence = FrameCadence()
        val start = 10 * second
        cadence.shouldPersist(start, "4|1|2", charge, 7.0f)
        cadence.persistAt(start, powerKw = 7.0f)
        val afterRamp = start + FrameCadence.CHARGE_RAMP_NANOS
        cadence.persistAt(afterRamp, powerKw = 7.0f)
        val nextCharge = ActiveFrameSession(id = "charge-2", type = "CHARGE")
        assertTrue(cadence.shouldPersist(afterRamp + second, "4|1|2", nextCharge, 7.0f))
    }

    @Test
    fun `leaving charge resets to base cadence`() {
        val cadence = FrameCadence()
        val start = 10 * second
        cadence.shouldPersist(start, "4|1|2", charge, 7.0f)
        cadence.persistAt(start, powerKw = 7.0f)
        val afterRamp = start + FrameCadence.CHARGE_RAMP_NANOS
        cadence.persistAt(afterRamp, powerKw = 7.0f)
        assertTrue(cadence.shouldPersist(afterRamp + second, "4|1|2", trip, null))
    }

    @Test
    fun `missing power keeps one second cadence during charge`() {
        val cadence = FrameCadence()
        val start = 10 * second
        cadence.shouldPersist(start, "4|1|2", charge, null)
        cadence.persistAt(start, powerKw = null)
        val afterRamp = start + FrameCadence.CHARGE_RAMP_NANOS
        cadence.persistAt(afterRamp, powerKw = null)
        assertTrue(cadence.shouldPersist(afterRamp + second, "4|1|2", charge, null))
    }
}
