package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.GeelyProfile
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Pure evaluator for position deadbands, maximum gaps, group tuples (GPS coordinates),
 * and keyframes for the Track.
 */
class PositionDeadbandEvaluator(
    private val defaultMaxGapMillis: Long = GeelyProfile.SAMPLE_MAX_GAP_MILLIS,
    private val gpsDistanceThresholdM: Double = GeelyProfile.POSITION_DISTANCE_THRESHOLD_M,
    private val altitudeThresholdM: Double = 5.0,
    private val standingSpeedThresholdKmh: Double = GeelyProfile.POSITION_STANDING_SPEED_KMH,
    private val movingSpeedThresholdKmh: Double = GeelyProfile.POSITION_MOVING_SPEED_KMH
) {
    data class GpsGroupState(
        var lastWrittenLat: Double? = null,
        var lastWrittenLon: Double? = null,
        var lastWrittenAlt: Double? = null,
        var lastWrittenTimestampMillis: Long = 0L,
        var isStanding: Boolean? = null
    )

    private val gpsState = GpsGroupState()

    fun reset() {
        gpsState.lastWrittenLat = null
        gpsState.lastWrittenLon = null
        gpsState.lastWrittenAlt = null
        gpsState.lastWrittenTimestampMillis = 0L
        gpsState.isStanding = null
    }

    /**
     * Evaluates a position tuple (latitude, longitude, altitude) for the `Track`.
     *
     * The route is one measurement written as one point: a fix without both
     * coordinates is not a position, so it earns no point and does not advance
     * the state. The deadband is measured against the last point kept, never
     * against the previous fix:
     * - a fix at least `gpsDistanceThresholdM` (20 m) from the last kept point
     *   earns a point,
     * - an altitude change of at least `altitudeThresholdM` (5 m) does too,
     * - a crossing of the standing/moving speed band does too (with hysteresis:
     *   only the crossing writes, not the ticks inside the band),
     * - a fix after `defaultMaxGapMillis` (300 s) of silence earns a point even
     *   when it has not moved,
     * - a `forcedKeyframe` always earns a point.
     *
     * [speedKmh] is the car's own speed from the bus, in km/h, not the Doppler
     * speed of the fix. A stop is a fact the vehicle reports; the receiver only
     * infers it. When it is null the speed rule is off and the distance,
     * altitude and maximum-gap rules decide alone, exactly as before.
     */
    fun evaluatePosition(
        latitude: Double?,
        longitude: Double?,
        altitude: Double?,
        speedKmh: Double? = null,
        timestampUtcMillis: Long,
        forcedKeyframe: Boolean = false,
    ): Boolean {
        // A tuple is whole or not at all. The maximum-gap branch fires on the
        // clock, so it can reach this point with one coordinate missing, and a
        // latitude with no longitude names no place the vehicle stood.
        if (latitude == null || longitude == null) return false

        val shouldWrite = when {
            forcedKeyframe -> true
            gpsState.lastWrittenLat == null || gpsState.lastWrittenLon == null -> true
            else -> {
                val dist = haversineDistanceMeters(
                    gpsState.lastWrittenLat!!,
                    gpsState.lastWrittenLon!!,
                    latitude,
                    longitude
                )
                val altDelta = if (altitude != null && gpsState.lastWrittenAlt != null) {
                    kotlin.math.abs(altitude - gpsState.lastWrittenAlt!!)
                } else 0.0

                // A crossing of the band, not a reading inside it. The state is
                // the side the last written point stood on, so a vehicle creeping
                // between the two thresholds writes nothing until it leaves them.
                // With no speed yet, a standing reading still earns the point that
                // names where the vehicle stopped.
                //
                // [StopBand] holds the rule because [TrackRecorder] spends the same
                // one to protect both ends of a stop from simplification.
                val speedTransition = StopBand.crosses(
                    wasStanding = gpsState.isStanding,
                    speedKmh = speedKmh,
                    standingKmh = standingSpeedThresholdKmh,
                    movingKmh = movingSpeedThresholdKmh
                )

                dist >= gpsDistanceThresholdM ||
                    altDelta >= altitudeThresholdM ||
                    speedTransition ||
                    (timestampUtcMillis - gpsState.lastWrittenTimestampMillis) >= defaultMaxGapMillis
            }
        }

        if (!shouldWrite) return false

        gpsState.lastWrittenLat = latitude
        gpsState.lastWrittenLon = longitude
        gpsState.lastWrittenAlt = altitude
        gpsState.lastWrittenTimestampMillis = timestampUtcMillis
        // Inside the band the side does not change: that is the hysteresis.
        // A first reading inside it has no side to keep, and counts as moving,
        // because the vehicle is above the standing threshold.
        gpsState.isStanding = StopBand.nextStanding(
            wasStanding = gpsState.isStanding,
            speedKmh = speedKmh,
            standingKmh = standingSpeedThresholdKmh,
            movingKmh = movingSpeedThresholdKmh
        )
        return true
    }

    companion object {
        private const val EARTH_RADIUS_M = 6_371_000.0

        fun haversineDistanceMeters(
            lat1: Double,
            lon1: Double,
            lat2: Double,
            lon2: Double
        ): Double {
            val dLat = Math.toRadians(lat2 - lat1)
            val dLon = Math.toRadians(lon2 - lon1)
            val rLat1 = Math.toRadians(lat1)
            val rLat2 = Math.toRadians(lat2)

            val a = sin(dLat / 2) * sin(dLat / 2) +
                cos(rLat1) * cos(rLat2) * sin(dLon / 2) * sin(dLon / 2)
            val c = 2 * atan2(sqrt(a), sqrt(1 - a))
            return EARTH_RADIUS_M * c
        }
    }
}
