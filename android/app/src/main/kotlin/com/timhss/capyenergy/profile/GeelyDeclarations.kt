package com.timhss.capyenergy.profile

import kotlin.math.abs

/**
 * What every signal on this vehicle is, and how a raw reading becomes a
 * canonical value.
 *
 * The **numbers** live here. The judgement stays with the collection layer:
 * `SignalEventPolicy` still decides that a quality change is always worth a
 * row, and it reads how far state of charge must drift from this file. Two
 * deadbands for one signal is the class of defect layer 0 exists to remove.
 *
 * The sample deadbands are measured, not preferred: each one is the band the
 * measurement lens chose. Do not change one without re-running the lens.
 */
/** The AutoEnergy consumption shares, reported as floats. */
private val ENERGY_FLOW_SHARE_KEYS = listOf(
    SignalKey.ED_DRIVING_ENERGY_FLOW,
    SignalKey.TRIP_ED_DRIVING_ENERGY_FLOW,
    SignalKey.TRIP_ED_DRIVING_ENERGY_FLOW_VENDOR
)

/** Probes whose scale is unknown until observed on a live drive. */
private val RAW_COUNT_KEYS = listOf(
    SignalKey.HYBRID_POWER_FLOW,
    SignalKey.BMSH_BAT_CURRENT,
    SignalKey.BMSH_PACK_VOLT,
    SignalKey.BMSH_BUS_VOLT,
    SignalKey.BMSH_BAT_SOE,
    SignalKey.DISCHARGING_CURRENT_PWR,
    SignalKey.DRIVE_POWER_OUT_PUT,
    SignalKey.VCU_AC_VCU_POWER_ACTUAL,
    SignalKey.GCU_ACT_INPUT_VOLT,
    SignalKey.GCU_ACT_INPUT_CURRENT,
    SignalKey.IPU_MOTOR_TQ,
    SignalKey.IPU_MOTOR_SPD,
    SignalKey.BATTERY_CURR,
    SignalKey.VCU_ACC_PEDAL_POSITION,
    SignalKey.IPK_AVERAGE_POWER_CONSUMPTION,
    SignalKey.ADAS_ACC_SPEED_VALUE
)

/**
 * Collected, and not carried by the sample series.
 *
 * This list is the series membership: a declaration's `sampled` is derived
 * from it when the map is built, so restoring a signal is one line here and
 * nowhere else. Each entry below names the measurement that put it there.
 *
 * Measured on `sample_2026_08` over 23-25 Aug 2026, every vehicle:
 * - `IPK_AVERAGE_POWER_CONSUMPTION` held one value, 328.0, for every row.
 * - `HYBRID_POWER_FLOW`, `TRIP_ED_DRIVING_ENERGY_FLOW_VENDOR`,
 *   `DRIVE_POWER_OUT_PUT` and `ADAS_ACC_SPEED_VALUE` held 0.0 for every row.
 * - `BATTERY_SOH_PERCENT` wrote 53 rows and every one was `INVALID`: the
 *   property is polled, the polling read carries no source timestamp, and
 *   `stateOfHealthPercent` needs one to tell 99.9 % from the factory default.
 *   Its event log still records each change, which is the history it needs.
 * - `TRIP_ED_DRIVING_ENERGY_FLOW` is the shadow half of a comparison that has
 *   answered: it resolves to the same property as `ED_DRIVING_ENERGY_FLOW`,
 *   and 1 701 of 1 701 pairs sharing a millisecond held the same value. The
 *   spec stays so the probe can be retaken; only the second series stops.
 *
 * Issue 184: the series carries exactly what a reader asks for. The read side
 * is `kTripDetailSampleKeys` + `kChargeDetailSampleKeys` in
 * `packages/telemetry_core/lib/session_detail_reading.dart` (4 keys:
 * `VEHICLE_SPEED`, `HV_BATTERY_SOC`, `ODOMETER`, `PACK_VOLTAGE`). Every other
 * `STATE` declaration is added here, with the measurement that stopped needing
 * a series row:
 * - `RANGE_REMAINING`: no screen draws the remaining range.
 * - `HV_BATTERY_VOLTAGE`: no screen draws the pack voltage; the charge detail
 *   reads `PACK_VOLTAGE`, a different property.
 * - `AC_INPUT_VOLTAGE`, `ROAD_INCLINE`, `ACCEL_PEDAL`, `BUS_VEHICLE_SPEED`,
 *   `REGEN_TORQUE`: no screen draws them.
 * - `EV_CHARGE_ESTIMATED_TIME`: the charge screen does not draw it.
 * - `AMBIENT_AIR_TEMPERATURE`, `OUTSIDE_TEMPERATURE`: `Session` carries
 *   start/end/mean ambient as a tile (issue 181).
 * - `LATITUDE`, `LONGITUDE`, `ALTITUDE`, `GPS_ACCURACY`: `Track` carries the
 *   route (issue 184). The tuple's deadband now drives `Track`, not rows.
 * - `ED_DRIVING_ENERGY_FLOW`: the energy-flow comparison answered (issue 173);
 *   the shadow half `TRIP_ED_DRIVING_ENERGY_FLOW` was already here.
 * - The remaining raw probes (`BMSH_*`, `DISCHARGING_CURRENT_PWR`,
 *   `VCU_AC_VCU_POWER_ACTUAL`, `GCU_ACT_*`, `IPU_*`, `BATTERY_CURR`,
 *   `VCU_ACC_PEDAL_POSITION`) never answered a read path; they stay declared
 *   and collected so a scale found next month can be applied to this month's
 *   drives (ADR-0010 kept the catalogue entry).
 *
 * Each stays declared and collected. Restoring one to the series is this list,
 * and `SampleSeriesMembershipTest` fails when the two sides diverge.
 */
