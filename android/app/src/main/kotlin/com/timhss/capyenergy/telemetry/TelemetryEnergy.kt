package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.CanPowerSample
import com.timhss.capyenergy.telemetry.db.ChargeSample
import kotlin.math.abs

/**
 * Trip energy from integrated CAN power, in Wh, with discharge positive.
 *
 * `packWh = tractionWh - regeneratedWh + auxiliaryWh` holds by construction,
 * because all four come from the same frames over the same intervals.
 */
internal data class TripPowerIntegral(
    val packWh: Double,
    val tractionWh: Double,
    val regeneratedWh: Double,
    val auxiliaryWh: Double,
    /** Seconds actually integrated, so callers can judge the coverage. */
    val integratedSeconds: Double
) {
    /** Share of traction energy that regeneration returned, or null below noise. */
    val regenerationRatio: Double?
        get() = if (tractionWh > 1.0) regeneratedWh / tractionWh else null
}

/**
 * Running total of the CAN power integral.
 *
 * The trip integral has to serve two callers: a materialized list in tests and
 * the paged sweep that finalizes a session in production. This is the one place
 * the maths lives, so the two cannot drift.
 *
 * A row missing any part of the triple is skipped without breaking the series,
 * so the interval simply spans it.
 */
internal class TripPowerAccumulator {
    private var hasPrevious = false
    private var previousNanos = 0L
    private var previousPackKw = 0.0
    private var previousDriveKw = 0.0

    private var packWh = 0.0
    private var tractionWh = 0.0
    private var regeneratedWh = 0.0
    private var auxiliaryWh = 0.0
    private var seconds = 0.0

    fun add(sample: CanPowerSample) {
        if (sample.elapsedRealtimeNanos <= 0L) return
        val packKw = TelemetryEnergy.packPowerKw(sample) ?: return
        val driveKw = sample.canDrivePowerKw?.toDouble()?.takeIf { it.isFinite() } ?: return

        if (hasPrevious) {
            val deltaSeconds =
                (sample.elapsedRealtimeNanos - previousNanos) / 1_000_000_000.0
            // A longer gap is missing data, not a plateau to integrate across.
            if (deltaSeconds > 0.0 && deltaSeconds <= TelemetryEnergy.MAX_CAN_GAP_SECONDS) {
                val wh = deltaSeconds / 3_600.0 * 1_000.0
                packWh += mean(previousPackKw, packKw) * wh
                tractionWh += mean(
                    previousDriveKw.coerceAtLeast(0.0),
                    driveKw.coerceAtLeast(0.0)
                ) * wh
                regeneratedWh += mean(
                    (-previousDriveKw).coerceAtLeast(0.0),
                    (-driveKw).coerceAtLeast(0.0)
                ) * wh
                auxiliaryWh += mean(
                    previousPackKw - previousDriveKw,
                    packKw - driveKw
                ) * wh
                seconds += deltaSeconds
            }
        }
        hasPrevious = true
        previousNanos = sample.elapsedRealtimeNanos
        previousPackKw = packKw
        previousDriveKw = driveKw
    }

    fun result(): TripPowerIntegral? {
        if (seconds <= 0.0) return null
        return TripPowerIntegral(
            packWh = packWh,
            tractionWh = tractionWh,
            regeneratedWh = regeneratedWh,
            auxiliaryWh = auxiliaryWh,
            integratedSeconds = seconds
        )
    }

    private fun mean(previous: Double, current: Double): Double = (previous + current) / 2.0
}

/**
 * A trip's energy, in kWh, from the CAN power integral. Discharge positive.
 *
 * The three terms come from the same frames over the same intervals, so
 * `netKwh = tractionKwh - regeneratedKwh + auxiliaryKwh` holds by construction
 * rather than by agreement between two measurements.
 *
 * `consumedKwh` is what left the pack to move the car and to run everything
 * else: traction plus auxiliary. It is not a second quantity — it is a reading
 * of the same three terms, kept because every screen and every export row is
 * spelled `consumed` / `regenerated` / `net`.
 */
