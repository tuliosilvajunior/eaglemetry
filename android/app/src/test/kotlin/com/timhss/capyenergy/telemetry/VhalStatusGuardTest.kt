package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalSpec

import com.timhss.capyenergy.profile.SignalKey

import android.car.hardware.CarPropertyValue
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The status gate shared by the initial-read and ON_CHANGE callback paths.
 * The constants are compile-time, so the predicate is testable without a car.
 */
class VhalStatusGuardTest {

    @Test
    fun `available status is accepted`() {
        assertTrue(vhalStatusIsAvailable(CarPropertyValue.STATUS_AVAILABLE))
        assertTrue(vhalStatusIsAvailable(ECARX_STATUS_SUPPORTED))
    }

    @Test
    fun `unavailable status is rejected`() {
        assertFalse(vhalStatusIsAvailable(CarPropertyValue.STATUS_UNAVAILABLE))
        assertFalse(vhalStatusIsAvailable(4))
    }

    @Test
    fun `error status is rejected`() {
        assertFalse(vhalStatusIsAvailable(CarPropertyValue.STATUS_ERROR))
    }

    @Test
    fun `latched key events keep raw callback logging enabled`() {
        val keySpec = SignalSpec(
            signalId = SignalKey.MCU_KEY_CODE_RESUME_CRUISE_INCREASE,
            propertyId = 1,
            keyEventLatch = true,
            rawLog = false
        )
        val normalSpec = SignalSpec(
            signalId = SignalKey.RANGE_REMAINING,
            propertyId = 2,
            keyEventLatch = false,
            rawLog = false
        )

        assertTrue(vhalShouldRawLog(keySpec))
        assertFalse(vhalShouldRawLog(normalSpec))
    }

}
