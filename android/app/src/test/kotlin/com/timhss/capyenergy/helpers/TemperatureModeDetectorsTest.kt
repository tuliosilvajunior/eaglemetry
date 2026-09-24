package com.timhss.capyenergy.helpers

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TemperatureModeDetectorsTest {
    private val config = TemperatureModeDetectorConfig()

    @Test
    fun knobDetectorActivatesOnAlternatingFourPositionSequence() {
        val detector = HeadlightKnobActivationDetector(config)

        assertFalse(detector.onValue(0, 0))
        assertFalse(detector.onValue(1, 500))
        assertFalse(detector.onValue(0, 1_000))
        assertTrue(detector.onValue(1, 1_500))
    }

    @Test
    fun knobDetectorIgnoresNonAlternatingChanges() {
        val detector = HeadlightKnobActivationDetector(config)

        assertFalse(detector.onValue(0, 0))
        assertFalse(detector.onValue(1, 500))
        assertFalse(detector.onValue(2, 1_000))
        assertFalse(detector.onValue(1, 1_500))
    }

    @Test
    fun combinedDetectorReportsActivationSource() {
        val detector = TemperatureModeActivationDetector(config)

        assertEquals(
            TemperatureModeActivation.NONE,
            detector.onPropertyValue(config.headlightSwitchPropertyId, 0, 0)
        )
        assertEquals(
            TemperatureModeActivation.NONE,
            detector.onPropertyValue(config.headlightSwitchPropertyId, 1, 500)
        )
        assertEquals(
            TemperatureModeActivation.NONE,
            detector.onPropertyValue(config.headlightSwitchPropertyId, 0, 1_000)
        )
        assertEquals(
            TemperatureModeActivation.HEADLIGHT_KNOB_SEQUENCE,
            detector.onPropertyValue(config.headlightSwitchPropertyId, 1, 1_500)
        )
    }
}
