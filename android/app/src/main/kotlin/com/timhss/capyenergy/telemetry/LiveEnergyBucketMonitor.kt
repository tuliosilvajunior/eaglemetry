package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.CanPowerSample

/** Recent minutes of the trip in progress, as held in memory. */
data class LiveEnergyBuckets(
    val sessionId: String,
    /** Wall clock at which this monitor began seeing frames for the session. */
    val startedAtUtcMillis: Long,
    val buckets: List<EnergyBucket>,
    /** Width every bucket in [buckets] was cut to. */
    val bucketMillis: Long = EnergyBucket.BUCKET_MILLIS
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "sessionId" to sessionId,
        "startedAtUtcMillis" to startedAtUtcMillis,
        "bucketMillis" to bucketMillis,
        "buckets" to buckets.map { it.toMap() }
    )
}

/**
 * Keeps the minute in progress up to date without touching the database.
 *
 * The chart polls this about once a second so the open bar grows while the car
 * is driving. Re-sweeping the session for that would re-read every frame of the
 * trip once per second, which on a long drive is thousands of rows for one
 * number that changed.
 *
 * It folds the frames as they are persisted, with [EnergyBucketAccumulator], so
 * the live bar is the same integral the stored series will report — not a
 * lighter-weight approximation that would step when the two met.
 *
 * A few closed minutes are reported alongside the open one. That is what lets a
 * caller watch a minute roll over without going back to the database for the
 * value it just watched being accumulated.
 */
class LiveEnergyBucketMonitor(
    private val windowMinutes: Int = DEFAULT_WINDOW_MINUTES,
    private val bucketMillis: Long = EnergyBucket.BUCKET_MILLIS,
    private val targetSessionType: String = TRIP_SESSION_TYPE,
    private val allowMissingDriveAsZero: Boolean = false,
    private val climateOnly: Boolean = false,
    private val deliveredOnly: Boolean = false,
    /**
     * How many buckets the accumulator itself may hold.
     *
     * [snapshot] can ask for fewer. The persist path asks for more than the
     * chart window, so this has to be at least that flush width or a dropped
     * write loses minutes the next flush cannot resurrect.
     */
    private val retainBuckets: Int = windowMinutes,
    /**
     * The boot the folded frames belong to. Read per frame, not once: the
     * pair each bucket carries must be the boot of its FIRST sample, and a
     * monitor that cached the count at construction would credit pre-reboot
     * minutes to the new boot. `FrameRepository` feeds its process boot
     * count here; tests feed whatever boot their fixture emulates.
     */
    private val bootCountProvider: () -> Int? = { null }
) {
    private var sessionId: String? = null
    private var startedAtUtcMillis = 0L
    private var accumulator = EnergyBucketAccumulator(
        bucketMillis = bucketMillis,
        allowMissingDriveAsZero = allowMissingDriveAsZero,
        climateOnly = climateOnly,
        deliveredOnly = deliveredOnly
    )

    /**
     * Folds one persisted frame.
     *
     * Only frames matching [targetSessionType] count. [isCharging] only matters
     * to a monitor spanning both driving and charging (`CONTINUOUS`, `PARKED`);
     * see [EnergyBucketAccumulator.add].
     */
    @Synchronized
    fun onFrame(
        sessionId: String?,
        sessionType: String?,
        frame: CanPowerSample,
        isCharging: Boolean = false
    ) {
        if (sessionId.isNullOrBlank() || sessionType != targetSessionType) {
            reset()
            return
        }
        if (sessionId != this.sessionId) {
            this.sessionId = sessionId
            startedAtUtcMillis = frame.wallTimeUtcMillis
            accumulator = EnergyBucketAccumulator(
                bucketMillis = bucketMillis,
                allowMissingDriveAsZero = allowMissingDriveAsZero,
                climateOnly = climateOnly,
                deliveredOnly = deliveredOnly
            )
        }
        accumulator.add(frame, isCharging, bootCountProvider())
        accumulator.retainLast(retainBuckets)
    }

    /**
     * The trip these buckets belong to, or null when none is running.
     *
     * The persistence path watches this to notice a trip ending, because the
     * minutes it is holding have to reach the database before [reset] drops
     * them.
     */
    @Synchronized
    fun currentSessionId(): String? = sessionId

    /**
     * Null when no trip is running, which is not the same as a trip at rest.
     *
     * [minutes] widens the tail for the persistence path. A flush may be dropped
     * when the write queue is full, and the next one has to be able to cover
     * what the dropped one was carrying — a window that only reached back as far
     * as the chart's would lose those minutes for good.
     */
    @Synchronized
    fun snapshot(minutes: Int = windowMinutes): LiveEnergyBuckets? {
        val id = sessionId ?: return null
        val buckets = accumulator.result()
        return LiveEnergyBuckets(
            sessionId = id,
            startedAtUtcMillis = startedAtUtcMillis,
            buckets = buckets.takeLast(minutes),
            bucketMillis = bucketMillis
        )
    }

    /**
     * Idempotent on purpose: [onFrame] resets on every reading that belongs to
     * no trip, and readings now arrive at bus rate, so a parked car would
     * otherwise discard and rebuild an accumulator sixty times a second.
     */
    @Synchronized
    fun reset() {
        if (sessionId == null) return
        sessionId = null
        startedAtUtcMillis = 0L
        accumulator = EnergyBucketAccumulator(
            bucketMillis = bucketMillis,
            allowMissingDriveAsZero = allowMissingDriveAsZero,
            climateOnly = climateOnly,
            deliveredOnly = deliveredOnly
        )
    }

    companion object {
        const val TRIP_SESSION_TYPE = "TRIP"
        const val PARKED_SESSION_TYPE = "PARKED"
        const val CHARGE_SESSION_TYPE = "CHARGE"
        const val CONTINUOUS_SESSION_TYPE = "CONTINUOUS"

        /**
         * Minutes kept for the caller. Three covers a poll that missed a tick
         * or two without keeping a window long enough to be mistaken for the
         * session's own history, which belongs to the database.
         */
        const val DEFAULT_WINDOW_MINUTES = 3
    }
}

