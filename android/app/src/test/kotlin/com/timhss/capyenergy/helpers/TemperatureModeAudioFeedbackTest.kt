package com.timhss.capyenergy.helpers

import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TemperatureModeAudioFeedbackTest {
    @Test
    fun knobProgressTonesRiseWithCount() {
        val first = TemperatureModeAudioProfile.knobProgress(1).tones.single().frequencyHz
        val second = TemperatureModeAudioProfile.knobProgress(2).tones.single().frequencyHz
        val third = TemperatureModeAudioProfile.knobProgress(3).tones.single().frequencyHz

        assertTrue(first < second)
        assertTrue(second < third)
    }

    @Test
    fun activationAndExitUseDifferentCues() {
        val active = TemperatureModeAudioProfile.modeActive().tones.map { it.frequencyHz }
        val exit = TemperatureModeAudioProfile.modeExit().tones.map { it.frequencyHz }

        assertNotEquals(active, exit)
        assertTrue(active.zipWithNext().all { (left, right) -> left < right })
        assertTrue(exit.zipWithNext().all { (left, right) -> left > right })
    }

    @Test
    fun temperatureAndFanChangesHaveDifferentSignaturesAndLevels() {
        val lowTemp = TemperatureModeAudioProfile.temperatureChanged(16f).tones.first()
        val highTemp = TemperatureModeAudioProfile.temperatureChanged(28f).tones.first()
        val lowFan = TemperatureModeAudioProfile.fanSpeedChanged(1).tones.first()
        val highFan = TemperatureModeAudioProfile.fanSpeedChanged(9).tones.first()

        assertTrue(lowTemp.frequencyHz < highTemp.frequencyHz)
        assertTrue(lowFan.frequencyHz < highFan.frequencyHz)
        assertNotEquals(lowTemp.harmonicMix, lowFan.harmonicMix)
    }
}

