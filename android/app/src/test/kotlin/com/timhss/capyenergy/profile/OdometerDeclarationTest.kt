package com.timhss.capyenergy.profile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OdometerDeclarationTest {
    private val declaration = GeelyProfile.declarationFor(SignalKey.ODOMETER)!!

    private fun odo(raw: Any?, sourceTimestampNanos: Long?): Float? =
        declaration.normalize(RawReading(raw, sourceTimestampNanos)) as Float?

    @Test
    fun rejectsSpuriousZeroWithoutSourceTimestamp() {
        assertNull(odo(0.0f, null))
        assertNull(odo(0.0f, 0L))
        assertNull(odo(0.0f, -1L))
    }

    @Test
    fun acceptsBrandNewCarReportingZeroWithLiveTimestamp() {
        assertEquals(0.0f, odo(0.0f, 1_000_000L)!!, 0.001f)
    }

    @Test
    fun acceptsNormalOdometerReadingsWithLiveTimestamp() {
        assertEquals(2551.0f, odo(2551.0f, 10_000_000L)!!, 0.001f)
        assertEquals(2772.0f, odo(2772.0f, 20_000_000L)!!, 0.001f)
    }

    @Test
    fun rejectsNegativeOdometerEvenWithTimestamp() {
        assertNull(odo(-5.0f, 10_000_000L))
    }

    @Test
    fun spuriousZeroBetweenNeighborsNormalizesToNull() {
        val odo1 = odo(2551.0f, 10_000_000L)
        val odoSpurious = odo(0.0f, null)
        val odo2 = odo(2772.0f, 20_000_000L)

        assertEquals(2551.0f, odo1!!, 0.001f)
        assertNull(odoSpurious)
        assertEquals(2772.0f, odo2!!, 0.001f)
        assertEquals(221.0f, odo2 - odo1, 0.001f)
    }
}
