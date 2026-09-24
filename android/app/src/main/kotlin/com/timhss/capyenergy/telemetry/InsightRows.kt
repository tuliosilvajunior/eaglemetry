package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.InsightPlaceEntity
import com.timhss.capyenergy.telemetry.db.SessionEntity
import com.timhss.capyenergy.telemetry.db.TripSegmentEntity

/**
 * One trip as the Insights engine is allowed to see it.
 *
 * There is no frame list and no GPS. The repository fills this from
 * `session`, minute intervals and segments. The Dart comparison engine is the only reader.
 */
data class InsightTripRow(
    val id: String,
    val endedAtUtcMillis: Long?,
    val rollupDistanceKm: Double?,
    val startOdometerKm: Double?,
    val endOdometerKm: Double?,
    val rollupTractionWh: Double?,
    val rollupRegenWh: Double?,
    val rollupAuxiliaryWh: Double?,
    val socAgreesWithIntegral: String?,
    val hasMinuteBuckets: Boolean,
    val startLatitude: Double? = null,
    val startLongitude: Double? = null,
    val endLatitude: Double? = null,
    val endLongitude: Double? = null,
    val path: String? = null,
    val meanAmbientTempC: Double? = null,
)

data class InsightPlaceRow(
    val id: String,
    val name: String,
    val latitude: Double,
    val longitude: Double,
    val radiusM: Double,
    val autoName: String? = null,
    val autoNameUpdatedAtUtcMillis: Long? = null,
    val autoNameSource: String? = null,
) {
    /// What the UI shows: user name wins, otherwise autoName.
    val displayName: String
        get() = if (name.trim().isNotEmpty()) name else (autoName ?: name)

    val effectiveName: String
        get() = displayName
}

data class InsightTripsPage(
    val trips: List<InsightTripRow>,
    val subjectId: String?,
)

/** Maps stored rows onto [InsightTripRow] without touching frames. */
object InsightTrips {
    /** Same 30-day product window as `kInsightOwnAverageWindow` in Dart. */
    const val WINDOW_MILLIS = 30L * 24L * 60L * 60L * 1_000L

    fun row(
        trip: SessionEntity,
        hasMinuteBuckets: Boolean,
        segments: List<TripSegmentEntity> = emptyList(),
    ): InsightTripRow {
        val geometry = geometryOf(segments)
        return InsightTripRow(
            id = trip.id,
            endedAtUtcMillis = trip.endedAtUtcMillis,
            rollupDistanceKm = trip.rollupDistanceKm,
            startOdometerKm = trip.startOdometerKm?.toDouble(),
            endOdometerKm = trip.endOdometerKm?.toDouble(),
            rollupTractionWh = trip.rollupTractionWh,
            rollupRegenWh = trip.rollupRegenWh,
            rollupAuxiliaryWh = trip.rollupAuxiliaryWh,
            socAgreesWithIntegral = trip.socAgreesWithIntegral,
            hasMinuteBuckets = hasMinuteBuckets,
            startLatitude = geometry.startLatitude,
            startLongitude = geometry.startLongitude,
            endLatitude = geometry.endLatitude,
            endLongitude = geometry.endLongitude,
            path = geometry.path,
            meanAmbientTempC = trip.meanAmbientTempC?.toDouble(),
        )
    }

    /**
     * Endpoints and the decimated path from stored segments. Frames are not
     * consulted: retention must not be able to change the grouping.
     */
    fun geometryOf(segments: List<TripSegmentEntity>): TripGeometry {
        if (segments.isEmpty()) return TripGeometry()
        val points = ArrayList<String>()
        fun add(latitude: Double?, longitude: Double?) {
            if (latitude == null || longitude == null) return
            if (!latitude.isFinite() || !longitude.isFinite()) return
            val token = "$latitude,$longitude"
            if (points.lastOrNull() != token) points.add(token)
        }
        for (segment in segments) {
            add(segment.startLatitude, segment.startLongitude)
            add(segment.endLatitude, segment.endLongitude)
        }
        if (points.isEmpty()) return TripGeometry()
        val start = points.first().split(',')
        val end = points.last().split(',')
        return TripGeometry(
            startLatitude = start[0].toDouble(),
            startLongitude = start[1].toDouble(),
            endLatitude = end[0].toDouble(),
            endLongitude = end[1].toDouble(),
            path = points.joinToString(";"),
        )
    }
}

data class TripGeometry(
    val startLatitude: Double? = null,
    val startLongitude: Double? = null,
    val endLatitude: Double? = null,
    val endLongitude: Double? = null,
    val path: String? = null,
)

internal fun InsightPlaceEntity.toRow() = InsightPlaceRow(
    id = id,
    name = name,
    latitude = latitude,
    longitude = longitude,
    radiusM = radiusM,
    autoName = autoName,
    autoNameUpdatedAtUtcMillis = autoNameUpdatedAtUtcMillis,
    autoNameSource = autoNameSource,
)
