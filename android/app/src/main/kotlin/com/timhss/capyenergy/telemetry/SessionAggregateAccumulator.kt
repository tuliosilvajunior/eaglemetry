package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey
import com.timhss.capyenergy.telemetry.db.SessionAggregateSampleRow
import kotlin.math.abs

/**
 * Replays every row of one session, in elapsed-time order, however the caller
 * has them: a materialized list in tests, or paged reads against Room.
 */
internal fun interface SessionSampleSweep {
    fun forEach(consume: (SessionAggregateSampleRow) -> Unit)
}

private const val AGGREGATE_PAGE_SIZE = 500

/**
 * Session aggregation in constant memory.
 *
 * The previous shape loaded the whole session with `aggregateSamplesForSession`
 * and folded over the list — the same materialization the historical detail path
 * had already been rewritten to avoid, still present on the finalization and
 * retention paths, and in the finalizer's case performed while holding the write
 * transaction. Everything here is either a running scalar or a one-sample
 * lookback, so the cost no longer scales with session length.
 *
 * The trip SOC breakdown genuinely needs two passes: the anchored walk's deadband
 * is derived from the quantization step, which is itself only known after seeing
 * the whole series. [add] detects the step, [walk] spends it. Charge sessions need
 * only the first pass. Paging the same indexed query twice costs less than holding
 * thousands of rows in RAM.
 */
internal class SessionAggregateAccumulator {
    private var frameCount = 0L
    private var lastElapsedNanos: Long? = null

    private var minSoc: Float? = null
    private var maxSoc: Float? = null
    private var firstSoc: Float? = null
    private var lastSoc: Float? = null

    private var powerSum = 0.0
    private var powerCount = 0L
    private var maxPower: Float? = null

    private var speedSum = 0.0
    private var speedCount = 0L
    private var maxSpeed: Float? = null

    private var previousSpeed: Pair<Long, Float>? = null
    private var speedDistanceKm = 0.0

    private var firstOdometerKm: Float? = null
    private var lastOdometerKm: Float? = null

    /** Freshness-aware integral, the durable `energyKwhEstimate`. */
    private var durablePrevious: Pair<Long, Double>? = null
    private var durableEnergyKwh = 0.0
    private var durableCount = 0L

    /** Display integral, clamped, mirroring [ChargeEnergy.estimatedEnergyKwh]. */
    private var displayPrevious: Pair<Long, Double>? = null
    private var displayEnergyKwh = 0.0
    private var displayCount = 0L

    // Layer 1: the CAN power integral, filled by the same single pass.
    private val canPower = TripPowerAccumulator()

    fun add(row: SessionAggregateSampleRow) {
        frameCount += 1
        lastElapsedNanos = row.elapsedRealtimeNanos
        canPower.add(row)

        row.socPercent?.let { soc ->
            if (firstSoc == null) firstSoc = soc
            lastSoc = soc
            minSoc = minSoc?.let { minOf(it, soc) } ?: soc
            maxSoc = maxSoc?.let { maxOf(it, soc) } ?: soc
        }

        row.powerKw?.let { power ->
            val magnitude = abs(power)
            powerSum += magnitude
            powerCount += 1
            maxPower = maxPower?.let { maxOf(it, magnitude) } ?: magnitude
        }

        row.speedKmh?.let { speed ->
            speedSum += speed
            speedCount += 1
            maxSpeed = maxSpeed?.let { maxOf(it, speed) } ?: speed
            previousSpeed?.let { (previousNanos, previousValue) ->
                val seconds = (row.elapsedRealtimeNanos - previousNanos) / 1e9
                if (seconds > 0.0 && seconds <= MAX_SPEED_GAP_SECONDS) {
                    speedDistanceKm +=
                        ((previousValue.toDouble() + speed.toDouble()) / 2.0) * seconds / 3600.0
                }
            }
            previousSpeed = row.elapsedRealtimeNanos to speed
        }

        row.odometerKm?.let { odometer ->
            if (firstOdometerKm == null) firstOdometerKm = odometer
            lastOdometerKm = odometer
        }

        durableChargePowerKw(row)?.let { power ->
            durableCount += 1
            durablePrevious?.let { (previousNanos, previousPower) ->
                val seconds = (row.elapsedRealtimeNanos - previousNanos) / 1e9
                if (seconds > 0.0 && seconds <= MAX_CHARGE_GAP_SECONDS) {
                    durableEnergyKwh += ((previousPower + power) / 2.0) * (seconds / 3600.0)
                }
            }
            durablePrevious = row.elapsedRealtimeNanos to power
        }

        ChargeEnergy.framePowerKw(row)?.let { power ->
            displayCount += 1
            displayPrevious?.let { (previousNanos, previousPower) ->
                val seconds = (row.elapsedRealtimeNanos - previousNanos) / 1e9
                if (seconds > 0.0 && seconds <= MAX_CHARGE_GAP_SECONDS) {
                    val average = (previousPower.coerceIn(0.0, MAX_POWER_KW) +
                        power.coerceIn(0.0, MAX_POWER_KW)) / 2.0
                    displayEnergyKwh += average * (seconds / 3600.0)
                }
            }
            displayPrevious = row.elapsedRealtimeNanos to power
        }

        row.ambientTempC?.let { temp ->
            if (firstAmbientTempC == null) firstAmbientTempC = temp
            lastAmbientTempC = temp
            ambientTempSum += temp
            ambientTempCount += 1
        }
    }

