package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SignalEventPolicyTest {
    private val policy = SignalEventPolicy()

    @Test
    fun `continuous signals never log value changes`() {
        assertFalse(policy.shouldLogValueChange(SignalKey.HV_BATTERY_VOLTAGE, 350.1f, 350.3f))
        assertFalse(policy.shouldLogValueChange(SignalKey.HV_BATTERY_VOLTAGE, 300.0f, 400.0f))
        assertFalse(policy.shouldLogValueChange(SignalKey.VEHICLE_SPEED, 0.0f, 87.5f))
        assertFalse(policy.shouldLogValueChange(SignalKey.HV_BATTERY_CURRENT, null, 12.4f))
        assertFalse(policy.shouldLogValueChange(SignalKey.ED_DRIVING_ENERGY_FLOW, 1, 2))
    }

    @Test
    fun `discrete signals log every distinct value`() {
        assertTrue(policy.shouldLogValueChange(SignalKey.GEAR, 4, 2))
        assertTrue(policy.shouldLogValueChange(SignalKey.EV_CHARGE_STATE, null, 1))
        assertTrue(policy.shouldLogValueChange(SignalKey.EV_CHARGE_PLUG_TYPE, 0, 2))
        assertTrue(policy.shouldLogValueChange(SignalKey.ODOMETER, 12000.0f, 12001.0f))
    }

    @Test
    fun `unchanged values never log`() {
        assertFalse(policy.shouldLogValueChange(SignalKey.GEAR, 4, 4))
        assertFalse(policy.shouldLogValueChange(SignalKey.HV_BATTERY_SOC, 63.1f, 63.1f))
        assertFalse(policy.shouldLogValueChange(SignalKey.HV_BATTERY_VOLTAGE, null, null))
    }

    @Test
    fun `deadband signals log only when drift reaches threshold`() {
        assertFalse(policy.shouldLogValueChange(SignalKey.HV_BATTERY_SOC, 63.1f, 63.2f))
        assertFalse(policy.shouldLogValueChange(SignalKey.HV_BATTERY_SOC, 63.1f, 63.5f))
        assertTrue(policy.shouldLogValueChange(SignalKey.HV_BATTERY_SOC, 63.1f, 63.6f))
        assertTrue(policy.shouldLogValueChange(SignalKey.HV_BATTERY_SOC, 63.1f, 62.5f))
        assertFalse(policy.shouldLogValueChange(SignalKey.AMBIENT_AIR_TEMPERATURE, 21.0f, 21.9f))
        assertTrue(policy.shouldLogValueChange(SignalKey.AMBIENT_AIR_TEMPERATURE, 21.0f, 22.0f))
    }

    @Test
    fun `deadband signals log the first observed value`() {
        assertTrue(policy.shouldLogValueChange(SignalKey.HV_BATTERY_SOC, null, 63.1f))
        assertTrue(policy.shouldLogValueChange(SignalKey.OUTSIDE_TEMPERATURE, null, 18.5f))
    }

    @Test
    fun `deadband signals fall back to log-on-change for non-numeric values`() {
        assertTrue(policy.shouldLogValueChange(SignalKey.HV_BATTERY_SOC, "n/a", 63.1f))
        assertTrue(policy.shouldLogValueChange(SignalKey.HV_BATTERY_SOC, 63.1f, "n/a"))
    }

    @Test
    fun `a signal that is already broken at startup still writes one row`() {
        // The regression this pins: the outside temperature was rejected by the
        // VHAL status guard on every read, so its sample carried no value and no
        // MEASURED quality. With both per-process maps empty after a start, the
        // value gate saw null == null and the quality gate saw no previous
        // quality, and three days of trips recorded no temperature and no
        // complaint. Reading the database, the signal looked like it had simply
        // stopped existing.
        assertTrue(
            policy.shouldLog(
                SignalKey.AMBIENT_AIR_TEMPERATURE,
                previousQuality = null,
                quality = SignalQuality.ERROR,
                lastLoggedValue = null,
                newValue = null
            )
        )
        assertTrue(
            policy.shouldLog(
                SignalKey.HV_BATTERY_VOLTAGE,
                previousQuality = null,
                quality = SignalQuality.UNAVAILABLE,
                lastLoggedValue = null,
                newValue = null
            )
        )
    }

    @Test
    fun `a signal that stays broken writes one row and not a flood`() {
        // Bounded on purpose. The first sight is only first once, so a signal
        // the car never fixes cannot fill storage with the same complaint.
        assertFalse(
            policy.shouldLog(
                SignalKey.AMBIENT_AIR_TEMPERATURE,
                previousQuality = SignalQuality.ERROR,
                quality = SignalQuality.ERROR,
                lastLoggedValue = null,
                newValue = null
            )
        )
    }

    @Test
    fun `a healthy first reading is left to the value gate`() {
        // A working signal must not gain a row just for being first, or every
        // start would write one per signal. The deadband decides, as before.
        assertFalse(
            policy.shouldLog(
                SignalKey.HV_BATTERY_VOLTAGE,
                previousQuality = null,
                quality = SignalQuality.MEASURED,
                lastLoggedValue = null,
                newValue = 394.3f
            )
        )
        assertTrue(
            policy.shouldLog(
                SignalKey.AMBIENT_AIR_TEMPERATURE,
                previousQuality = null,
                quality = SignalQuality.MEASURED,
                lastLoggedValue = null,
                newValue = 21.5f
            )
        )
    }

    @Test
    fun `recovery from broken to measured writes a row`() {
        assertTrue(
            policy.shouldLog(
                SignalKey.AMBIENT_AIR_TEMPERATURE,
                previousQuality = SignalQuality.ERROR,
                quality = SignalQuality.MEASURED,
                lastLoggedValue = null,
                newValue = 21.5f
            )
        )
    }
}
