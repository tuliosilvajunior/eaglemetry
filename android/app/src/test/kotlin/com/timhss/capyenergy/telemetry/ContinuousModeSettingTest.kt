package com.timhss.capyenergy.telemetry

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * CONTINUOUS is opt-in: nothing about recording changes until the owner turns
 * it on, so the default matters as much as the switch.
 */
class ContinuousModeSettingTest {
    @Test
    fun defaultsOffSoRecordingIsUnchangedUntilAsked() {
        val settings = TelemetrySettings(FakeSettingsContext())

        assertFalse(settings.continuousModeEnabled())
        assertEquals(false, settings.toMap()["continuousModeEnabled"])
    }

    @Test
    fun survivesAReopen() {
        val context = FakeSettingsContext()
        TelemetrySettings(context).setContinuousModeEnabled(true)

        val reopened = TelemetrySettings(context)
        assertTrue(reopened.continuousModeEnabled())
        assertEquals(true, reopened.toMap()["continuousModeEnabled"])
    }

    @Test
    fun switchesBackOff() {
        val context = FakeSettingsContext()
        val settings = TelemetrySettings(context)
        settings.setContinuousModeEnabled(true)
        settings.setContinuousModeEnabled(false)

        assertFalse(TelemetrySettings(context).continuousModeEnabled())
    }

    @Test
    fun leavesEveryOtherSettingAlone() {
        val context = FakeSettingsContext()
        val settings = TelemetrySettings(context)
        settings.setGpsEnabled(true)
        settings.setContinuousModeEnabled(true)

        val map = settings.toMap()
        assertEquals(true, map["gpsEnabled"])
        assertEquals(true, map["autoStartOnBoot"])
        assertEquals(false, map["keepBluetoothOnEnabled"])
    }
}
