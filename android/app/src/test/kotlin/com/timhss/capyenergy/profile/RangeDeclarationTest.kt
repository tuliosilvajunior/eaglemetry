package com.timhss.capyenergy.profile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Distance-to-empty is gated on a 0..2 000 km corruption guard.
 *
 * The guard is a band in the profile, not a range the vehicle declares: 2 000
 * km is what a unit or scaling fault would exceed, and zero is a valid reading
 * because an empty pack has no range.
 */
class RangeDeclarationTest {
    private val declaration = GeelyProfile.declarationFor(SignalKey.RANGE_REMAINING)!!

    private fun km(raw: Any?): Float? = declaration.normalize(RawReading(raw)) as Float?

    @Test
    fun `zero is a valid reading`() {
        assertEquals(0f, km(0)!!, 0f)
    }

    @Test
    fun `a normal reading passes through`() {
        assertEquals(266f, km(266)!!, 0f)
        assertEquals(171.5f, km(171.5)!!, 0f)
    }

    @Test
    fun `the 2000 km upper bound is accepted`() {
        assertEquals(2000f, km(2000)!!, 0f)
    }

    @Test
    fun `negative readings are rejected`() {
        assertNull(km(-1))
        assertNull(km(-0.5))
    }

    @Test
    fun `readings over 2000 km are rejected`() {
        assertNull(km(2001))
        assertNull(km(100000))
    }

    @Test
    fun `non-numeric and missing inputs are rejected`() {
        assertNull(km("not-a-number"))
        assertNull(km(null))
    }

    @Test
    fun `numeric strings decode like their numeric value`() {
        assertEquals(266f, km("266")!!, 0f)
    }

    @Test
    fun `the guard constant is 2000`() {
        assertTrue(RANGE_MAX_KM == 2000f)
    }
}
