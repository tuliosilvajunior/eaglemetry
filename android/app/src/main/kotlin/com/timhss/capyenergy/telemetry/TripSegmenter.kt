package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.SessionAggregateSampleRow
import kotlin.math.abs

/**
 * One 200 m cut of a trip, derived at close from frames.
 *
 * Geometry and the CAN integral live here so retention can drop the frames
 * without changing a later comparison.
 */
data class TripSegment(
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
    val path: List<LatLon>,
)

data class LatLon(val latitude: Double, val longitude: Double)

/** Ambient and climb for the whole trip, from the same walk as the segments. */
data class TripContext(
    val meanAmbientTempC: Double?,
    val altitudeGainM: Double?,
    val altitudeLossM: Double?,
)

data class TripSegmentation(
    val segments: List<TripSegment>,
    val context: TripContext,
)

/**
 * Cuts a trip into fixed-distance segments.
 *
 * Odometer first, then speed. Energy is the same trapezoid
 * [TripPowerAccumulator] uses, so a segment's integral and the trip integral
 * are the same measurement. A leftover shorter than 200 m is kept: dropping
 * it would throw away the energy of the last stretch.
 */
object TripSegmenter {
    const val LENGTH_KM = 0.2

    /**
     * A GPS step larger than this is a glitch, not a climb. One-hertz frames
     * cannot climb 50 m in a second on this car.
     */
    const val MAX_ALTITUDE_STEP_M = 50.0

    internal fun cut(sweep: SessionSampleSweep): TripSegmentation {
        val segments = ArrayList<TripSegment>()
        var previous: SessionAggregateSampleRow? = null
        var open = OpenSegment()
        var ambientSum = 0.0
        var ambientCount = 0
        var tripGain = 0.0
        var tripLoss = 0.0
        var sawAltitude = false

        sweep.forEach { sample ->
            sample.ambientTempC?.toDouble()?.takeIf { it.isFinite() }?.let {
                ambientSum += it
                ambientCount += 1
            }
            val last = previous
            if (last == null) {
                open.markStart(sample)
            } else {
                val interval = interval(last, sample)
                interval.altitudeDeltaM?.let { delta ->
                    sawAltitude = true
                    if (delta > 0.0) tripGain += delta else tripLoss += -delta
                }
                open.add(interval, sample)
                // The odometer is a float. A 200 m step is often 0.19999999
                // km, and refusing that would glue two stretches into 400 m.
                if (open.distanceKm + 1e-4 >= LENGTH_KM) {
                    segments.add(open.close(segments.size))
                    open = OpenSegment().also { it.markStart(sample) }
                }
            }
            previous = sample
        }
        if (open.distanceKm > 0.0) {
            segments.add(open.close(segments.size))
        }
        return TripSegmentation(
            segments = segments,
            context = TripContext(
                meanAmbientTempC = if (ambientCount == 0) {
                    null
                } else {
                    ambientSum / ambientCount
                },
                altitudeGainM = if (sawAltitude) tripGain else null,
                altitudeLossM = if (sawAltitude) tripLoss else null,
            ),
        )
    }

    fun cut(samples: List<SessionAggregateSampleRow>): TripSegmentation =
        cut(SessionSampleSweep { consume -> samples.forEach(consume) })

    fun encodePath(path: List<LatLon>): String =
        path.joinToString(";") { "${it.latitude},${it.longitude}" }

    fun toEntity(
        segment: TripSegment,
        sessionId: String,
        accountId: String? = null,
    ) = com.timhss.capyenergy.telemetry.db.TripSegmentEntity(
        sessionId = sessionId,
        accountId = accountId,
        ordinal = segment.ordinal,
        startUtcMillis = segment.startUtcMillis,
        endUtcMillis = segment.endUtcMillis,
        distanceKm = segment.distanceKm,
        packWh = segment.packWh,
        tractionWh = segment.tractionWh,
        regeneratedWh = segment.regeneratedWh,
        auxiliaryWh = segment.auxiliaryWh,
        integratedSeconds = segment.integratedSeconds,
        elapsedSeconds = segment.elapsedSeconds,
        meanSpeedKmh = segment.meanSpeedKmh,
        altitudeGainM = segment.altitudeGainM,
        altitudeLossM = segment.altitudeLossM,
        ambientTempC = segment.ambientTempC,
        startLatitude = segment.startLatitude,
        startLongitude = segment.startLongitude,
        endLatitude = segment.endLatitude,
        endLongitude = segment.endLongitude,
        path = encodePath(segment.path),
    )