internal data class TripEnergyBreakdown(
    val tractionKwh: Double = 0.0,
    val regeneratedKwh: Double = 0.0,
    val auxiliaryKwh: Double = 0.0
) {
    val consumedKwh: Double
        get() = tractionKwh + auxiliaryKwh

    val netKwh: Double
        get() = (consumedKwh - regeneratedKwh).coerceAtLeast(0.0)
}

/** The stored integral, read as the trip's energy. */
internal fun TripPowerIntegral.toBreakdown(): TripEnergyBreakdown = TripEnergyBreakdown(
    tractionKwh = tractionWh / 1_000.0,
    regeneratedKwh = regeneratedWh / 1_000.0,
    auxiliaryKwh = auxiliaryWh / 1_000.0
)

/**
 * Trip energy comes from the CAN power integral, and from nothing else.
 *
 * SOC is a state. An energy is made from a rate. Multiplying SOC by a stated
 * pack capacity manufactured an energy out of a state, and the car then held
 * two answers for one trip that did not agree. That SOC-times-capacity model
 * was removed on 2026-08-19.
 *
 * SOC stays as a recorded state — the curve, the session endpoints, and the
 * direction check in [integralAgreesWithSoc]. It is never multiplied by a
 * capacity here again.
 *
 * Distance for Wh/km lives outside this helper (odometer preferred, speed
 * fallback).
 */
internal object TelemetryEnergy {
    /** Ignore SOC jitter below this percentage change. */
    const val SOC_NOISE_PERCENT = 0.05
    /** Below this distance an efficiency figure is mostly quantization error. */
    private const val MIN_EFFICIENCY_DISTANCE_KM = 1.0

    /**
     * Frames further apart than this are a data gap. Trip frames arrive at about
     * 1.06 s, so ten seconds is roughly nine missed frames.
     */
    const val MAX_CAN_GAP_SECONDS = 10.0

    const val FRESH_SOC_MASK = 1 shl 0
    const val FRESH_SPEED_MASK = 1 shl 1
    const val FRESH_ODOMETER_MASK = 1 shl 2
    const val FRESH_VOLTAGE_MASK = 1 shl 3
    const val FRESH_CURRENT_MASK = 1 shl 4
    const val FRESH_DC_POWER_MASK = 1 shl 5
    const val FRESH_INSTANT_POWER_MASK = 1 shl 6
    const val FRESH_GEAR_MASK = 1 shl 7
    const val FRESH_CHARGE_STATE_MASK = 1 shl 8
    const val FRESH_CHARGE_PLUG_TYPE_MASK = 1 shl 9

    /**
     * Trip energy from integrated CAN power, in Wh, discharge positive.
     *
     * Trapezoidal and time-weighted over the frames that carry the whole
     * voltage, current and drive-power triple, so the components are measured
     * over the same intervals and the breakdown balances by construction rather
     * than by luck.
     *
     * This owes nothing to pack capacity and nothing to where the pack sits on
     * its voltage curve, which is the point of it. LFP holds an almost flat
     * open-circuit voltage across the middle of its range, so the BMS falls back
     * on coulomb counting there and drifts — and every trip this vehicle has
     * recorded sat between 39 % and 67 % SOC, the centre of that plateau. SOC
     * stays as the slow absolute reference to check this against, not as the
     * instrument that produces the number.
     */
    fun tripPowerIntegral(frames: List<CanPowerSample>): TripPowerIntegral? {
        val accumulator = TripPowerAccumulator()
        frames.sortedBy { it.elapsedRealtimeNanos }.forEach(accumulator::add)
        return accumulator.result()
    }

