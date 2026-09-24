package com.timhss.capyenergy.telemetry.db

/**
 * Narrow read shapes over `telemetry_frames`.
 *
 * The energy and chart maths never needed a whole [TelemetryFrameEntity]: a
 * charge integral wants four numbers per row, and `SELECT *` was materializing
 * 28 columns — GPS, provider strings, masks — for every frame of every session
 * just so the list could print one kWh figure. On an 8 h charge that is ~6.5k
 * wide objects per session, per refresh.
 *
 * The interfaces exist so the same maths runs over narrow projection rows or a
 * full entity. Historical detail has dedicated paged projections for GPS and
 * chart fields instead of loading every [TelemetryFrameEntity].
 */

/** Anything positioned on the session's elapsed-time axis. */
interface TimedSample {
    val elapsedRealtimeNanos: Long

    /**
     * Wall clock for the same frame.
     *
     * The only timestamp that survives a reboot. It is not the axis — it drifts
     * with clock corrections, which is why elapsed realtime was chosen — but it
     * is what [com.timhss.capyenergy.telemetry.SessionTimeline] rebases onto
     * when a session's elapsed axis has restarted mid-session. Defaults to 0 for
     * the projections and fixtures that never leave one boot.
     */
    val wallTimeUtcMillis: Long
        get() = 0L
}

/** Row shape the charge power/energy integral reads. */
interface ChargeSample : TimedSample {
    val voltageV: Float?
    val currentA: Float?
    val powerKw: Float?
    val freshnessMask: Int
}

/** Row shape the SOC-based trip energy model reads. */
interface SocSample : TimedSample {
    val socPercent: Float?
}

/** Row shape the trip distance/efficiency maths reads. */
interface TripSample : SocSample {
    val speedKmh: Float?
    val odometerKm: Float?
}

/**
 * Row shape the CAN power integral reads.
 *
 * All three come from Roadcast rather than the VHAL, and all three are null
 * together when the daemon had nothing fresh for the frame, so the integral
 * treats a row as usable only when it carries the whole triple.
 *
 * [canPackCurrentA] is positive on discharge, but two windows of stored frames
 * carry the opposite sign: everything before 2026-08-02, and everything from
 * about 18:00 on 2026-08-06 until the daemon on the car is next updated. Both
 * windows come from a Roadcast build that decoded this signal with a negative
 * scale.
 *
 * Do not repair them with a constant. The sign has now reversed twice on its
 * own, so the window bounds are a property of which daemon binary was running,
 * not of the data. Regress pack power against `canDrivePowerKw` over moving
 * frames instead: the two regimes separate at r near +-0.97, which is how both
 * windows were found. This is also why the trip integral is cross-checked
 * against SOC rather than published on its own.
 */
interface CanPowerSample : TimedSample {
    val canDrivePowerKw: Float?
    val canPackVoltageV: Float?
    val canPackCurrentA: Float?

    /** Optional driving context used by the energy monitor's window metrics. */
    val speedKmh: Float?
        get() = null
    val odometerKm: Float?
        get() = null

    /**
     * Climate power, in kW, and a named share of the auxiliary remainder.
     *
     * Null is the ordinary case and means the split is unknown for this reading,
     * never that climate drew nothing. The accumulator therefore counts the
     * seconds it covers separately, so a partly covered interval can be told
     * apart from a covered one that measured zero.
     */
    val canClimatePowerKw: Float?
        get() = null

    /**
     * When [speedKmh] arrives on a slower clock than the CAN reading, the stamps
     * of the speed reading itself.
     *
     * The speed is the VHAL's `VEHICLE_SPEED`, subscribed at 5 Hz, while this
     * sample is folded at bus rate. Integrating a held value against the CAN
     * clock would turn one speed reading into twelve slices of a staircase;
     * carrying its own stamps makes a repeat contribute nothing and keeps the
     * trapezoid on the cadence the value actually has.
     *
     * Null on a row where the speed and the CAN reading share one timestamp,
     * which is every persisted projection.
     */
    val speedElapsedRealtimeNanos: Long?
        get() = null
    val speedWallTimeUtcMillis: Long?
        get() = null

    val socPercent: Float?
        get() = null
}

/**
 * Charge projection over a whole session.
 *
 * No production query returns this any more — every read path pages instead —
 * but the list-based integral in [com.timhss.capyenergy.telemetry.ChargeEnergy]
 * survives as the reference the streaming accumulator is tested against, and this
 * is the row shape that proves the maths works over a narrow projection as well
 * as over a full entity.
 */