private val UNSAMPLED_KEYS = setOf(
    // Issue 173 / ADR-0010: measured constant or shadow-half probes.
    SignalKey.IPK_AVERAGE_POWER_CONSUMPTION,
    SignalKey.HYBRID_POWER_FLOW,
    SignalKey.TRIP_ED_DRIVING_ENERGY_FLOW_VENDOR,
    SignalKey.TRIP_ED_DRIVING_ENERGY_FLOW,
    SignalKey.DRIVE_POWER_OUT_PUT,
    SignalKey.ADAS_ACC_SPEED_VALUE,
    SignalKey.BATTERY_SOH_PERCENT,
    // Issue 184: unread STATE signals, temperature on Session, position on Track.
    SignalKey.RANGE_REMAINING,
    SignalKey.HV_BATTERY_VOLTAGE,
    SignalKey.AC_INPUT_VOLTAGE,
    SignalKey.ROAD_INCLINE,
    SignalKey.ACCEL_PEDAL,
    SignalKey.BUS_VEHICLE_SPEED,
    SignalKey.REGEN_TORQUE,
    SignalKey.EV_CHARGE_ESTIMATED_TIME,
    SignalKey.AMBIENT_AIR_TEMPERATURE,
    SignalKey.OUTSIDE_TEMPERATURE,
    SignalKey.LATITUDE,
    SignalKey.LONGITUDE,
    SignalKey.ALTITUDE,
    SignalKey.GPS_ACCURACY,
    SignalKey.ED_DRIVING_ENERGY_FLOW,
    SignalKey.BMSH_BAT_CURRENT,
    SignalKey.BMSH_PACK_VOLT,
    SignalKey.BMSH_BUS_VOLT,
    SignalKey.BMSH_BAT_SOE,
    SignalKey.DISCHARGING_CURRENT_PWR,
    SignalKey.VCU_AC_VCU_POWER_ACTUAL,
    SignalKey.GCU_ACT_INPUT_VOLT,
    SignalKey.GCU_ACT_INPUT_CURRENT,
    SignalKey.IPU_MOTOR_TQ,
    SignalKey.IPU_MOTOR_SPD,
    SignalKey.BATTERY_CURR,
    SignalKey.VCU_ACC_PEDAL_POSITION
)