    /**
     * Whether the power integral moved in the direction SOC says it must.
     *
     * This is a **direction check, not a second measurement**. SOC is a state,
     * so it cannot be turned into an energy to compare against (decision 5).
     * What it can still say is which way the pack went: a trip that ended lower
     * than it started must report a net discharge.
     *
     * The check earns its place on this vehicle. Frames recorded before
     * 2026-08-02 carry `BMSH_BattCurr` with the opposite sign, and that signal
     * has reversed between daemon builds more than once. An inverted integral
     * fails here instead of reaching a screen as negative consumption.
     *
     * Returns null when SOC did not move enough to state a direction, which is
     * an unconfirmed sign rather than a contradiction. A scale error is not
     * caught, and never was.
     */
    fun integralAgreesWithSoc(
        integralWh: Double,
        startSoc: Double?,
        endSoc: Double?
    ): Boolean? {
        val start = startSoc ?: return null
        val end = endSoc ?: return null
        val dropPercent = start - end
        if (abs(dropPercent) < SOC_NOISE_PERCENT) return null
        if (abs(integralWh) < 1.0) return null
        return (dropPercent > 0.0) == (integralWh > 0.0)
    }

    /** Pack power in kW, discharge positive, or null without the whole pair. */
    fun packPowerKw(sample: CanPowerSample): Double? {
        val volts = sample.canPackVoltageV?.toDouble() ?: return null
        val amps = sample.canPackCurrentA?.toDouble() ?: return null
        if (volts <= 0.0) return null
        return (volts * amps / 1_000.0).takeIf { it.isFinite() }
    }

    /** Efficiency for a single trip, gated on distance. */
    fun efficiencyWhPerKm(energy: TripEnergyBreakdown, distanceKm: Double?): Double? =
        aggregateEfficiencyWhPerKm(energy.netKwh, distanceKm)

    /** Range efficiency for a single trip, gated on distance. */
    fun kmPerKwh(energy: TripEnergyBreakdown, distanceKm: Double?): Double? =
        aggregateKmPerKwh(energy.netKwh, distanceKm)

    /** Efficiency across multiple trips; only the distance gate applies. */
    fun aggregateEfficiencyWhPerKm(netKwh: Double, distanceKm: Double?): Double? {
        if (distanceKm == null || distanceKm < MIN_EFFICIENCY_DISTANCE_KM || netKwh <= 0.0) {
            return null
        }
        return netKwh * 1_000.0 / distanceKm
    }

    /** Range efficiency across multiple trips; only the distance gate applies. */
    fun aggregateKmPerKwh(netKwh: Double, distanceKm: Double?): Double? {
        if (distanceKm == null || distanceKm < MIN_EFFICIENCY_DISTANCE_KM || netKwh <= 0.0) {
            return null
        }
        return distanceKm / netKwh
    }

    fun chargeEnergyKwh(frames: List<ChargeSample>, maxDeltaSeconds: Double = 60.0): Double? {
        val sorted = frames
            .mapNotNull { frame -> chargePowerKw(frame)?.let { frame to it } }
            .filter { it.first.elapsedRealtimeNanos > 0L }
            .sortedBy { it.first.elapsedRealtimeNanos }
        if (sorted.size < 2) return null

        var energy = 0.0
        for (index in 1 until sorted.size) {
            val previous = sorted[index - 1]
            val current = sorted[index]
            val deltaSeconds =
                (current.first.elapsedRealtimeNanos - previous.first.elapsedRealtimeNanos) / 1_000_000_000.0
            if (deltaSeconds <= 0.0 || deltaSeconds > maxDeltaSeconds) continue
            val averagePower = (previous.second + current.second) / 2.0
            energy += averagePower * (deltaSeconds / 3600.0)
        }
        return energy.takeIf { it > 0.0001 }
    }

    private fun chargePowerKw(frame: ChargeSample): Double? {
        if (frame.isFresh(FRESH_DC_POWER_MASK)) {
            return frame.powerKw?.toDouble()?.let(::abs)
        }

        val current = frame.currentA?.takeIf { frame.isFresh(FRESH_CURRENT_MASK) }
        val voltage = frame.voltageV?.takeIf { frame.isFresh(FRESH_VOLTAGE_MASK) }
        if (current != null && voltage != null && voltage > 0f) {
            return abs(current.toDouble()) * voltage.toDouble() / 1_000.0
        }

        return null
    }

    private fun ChargeSample.isFresh(mask: Int): Boolean = freshnessMask and mask != 0
}