    internal fun interval(
        previous: SessionAggregateSampleRow,
        current: SessionAggregateSampleRow,
    ): SegmentInterval {
        val deltaSeconds =
            (current.elapsedRealtimeNanos - previous.elapsedRealtimeNanos) /
                1_000_000_000.0
        val usable = deltaSeconds > 0.0 &&
            deltaSeconds <= TelemetryEnergy.MAX_CAN_GAP_SECONDS
        val distanceKm = if (!usable) {
            0.0
        } else {
            odometerDeltaKm(previous, current)
                ?: speedDistanceKm(previous, current, deltaSeconds)
                ?: 0.0
        }
        val energy = if (usable) energyDelta(previous, current, deltaSeconds) else null
        val altitudeDeltaM = if (!usable) {
            null
        } else {
            altitudeDeltaM(previous, current)
        }
        return SegmentInterval(
            deltaSeconds = if (usable) deltaSeconds else 0.0,
            distanceKm = distanceKm,
            energy = energy,
            altitudeDeltaM = altitudeDeltaM,
            ambientTempC = current.ambientTempC?.toDouble()?.takeIf { it.isFinite() },
            point = pointOf(current),
            endUtcMillis = current.wallTimeUtcMillis,
        )
    }
    private fun odometerDeltaKm(
        previous: SessionAggregateSampleRow,
        current: SessionAggregateSampleRow,
    ): Double? {
        val start = previous.odometerKm?.toDouble() ?: return null
        val end = current.odometerKm?.toDouble() ?: return null
        val delta = end - start
        return delta.takeIf { it.isFinite() && it >= 0.0 }
    }

    private fun speedDistanceKm(
        previous: SessionAggregateSampleRow,
        current: SessionAggregateSampleRow,
        deltaSeconds: Double,
    ): Double? {
        val previousSpeed = previous.speedKmh?.toDouble()?.takeIf { it.isFinite() && it >= 0.0 }
        val currentSpeed = current.speedKmh?.toDouble()?.takeIf { it.isFinite() && it >= 0.0 }
        val speed = when {
            previousSpeed != null && currentSpeed != null -> (previousSpeed + currentSpeed) / 2.0
            previousSpeed != null -> previousSpeed
            currentSpeed != null -> currentSpeed
            else -> return null
        }
        return speed * deltaSeconds / 3_600.0
    }

    private fun energyDelta(
        previous: SessionAggregateSampleRow,
        current: SessionAggregateSampleRow,
        deltaSeconds: Double,
    ): EnergyDelta? {
        val previousPack = TelemetryEnergy.packPowerKw(previous) ?: return null
        val currentPack = TelemetryEnergy.packPowerKw(current) ?: return null
        val previousDrive = previous.canDrivePowerKw?.toDouble()?.takeIf { it.isFinite() }
            ?: return null
        val currentDrive = current.canDrivePowerKw?.toDouble()?.takeIf { it.isFinite() }
            ?: return null
        val wh = deltaSeconds / 3_600.0 * 1_000.0
        return EnergyDelta(
            packWh = mean(previousPack, currentPack) * wh,
            tractionWh = mean(
                previousDrive.coerceAtLeast(0.0),
                currentDrive.coerceAtLeast(0.0),
            ) * wh,
            regeneratedWh = mean(
                (-previousDrive).coerceAtLeast(0.0),
                (-currentDrive).coerceAtLeast(0.0),
            ) * wh,
            auxiliaryWh = mean(
                previousPack - previousDrive,
                currentPack - currentDrive,
            ) * wh,
            seconds = deltaSeconds,
        )
    }

    private fun altitudeDeltaM(
        previous: SessionAggregateSampleRow,
        current: SessionAggregateSampleRow,
    ): Double? {
        val start = previous.altitudeM?.takeIf { it.isFinite() } ?: return null
        val end = current.altitudeM?.takeIf { it.isFinite() } ?: return null
        val delta = end - start
        return delta.takeIf { abs(it) <= MAX_ALTITUDE_STEP_M }
    }

    private fun pointOf(sample: SessionAggregateSampleRow): LatLon? {
        val latitude = sample.latitude?.takeIf { it.isFinite() } ?: return null
        val longitude = sample.longitude?.takeIf { it.isFinite() } ?: return null
        return LatLon(latitude, longitude)
    }

