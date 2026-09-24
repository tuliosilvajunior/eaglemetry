package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.ChargeSample

/**
 * Charge-session math shared by the native detail endpoint. Mirrors the Dart
 * helpers historically used by the charge detail screen so values stay stable
 * across the migration to native aggregation.
 *
 * Takes [ChargeSample] rather than the full frame entity so the list and detail
 * paths can read a four-column projection instead of `SELECT *`.
 */
object ChargeEnergy {

    /** Explicit charge power, falling back to |V x I| when absent. */
    fun framePowerKw(frame: ChargeSample): Double? {
        frame.powerKw?.let { return kotlin.math.abs(it.toDouble()) }
        val voltage = frame.voltageV ?: return null
        val current = frame.currentA ?: return null
        return voltage.toDouble() * kotlin.math.abs(current.toDouble()) / 1_000.0
    }

    /**
     * Zero is not a measurement in the historical electrical charts.
     *
     * On DC sessions the wall-side `DCHA_CHARGE_ACDC_*` pair is bypassed and
     * publishes 0 V / 0 A while the independent DC power signal remains valid.
     * Keeping those zeros would draw authoritative-looking empty curves.
     */
    fun chartVoltageV(frame: ChargeSample): Double? =
        frame.voltageV?.toDouble()?.takeIf { it > 0.0 }

    fun chartCurrentA(frame: ChargeSample): Double? =
        frame.currentA?.toDouble()?.let { kotlin.math.abs(it) }?.takeIf { it > 0.0 }

    /** Trapezoidal power integration; frames must be sorted by elapsed time. */
    fun estimatedEnergyKwh(frames: List<ChargeSample>): Double? {
        val powerFrames = frames.mapNotNull { frame ->
            framePowerKw(frame)?.let { frame to it }
        }
        if (powerFrames.size < 2) return null
        var energyKwh = 0.0
        for (index in 1 until powerFrames.size) {
            val (previousFrame, previousPower) = powerFrames[index - 1]
            val (currentFrame, currentPower) = powerFrames[index]
            val deltaSeconds =
                (currentFrame.elapsedRealtimeNanos - previousFrame.elapsedRealtimeNanos) / 1e9
            if (deltaSeconds <= 0.0 || deltaSeconds > MAX_GAP_SECONDS) continue
            val averagePower =
                (previousPower.coerceIn(0.0, MAX_POWER_KW) + currentPower.coerceIn(0.0, MAX_POWER_KW)) / 2.0
            energyKwh += averagePower * (deltaSeconds / 3_600.0)
        }
        return energyKwh
    }

    fun averagePowerKw(frames: List<ChargeSample>): Double? {
        val powers = frames.mapNotNull { framePowerKw(it) }
        if (powers.isEmpty()) return null
        return powers.sum() / powers.size
    }

    private const val MAX_GAP_SECONDS = 60.0
    private const val MAX_POWER_KW = 400.0
}
