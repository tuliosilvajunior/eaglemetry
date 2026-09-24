package com.timhss.capyenergy.telemetry

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The heading is refused for five different reasons, and each one is a
 * different fact about the car. These tests pin that they stay apart.
 */
class VehicleHeadingTest {

    private fun resolve(
        gpsEnabled: Boolean = true,
        permissionGranted: Boolean = true,
        hasFix: Boolean = true,
        fixAgeMillis: Long? = 500L,
        bearingDeg: Double? = 90.0,
        bearingAccuracyDeg: Double? = 5.0,
        speedMps: Double? = 12.0,
    ): VehicleHeading = VehicleHeading.resolve(
        timestampMillis = 1_000L,
        gpsEnabled = gpsEnabled,
        permissionGranted = permissionGranted,
        hasFix = hasFix,
        fixAgeMillis = fixAgeMillis,
        maxFixAgeMillis = 10_000L,
        bearingDeg = bearingDeg,
        bearingAccuracyDeg = bearingAccuracyDeg,
        speedMps = speedMps,
    )

    @Test
    fun `reports the course when the fix carries one`() {
        val heading = resolve()
        assertEquals(HeadingAvailability.OK, heading.availability)
        assertEquals(90.0, heading.bearingDeg!!, 1e-9)
        assertEquals(12.0, heading.speedMps!!, 1e-9)
    }

    @Test
    fun `the app setting is reported before the permission`() {
        val heading = resolve(gpsEnabled = false, permissionGranted = false)
        assertEquals(HeadingAvailability.GPS_DISABLED, heading.availability)
        assertNull(heading.bearingDeg)
    }

    @Test
    fun `a missing permission is not a missing fix`() {
        assertEquals(
            HeadingAvailability.PERMISSION_MISSING,
            resolve(permissionGranted = false, hasFix = false).availability
        )
    }

    @Test
    fun `no fix and a stale fix are different states`() {
        assertEquals(
            HeadingAvailability.NO_FIX,
            resolve(hasFix = false, fixAgeMillis = null).availability
        )
        assertEquals(
            HeadingAvailability.FIX_STALE,
            resolve(fixAgeMillis = 10_001L).availability
        )
    }

    @Test
    fun `a stopped car keeps its speed and loses its course`() {
        val heading = resolve(bearingDeg = null, speedMps = 0.0)
        assertEquals(HeadingAvailability.NO_BEARING, heading.availability)
        assertNull(heading.bearingDeg)
        // The reader needs the speed to judge whether a held heading still
        // describes the car, so a refused course must not take it away.
        assertEquals(0.0, heading.speedMps!!, 1e-9)
    }

    @Test
    fun `a course that is not a number is not a course`() {
        assertEquals(
            HeadingAvailability.NO_BEARING,
            resolve(bearingDeg = Double.NaN).availability
        )
    }

    @Test
    fun `a course is folded into one turn`() {
        assertEquals(1.0, resolve(bearingDeg = 361.0).bearingDeg!!, 1e-9)
        assertEquals(350.0, resolve(bearingDeg = -10.0).bearingDeg!!, 1e-9)
        assertEquals(0.0, resolve(bearingDeg = 360.0).bearingDeg!!, 1e-9)
    }

    @Test
    fun `a negative accuracy or speed is refused`() {
        val heading = resolve(bearingAccuracyDeg = -1.0, speedMps = -3.0)
        assertNull(heading.bearingAccuracyDeg)
        assertNull(heading.speedMps)
    }
}