    private fun mean(previous: Double, current: Double): Double = (previous + current) / 2.0
}

internal data class EnergyDelta(
    val packWh: Double,
    val tractionWh: Double,
    val regeneratedWh: Double,
    val auxiliaryWh: Double,
    val seconds: Double,
)

internal data class SegmentInterval(
    val deltaSeconds: Double,
    val distanceKm: Double,
    val energy: EnergyDelta?,
    val altitudeDeltaM: Double?,
    val ambientTempC: Double?,
    val point: LatLon?,
    val endUtcMillis: Long,
)

private class OpenSegment {
    private var startUtcMillis: Long = 0L
    private var endUtcMillis: Long = 0L
    var distanceKm: Double = 0.0
        private set
    private var packWh = 0.0
    private var tractionWh = 0.0
    private var regeneratedWh = 0.0
    private var auxiliaryWh = 0.0
    private var integratedSeconds = 0.0
    private var elapsedSeconds = 0.0
    private var gainM = 0.0
    private var lossM = 0.0
    private var sawAltitude = false
    private var ambientSum = 0.0
    private var ambientCount = 0
    private var startPoint: LatLon? = null
    private var endPoint: LatLon? = null
    private val path = ArrayList<LatLon>()

    fun markStart(sample: SessionAggregateSampleRow) {
        startUtcMillis = sample.wallTimeUtcMillis
        endUtcMillis = sample.wallTimeUtcMillis
        val point = sample.latitude?.takeIf { it.isFinite() }?.let { latitude ->
            sample.longitude?.takeIf { it.isFinite() }?.let { longitude ->
                LatLon(latitude, longitude)
            }
        }
        if (point != null && startPoint == null) {
            startPoint = point
            endPoint = point
            path.add(point)
        }
        sample.ambientTempC?.toDouble()?.takeIf { it.isFinite() }?.let {
            ambientSum += it
            ambientCount += 1
        }
    }

    fun add(interval: SegmentInterval, sample: SessionAggregateSampleRow) {
        if (startUtcMillis == 0L && sample.wallTimeUtcMillis != 0L) {
            startUtcMillis = sample.wallTimeUtcMillis - (interval.deltaSeconds * 1_000.0).toLong()
        }
        endUtcMillis = interval.endUtcMillis
        distanceKm += interval.distanceKm
        elapsedSeconds += interval.deltaSeconds
        interval.energy?.let { energy ->
            packWh += energy.packWh
            tractionWh += energy.tractionWh
            regeneratedWh += energy.regeneratedWh
            auxiliaryWh += energy.auxiliaryWh
            integratedSeconds += energy.seconds
        }
        interval.altitudeDeltaM?.let { delta ->
            sawAltitude = true
            if (delta > 0.0) gainM += delta else lossM += -delta
        }
        interval.ambientTempC?.let {
            ambientSum += it
            ambientCount += 1
        }
        interval.point?.let { point ->
            if (startPoint == null) startPoint = point
            endPoint = point
            if (path.lastOrNull() != point) path.add(point)
        }
    }

    fun close(ordinal: Int): TripSegment {
        val elapsedHours = elapsedSeconds / 3_600.0
        return TripSegment(
            ordinal = ordinal,
            startUtcMillis = startUtcMillis,
            endUtcMillis = endUtcMillis,
            distanceKm = distanceKm,
            packWh = packWh.takeIf { integratedSeconds > 0.0 },
            tractionWh = tractionWh.takeIf { integratedSeconds > 0.0 },
            regeneratedWh = regeneratedWh.takeIf { integratedSeconds > 0.0 },
            auxiliaryWh = auxiliaryWh.takeIf { integratedSeconds > 0.0 },
            integratedSeconds = integratedSeconds,
            elapsedSeconds = elapsedSeconds,
            meanSpeedKmh = if (elapsedHours > 0.0) distanceKm / elapsedHours else null,
            altitudeGainM = if (sawAltitude) gainM else null,
            altitudeLossM = if (sawAltitude) lossM else null,
            ambientTempC = if (ambientCount == 0) null else ambientSum / ambientCount,
            startLatitude = startPoint?.latitude,
            startLongitude = startPoint?.longitude,
            endLatitude = endPoint?.latitude,
            endLongitude = endPoint?.longitude,
            path = path.toList(),
        )
    }
}