data class ChargeSampleRow(
    override val elapsedRealtimeNanos: Long,
    val socPercent: Float?,
    override val voltageV: Float?,
    override val currentA: Float?,
    override val powerKw: Float?,
    override val freshnessMask: Int
) : ChargeSample

/**
 * Narrow union read when a session is finalized or backfilled.
 *
 * Carries [id] so the aggregation sweep can page with the same
 * `(elapsedRealtimeNanos, id)` keyset cursor the detail paths use, instead of
 * loading the session in one shot.
 */
data class SessionAggregateSampleRow(
    val id: Long = 0L,
    override val elapsedRealtimeNanos: Long,
    override val wallTimeUtcMillis: Long = 0L,
    override val speedKmh: Float?,
    override val socPercent: Float?,
    override val odometerKm: Float?,
    override val voltageV: Float?,
    override val currentA: Float?,
    override val powerKw: Float?,
    override val freshnessMask: Int,
    override val canDrivePowerKw: Float? = null,
    override val canPackVoltageV: Float? = null,
    override val canPackCurrentA: Float? = null,
    val ambientTempC: Float? = null,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val altitudeM: Double? = null,
) : TripSample, ChargeSample, CanPowerSample

/**
 * One CAN reading folded straight into the energy integral, never persisted.
 *
 * The integral used to run over the 1 Hz rows in `telemetry_frames`, which is
 * the rate storage wants, not the rate the maths needs. Auxiliary power is the
 * remainder `pack - drive` — a difference of two numbers that each reach 100 kW
 * while the remainder sits near 0.5 kW — so it only survives if both operands
 * are integrated as fast as the bus reports them. Measured on the 2026-08-05
 * drives, integrating at 1 Hz put 25 % of samples below zero and left two
 * half-rate phases of the same trip disagreeing by 176 %.
 *
 * This shape carries neither odometer nor speed of its own: both arrive on the
 * VHAL's own slow cadence and are carried over from the signal store. The
 * odometer ticks every 10 m, so the last value is as current as it ever gets;
 * the speed brings its own stamps, because unlike a distance reading it cannot
 * be integrated twice without inventing motion — see [CanPowerSample].
 */
data class CanStreamSample(
    override val elapsedRealtimeNanos: Long,
    override val wallTimeUtcMillis: Long,
    override val canDrivePowerKw: Float?,
    override val canPackVoltageV: Float?,
    override val canPackCurrentA: Float?,
    override val speedKmh: Float? = null,
    override val odometerKm: Float? = null,
    override val socPercent: Float? = null,
    override val speedElapsedRealtimeNanos: Long? = null,
    override val speedWallTimeUtcMillis: Long? = null,
    override val canClimatePowerKw: Float? = null
) : CanPowerSample

data class SessionFrameBounds(
    val totalCount: Long,
    val firstElapsedNanos: Long?,
    val lastElapsedNanos: Long?
)

/**
 * Chart bounds for a session whose elapsed axis restarted mid-session.
 *
 * `MIN`/`MAX` over `elapsedRealtimeNanos` describe two different boots at once
 * for such a session, so the chart range comes from the wall clock instead —
 * the same axis the rebased rows are placed on.
 */
data class SessionWallBounds(
    val totalCount: Long,
    val firstWallUtcMillis: Long?,
    val lastWallUtcMillis: Long?
)

data class TripDetailFrameRow(
    val id: Long,
    override val elapsedRealtimeNanos: Long,
    override val wallTimeUtcMillis: Long = 0L,
    override val speedKmh: Float?,
    override val socPercent: Float?,
    override val odometerKm: Float?,
    val ambientTempC: Float?,
    val latitude: Double?,
    val longitude: Double?,
    val altitudeM: Double?,
    val gpsAccuracyM: Float?,
    override val canDrivePowerKw: Float? = null,
    override val canPackVoltageV: Float? = null,
    override val canPackCurrentA: Float? = null
) : TripSample, CanPowerSample

data class ChargeDetailFrameRow(
    val id: Long,
    override val elapsedRealtimeNanos: Long,
    override val wallTimeUtcMillis: Long = 0L,
    val socPercent: Float?,
    override val voltageV: Float?,
    override val currentA: Float?,
    override val powerKw: Float?,
    override val freshnessMask: Int
) : ChargeSample
