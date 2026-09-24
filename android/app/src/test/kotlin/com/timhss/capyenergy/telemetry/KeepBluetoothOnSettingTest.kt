package com.timhss.capyenergy.telemetry

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The car radio is shared hardware: the driver pairs a phone to it for calls
 * and music. Taking it without being asked is why the default matters as much
 * as the switch.
 */
class KeepBluetoothOnSettingTest {
    @Test
    fun defaultsOffSoTheAppNeverTakesTheRadioUnasked() {
        val settings = TelemetrySettings(FakeSettingsContext())

        assertFalse(settings.keepBluetoothOnEnabled())
        assertEquals(false, settings.toMap()["keepBluetoothOnEnabled"])
    }

    @Test
    fun survivesAReopen() {
        val context = FakeSettingsContext()
        TelemetrySettings(context).setKeepBluetoothOnEnabled(true)

        val reopened = TelemetrySettings(context)
        assertTrue(reopened.keepBluetoothOnEnabled())
        assertEquals(true, reopened.toMap()["keepBluetoothOnEnabled"])
    }

    @Test
    fun switchesBackOff() {
        val context = FakeSettingsContext()
        val settings = TelemetrySettings(context)
        settings.setKeepBluetoothOnEnabled(true)
        settings.setKeepBluetoothOnEnabled(false)

        assertFalse(TelemetrySettings(context).keepBluetoothOnEnabled())
    }

    @Test
    fun leavesEveryOtherSettingAlone() {
        val context = FakeSettingsContext()
        val settings = TelemetrySettings(context)
        settings.setGpsEnabled(true)
        settings.setKeepBluetoothOnEnabled(true)

        val map = settings.toMap()
        assertEquals(true, map["gpsEnabled"])
        assertEquals(true, map["autoStartOnBoot"])
        assertEquals(false, map["externalChargeControlEnabled"])
    }
}
