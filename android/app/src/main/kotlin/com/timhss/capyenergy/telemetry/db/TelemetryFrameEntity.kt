package com.timhss.capyenergy.telemetry.db

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

@Entity(
    tableName = "telemetry_frames",
    indices = [Index(value = ["sessionId", "elapsedRealtimeNanos"])]
)
data class TelemetryFrameEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val sessionId: String?,
    val sessionType: String?,
    override val wallTimeUtcMillis: Long,
    override val elapsedRealtimeNanos: Long,
    val timestampAccuracy: String,
    val uncertaintyMillis: Long,
    override val speedKmh: Float?,
    override val socPercent: Float?,
    override val odometerKm: Float?,
    override val voltageV: Float?,
    override val currentA: Float?,
    override val powerKw: Float?,
    override val canDrivePowerKw: Float? = null,
    override val canPackVoltageV: Float? = null,
    override val canPackCurrentA: Float? = null,
    val canPackCurrentRaw: Long? = null,
    val canPackCurrentEstimated: Boolean? = null,
    val canSampleElapsedNanos: Long? = null,
    /**
     * The second drive-power signal and the charger's own AC input. Added to
     * settle a suspected scale error between `VCU_DrvPwrAct` and the pack pair,
     * which measurement then showed does not exist — see
     * `RoadcastTripMetricsProvider` for what the two columns are worth now.
     *
     * The `canTotalDrivePower*` pair is null on every row: frame `0x29B` is not
     * transmitted to this head unit. The AC input pair is live and is the only
     * calibrated mains-side reference the app has.
     */
    val canTotalDrivePowerKw: Float? = null,
    val canTotalDrivePowerRaw: Long? = null,
    val canAcInputVoltageV: Float? = null,
    val canAcInputCurrentA: Float? = null,
    /**
     * Signal Lab stage 1: the road-load and driver-intent terms, plus the raw
     * counts behind three power signals whose scale is assumed.
     *
     * Grade is the term the energy model has never had, so a climb has until
     * now been recorded as a heavy foot. The brake state separates friction
     * braking from regeneration by measurement instead of by inference. The
     * three `*Raw` counts carry no scaled companion on purpose: the scale is
     * unknown or assumed, and a count stored today can be rescaled later
     * without re-logging the drive.
     *
     * `canBrakePedalOn` has no `Invalid` companion column, because that
     * companion has never published on this head unit — see
     * `RoadcastTripMetricsProvider.flag`.
     *
     * `canBrakePedalOn` and `canAccelPedalPercent` describe the whole second,
     * not the instant the row was written: the first is true when the pedal
     * went down at any point in it, the second is the mean over it. The rest
     * of these columns are the instant, which is what keeps a value and its
     * raw count decodable into each other. See `DriverInputWindow`.
     *
     * Written on trip frames only, for the reason given above the
     * `canTotalDrivePower*` pair: a drivetrain signal recorded during a charge
     * is the last value the VCU sent before it went quiet.
     */
    val canRoadInclinePercent: Float? = null,
    val canRoadInclineRaw: Long? = null,
    val canBrakePedalOn: Boolean? = null,
    val canRegenTorqueNm: Float? = null,
    val canRegenTorqueRaw: Long? = null,
    val canAccelPedalPercent: Float? = null,
    val canAccelPedalInvalid: Boolean? = null,
    val canRegenLevel: Int? = null,
    val canThermalPowerRaw: Long? = null,
    val canDcDcPowerRaw: Long? = null,
    val canDrivePowerRaw: Long? = null,
    /**
     * What the driver asked the climate system for, and the drive mode.
     *
     * The climate columns are written on trip **and** charge frames, unlike
     * every other CAN column above: the climate system runs while the car is
     * plugged in, so that load belongs to the charge it lands in rather than
     * being a stale value from a controller that went quiet.
     *
     * `canDriveMode` is trip-gated with `canRegenLevel`, for the reason given
     * above the `canRoadIncline*` pair.
     *
     * All six are counts, not names. `canDriveMode` is 0 NORMAL, 1 ECO,
     * 2 SPORT; `canRegenLevel` is 1 low, 2 medium, 3 high. The mapping is kept
     * out of storage on purpose, so a correction to it does not invalidate
     * recorded drives. `canCabinSetpointC` is the exception and holds degrees,
     * because the daemon carries a verified scale for it.
     */
    val canClimateOn: Boolean? = null,
    val canClimateCompressorOn: Boolean? = null,
    val canBlowerLevel: Int? = null,
    val canCabinSetpointC: Float? = null,
    val canRearDefrosterState: Int? = null,
    val canDriveMode: Int? = null,
    val gear: Int?,
    val chargeState: Int?,
    val chargePlugType: Int?,
    val ambientTempC: Float?,
    val latitude: Double?,
    val longitude: Double?,
    val altitudeM: Double?,
    val gpsAccuracyM: Float?,
    val locationProvider: String?,
    val locationElapsedRealtimeNanos: Long?,
    val sampleCount: Int,
    override val freshnessMask: Int,
    val qualityMask: Int
) : ChargeSample, TripSample, CanPowerSample {
    fun toMap(): Map<String, Any?> = mapOf(
        "id" to id,
        "sessionId" to sessionId,
        "sessionType" to sessionType,
        "wallTimeUtcMillis" to wallTimeUtcMillis,
        "elapsedRealtimeNanos" to elapsedRealtimeNanos,
        "timestampAccuracy" to timestampAccuracy,
        "uncertaintyMillis" to uncertaintyMillis,
        "speedKmh" to speedKmh,
        "socPercent" to socPercent,
        "odometerKm" to odometerKm,
        "voltageV" to voltageV,
        "currentA" to currentA,
        "powerKw" to powerKw,
        "canDrivePowerKw" to canDrivePowerKw,
        "canPackVoltageV" to canPackVoltageV,
        "canPackCurrentA" to canPackCurrentA,
        "canPackCurrentRaw" to canPackCurrentRaw,
        "canPackCurrentEstimated" to canPackCurrentEstimated,
        "canSampleElapsedNanos" to canSampleElapsedNanos,
        "canTotalDrivePowerKw" to canTotalDrivePowerKw,
        "canTotalDrivePowerRaw" to canTotalDrivePowerRaw,
        "canAcInputVoltageV" to canAcInputVoltageV,
        "canAcInputCurrentA" to canAcInputCurrentA,
        "canRoadInclinePercent" to canRoadInclinePercent,
        "canRoadInclineRaw" to canRoadInclineRaw,
        "canBrakePedalOn" to canBrakePedalOn,
        "canRegenTorqueNm" to canRegenTorqueNm,
        "canRegenTorqueRaw" to canRegenTorqueRaw,
        "canAccelPedalPercent" to canAccelPedalPercent,
        "canAccelPedalInvalid" to canAccelPedalInvalid,
        "canRegenLevel" to canRegenLevel,
        "canThermalPowerRaw" to canThermalPowerRaw,
        "canDcDcPowerRaw" to canDcDcPowerRaw,
        "canDrivePowerRaw" to canDrivePowerRaw,
        "canClimateOn" to canClimateOn,
        "canClimateCompressorOn" to canClimateCompressorOn,
        "canBlowerLevel" to canBlowerLevel,
        "canCabinSetpointC" to canCabinSetpointC,
        "canRearDefrosterState" to canRearDefrosterState,
        "canDriveMode" to canDriveMode,
        "gear" to gear,
        "chargeState" to chargeState,
        "chargePlugType" to chargePlugType,
        "ambientTempC" to ambientTempC,
        "latitude" to latitude,
        "longitude" to longitude,
        "altitudeM" to altitudeM,
        "gpsAccuracyM" to gpsAccuracyM,
        "locationProvider" to locationProvider,
        "locationElapsedRealtimeNanos" to locationElapsedRealtimeNanos,
        "sampleCount" to sampleCount,
        "freshnessMask" to freshnessMask,
        "qualityMask" to qualityMask
    )
}
