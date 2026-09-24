package com.timhss.capyenergy.helpers

import com.timhss.capyenergy.profile.SignalKey

import com.timhss.capyenergy.concurrent.namedSingleThreadScheduledExecutor
import com.timhss.capyenergy.telemetry.SignalSample
import com.timhss.capyenergy.telemetry.SignalStateStore
import com.timhss.capyenergy.telemetry.intValue
import com.timhss.capyenergy.vehicle.HvacClimateController
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

class TemperatureModeHelperMonitor(
    private val detector: TemperatureModeActivationDetector = TemperatureModeActivationDetector(),
    private val keyserverController: MediaKeyserverController,
    private val hvacClimateController: HvacClimateController,
    private val config: TemperatureModeDetectorConfig = TemperatureModeDetectorConfig(),
    private val audioFeedback: TemperatureModeAudioFeedback = NoopTemperatureModeAudioFeedback,
    private val enabledProvider: () -> Boolean = { true }
) : SignalStateStore.Listener {
    private var lastSignal: SignalKey? = null
    private var lastValue: Int? = null
    private var lastEventUtcMillis: Long? = null
    private var lastActivation: TemperatureModeActivation = TemperatureModeActivation.NONE
    private var lastActivationUtcMillis: Long? = null
    private var modeState: TemperatureModeState = TemperatureModeState.IDLE
    private var modeEnteredUtcMillis: Long? = null
    private var modeExitedUtcMillis: Long? = null
    private var modeExitReason: String? = null
    private var lastMediaAction: String? = null
    private var lastMediaActionUtcMillis: Long? = null
    private var lastHvacResult: Map<String, Any?>? = null
    private var lastKeyserverResult: KeyserverCommandResult? = null
    private var lastAudioCue: String? = null
    private var knobProgressCount = 0
    private var lastKnobProgressUtcMillis: Long? = null
    private val previousValues = mutableMapOf<SignalKey, Int?>()
    private val scheduler = namedSingleThreadScheduledExecutor("helper-monitor")
    private var idleTimeout: ScheduledFuture<*>? = null
    private var hardCapTimeout: ScheduledFuture<*>? = null

    @Synchronized
    override fun onSignalUpdated(sample: SignalSample, snapshot: Map<SignalKey, SignalSample>) {
        if (sample.signalId !in helperSignals) return
        if (!enabledProvider()) {
            if (modeState == TemperatureModeState.ACTIVE) exitMode("disabled")
            detector.reset()
            resetKnobProgress()
            return
        }
        val value = sample.intValue()
        val previous = previousValues[sample.signalId]
        previousValues[sample.signalId] = value
        lastSignal = sample.signalId
        lastValue = value
        lastEventUtcMillis = sample.timestampMillis
        val headlightTransition = sample.signalId == SignalKey.HEADLIGHTS_SWITCH &&
            value != null &&
            previous != null &&
            value != previous

        if (modeState == TemperatureModeState.ACTIVE) {
            if (isExitSignal(sample, value, previous)) {
                exitMode("manual ${sample.signalId.name}")
                return
            }
            handleMediaSignal(sample.signalId, value, previous)
            return
        }

        val activation = detector.onPropertyValue(
            propertyId = sample.propertyId,
            value = value,
            timestampMillis = sample.timestampMillis
        )
        if (activation != TemperatureModeActivation.NONE) {
            lastActivation = activation
            lastActivationUtcMillis = sample.timestampMillis
            enterMode(activation)
        } else if (headlightTransition) {
            playKnobProgress(sample.timestampMillis)
        }
    }

    @Synchronized
    fun statusMap(): Map<String, Any?> = mapOf(
        "enabled" to enabledProvider(),
        "lastSignal" to lastSignal?.name,
        "lastValue" to lastValue,
        "lastEventUtcMillis" to lastEventUtcMillis,
        "lastActivation" to lastActivation.name,
        "lastActivationUtcMillis" to lastActivationUtcMillis,
        "modeState" to modeState.name,
        "modeEnteredUtcMillis" to modeEnteredUtcMillis,
        "modeExitedUtcMillis" to modeExitedUtcMillis,
        "modeExitReason" to modeExitReason,
        "lastMediaAction" to lastMediaAction,
        "lastMediaActionUtcMillis" to lastMediaActionUtcMillis,
        "lastHvacResult" to lastHvacResult,
        "lastKeyserverAction" to lastKeyserverResult?.action,
        "lastKeyserverOk" to lastKeyserverResult?.ok,
        "lastKeyserverDetails" to lastKeyserverResult?.details,
        "lastAudioCue" to lastAudioCue
    )

    @Synchronized
    fun ensureKeyserverRestored() {
        lastKeyserverResult = keyserverController.ensureRestored()
        modeState = TemperatureModeState.IDLE
        cancelTimers()
        resetKnobProgress()
    }

    @Synchronized
    fun setEnabled(enabled: Boolean) {
        if (!enabled) {
            if (modeState == TemperatureModeState.ACTIVE) {
                exitMode("disabled")
            } else {
                lastKeyserverResult = keyserverController.ensureRestored()
            }
            detector.reset()
            resetKnobProgress()
        }
    }

    @Synchronized
    fun shutdown() {
        exitMode("collector stopped")
        audioFeedback.shutdown()
        scheduler.shutdownNow()
    }

    private fun enterMode(activation: TemperatureModeActivation) {
        if (modeState == TemperatureModeState.ACTIVE) return
        lastKeyserverResult = keyserverController.disable()
        modeState = TemperatureModeState.ACTIVE
        modeEnteredUtcMillis = System.currentTimeMillis()
        modeExitReason = null
        detector.reset()
        resetKnobProgress()
        playAudio("modeActive") { audioFeedback.modeActive() }
        armTimers()
        if (lastKeyserverResult?.ok != true) {
            exitMode("keyserver disable failed after ${activation.name}")
        }
    }

    private fun exitMode(reason: String) {
        if (modeState == TemperatureModeState.IDLE) return
        cancelTimers()
        modeState = TemperatureModeState.IDLE
        modeExitedUtcMillis = System.currentTimeMillis()
        modeExitReason = reason
        detector.reset()
        lastKeyserverResult = keyserverController.restore()
        resetKnobProgress()
        playAudio("modeExit") { audioFeedback.modeExit() }
    }

    private fun handleMediaSignal(signalId: SignalKey, value: Int?, previous: Int?) {
        if (value != MEDIA_KEY_PRESS_VALUE || previous == MEDIA_KEY_PRESS_VALUE) return
        val result = when (signalId) {
            SignalKey.MCU_KEY_CODE_VOLUME_INCREASE -> {
                lastMediaAction = "temperature +1"
                hvacClimateController.increaseTemperature()
            }
            SignalKey.MCU_KEY_CODE_VOLUME_DECREASE -> {
                lastMediaAction = "temperature -0.5"
                hvacClimateController.decreaseTemperature()
            }
            SignalKey.MCU_KEY_CODE_PLAY_NEXT -> {
                lastMediaAction = "fan +1"
                hvacClimateController.stepFanSpeed(1)
            }
            SignalKey.MCU_KEY_CODE_PLAY_PREVIOUS -> {
                lastMediaAction = "fan -1"
                hvacClimateController.stepFanSpeed(-1)
            }
            else -> null
        } ?: return
        lastMediaActionUtcMillis = System.currentTimeMillis()
        lastHvacResult = result
        if (result["ok"] == true) {
            when (signalId) {
                SignalKey.MCU_KEY_CODE_VOLUME_INCREASE,
                SignalKey.MCU_KEY_CODE_VOLUME_DECREASE -> {
                    playAudio("temperatureChanged") {
                        audioFeedback.temperatureChanged(result["appliedValue"] as? Number)
                    }
                }
                SignalKey.MCU_KEY_CODE_PLAY_NEXT,
                SignalKey.MCU_KEY_CODE_PLAY_PREVIOUS -> {
                    playAudio("fanSpeedChanged") {
                        audioFeedback.fanSpeedChanged(result["appliedValue"] as? Number)
                    }
                }
                else -> Unit
            }
        }
        armIdleTimer()
    }

    private fun isExitSignal(sample: SignalSample, value: Int?, previous: Int?): Boolean {
        return when (sample.signalId) {
            SignalKey.HEADLIGHTS_SWITCH -> value != null && previous != null && value != previous
            else -> false
        }
    }

    private fun armTimers() {
        armIdleTimer()
        hardCapTimeout?.cancel(false)
        hardCapTimeout = scheduler.schedule({
            synchronized(this@TemperatureModeHelperMonitor) { exitMode("hard cap") }
        }, config.hardCapMillis, TimeUnit.MILLISECONDS)
    }

    private fun armIdleTimer() {
        idleTimeout?.cancel(false)
        idleTimeout = scheduler.schedule({
            synchronized(this@TemperatureModeHelperMonitor) { exitMode("idle timeout") }
        }, config.mediaIdleTimeoutMillis, TimeUnit.MILLISECONDS)
    }

    private fun cancelTimers() {
        idleTimeout?.cancel(false)
        hardCapTimeout?.cancel(false)
        idleTimeout = null
        hardCapTimeout = null
    }

    private fun playKnobProgress(timestampMillis: Long) {
        val last = lastKnobProgressUtcMillis
        knobProgressCount = if (last == null || timestampMillis - last > config.knobActivationWindowMillis) {
            1
        } else {
            (knobProgressCount + 1).coerceAtMost(config.knobActivationTransitions)
        }
        lastKnobProgressUtcMillis = timestampMillis
        playAudio("knobProgress$knobProgressCount") {
            audioFeedback.knobProgress(knobProgressCount)
        }
    }

    private fun resetKnobProgress() {
        knobProgressCount = 0
        lastKnobProgressUtcMillis = null
    }

    private fun playAudio(cue: String, block: () -> Unit) {
        lastAudioCue = cue
        block()
    }

    companion object {
        private const val MEDIA_KEY_PRESS_VALUE = 1

        private val helperSignals = setOf(
            SignalKey.MCU_KEY_CODE_VOLUME_INCREASE,
            SignalKey.MCU_KEY_CODE_VOLUME_DECREASE,
            SignalKey.MCU_KEY_CODE_PLAY_PREVIOUS,
            SignalKey.MCU_KEY_CODE_PLAY_NEXT,
            SignalKey.HEADLIGHTS_SWITCH
        )
    }
}

enum class TemperatureModeState {
    IDLE,
    ACTIVE
}
