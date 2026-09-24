package com.timhss.capyenergy.helpers

import com.timhss.capyenergy.profile.GeelyProfile
import com.timhss.capyenergy.profile.SignalKey

data class TemperatureModeDetectorConfig(
    /**
     * Which property the knob sequence watches, reported in the status map so a
     * field diagnosis can name it. The address is a vehicle fact and comes from
     * the profile; this helper only needs to say which signal it watched.
     */
    val headlightSwitchPropertyId: Int =
        GeelyProfile.propertyIdFor(SignalKey.HEADLIGHTS_SWITCH) ?: 0,
    val knobActivationTransitions: Int = 3,
    val knobActivationWindowMillis: Long = 3_000L,
    val mediaIdleTimeoutMillis: Long = 5_000L,
    val hardCapMillis: Long = 60_000L
) {
    init {
        require(knobActivationTransitions > 0) { "knobActivationTransitions must be positive" }
        require(knobActivationWindowMillis > 0) { "knobActivationWindowMillis must be positive" }
        require(mediaIdleTimeoutMillis > 0) { "mediaIdleTimeoutMillis must be positive" }
        require(hardCapMillis >= mediaIdleTimeoutMillis) {
            "hardCapMillis must be greater than or equal to mediaIdleTimeoutMillis"
        }
    }

    fun toMap(): Map<String, Any?> = mapOf(
        "headlightSwitchPropertyId" to headlightSwitchPropertyId,
        "headlightSwitchPropertyIdHex" to headlightSwitchPropertyId.toHexPropertyId(),
        "knobActivationTransitions" to knobActivationTransitions,
        "knobActivationWindowMillis" to knobActivationWindowMillis,
        "mediaIdleTimeoutMillis" to mediaIdleTimeoutMillis,
        "hardCapMillis" to hardCapMillis
    )
}

enum class TemperatureModeActivation {
    NONE,
    HEADLIGHT_KNOB_SEQUENCE
}

class HeadlightKnobActivationDetector(
    private val config: TemperatureModeDetectorConfig = TemperatureModeDetectorConfig()
) {
    private val transitions = ArrayDeque<KnobTransition>()
    private var previousValue: Int? = null

    fun onValue(value: Int?, timestampMillis: Long): Boolean {
        val previous = previousValue
        previousValue = value
        if (value == null || previous == null || value == previous) return false

        transitions.addLast(KnobTransition(from = previous, to = value, timestampMillis = timestampMillis))
        prune(timestampMillis)
        if (transitions.size < config.knobActivationTransitions) return false
        if (!isAlternating()) return false

        reset()
        return true
    }

    fun reset() {
        transitions.clear()
        previousValue = null
    }

    private fun prune(nowMillis: Long) {
        while (
            transitions.isNotEmpty() &&
            nowMillis - transitions.first().timestampMillis > config.knobActivationWindowMillis
        ) {
            transitions.removeFirst()
        }
    }

    private fun isAlternating(): Boolean {
        val recent = transitions.takeLast(config.knobActivationTransitions)
        if (recent.size < config.knobActivationTransitions) return false
        return recent.zipWithNext().all { (left, right) ->
            left.from == right.to && left.to == right.from
        }
    }
}

class TemperatureModeActivationDetector(
    private val config: TemperatureModeDetectorConfig = TemperatureModeDetectorConfig()
) {
    private val knobDetector = HeadlightKnobActivationDetector(config)

    fun onPropertyValue(
        propertyId: Int,
        value: Int?,
        timestampMillis: Long
    ): TemperatureModeActivation = when (propertyId) {
        config.headlightSwitchPropertyId -> {
            if (knobDetector.onValue(value, timestampMillis)) {
                TemperatureModeActivation.HEADLIGHT_KNOB_SEQUENCE
            } else {
                TemperatureModeActivation.NONE
            }
        }
        else -> TemperatureModeActivation.NONE
    }

    fun reset() {
        knobDetector.reset()
    }
}

private data class KnobTransition(
    val from: Int,
    val to: Int,
    val timestampMillis: Long
)

private fun Int.toHexPropertyId(): String = "0x${toUInt().toString(16).uppercase()}"
