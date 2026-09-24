package com.timhss.capyenergy.telemetry.db

import androidx.room.Entity
import androidx.room.Index

/**
 * One 200 m stretch of a closed trip.
 *
 * Derived at trip close from frames, then kept after retention deletes those
 * frames. The comparison engine must never recompute this from
 * `telemetry_frames`.
 */
@Entity(
    tableName = "trip_segments",
    primaryKeys = ["sessionId", "ordinal"],
    indices = [Index("sessionId")],
)
data class TripSegmentEntity(
    val sessionId: String,
    val ordinal: Int,
    val startUtcMillis: Long,
    val endUtcMillis: Long,
    val distanceKm: Double,
    val packWh: Double?,
    val tractionWh: Double?,
    val regeneratedWh: Double?,
    val auxiliaryWh: Double?,
    val integratedSeconds: Double,
    val elapsedSeconds: Double,
    val meanSpeedKmh: Double?,
    val altitudeGainM: Double?,
    val altitudeLossM: Double?,
    val ambientTempC: Double?,
    val startLatitude: Double?,
    val startLongitude: Double?,
    val endLatitude: Double?,
    val endLongitude: Double?,
    /** Decimated `lat,lon;lat,lon` path, enough to tell two variants apart. */
    val path: String,
    val accountId: String? = null,
)
