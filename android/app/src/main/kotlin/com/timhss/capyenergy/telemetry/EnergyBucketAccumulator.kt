package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.CanPowerSample
import com.timhss.capyenergy.telemetry.db.IntervalEntity
import kotlin.math.abs

/**
 * One wall-clock-aligned minute of a trip's or charge's energy, in Wh.
 *
 * The minute is the finest bucket the energy chart draws. Wider bars are made
 * by summing adjacent buckets rather than by re-integrating, which is only
 * exact because [startUtcMillis] is aligned to the wall clock: five of these
 * sum to exactly one five-minute bar on the same boundaries the axis labels.
 */
data class EnergyBucket(
    /** Start of the minute, UTC, always a multiple of [BUCKET_MILLIS]. */
    val startUtcMillis: Long,
    val tractionWh: Double = 0.0,
    val regeneratedWh: Double = 0.0,
    val auxiliaryWh: Double = 0.0,
    /** Seconds of this minute the integral actually covers. */
    val integratedSeconds: Double = 0.0,
    val speedDistanceKm: Double = 0.0,
    val odometerDistanceKm: Double = 0.0,
    val speedIntegratedSeconds: Double = 0.0,
    val climateWh: Double = 0.0,
    val climateIntegratedSeconds: Double = 0.0,
    val deliveredWh: Double = 0.0,
    val deliveredCoveredSeconds: Double = 0.0,
    val startSoc: Double? = null,
    val endSoc: Double? = null,
    val startVoltage: Double? = null,
    val endVoltage: Double? = null,
    /**
     * The monotonic reading behind this minute's first sample, with the boot
     * it belongs to. Stamped when the bucket is created — the sample being
     * folded when its first slice lands — never at flush time, so a late
     * flush cannot move the minute onto a younger reading. Null only on
     * buckets built before the pair existed (old tests, old projections).
     */
    val startElapsedNanos: Long? = null,
    val startBootCount: Int? = null
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "startUtcMillis" to startUtcMillis,
        "tractionWh" to tractionWh,
        "regeneratedWh" to regeneratedWh,
        "auxiliaryWh" to auxiliaryWh,
        "integratedSeconds" to integratedSeconds,
        "speedDistanceKm" to speedDistanceKm,
        "odometerDistanceKm" to odometerDistanceKm,
        "speedIntegratedSeconds" to speedIntegratedSeconds,
        "climateWh" to climateWh,
        "climateIntegratedSeconds" to climateIntegratedSeconds,
        "deliveredWh" to deliveredWh,
        "deliveredCoveredSeconds" to deliveredCoveredSeconds,
        "startSoc" to startSoc,
        "endSoc" to endSoc,
        "startVoltage" to startVoltage,
        "endVoltage" to endVoltage,
        "startElapsedNanos" to startElapsedNanos,
        "startBootCount" to startBootCount
    )

    companion object {
        const val BUCKET_MILLIS = 60_000L
    }
}

/** The stored row for one bucket. */
fun EnergyBucket.toEntity(
    sessionId: String,
    updatedAtUtcMillis: Long,
    accountId: String? = null,
    // One owner for the birth rule: a minute written before the boot learned
    // its anchor is pending and waits, like the session it belongs to.
    timeState: String = ClockUnlockBackfillEngine.sessionBirthState(ClockAnchorStore.isLearned())
): IntervalEntity {
    val distance = if (odometerDistanceKm > 0.0) odometerDistanceKm else speedDistanceKm
    return IntervalEntity(
        sessionId = sessionId,
        startUtcMillis = startUtcMillis,
        widthMillis = EnergyBucket.BUCKET_MILLIS,
        tractionWh = tractionWh,
        regenWh = regeneratedWh,
        auxiliaryWh = auxiliaryWh,
        climateWh = climateWh,
        deliveredWh = deliveredWh,
        distanceKm = distance,
        coveredSeconds = integratedSeconds,
        climateCoveredSeconds = climateIntegratedSeconds,
        speedCoveredSeconds = speedIntegratedSeconds,
        deliveredCoveredSeconds = deliveredCoveredSeconds,
        startSoc = startSoc,
        endSoc = endSoc,
        startVoltage = startVoltage,
        endVoltage = endVoltage,
        startElapsedNanos = startElapsedNanos,
        startBootCount = startBootCount,
        updatedAtUtcMillis = updatedAtUtcMillis,
        accountId = accountId,
        timeState = timeState
    )
}


