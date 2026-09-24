package com.timhss.capyenergy.telemetry.db

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

@Entity(
    tableName = "session",
    indices = [
        Index(value = ["id"], unique = true),
        Index(value = ["startedAtUtcMillis"]),
        Index(value = ["kind", "startedAtUtcMillis"]),
        Index(value = ["dirty", "id"])
    ]
)
data class SessionEntity(
    @PrimaryKey(autoGenerate = true)
    val rowId: Long = 0L,
    val id: String,
    val vehicleId: String,
    val kind: String,
    val status: String,
    val startedAtUtcMillis: Long,
    val startedAtElapsedNanos: Long,
    val startedAtBootCount: Int? = null,
    val endedAtUtcMillis: Long? = null,
    val endedAtElapsedNanos: Long? = null,
    val endedAtBootCount: Int? = null,
    val movementStartedAtUtcMillis: Long? = null,
    val movementStartedAtElapsedNanos: Long? = null,
    val movementStartedAtBootCount: Int? = null,
    val chargeStartedAtUtcMillis: Long? = null,
    val chargeStartedAtElapsedNanos: Long? = null,
    val chargeStartedAtBootCount: Int? = null,
    val chargeEndedAtUtcMillis: Long? = null,
    val chargeEndedAtElapsedNanos: Long? = null,
    val chargeEndedAtBootCount: Int? = null,
    val plugDisconnectedAtUtcMillis: Long? = null,
    val plugDisconnectedAtElapsedNanos: Long? = null,
    val plugDisconnectedAtBootCount: Int? = null,
    val rollupDistanceKm: Double? = null,
    val rollupTractionWh: Double? = null,
    val rollupRegenWh: Double? = null,
    val rollupAuxiliaryWh: Double? = null,
    val rollupClimateWh: Double? = null,
    val rollupDeliveredWh: Double? = null,
    val rollupIntegratedSeconds: Double? = null,
    val startOdometerKm: Float? = null,
    val endOdometerKm: Float? = null,
    val plugType: Int? = null,
    val startAmbientTempC: Float? = null,
    val endAmbientTempC: Float? = null,
    val meanAmbientTempC: Float? = null,
    val startSocPercent: Float? = null,
    val endSocPercent: Float? = null,
    val minSocPercent: Float? = null,
    val maxSocPercent: Float? = null,
    val socAgreesWithIntegral: String? = null,
    val noLongerReducible: Boolean = false,
    val startPowerKw: Float? = null,
    val startLatitude: Double? = null,
    val startLongitude: Double? = null,
    val startAltitudeM: Double? = null,
    val startGpsAccuracyM: Float? = null,
    val startLocationProvider: String? = null,
    val startLocationElapsedRealtimeNanos: Long? = null,
    val costPerKwh: Double? = null,
    val paidAmount: Double? = null,
    val costCurrency: String? = null,
    val chargeEndReason: String? = null,
    val endReason: String? = null,
    val startGear: Int? = null,
    val lastSoc: Float? = null,
    val sleepSeconds: Long? = null,
    val sleepSocDeltaPercent: Float? = null,
    val sleepEnergyWhEstimate: Double? = null,
    val parkingMode: Int? = null,
    /**
     * The climb, the descent and how many position fixes the drive holds.
     *
     * Summed at close from the raw Track points, before simplification. A
     * reader used to walk the altitude Samples for the first two and count the
     * position groups for the third, on every read. Simplification drops
     * points, so these cannot be recovered from the stored path afterwards.
     * See issue 178.
     */
    val climbM: Double? = null,
    val descentM: Double? = null,
    val fixCount: Int? = null,
    val createdAtUtcMillis: Long = System.currentTimeMillis(),
    val updatedAtUtcMillis: Long = System.currentTimeMillis(),
    val updatedAtElapsedNanos: Long? = null,
    /**
     * Whether this row has not yet reached the cloud. Everything recorded
     * before the mark existed owes an upload, because no upload has ever
     * run, so the column lands as NOT NULL DEFAULT 1 in `MIGRATION_42_43`
     * and every historical row reads dirty. The companion carries the same
     * mark on its five tables (`companion_database.dart`, `oldVersion < 6`).
     */
    val dirty: Boolean = true,
    /**
     * What the time authority believes about this session's stamps. Born
     * from the boot's anchor state at create (`pending` while the boot has
     * no learned anchor, `known` once it does); the close sweep resolves it
     * to `known` when the backfill rewrites the session's minutes.
     * Consumers read it instead of re-deriving: retention never ages a
     * pending session, the uploader never clears a pending row.
     */
    val timeState: String = "unknown",
    /**
     * The account whose pairing wrote this row, or null before the car was
     * claimed. Born null; only a change of writer account ever fills it, and
     * only while the row is still null (see `MIGRATION_44_45`).
     */
    val accountId: String? = null,
) {
    fun toMap(): Map<String, Any?> = toExportRow()
    fun toExportRow(): Map<String, Any?> = mapOf(
        "id" to id,
        "vehicleId" to vehicleId,
        "kind" to kind,
        "status" to status,
        "startedAtUtcMillis" to startedAtUtcMillis,
        "startedAtElapsedNanos" to startedAtElapsedNanos,
        "startedAtBootCount" to startedAtBootCount,
        "endedAtUtcMillis" to endedAtUtcMillis,
        "endedAtElapsedNanos" to endedAtElapsedNanos,
        "endedAtBootCount" to endedAtBootCount,
        "movementStartedAtUtcMillis" to movementStartedAtUtcMillis,
        "movementStartedAtElapsedNanos" to movementStartedAtElapsedNanos,
        "movementStartedAtBootCount" to movementStartedAtBootCount,
        "chargeStartedAtUtcMillis" to chargeStartedAtUtcMillis,
        "chargeStartedAtElapsedNanos" to chargeStartedAtElapsedNanos,
        "chargeStartedAtBootCount" to chargeStartedAtBootCount,
        "chargeEndedAtUtcMillis" to chargeEndedAtUtcMillis,
        "chargeEndedAtElapsedNanos" to chargeEndedAtElapsedNanos,
        "chargeEndedAtBootCount" to chargeEndedAtBootCount,
        "plugDisconnectedAtUtcMillis" to plugDisconnectedAtUtcMillis,
        "plugDisconnectedAtElapsedNanos" to plugDisconnectedAtElapsedNanos,
        "plugDisconnectedAtBootCount" to plugDisconnectedAtBootCount,
        "rollupDistanceKm" to rollupDistanceKm,
        "rollupTractionWh" to rollupTractionWh,
        "rollupRegenWh" to rollupRegenWh,
        "rollupAuxiliaryWh" to rollupAuxiliaryWh,
        "rollupClimateWh" to rollupClimateWh,
        "rollupDeliveredWh" to rollupDeliveredWh,
        "rollupIntegratedSeconds" to rollupIntegratedSeconds,
        "startOdometerKm" to startOdometerKm,
        "endOdometerKm" to endOdometerKm,
        "plugType" to plugType,
        "startAmbientTempC" to startAmbientTempC,
        "endAmbientTempC" to endAmbientTempC,
        "meanAmbientTempC" to meanAmbientTempC,
        "startSocPercent" to startSocPercent,
        "endSocPercent" to endSocPercent,
        "minSocPercent" to minSocPercent,
        "maxSocPercent" to maxSocPercent,
        "socAgreesWithIntegral" to socAgreesWithIntegral,
        "noLongerReducible" to noLongerReducible,
        "startPowerKw" to startPowerKw,
        "startLatitude" to startLatitude,
        "startLongitude" to startLongitude,
        "startAltitudeM" to startAltitudeM,
        "startGpsAccuracyM" to startGpsAccuracyM,
        "startLocationProvider" to startLocationProvider,
        "startLocationElapsedRealtimeNanos" to startLocationElapsedRealtimeNanos,
        "costPerKwh" to costPerKwh,
        "paidAmount" to paidAmount,
        "costCurrency" to costCurrency,
        "chargeEndReason" to chargeEndReason,
        "endReason" to endReason,
        "startGear" to startGear,
        "lastSoc" to lastSoc,
        "sleepSeconds" to sleepSeconds,
        "sleepSocDeltaPercent" to sleepSocDeltaPercent,
        "sleepEnergyWhEstimate" to sleepEnergyWhEstimate,
        "parkingMode" to parkingMode,
        "climbM" to climbM,
        "descentM" to descentM,
        "fixCount" to fixCount,
        "createdAtUtcMillis" to createdAtUtcMillis,
        "updatedAtUtcMillis" to updatedAtUtcMillis,
        "updatedAtElapsedNanos" to updatedAtElapsedNanos
    )
}
