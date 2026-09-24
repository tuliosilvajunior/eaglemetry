package com.timhss.capyenergy.profile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The whole point of the state-of-health decode is the pair below: raw 999
 * means two opposite things, and only the source timestamp separates them.
 */
class BatterySohDeclarationTest {
    private val declaration = GeelyProfile.declarationFor(SignalKey.BATTERY_SOH_PERCENT)!!

    private fun percent(raw: Any?, sourceTimestampNanos: Long?): Float? =
        declaration.normalize(RawReading(raw, sourceTimestampNanos)) as Float?

    @Test
    fun rejectsTheFactoryDefaultThatWasNeverPublished() {
        assertNull(percent(999, null))
        assertNull(percent(999, 0L))
    }

    @Test
    fun acceptsThatSameValueWhenTheVehiclePublishedIt() {
        assertEquals(99.9f, percent(999, 1_234_567L)!!, 0.001f)
        assertEquals(100f, percent(1000, 1_234_567L)!!, 0.001f)
        assertEquals(87.4f, percent(874, 1_234_567L)!!, 0.001f)
    }

    @Test
    fun refusesValuesOutsideThePercentRange() {
        assertNull(percent(1001, 1_234_567L))
        assertNull(percent(-1, 1_234_567L))
        assertNull(percent(null, 1_234_567L))
    }
}
