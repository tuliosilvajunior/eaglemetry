package com.timhss.capyenergy.profile

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GeelyProfileDcFastChargeTest {
    @Test
    fun `detects DC fast charge for small code 2`() {
        assertTrue(GeelyProfile.isDcFastCharge(2))
        assertTrue(GeelyProfile.isDcFastCharge(2.0))
        assertTrue(GeelyProfile.isDcFastCharge(2f))
        assertTrue(GeelyProfile.isDcFastCharge(2L))
        assertTrue(GeelyProfile.isDcFastCharge("2"))
        assertTrue(GeelyProfile.isDcFastCharge("2.0"))
    }

    @Test
    fun `detects DC fast charge for hardware constant`() {
        val dc = GeelyProperties.ChargePlugStateDcConnected
        assertTrue(GeelyProfile.isDcFastCharge(dc))
        assertTrue(GeelyProfile.isDcFastCharge(dc.toLong()))
        assertTrue(GeelyProfile.isDcFastCharge(dc.toDouble()))
        assertTrue(GeelyProfile.isDcFastCharge(dc.toString()))
    }

    @Test
    fun `rejects AC and none codes`() {
        assertFalse(GeelyProfile.isDcFastCharge(GeelyProperties.ChargePlugStateAcConnected))
        assertFalse(GeelyProfile.isDcFastCharge(GeelyProperties.ChargePlugStateNone))
        assertFalse(GeelyProfile.isDcFastCharge(GeelyProperties.ChargePlugStateIntegrationConnected))
        assertFalse(GeelyProfile.isDcFastCharge(1))
        assertFalse(GeelyProfile.isDcFastCharge(0))
        assertFalse(GeelyProfile.isDcFastCharge(null))
        assertFalse(GeelyProfile.isDcFastCharge("1"))
    }

    @Test
    fun `rejects non-integral doubles`() {
        assertFalse(GeelyProfile.isDcFastCharge(2.1))
        assertFalse(GeelyProfile.isDcFastCharge(2.5))
        assertFalse(GeelyProfile.isDcFastCharge("2.1"))
    }
}
