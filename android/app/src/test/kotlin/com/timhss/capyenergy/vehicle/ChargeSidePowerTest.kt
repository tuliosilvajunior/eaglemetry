package com.timhss.capyenergy.vehicle

import com.timhss.capyenergy.profile.GeelyProperties
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ChargeSidePowerTest {

    @Test
    fun `AC charging refuses the DC reading`() {
        // The 2026-08-11 case: charging on AC at 1.0 kW with the DC property
        // stuck at 12.5 kW. Taken as the rate, it hid a climate load that was
        // larger than the whole charge.
        val state = GeelyProperties.ChargeStateAcCharging
        assertEquals(1.0f, ChargeSidePower.acPowerKw(state, 1.0f))
        assertNull(ChargeSidePower.dcPowerKw(state, 12.5f))
    }

    @Test
    fun `DC charging refuses the AC reading`() {
        val state = GeelyProperties.ChargeStateDcCharging
        assertEquals(48.0f, ChargeSidePower.dcPowerKw(state, 48.0f))
        assertNull(ChargeSidePower.acPowerKw(state, 1.0f))
    }

    @Test
    fun `an unknown state rules out neither side`() {
        // The car has not said which side is live. Refusing a reading here
        // would be a guess, and the guess would be about the number the whole
        // charge screen is built on.
        assertEquals(1.0f, ChargeSidePower.acPowerKw(null, 1.0f))
        assertEquals(12.5f, ChargeSidePower.dcPowerKw(null, 12.5f))
    }

    @Test
    fun `a state that is neither rules out neither side`() {
        val state = GeelyProperties.ChargeStateNoCharging
        assertEquals(1.0f, ChargeSidePower.acPowerKw(state, 1.0f))
        assertEquals(12.5f, ChargeSidePower.dcPowerKw(state, 12.5f))
    }

    @Test
    fun `noise around zero is not a charge`() {
        assertNull(ChargeSidePower.acPowerKw(null, 0.1f))
        assertNull(ChargeSidePower.dcPowerKw(null, -0.05f))
        assertNull(ChargeSidePower.acPowerKw(null, Float.NaN))
        assertNull(ChargeSidePower.acPowerKw(null, null))
    }

    @Test
    fun `a negative reading past the floor survives`() {
        // Discharge to the grid is not this app's case today, but the old
        // guard used the magnitude and this keeps that rule visible.
        assertEquals(-3.0f, ChargeSidePower.acPowerKw(null, -3.0f))
    }
}