/** Switches, modes and momentary keys. Every change is a transition. */
private val DISCRETE_COUNT_KEYS = listOf(
    SignalKey.MCU_KEY_CODE_RESUME_CRUISE_INCREASE,
    SignalKey.MCU_KEY_CODE_RESUME_CRUISE_DECREASE,
    SignalKey.MCU_KEY_CODE_CRUISE_DISTANCE_INCREASE,
    SignalKey.MCU_KEY_CODE_CRUISE_DISTANCE_DECREASE,
    SignalKey.CRUISE_SWITCH_STATUS,
    SignalKey.ADAS_ACC_CRUISE_MODE,
    SignalKey.MCU_KEY_CODE_VOLUME_INCREASE,
    SignalKey.MCU_KEY_CODE_VOLUME_DECREASE,
    SignalKey.MCU_KEY_CODE_PLAY_PREVIOUS,
    SignalKey.MCU_KEY_CODE_PLAY_NEXT,
    SignalKey.VEHIC_RKE_LOCK_FEEDBACK,
    SignalKey.VEHIC_RLS,
    SignalKey.DOOR_MOVE,
    SignalKey.HEADLIGHTS_SWITCH,
    SignalKey.DOOR_POS_FRONT_LEFT,
    SignalKey.DOOR_POS_FRONT_RIGHT,
    SignalKey.DOOR_POS_REAR_LEFT,
    SignalKey.DOOR_POS_REAR_RIGHT,
    SignalKey.BCM_HOOD_STATUS,
    SignalKey.BODY_DOOR_TRUNK_DOOR_POS,
    SignalKey.LOCK_HOOD,
    SignalKey.BODY_BUCKLE_SWITCH_STATUS,
    SignalKey.ACU_PASS_SEAT_OCCUPANT_SENSOR_ST,
    SignalKey.IPKWARN_DRV_SEAT_BELT,
    SignalKey.IPKWARN_PASS_SEAT_BELT,
    SignalKey.ACU_DRV_SEAT_BELT_BUCKLE_INVALID,
    SignalKey.PEPS_POWER_MODE,
    SignalKey.PEPS_POWER_MODE_VAILD,
    SignalKey.PEPS_USAGE_MODE,
    SignalKey.PEPS_USAGE_MODE_VALIDITY,
    SignalKey.PEPS_REMOTE_CTL_STS,
    SignalKey.PEPS_RESPONSE_STS,
    SignalKey.PARKING_COMFORT_SWT,
    SignalKey.PARKING_NAP_SWT,
    SignalKey.AC_PARKINGCLIMATESET
)