fun IntervalEntity.toEnergyBucket(): EnergyBucket = EnergyBucket(
    startUtcMillis = startUtcMillis,
    tractionWh = tractionWh,
    regeneratedWh = regenWh,
    auxiliaryWh = auxiliaryWh,
    integratedSeconds = coveredSeconds,
    speedDistanceKm = distanceKm,
    odometerDistanceKm = 0.0,
    speedIntegratedSeconds = speedCoveredSeconds,
    climateWh = climateWh,
    climateIntegratedSeconds = climateCoveredSeconds,
    deliveredWh = deliveredWh,
    deliveredCoveredSeconds = deliveredCoveredSeconds,
    startSoc = startSoc,
    endSoc = endSoc,
    startVoltage = startVoltage,
    endVoltage = endVoltage,
    startElapsedNanos = startElapsedNanos,
    startBootCount = startBootCount
)

/**
 * Splits the trip or charge power integral into wall-clock minutes.
 */
class EnergyBucketAccumulator(
    private val bucketMillis: Long = EnergyBucket.BUCKET_MILLIS,
    private val allowMissingDriveAsZero: Boolean = false,
    private val climateOnly: Boolean = false,
    private val deliveredOnly: Boolean = false
) {
    init {
        require(bucketMillis > 0L) { "bucket width must be positive" }
        require(EnergyBucket.BUCKET_MILLIS % bucketMillis == 0L) {
            "bucket width must divide the minute so buckets sum back to it"
        }
    }

    private val buckets = LinkedHashMap<Long, MutableBucket>()

    private var hasPrevious = false
    private var previousNanos = 0L
    private var previousWallMillis = 0L
    private var previousPackKw = 0.0
    private var previousDriveKw = 0.0
    private var previousClimateKw: Double? = null
    private var previousDeliveredKw: Double? = null
    private var previousIsCharging = false
    // Anchor of the monotonic projection: the first honest sample's wall and
    // elapsed pair. The monitor rebuilds this accumulator on every session
    // rotation, so the anchor's life is the session's — the session-open
    // stamp is ground truth and every later wall reading must agree with
    // anchor + elapsed delta (see WallClockGuard).
    private var anchorWallMillis = 0L
    private var anchorElapsedNanos = 0L
    /**
     * The pair the bucket under construction is stamped with: the elapsed
     * reading and boot of the sample being folded right now. Every
     * [MutableBucket] captures these when it is created, so each minute
     * carries the pair of the sample that opened it — never the flush
     * instant's. A reboot restarts the elapsed axis, so the boot must travel
     * sample by sample beside it; stamping the flush-time boot would credit
     * pre-reboot minutes to the new boot and break the subtraction.
     */
    private var currentElapsedNanos = 0L
    private var currentBootCount: Int? = null

    private var hasPreviousSpeed = false
    private var previousSpeedNanos = 0L
    private var previousSpeedWallMillis = 0L
    private var previousSpeedKmh = 0.0

    private var hasPreviousOdometer = false
    private var previousOdometerNanos = 0L
    private var previousOdometerWallMillis = 0L
    private var previousOdometerKm = 0.0

    private val pendingStartSoc = HashMap<Long, Double>()
    private val pendingEndSoc = HashMap<Long, Double>()
    private val pendingStartVoltage = HashMap<Long, Double>()
    private val pendingEndVoltage = HashMap<Long, Double>()
    private val pendingStartElapsedNanos = HashMap<Long, Long>()
    private val pendingStartBootCount = HashMap<Long, Int>()

    /**
     * [isCharging] is only meaningful in the normal (non-`deliveredOnly`,
     * non-`climateOnly`) mode: a `CONTINUOUS` or `PARKED` session spans both
     * driving and charging, unlike a `TRIP` or `CHARGE` row which is only ever
     * one or the other. It tells [addSlice] to read the pack's negative power as
     * a charger's delivered energy instead of folding it into the traction-based
     * auxiliary split, which was built for a car that is not plugged in. See
     * issue 199/211.
     */
    fun add(sample: CanPowerSample, isCharging: Boolean = false, bootCount: Int? = null) {
        if (sample.elapsedRealtimeNanos <= 0L) return
        currentElapsedNanos = sample.elapsedRealtimeNanos
        currentBootCount = bootCount
        val wallMillis = guardWall(sample.wallTimeUtcMillis, sample.elapsedRealtimeNanos)
        if (wallMillis > 0L) {
            recordSampleEndpoints(sample.elapsedRealtimeNanos, bootCount, wallMillis)
        }
        addSoc(sample, wallMillis)
        addVoltage(sample, wallMillis)

        if (deliveredOnly) {
            val packKw = TelemetryEnergy.packPowerKw(sample)
            val deliveredKw = packKw?.let { (-it).coerceAtLeast(0.0) }
            val climateKw = sample.canClimatePowerKw?.toDouble()?.takeIf { it.isFinite() }
            // Guarded above: bucketing a jumped wall would strand the row
            // months off the monotonic line (gb-continuous-mode finding F-C).
            val nanos = sample.elapsedRealtimeNanos

            if (hasPrevious && wallMillis > 0L && previousWallMillis > 0L &&
                previousDeliveredKw != null && deliveredKw != null
            ) {
                val deltaSeconds = (nanos - previousNanos) / 1_000_000_000.0
                if (deltaSeconds > 0.0 && deltaSeconds <= TelemetryEnergy.MAX_CAN_GAP_SECONDS) {
                    integrateDelivered(
                        startWallMillis = previousWallMillis,
                        endWallMillis = wallMillis,
                        deltaSeconds = deltaSeconds,
                        startDeliveredKw = previousDeliveredKw!!,
                        endDeliveredKw = deliveredKw,
                        startClimateKw = previousClimateKw,
                        endClimateKw = climateKw
                    )
                }
            }
            hasPrevious = true
            previousNanos = nanos
            previousWallMillis = wallMillis
            previousDeliveredKw = deliveredKw
            previousClimateKw = climateKw
            return
        }

        if (climateOnly) {
            val climateKw = sample.canClimatePowerKw?.toDouble()?.takeIf { it.isFinite() }
            // Guarded above: see deliveredOnly.
            val nanos = sample.elapsedRealtimeNanos
            if (hasPrevious && wallMillis > 0L && previousWallMillis > 0L) {
                val deltaSeconds = (nanos - previousNanos) / 1_000_000_000.0
                if (deltaSeconds > 0.0 && deltaSeconds <= TelemetryEnergy.MAX_CAN_GAP_SECONDS) {
                    integrate(
                        startWallMillis = previousWallMillis,
                        endWallMillis = wallMillis,
                        deltaSeconds = deltaSeconds,
                        startPackKw = 0.0,
                        endPackKw = 0.0,
                        startDriveKw = 0.0,
                        endDriveKw = 0.0,
                        startClimateKw = previousClimateKw,
                        endClimateKw = climateKw,
                        charging = false
                    )
                }
            }
            hasPrevious = true
            previousNanos = nanos
            previousWallMillis = wallMillis
            previousClimateKw = climateKw
            return
        }

        addSpeed(sample)
        addOdometer(sample, wallMillis)
        val packKw = TelemetryEnergy.packPowerKw(sample) ?: return
        val driveKw = sample.canDrivePowerKw?.toDouble()?.takeIf { it.isFinite() }
            ?: if (allowMissingDriveAsZero) 0.0 else return
        val climateKw = sample.canClimatePowerKw?.toDouble()?.takeIf { it.isFinite() }

        if (hasPrevious && wallMillis > 0L && previousWallMillis > 0L) {
            val deltaSeconds =
                (sample.elapsedRealtimeNanos - previousNanos) / 1_000_000_000.0
            if (deltaSeconds > 0.0 && deltaSeconds <= TelemetryEnergy.MAX_CAN_GAP_SECONDS) {
                integrate(
                    startWallMillis = previousWallMillis,
                    endWallMillis = wallMillis,
                    deltaSeconds = deltaSeconds,
                    startPackKw = previousPackKw,
                    endPackKw = packKw,
                    startDriveKw = previousDriveKw,
                    endDriveKw = driveKw,
                    startClimateKw = previousClimateKw,
                    endClimateKw = climateKw,
                    charging = previousIsCharging
                )
            }
        }
        hasPrevious = true
        previousNanos = sample.elapsedRealtimeNanos
        previousWallMillis = wallMillis
        previousPackKw = packKw
        previousDriveKw = driveKw
        previousClimateKw = climateKw
        previousIsCharging = isCharging
    }

    fun retainLast(count: Int) {
        require(count >= 0) { "retain count must not be negative" }
        if (count == 0) {
            buckets.clear()
            pendingStartElapsedNanos.clear()
            pendingStartBootCount.clear()
            pendingStartSoc.clear()
            pendingEndSoc.clear()
            pendingStartVoltage.clear()
            pendingEndVoltage.clear()
            return
        }
        if (buckets.size <= count) return
        val ordered = buckets.keys.sorted()
        val extra = ordered.size - count
        for (i in 0 until extra) {
            val key = ordered[i]
            buckets.remove(key)
            pendingStartElapsedNanos.remove(key)
            pendingStartBootCount.remove(key)
            pendingStartSoc.remove(key)
            pendingEndSoc.remove(key)
            pendingStartVoltage.remove(key)
            pendingEndVoltage.remove(key)
        }
    }

    fun result(): List<EnergyBucket> =
        buckets.entries
            .sortedBy { it.key }
            .map { (start, bucket) ->
                EnergyBucket(
                    startUtcMillis = start,
                    tractionWh = bucket.tractionWh,
                    regeneratedWh = bucket.regeneratedWh,
                    auxiliaryWh = bucket.auxiliaryWh,
                    integratedSeconds = bucket.seconds,
                    speedDistanceKm = bucket.speedDistanceKm,
                    odometerDistanceKm = bucket.odometerDistanceKm,
                    speedIntegratedSeconds = bucket.speedSeconds,
                    climateWh = bucket.climateWh,
                    climateIntegratedSeconds = bucket.climateSeconds,
                    deliveredWh = bucket.deliveredWh,
                    deliveredCoveredSeconds = bucket.deliveredSeconds,
                    startSoc = bucket.startSoc,
                    endSoc = bucket.endSoc,
                    startVoltage = bucket.startVoltage,
                    endVoltage = bucket.endVoltage,
                    startElapsedNanos = bucket.startElapsedNanos,
                    startBootCount = bucket.startBootCount
                )
            }

    private fun recordSampleEndpoints(nanos: Long, bootCount: Int?, wallMillis: Long) {
        val bucketStart = alignToBucket(wallMillis, bucketMillis)
        val existing = buckets[bucketStart]
        if (existing != null) {
            if (existing.startElapsedNanos == null) {
                existing.startElapsedNanos = nanos
                existing.startBootCount = bootCount
            }
        } else if (!pendingStartElapsedNanos.containsKey(bucketStart)) {
            pendingStartElapsedNanos[bucketStart] = nanos
            if (bootCount != null) {
                pendingStartBootCount[bucketStart] = bootCount
            }
        }
    }

    private fun getOrCreateBucket(bucketStart: Long): MutableBucket =
        buckets.getOrPut(bucketStart) {
            MutableBucket().apply {
                startElapsedNanos = pendingStartElapsedNanos[bucketStart] ?: currentElapsedNanos
                startBootCount = pendingStartBootCount[bucketStart] ?: currentBootCount
                startSoc = pendingStartSoc[bucketStart]
                endSoc = pendingEndSoc[bucketStart] ?: pendingStartSoc[bucketStart]
                startVoltage = pendingStartVoltage[bucketStart]
                endVoltage = pendingEndVoltage[bucketStart] ?: pendingStartVoltage[bucketStart]
            }
        }

    private fun addSoc(sample: CanPowerSample, wallMillis: Long) {
        val soc = sample.socPercent?.toDouble()?.takeIf { it.isFinite() } ?: return
        addBucketEndpoints(soc, wallMillis, pendingStartSoc, pendingEndSoc,
            getStart = { it.startSoc }, setStart = { b, v -> b.startSoc = v },
            setEnd = { b, v -> b.endSoc = v })
    }

    private fun addVoltage(sample: CanPowerSample, wallMillis: Long) {
        val voltage = sample.canPackVoltageV?.toDouble()?.takeIf { it.isFinite() && it > 0.0 } ?: return
        addBucketEndpoints(voltage, wallMillis, pendingStartVoltage, pendingEndVoltage,
            getStart = { it.startVoltage }, setStart = { b, v -> b.startVoltage = v },
            setEnd = { b, v -> b.endVoltage = v })
    }

    private inline fun addBucketEndpoints(
        value: Double,
        wallMillis: Long,
        pendingStart: HashMap<Long, Double>,
        pendingEnd: HashMap<Long, Double>,
        getStart: (MutableBucket) -> Double?,
        setStart: (MutableBucket, Double) -> Unit,
        setEnd: (MutableBucket, Double) -> Unit
    ) {
        if (wallMillis <= 0L) return
        val bucketStart = alignToBucket(wallMillis, bucketMillis)
        if (wallMillis == bucketStart && wallMillis > 0L) {
            buckets[bucketStart - bucketMillis]?.let { setEnd(it, value) }
        }
        val existing = buckets[bucketStart]
        if (existing != null) {
            if (getStart(existing) == null) {
                setStart(existing, pendingStart[bucketStart] ?: value)
            }
            setEnd(existing, value)
        } else {
            if (!pendingStart.containsKey(bucketStart)) {
                pendingStart[bucketStart] = value
            }
            pendingEnd[bucketStart] = value
        }
    }

    private fun addSpeed(sample: CanPowerSample) {
        if (climateOnly || deliveredOnly) return
        val speed = sample.speedKmh?.toDouble()?.takeIf { it.isFinite() }
            ?.coerceIn(0.0, MAX_SPEED_KMH) ?: return
        val nanos = sample.speedElapsedRealtimeNanos ?: sample.elapsedRealtimeNanos
        if (nanos <= 0L) return
        // The speed reading carries its own stamps; guard them on the same
        // anchor so a jumped VHAL wall cannot strand the distance buckets.
        val wallMillis = guardWall(sample.speedWallTimeUtcMillis ?: sample.wallTimeUtcMillis, nanos)
        if (hasPreviousSpeed && wallMillis > 0L && previousSpeedWallMillis > 0L) {
            val seconds = (nanos - previousSpeedNanos) / 1e9
            if (seconds > 0.0 && seconds <= MAX_MOTION_GAP_SECONDS) {
                integrateSpeed(
                    previousSpeedWallMillis,
                    wallMillis,
                    seconds,
                    previousSpeedKmh,
                    speed
                )
            }
        }
        hasPreviousSpeed = true
        previousSpeedNanos = nanos
        previousSpeedWallMillis = wallMillis
        previousSpeedKmh = speed
    }

    private fun addOdometer(sample: CanPowerSample, wallMillis: Long) {
        if (climateOnly || deliveredOnly) return
        val odometer = sample.odometerKm?.toDouble()?.takeIf { it.isFinite() } ?: return
        if (hasPreviousOdometer && wallMillis > 0L && previousOdometerWallMillis > 0L) {
            val seconds = (sample.elapsedRealtimeNanos - previousOdometerNanos) / 1e9
            val distance = odometer - previousOdometerKm
            if (seconds > 0.0 &&
                seconds <= MAX_MOTION_GAP_SECONDS &&
                distance >= 0.0 &&
                distance <= MAX_PLAUSIBLE_ODOMETER_DELTA_KM
            ) {
                // A single bad odometer reading thousands of km off would
                // otherwise land verbatim on the minute's distance (live-DB
                // finding F-B: 36 continuous rows, ~131,092 km of phantom
                // distance, SOC flat while "distance" explodes). Drop the
                // interval, not the stream: the baseline below still advances
                // past the bad reading, so the next good one deltas cleanly
                // instead of wedging every later minute at zero. A
                // clamped-but-wrong number is still wrong, so nothing is
                // clamped — an implausible step records no distance at all,
                // the same way an over-long gap already degrades elsewhere.
                integrateOdometer(
                    previousOdometerWallMillis,
                    wallMillis,
                    seconds,
                    distance
                )
            }
        }
        hasPreviousOdometer = true
        previousOdometerNanos = sample.elapsedRealtimeNanos
        previousOdometerWallMillis = wallMillis
        previousOdometerKm = odometer
    }
    private fun integrateSpeed(
        startWallMillis: Long,
        endWallMillis: Long,
        deltaSeconds: Double,
        startSpeedKmh: Double,
        endSpeedKmh: Double
    ) {
        val wallSpan = endWallMillis - startWallMillis
        if (wallSpan <= 0L || !wallAgreesWithElapsed(wallSpan, deltaSeconds)) {
            addSpeedSlice(
                alignToBucket(startWallMillis, bucketMillis),
                deltaSeconds,
                startSpeedKmh,
                endSpeedKmh
            )
            return
        }
        var cursorMillis = startWallMillis
        while (cursorMillis < endWallMillis) {
            val bucketStart = alignToBucket(cursorMillis, bucketMillis)
            val sliceEnd = minOf(bucketStart + bucketMillis, endWallMillis)
            val fromFraction = (cursorMillis - startWallMillis).toDouble() / wallSpan
            val toFraction = (sliceEnd - startWallMillis).toDouble() / wallSpan
            addSpeedSlice(
                bucketStart,
                deltaSeconds * (toFraction - fromFraction),
                lerp(startSpeedKmh, endSpeedKmh, fromFraction),
                lerp(startSpeedKmh, endSpeedKmh, toFraction)
            )
            cursorMillis = sliceEnd
        }
    }

    private fun addSpeedSlice(
        bucketStart: Long,
        seconds: Double,
        startSpeedKmh: Double,
        endSpeedKmh: Double
    ) {
        if (seconds <= 0.0) return
        val bucket = getOrCreateBucket(bucketStart)
        bucket.speedDistanceKm += mean(startSpeedKmh, endSpeedKmh) * seconds / 3_600.0
        bucket.speedSeconds += seconds
    }

    private fun integrateOdometer(
        startWallMillis: Long,
        endWallMillis: Long,
        deltaSeconds: Double,
        distanceKm: Double
    ) {
        val wallSpan = endWallMillis - startWallMillis
        if (wallSpan <= 0L || !wallAgreesWithElapsed(wallSpan, deltaSeconds)) {
            getOrCreateBucket(alignToBucket(startWallMillis, bucketMillis))
                .odometerDistanceKm += distanceKm
            return
        }
        var cursorMillis = startWallMillis
        while (cursorMillis < endWallMillis) {
            val bucketStart = alignToBucket(cursorMillis, bucketMillis)
            val sliceEnd = minOf(bucketStart + bucketMillis, endWallMillis)
            val fraction = (sliceEnd - cursorMillis).toDouble() / wallSpan
            getOrCreateBucket(bucketStart)
                .odometerDistanceKm += distanceKm * fraction
            cursorMillis = sliceEnd
        }
    }

    private fun integrateDelivered(
        startWallMillis: Long,
        endWallMillis: Long,
        deltaSeconds: Double,
        startDeliveredKw: Double,
        endDeliveredKw: Double,
        startClimateKw: Double? = null,
        endClimateKw: Double? = null
    ) {
        val wallSpan = endWallMillis - startWallMillis
        if (wallSpan <= 0L || !wallAgreesWithElapsed(wallSpan, deltaSeconds)) {
            addDeliveredSlice(
                bucketStart = alignToBucket(startWallMillis, bucketMillis),
                seconds = deltaSeconds,
                startDeliveredKw = startDeliveredKw,
                endDeliveredKw = endDeliveredKw,
                startClimateKw = startClimateKw,
                endClimateKw = endClimateKw
            )
            return
        }

        var cursorMillis = startWallMillis
        while (cursorMillis < endWallMillis) {
            val bucketStart = alignToBucket(cursorMillis, bucketMillis)
            val sliceEnd = minOf(bucketStart + bucketMillis, endWallMillis)

            val fromFraction = (cursorMillis - startWallMillis).toDouble() / wallSpan
            val toFraction = (sliceEnd - startWallMillis).toDouble() / wallSpan

            addDeliveredSlice(
                bucketStart = bucketStart,
                seconds = deltaSeconds * (toFraction - fromFraction),
                startDeliveredKw = lerp(startDeliveredKw, endDeliveredKw, fromFraction),
                endDeliveredKw = lerp(startDeliveredKw, endDeliveredKw, toFraction),
                startClimateKw = lerpOrNull(startClimateKw, endClimateKw, fromFraction),
                endClimateKw = lerpOrNull(startClimateKw, endClimateKw, toFraction)
            )
            cursorMillis = sliceEnd
        }
    }

    private fun addDeliveredSlice(
        bucketStart: Long,
        seconds: Double,
        startDeliveredKw: Double,
        endDeliveredKw: Double,
        startClimateKw: Double? = null,
        endClimateKw: Double? = null
    ) {
        if (seconds <= 0.0) return
        val wh = seconds / 3_600.0 * 1_000.0
        val bucket = getOrCreateBucket(bucketStart)
        bucket.deliveredWh += mean(startDeliveredKw, endDeliveredKw) * wh
        bucket.deliveredSeconds += seconds
        if (startClimateKw != null && endClimateKw != null) {
            bucket.climateWh += mean(startClimateKw, endClimateKw) * wh
            bucket.climateSeconds += seconds
        }
    }

    private fun integrate(
        startWallMillis: Long,
        endWallMillis: Long,
        deltaSeconds: Double,
        startPackKw: Double,
        endPackKw: Double,
        startDriveKw: Double,
        endDriveKw: Double,
        startClimateKw: Double?,
        endClimateKw: Double?,
        charging: Boolean
    ) {
        val wallSpan = endWallMillis - startWallMillis
        if (wallSpan <= 0L || !wallAgreesWithElapsed(wallSpan, deltaSeconds)) {
            addSlice(
                bucketStart = alignToBucket(startWallMillis, bucketMillis),
                seconds = deltaSeconds,
                startPackKw = startPackKw,
                endPackKw = endPackKw,
                startDriveKw = startDriveKw,
                endDriveKw = endDriveKw,
                startClimateKw = startClimateKw,
                endClimateKw = endClimateKw,
                charging = charging
            )
            return
        }

        var cursorMillis = startWallMillis
        while (cursorMillis < endWallMillis) {
            val bucketStart = alignToBucket(cursorMillis, bucketMillis)
            val sliceEnd = minOf(bucketStart + bucketMillis, endWallMillis)

            val fromFraction = (cursorMillis - startWallMillis).toDouble() / wallSpan
            val toFraction = (sliceEnd - startWallMillis).toDouble() / wallSpan

            addSlice(
                bucketStart = bucketStart,
                seconds = deltaSeconds * (toFraction - fromFraction),
                startPackKw = lerp(startPackKw, endPackKw, fromFraction),
                endPackKw = lerp(startPackKw, endPackKw, toFraction),
                startDriveKw = lerp(startDriveKw, endDriveKw, fromFraction),
                endDriveKw = lerp(startDriveKw, endDriveKw, toFraction),
                startClimateKw = lerpOrNull(startClimateKw, endClimateKw, fromFraction),
                endClimateKw = lerpOrNull(startClimateKw, endClimateKw, toFraction),
                charging = charging
            )
            cursorMillis = sliceEnd
        }
    }

    private fun addSlice(
        bucketStart: Long,
        seconds: Double,
        startPackKw: Double,
        endPackKw: Double,
        startDriveKw: Double,
        endDriveKw: Double,
        startClimateKw: Double?,
        endClimateKw: Double?,
        charging: Boolean
    ) {
        if (seconds <= 0.0) return
        val wh = seconds / 3_600.0 * 1_000.0
        val bucket = getOrCreateBucket(bucketStart)
        if (!climateOnly) {
            if (charging) {
                // The pack is not driving the wheels while a charger is plugged
                // in, so its negative power is the charger's delivered energy,
                // not an accessory draw the split below was built to read. See
                // issue 199/211: this used to fall through to auxiliaryWh, which
                // went negative and drew as a broken traction bar.
                bucket.deliveredWh += mean(
                    (-startPackKw).coerceAtLeast(0.0),
                    (-endPackKw).coerceAtLeast(0.0)
                ) * wh
                bucket.deliveredSeconds += seconds
            } else {
                bucket.tractionWh += mean(
                    startDriveKw.coerceAtLeast(0.0),
                    endDriveKw.coerceAtLeast(0.0)
                ) * wh
                bucket.regeneratedWh += mean(
                    (-startDriveKw).coerceAtLeast(0.0),
                    (-endDriveKw).coerceAtLeast(0.0)
                ) * wh
                bucket.auxiliaryWh += mean(
                    startPackKw - startDriveKw,
                    endPackKw - endDriveKw
                ) * wh
            }
            bucket.seconds += seconds
        }
        if (startClimateKw != null && endClimateKw != null) {
            bucket.climateWh += mean(startClimateKw, endClimateKw) * wh
            bucket.climateSeconds += seconds
        }
    }

    /**
     * Wall instant to bucket this sample under.
     *
     * The first sample anchors the session's monotonic line (the session-open
     * stamp is ground truth — there is nothing earlier to check it against).
     * Every later wall reading must agree with anchor + elapsed delta within
     * [WallClockGuard.TOLERANCE_MILLIS]; a jumped clock is stamped with the
     * projection instead, so the row lands on the monotonic line rather than
     * months off it. Replaces the old reanchor, which moved the buckets onto
     * the jumped clock and so could not tell an NTP correction from a glitch.
     *
     * Elapsed running backwards means a reboot: the anchor's boot is over, so
     * the wall passes through and re-anchors here.
     */
    private fun guardWall(wallMillis: Long, nanos: Long): Long {
        if (anchorElapsedNanos <= 0L || nanos < anchorElapsedNanos) {
            anchorWallMillis = wallMillis
            anchorElapsedNanos = nanos
            return wallMillis
        }
        return WallClockGuard.guardedWallMillis(wallMillis, nanos, anchorWallMillis, anchorElapsedNanos)
    }

    private class MutableBucket {
        var tractionWh = 0.0
        var regeneratedWh = 0.0
        var auxiliaryWh = 0.0
        var seconds = 0.0
        var speedDistanceKm = 0.0
        var odometerDistanceKm = 0.0
        var speedSeconds = 0.0
        var climateWh = 0.0
        var climateSeconds = 0.0
        var deliveredWh = 0.0
        var deliveredSeconds = 0.0
        var startSoc: Double? = null
        var endSoc: Double? = null
        var startVoltage: Double? = null
        var endVoltage: Double? = null
        var startElapsedNanos: Long? = null
        var startBootCount: Int? = null
    }

    companion object {
        private const val WALL_DRIFT_TOLERANCE_SECONDS = 0.5
        private const val MAX_MOTION_GAP_SECONDS = 10.0
        private const val MAX_SPEED_KMH = 220.0
        /**
         * Ceiling for one accepted odometer step: the distance [MAX_SPEED_KMH]
         * covers in the longest gap the accumulator integrates
         * ([MAX_MOTION_GAP_SECONDS]), with headroom for sample jitter. Steps
         * arrive at bus rate and are far smaller in practice, so anything past
         * this is a bad reading, not a fast car — and the 60x margin over a
         * real step means genuine highway driving never touches it.
         */
        private const val MAX_PLAUSIBLE_ODOMETER_DELTA_KM =
            MAX_SPEED_KMH * 1.5 * MAX_MOTION_GAP_SECONDS / 3_600.0

        fun alignToBucket(
            wallMillis: Long,
            bucketMillis: Long = EnergyBucket.BUCKET_MILLIS
        ): Long = Math.floorDiv(wallMillis, bucketMillis) * bucketMillis

        fun combine(series: List<List<EnergyBucket>>): List<EnergyBucket> {
            val merged = HashMap<Long, EnergyBucket>()
            for (buckets in series) {
                for (bucket in buckets) {
                    merged.merge(bucket.startUtcMillis, bucket) { a, b ->
                        EnergyBucket(
                            startUtcMillis = a.startUtcMillis,
                            tractionWh = a.tractionWh + b.tractionWh,
                            regeneratedWh = a.regeneratedWh + b.regeneratedWh,
                            auxiliaryWh = a.auxiliaryWh + b.auxiliaryWh,
                            integratedSeconds = a.integratedSeconds + b.integratedSeconds,
                            speedDistanceKm = a.speedDistanceKm + b.speedDistanceKm,
                            odometerDistanceKm = a.odometerDistanceKm + b.odometerDistanceKm,
                            speedIntegratedSeconds =
                                a.speedIntegratedSeconds + b.speedIntegratedSeconds,
                            climateWh = a.climateWh + b.climateWh,
                            climateIntegratedSeconds =
                                a.climateIntegratedSeconds + b.climateIntegratedSeconds,
                            deliveredWh = a.deliveredWh + b.deliveredWh,
                            deliveredCoveredSeconds =
                                a.deliveredCoveredSeconds + b.deliveredCoveredSeconds,
                            startSoc = a.startSoc ?: b.startSoc,
                            endSoc = b.endSoc ?: a.endSoc,
                            startVoltage = a.startVoltage ?: b.startVoltage,
                            endVoltage = b.endVoltage ?: a.endVoltage,
                            startElapsedNanos = a.startElapsedNanos ?: b.startElapsedNanos,
                            startBootCount = a.startBootCount ?: b.startBootCount
                        )
                    }
                }
            }
            return merged.values.sortedBy { it.startUtcMillis }
        }

        private fun wallAgreesWithElapsed(wallSpan: Long, deltaSeconds: Double): Boolean =
            abs(wallSpan / 1_000.0 - deltaSeconds) <= WALL_DRIFT_TOLERANCE_SECONDS

        private fun mean(previous: Double, current: Double): Double =
            (previous + current) / 2.0

        private fun lerp(from: Double, to: Double, t: Double): Double =
            from + (to - from) * t

        private fun lerpOrNull(from: Double?, to: Double?, t: Double): Double? =
            if (from == null || to == null) null else lerp(from, to, t)
    }
}