    private var firstAmbientTempC: Float? = null
    private var lastAmbientTempC: Float? = null
    private var ambientTempSum = 0.0
    private var ambientTempCount = 0L

    fun firstAmbientTempC(): Float? = firstAmbientTempC
    fun lastAmbientTempC(): Float? = lastAmbientTempC
    fun meanAmbientTempC(): Float? = if (ambientTempCount == 0L) null else (ambientTempSum / ambientTempCount).toFloat()

    fun frameCount(): Long = frameCount

    fun lastElapsedNanos(): Long? = lastElapsedNanos

    fun minSoc(): Float? = minSoc

    fun maxSoc(): Float? = maxSoc

    fun avgPowerKw(): Float? = if (powerCount == 0L) null else (powerSum / powerCount).toFloat()

    fun maxPowerKw(): Float? = maxPower

    fun avgSpeedKmh(): Float? = if (speedCount == 0L) null else (speedSum / speedCount).toFloat()

    fun maxSpeedKmh(): Float? = maxSpeed

    fun speedDistanceKm(): Double? = speedDistanceKm.takeIf { speedCount >= 2 && it > 0.0001 }

    /**
     * Frame-derived odometer distance. Not part of the stored aggregate — the
     * session row's own endpoints are authoritative there — but the live and
     * detail screens fall back to it when a session has no odometer endpoints.
     */
    fun odometerDistanceKm(): Double? {
        val first = firstOdometerKm ?: return null
        val last = lastOdometerKm ?: return null
        return (last - first).toDouble().takeIf { it >= 0.0 }
    }

    /** Matches [TelemetryEnergy.chargeEnergyKwh]. */
    fun durableChargeEnergyKwh(): Double? =
        if (durableCount < 2) null else durableEnergyKwh.takeIf { it > 0.0001 }

    /** Matches [ChargeEnergy.estimatedEnergyKwh]. */
    fun displayChargeEnergyKwh(): Double? = if (displayCount < 2) null else displayEnergyKwh

    /** SOC at the first and last sample that carried one. */
    fun firstSoc(): Float? = firstSoc

    fun lastSoc(): Float? = lastSoc

    /**
     * The session's energy, or null when it carries no usable CAN power. This
     * is the only energy a trip has; see [TelemetryEnergy].
     */
    fun tripPowerIntegral(): TripPowerIntegral? = canPower.result()

    private fun durableChargePowerKw(row: SessionAggregateSampleRow): Double? {
        if (row.freshnessMask and TelemetryEnergy.FRESH_DC_POWER_MASK != 0) {
            return row.powerKw?.toDouble()?.let(::abs)
        }
        val current = row.currentA
            ?.takeIf { row.freshnessMask and TelemetryEnergy.FRESH_CURRENT_MASK != 0 }
        val voltage = row.voltageV
            ?.takeIf { row.freshnessMask and TelemetryEnergy.FRESH_VOLTAGE_MASK != 0 }
        if (current != null && voltage != null && voltage > 0f) {
            return abs(current.toDouble()) * voltage.toDouble() / 1_000.0
        }
        return null
    }

    private companion object {
        const val MAX_SPEED_GAP_SECONDS = 10.0
        private const val MAX_CHARGE_GAP_SECONDS = 60.0
        private const val MAX_POWER_KW = 400.0
    }
}