internal val geelyDeclarations: Map<SignalKey, SignalDeclaration> = buildList {

    // --- Energy and motion --------------------------------------------------

    add(
        SignalDeclaration(
            key = SignalKey.HV_BATTERY_SOC,
            nature = SignalNature.STATE,
            transform = ::stateOfChargePercent,
            band = SignalBand(0.0, 100.0),
            // 0.5 % for the event log, which records what a person would
            // notice. 0.1 % for the sample series, which a chart is drawn from:
            // at 0.5 % three quarters of the kept rows are written by the
            // maximum gap rather than by movement, so the series stops
            // describing the curve and starts describing the clock.
            deadbands = SignalDeadbands(event = 0.5, sample = 0.1),
            maxGapMillis = GeelyProfile.SAMPLE_MAX_GAP_MILLIS
        )
    )
    add(
        SignalDeclaration(
            key = SignalKey.VEHICLE_SPEED,
            nature = SignalNature.STATE,
            transform = ::vehicleSpeedKmh,
            band = SignalBand(0.0, SPEED_MAX_KMH.toDouble()),
            deadbands = SignalDeadbands(sample = 1.0),
            maxGapMillis = GeelyProfile.SAMPLE_MAX_GAP_MILLIS
        )
    )
    add(
        SignalDeclaration(
            key = SignalKey.ODOMETER,
            nature = SignalNature.STATE,
            transform = ::nonNegativeMeasuredFloat,
            // Every change is a transition worth recording: the odometer moves
            // in steps the vehicle chooses, and the event log is where a step
            // that skipped is visible.
            everyChangeIsAnEvent = true,
            deadbands = SignalDeadbands(sample = 0.1),
            maxGapMillis = GeelyProfile.SAMPLE_MAX_GAP_MILLIS
        )
    )
    add(
        SignalDeclaration(
            key = SignalKey.HV_BATTERY_VOLTAGE,
            nature = SignalNature.STATE,
            transform = ::nonNegativeFloat,
            band = SignalBand(0.0, 500.0),
            deadbands = SignalDeadbands(sample = 0.5),
            maxGapMillis = GeelyProfile.SAMPLE_MAX_GAP_MILLIS
        )
    )
    add(
        SignalDeclaration(
            key = SignalKey.HV_BATTERY_CURRENT,
            nature = SignalNature.RATE,
            transform = ::plainFloat,
            foldRateHz = 1.0,
            foldRateEvidence = "Charger-side reading, polled at 5 s. It is not " +
                "folded into a trip integral; the bus pair is."
        )
    )
    add(
        SignalDeclaration(
            key = SignalKey.EV_BATTERY_INSTANTANEOUS_POWER,
            nature = SignalNature.RATE,
            // Milliwatts on the wire. The 0.05 kW floor rejects the resting
            // jitter of a property that mostly does not publish on this car.
            transform = { milliwattsToKw(it, floorKw = 0.05f) },
            foldRateHz = 2.0,
            foldRateEvidence = "Polled at 500 ms. This property does not publish " +
                "on this vehicle, so no integral is taken from it today."
        )
    )
    add(
        SignalDeclaration(
            key = SignalKey.EV_DC_CHARGE_POWER,
            nature = SignalNature.RATE,
            transform = { floatAboveMagnitude(it, floor = 0.2f) },
            foldRateHz = 0.2,
            foldRateEvidence = "Polled at 5 s. A charge is a slow, steady rate; " +
                "slice 0 measured charging at 2 % of the rows and 80 % of the " +
                "recorded time."
        )
    )
    add(
        SignalDeclaration(
            key = SignalKey.RANGE_REMAINING,
            nature = SignalNature.STATE,
            transform = ::plainFloat,
            // The 2 000 km cap is a corruption guard against a unit or scaling
            // fault, not a declared control range. Zero is a valid reading: an
            // empty pack has no range.
            band = SignalBand(0.0, RANGE_MAX_KM.toDouble())
        )
    )
    add(
        SignalDeclaration(
            key = SignalKey.BATTERY_SOH_PERCENT,
            nature = SignalNature.STATE,
            transform = ::stateOfHealthPercent,
            band = SignalBand(0.0, 100.0),
            // State of health moves over months, so every change is the
            // degradation history rather than jitter.
            everyChangeIsAnEvent = true
        )
    )

    // --- Charging -----------------------------------------------------------

    add(SignalDeclaration(SignalKey.EV_CHARGE_STATE, SignalNature.EVENT, everyChangeIsAnEvent = true))
    add(SignalDeclaration(SignalKey.EV_CHARGE_PLUG_TYPE, SignalNature.EVENT, everyChangeIsAnEvent = true))
    add(SignalDeclaration(SignalKey.EV_CHARGE_PORT_CONNECTED, SignalNature.EVENT, everyChangeIsAnEvent = true))
    add(
        SignalDeclaration(
            key = SignalKey.EV_CHARGE_ESTIMATED_TIME,
            nature = SignalNature.STATE,
            transform = ::nonNegativeFloat,
            // Five minutes. The vehicle re-estimates constantly and a smaller
            // band records arithmetic rather than news.
            deadbands = SignalDeadbands(event = 5.0)
        )
    )

    // --- Cabin and environment ----------------------------------------------

    add(SignalDeclaration(SignalKey.GEAR, SignalNature.EVENT, everyChangeIsAnEvent = true))
    add(
        SignalDeclaration(
            key = SignalKey.AMBIENT_AIR_TEMPERATURE,
            nature = SignalNature.STATE,
            // The vendor int encodes degrees Celsius as (raw - 80) / 2.
            transform = ::flymeAmbientTempC,
            band = SignalBand(TEMP_MIN_C.toDouble(), TEMP_MAX_C.toDouble()),
            deadbands = SignalDeadbands(event = 1.0, sample = 1.0),
            maxGapMillis = GeelyProfile.SAMPLE_MAX_GAP_MILLIS
        )
    )
    add(
        SignalDeclaration(
            key = SignalKey.OUTSIDE_TEMPERATURE,
            nature = SignalNature.STATE,
            // The AOSP float is already in degrees Celsius.
            transform = ::plainFloat,
            band = SignalBand(TEMP_MIN_C.toDouble(), TEMP_MAX_C.toDouble()),
            deadbands = SignalDeadbands(event = 1.0, sample = 1.0),
            maxGapMillis = GeelyProfile.SAMPLE_MAX_GAP_MILLIS
        )
    )

    // --- Bus-rate readings --------------------------------------------------

    add(
        SignalDeclaration(
            key = SignalKey.PACK_POWER_DRIVE,
            nature = SignalNature.RATE,
            band = SignalBand(-500.0, 500.0),
            foldRateHz = 60.0,
            foldRateEvidence = "Auxiliary power is pack minus drive: a difference " +
                "of two numbers that each reach 100 kW while the remainder sits " +
                "near 0.5 kW. Folding at 1 Hz on the 2026-08-05 drives put 25 % " +
                "of samples below zero and left two half-rate phases of one trip " +
                "disagreeing by 176 %."
        )
    )
    add(
        SignalDeclaration(
            key = SignalKey.PACK_VOLTAGE,
            nature = SignalNature.STATE,
            band = SignalBand(100.0, 1_000.0),
            deadbands = SignalDeadbands(sample = 1.0),
            maxGapMillis = GeelyProfile.SAMPLE_MAX_GAP_MILLIS
        )
    )
    add(
        SignalDeclaration(
            key = SignalKey.PACK_CURRENT,
            nature = SignalNature.RATE,
            band = SignalBand(-500.0, 500.0),
            foldRateHz = 60.0,
            foldRateEvidence = "Folded with PACK_POWER_DRIVE and for the same " +
                "measurement."
        )
    )
    add(
        SignalDeclaration(
            key = SignalKey.BUS_VEHICLE_SPEED,
            nature = SignalNature.STATE,
            band = SignalBand(0.0, 250.0)
        )
    )
    add(
        SignalDeclaration(
            key = SignalKey.TOTAL_DRIVE_POWER,
            nature = SignalNature.RATE,
            band = SignalBand(-500.0, 500.0),
            foldRateHz = 60.0,
            foldRateEvidence = "Declared with the pack pair. Frame 0x29B does not " +
                "reach this head unit, so in practice it never arrives and the " +
                "column is expected to be null."
        )
    )
    add(SignalDeclaration(SignalKey.AC_INPUT_VOLTAGE, SignalNature.STATE, band = SignalBand(0.0, 500.0)))
    add(
        SignalDeclaration(
            key = SignalKey.AC_INPUT_CURRENT,
            nature = SignalNature.RATE,
            band = SignalBand(0.0, 100.0),
            foldRateHz = 60.0,
            foldRateEvidence = "The charger's own measurement of the mains, read " +
                "at the same cadence as the pack pair."
        )
    )
    add(
        SignalDeclaration(
            key = SignalKey.ROAD_INCLINE,
            nature = SignalNature.STATE,
            band = SignalBand(-50.0, 50.0),
            deadbands = SignalDeadbands(sample = 1.0),
            maxGapMillis = GeelyProfile.SAMPLE_MAX_GAP_MILLIS
        )
    )
    add(SignalDeclaration(SignalKey.BRAKE_PEDAL, SignalNature.EVENT, everyChangeIsAnEvent = true))
    add(
        SignalDeclaration(
            key = SignalKey.REGEN_TORQUE,
            nature = SignalNature.STATE,
            band = SignalBand(-5_000.0, 5_000.0)
        )
    )
    add(
        SignalDeclaration(
            key = SignalKey.ACCEL_PEDAL,
            nature = SignalNature.STATE,
            band = SignalBand(0.0, 100.0),
            deadbands = SignalDeadbands(sample = 5.0),
            maxGapMillis = GeelyProfile.SAMPLE_MAX_GAP_MILLIS
        )
    )
    add(SignalDeclaration(SignalKey.REGEN_LEVEL, SignalNature.EVENT, everyChangeIsAnEvent = true))
    add(
        SignalDeclaration(
            key = SignalKey.THERMAL_POWER,
            nature = SignalNature.RATE,
            // The bench maximum is 20.4 kW at the top of the 8-bit count, so a
            // reading outside this band is not this signal.
            band = SignalBand(0.0, 30.0),
            foldRateHz = 60.0,
            foldRateEvidence = "Folded with the pack pair, because the climate " +
                "share is subtracted from it. Bench of 2026-08-08, 0.08 kW per " +
                "count over 89 samples, R2 0.9945."
        )
    )
    add(
        SignalDeclaration(
            key = SignalKey.DCDC_POWER,
            nature = SignalNature.RATE,
            foldRateHz = 60.0,
            foldRateEvidence = "Read as a raw count beside the pack pair; no " +
                "verified scale exists yet, so nothing integrates it today."
        )
    )
    add(SignalDeclaration(SignalKey.CLIMATE_ON, SignalNature.EVENT, everyChangeIsAnEvent = true))
    add(SignalDeclaration(SignalKey.CLIMATE_COMPRESSOR, SignalNature.EVENT, everyChangeIsAnEvent = true))
    add(SignalDeclaration(SignalKey.BLOWER_LEVEL, SignalNature.EVENT, everyChangeIsAnEvent = true))
    add(
        SignalDeclaration(
            key = SignalKey.CABIN_SETPOINT,
            // An event, not a state. Slice 0 measured it changing on 0.095 % of
            // samples, and 83 % of the rows a deadband kept for it were the
            // maximum gap writing a value nobody had touched. It is a discrete
            // control that a person turns.
            nature = SignalNature.EVENT,
            // 15.5 to 28.5 degC is what the head unit offers; a reading outside
            // it is not this signal.
            band = SignalBand(15.5, 28.5),
            everyChangeIsAnEvent = true
        )
    )
    add(SignalDeclaration(SignalKey.REAR_DEFROSTER, SignalNature.EVENT, everyChangeIsAnEvent = true))
    add(SignalDeclaration(SignalKey.DRIVE_MODE, SignalNature.EVENT, everyChangeIsAnEvent = true))

    // --- Receiver -----------------------------------------------------------
    // One measurement written as four rows. The deadband is evaluated on the
    // group: a move of any member writes every member, because keeping the
    // latitude while dropping the longitude reports a position the vehicle
    // never held.

    add(
        SignalDeclaration(
            key = SignalKey.LATITUDE,
            nature = SignalNature.STATE,
            band = SignalBand(-90.0, 90.0),
            group = GeelyProfile.GROUP_POSITION,
            maxGapMillis = GeelyProfile.SAMPLE_MAX_GAP_MILLIS
        )
    )
    add(
        SignalDeclaration(
            key = SignalKey.LONGITUDE,
            nature = SignalNature.STATE,
            band = SignalBand(-180.0, 180.0),
            group = GeelyProfile.GROUP_POSITION,
            maxGapMillis = GeelyProfile.SAMPLE_MAX_GAP_MILLIS
        )
    )
    add(
        SignalDeclaration(
            key = SignalKey.ALTITUDE,
            nature = SignalNature.STATE,
            group = GeelyProfile.GROUP_POSITION,
            maxGapMillis = GeelyProfile.SAMPLE_MAX_GAP_MILLIS
        )
    )
    add(
        SignalDeclaration(
            key = SignalKey.GPS_ACCURACY,
            nature = SignalNature.STATE,
            // An attribute of the coordinate, not a series of its own: it
            // describes the fix, not the vehicle. On its own it spends half its
            // rows on gap writes.
            group = GeelyProfile.GROUP_POSITION,
            maxGapMillis = GeelyProfile.SAMPLE_MAX_GAP_MILLIS
        )
    )

    // --- Unscaled probes ----------------------------------------------------
    // Raw counts, kept as counts. A raw count kept today is what lets a scale
    // found next month be applied to this month's drives instead of re-logging
    // them, and nothing may print one as a measurement.

    // The AutoEnergy distribution shares. They are floats near 100 that sum to
    // about 100, so they are shares and not kilowatts, and nothing may feed them
    // into an efficiency figure. Kept unscaled, as the vehicle reports them.
    ENERGY_FLOW_SHARE_KEYS.forEach {
        add(
            SignalDeclaration(
                it,
                SignalNature.STATE,
                transform = ::plainFloat
            )
        )
    }

    RAW_COUNT_KEYS.forEach {
        add(SignalDeclaration(it, SignalNature.STATE))
    }
    DISCRETE_COUNT_KEYS.forEach {
        add(SignalDeclaration(it, SignalNature.EVENT, everyChangeIsAnEvent = true))
    }
}
    .associateBy { it.key }
    // The list is the series membership (ADR-0010, decision 1). A declaration
    // does not opt out on its own; restoring a signal to the series is one line
    // in `UNSAMPLED_KEYS`, and the line above is the only place `sampled` is
    // decided.
    .mapValues { (key, declaration) ->
        declaration.copy(sampled = key !in UNSAMPLED_KEYS)
    }

