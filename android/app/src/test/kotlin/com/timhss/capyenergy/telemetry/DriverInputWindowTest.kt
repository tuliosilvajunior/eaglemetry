package com.timhss.capyenergy.telemetry

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DriverInputWindowTest {

    @Test
    fun keepsABrakeTapThatFallsBetweenTwoFrames() {
        // The defect this class exists for. At 60 Hz into a 1 Hz row, a tap
        // that starts and ends inside the second is invisible to the sample
        // taken at the tick, and the friction-brake estimator is gated on it.
        val window = DriverInputWindow()
        window.observe(metrics(brakePedalOn = false))
        window.observe(metrics(brakePedalOn = true))
        window.observe(metrics(brakePedalOn = false))

        assertEquals(true, window.drain().brakePressed)
    }

    @Test
    fun reportsASecondWithoutAPressAsFalse() {
        val window = DriverInputWindow()
        window.observe(metrics(brakePedalOn = false))
        window.observe(metrics(brakePedalOn = false))

        assertEquals(false, window.drain().brakePressed)
    }

    @Test
    fun separatesASilentBusFromASecondNobodyBraked() {
        // Null and false are different facts, and the column has to keep them
        // apart: one says the switch never reported, the other says it did and
        // the pedal was up.
        val window = DriverInputWindow()
        window.observe(metrics(brakePedalOn = null))

        assertNull(window.drain().brakePressed)
    }

    @Test
    fun averagesThePedalOverTheWindowRatherThanSamplingIt() {
        val window = DriverInputWindow()
        window.observe(metrics(accelPedalPercent = 0f))
        window.observe(metrics(accelPedalPercent = 40f))
        window.observe(metrics(accelPedalPercent = 20f))

        assertEquals(20f, window.drain().accelPedalPercent!!, 1e-4f)
    }

    @Test
    fun ignoresAPedalReadingTheProviderRejected() {
        val window = DriverInputWindow()
        window.observe(metrics(accelPedalPercent = null))
        window.observe(metrics(accelPedalPercent = 30f))

        assertEquals(30f, window.drain().accelPedalPercent!!, 1e-4f)
    }

    @Test
    fun drainingStartsANewWindow() {
        // A press held in the window would otherwise be reported for every
        // frame of the rest of the trip.
        val window = DriverInputWindow()
        window.observe(metrics(brakePedalOn = true, accelPedalPercent = 50f))
        assertTrue(window.drain().brakePressed == true)

        val second = window.drain()
        assertNull(second.brakePressed)
        assertNull(second.accelPedalPercent)
    }

    @Test
    fun resettingDiscardsTheWindowWithoutReportingIt() {
        val window = DriverInputWindow()
        window.observe(metrics(brakePedalOn = true))
        window.reset()

        assertNull(window.drain().brakePressed)
    }

    private fun metrics(
        brakePedalOn: Boolean? = null,
        accelPedalPercent: Float? = null,
    ) = RoadcastTripMetrics(
        drivePowerKw = null,
        packVoltageV = null,
        packCurrentA = null,
        packCurrentRaw = null,
        packCurrentEstimated = null,
        vehicleSpeedKmh = null,
        brakePedalOn = brakePedalOn,
        accelPedalPercent = accelPedalPercent,
        receivedAtElapsedNanos = 0L,
        sourceAgeNanos = 0L,
    )
}
