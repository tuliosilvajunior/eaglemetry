package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.IntervalEntity

/**
 * What a set of intervals adds up to, in Wh, discharge positive.
 *
 * The rollup is **by definition** the sum of the intervals it covers. One
 * function writes it and one function reads it, so a session total and the
 * minutes behind it cannot disagree — see the rollup invariant in
 * `IntervalFixtureTest`.
 *
 * This is a reduction, not an integration. The energy was made from a rate on
 * the car, at the bus rate, and stored one minute at a time. Nothing here
 * multiplies a rate by a duration.
 */
data class EnergyRollup(
    val tractionWh: Double = 0.0,
    val regenWh: Double = 0.0,
    val auxiliaryWh: Double = 0.0,
    val climateWh: Double = 0.0,
    val deliveredWh: Double = 0.0,
    val integratedSeconds: Double = 0.0,
    val climateIntegratedSeconds: Double = 0.0,
    val deliveredIntegratedSeconds: Double = 0.0,
    val distanceKm: Double = 0.0
) {
    /** Alias for backwards compatibility with callers expecting regeneratedWh. */
    val regeneratedWh: Double get() = regenWh

    /** Net energy taken from the pack: what was drawn, less what came back. */
    val netPackWh: Double
        get() = tractionWh - regenWh + auxiliaryWh

    /** Energy drawn before regeneration is credited back. */
    val drawnWh: Double
        get() = tractionWh + auxiliaryWh

    val isEmpty: Boolean
        get() = integratedSeconds <= 0.0 && deliveredIntegratedSeconds <= 0.0

    /**
     * Below a kilometre an efficiency figure is mostly quantization error, and
     * a net at or below zero has no efficiency to state.
     */
    val efficiencyWhPerKm: Double?
        get() = if (distanceKm >= MIN_EFFICIENCY_DISTANCE_KM && netPackWh > 0.0) {
            netPackWh / distanceKm
        } else {
            null
        }

    val kmPerKwh: Double?
        get() = if (distanceKm >= MIN_EFFICIENCY_DISTANCE_KM && netPackWh > 0.0) {
            distanceKm / (netPackWh / 1_000.0)
        } else {
            null
        }

    /** Share of traction energy that regeneration returned, or null below noise. */
    val regenerationRatio: Double?
        get() = if (tractionWh > 1.0) regenWh / tractionWh else null

    companion object {
        private const val MIN_EFFICIENCY_DISTANCE_KM = 1.0
    }
}

/**
 * Folds intervals into their rollup.
 *
 * Each IntervalEntity already has its single distanceKm chosen,
 * and deliveredWh for charge sessions.
 */
fun Iterable<IntervalEntity>.rollup(): EnergyRollup {
    var traction = 0.0
    var regen = 0.0
    var auxiliary = 0.0
    var climate = 0.0
    var delivered = 0.0
    var seconds = 0.0
    var climateSeconds = 0.0
    var deliveredSeconds = 0.0
    var distance = 0.0
    for (interval in this) {
        traction += interval.tractionWh
        regen += interval.regenWh
        auxiliary += interval.auxiliaryWh
        climate += interval.climateWh
        delivered += interval.deliveredWh
        seconds += interval.coveredSeconds
        climateSeconds += interval.climateCoveredSeconds
        deliveredSeconds += interval.deliveredCoveredSeconds
        distance += interval.distanceKm
    }
    return EnergyRollup(
        tractionWh = traction,
        regenWh = regen,
        auxiliaryWh = auxiliary,
        climateWh = climate,
        deliveredWh = delivered,
        integratedSeconds = seconds,
        climateIntegratedSeconds = climateSeconds,
        deliveredIntegratedSeconds = deliveredSeconds,
        distanceKm = distance
    )
}