// --- The transforms ---------------------------------------------------------

/** Upper bound for a plausible remaining-range reading, in km. */
const val RANGE_MAX_KM = 2_000f

/** Upper bound for a plausible road speed on this vehicle, in km/h. */
const val SPEED_MAX_KMH = 140f

const val TEMP_MIN_C = -50f
const val TEMP_MAX_C = 85f

private fun plainFloat(reading: RawReading): Float? = asFloat(reading)?.takeIf { it.isFinite() }

private fun nonNegativeFloat(reading: RawReading): Float? =
    asFloat(reading)?.takeIf { it.isFinite() && it >= 0f }

/**
 * Non-negative float accepted only from a value carrying a live source timestamp.
 *
 * A reading without a live source timestamp (e.g. 0.0 with null or <= 0 timestamp)
 * is a VHAL default, not a live measurement. A brand-new car reporting 0.0 with
 * a positive timestamp stays accepted.
 */
private fun nonNegativeMeasuredFloat(reading: RawReading): Float? {
    val stamp = reading.sourceTimestampNanos
    if (stamp == null || stamp <= 0L) return null
    return asFloat(reading)?.takeIf { it.isFinite() && it >= 0f }
}

/**
 * State of charge in percent.
 *
 * The vehicle answers tenths on one property and whole percent on another, and
 * nothing but the magnitude separates them.
 */