/**
 * Finding 13c: the one place that decides how each stream's live monitor is
 * configured. `FrameRepository` builds its six monitors through here, and the
 * regression tests pin the wiring through here too — constructing a monitor
 * inline with hand-picked flags proves the fold, never the wiring. That exact
 * gap hid the 2026-08-20 defect where the charge monitor ran `climateOnly`
 * instead of `deliveredOnly` and stored zero delivered energy for two months.
 */
internal object LiveEnergyBucketMonitors {
    fun trip(retainBuckets: Int, bootCountProvider: () -> Int? = { null }): LiveEnergyBucketMonitor =
        LiveEnergyBucketMonitor(retainBuckets = retainBuckets, bootCountProvider = bootCountProvider)

    fun efficiency(windowMinutes: Int, bucketMillis: Long): LiveEnergyBucketMonitor =
        LiveEnergyBucketMonitor(windowMinutes = windowMinutes, bucketMillis = bucketMillis)

    fun parked(retainBuckets: Int, bootCountProvider: () -> Int? = { null }): LiveEnergyBucketMonitor =
        LiveEnergyBucketMonitor(
            targetSessionType = LiveEnergyBucketMonitor.PARKED_SESSION_TYPE,
            allowMissingDriveAsZero = true,
            retainBuckets = retainBuckets,
            bootCountProvider = bootCountProvider
        )

    fun continuous(retainBuckets: Int, bootCountProvider: () -> Int? = { null }): LiveEnergyBucketMonitor =
        LiveEnergyBucketMonitor(
            targetSessionType = LiveEnergyBucketMonitor.CONTINUOUS_SESSION_TYPE,
            allowMissingDriveAsZero = true,
            retainBuckets = retainBuckets,
            bootCountProvider = bootCountProvider
        )

    fun charge(retainBuckets: Int, bootCountProvider: () -> Int? = { null }): LiveEnergyBucketMonitor =
        LiveEnergyBucketMonitor(
            targetSessionType = LiveEnergyBucketMonitor.CHARGE_SESSION_TYPE,
            deliveredOnly = true,
            retainBuckets = retainBuckets,
            bootCountProvider = bootCountProvider
        )

    fun chargeClimate(windowMinutes: Int, bucketMillis: Long): LiveEnergyBucketMonitor =
        LiveEnergyBucketMonitor(
            windowMinutes = windowMinutes,
            bucketMillis = bucketMillis,
            targetSessionType = LiveEnergyBucketMonitor.CHARGE_SESSION_TYPE,
            climateOnly = true
        )
}