private fun stateOfChargePercent(reading: RawReading): Float? {
    val numeric = asFloat(reading) ?: return null
    val percent = if (numeric > 100f) numeric / 10f else numeric
    return percent.takeIf { it.isFinite() && it in 0f..100f }?.coerceIn(0f, 100f)
}

/**
 * State of health in percent, accepted only from a value the vehicle wrote.
 *
 * `BMSH_BAT_SOH` reads raw 999 with a zero source timestamp on this car, and
 * 999 also decodes to a legitimate 99.9 %. Nothing in the value tells the two
 * apart; only the timestamp does. A reading without one is therefore
 * unavailable rather than a healthy pack.
 */
private fun stateOfHealthPercent(reading: RawReading): Float? {
    val stamp = reading.sourceTimestampNanos
    if (stamp == null || stamp <= 0L) return null
    val percent = asFloat(reading)?.div(10f) ?: return null
    return percent.takeIf { it.isFinite() && it in 0f..100f }
}

/**
 * Road speed in km/h.
 *
 * The +1 above 10 km/h is the cluster's own correction: the head unit shows one
 * more than the property reports, and the number a driver can check against is
 * the one on the cluster.
 */
private fun vehicleSpeedKmh(reading: RawReading): Float? {
    val raw = asFloat(reading) ?: return null
    val normalized = abs(raw).coerceIn(0f, SPEED_MAX_KMH)
    return if (normalized >= 10f) (normalized + 1f).coerceIn(0f, SPEED_MAX_KMH) else normalized
}

private fun floatAboveMagnitude(reading: RawReading, floor: Float): Float? =
    asFloat(reading)?.takeIf { it.isFinite() && abs(it) >= floor }

private fun milliwattsToKw(reading: RawReading, floorKw: Float): Float? =
    asFloat(reading)
        ?.let { it / 1_000_000f }
        ?.takeIf { it.isFinite() && abs(it) >= floorKw }

private fun flymeAmbientTempC(reading: RawReading): Float? =
    asFloat(reading)?.let { (it - 80f) / 2f }?.takeIf { it.isFinite() }
