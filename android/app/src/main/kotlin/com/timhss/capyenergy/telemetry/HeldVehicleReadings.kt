package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey

/**
 * The vehicle readings a CAN frame carries but the CAN bus does not publish.
 *
 * The state of charge and the odometer arrive on the snapshot tick, once a
 * second, and are read again at bus rate when a frame is composed. They have to
 * survive between the two, so they are held here.
 *
 * ## Why a reading is held, not owned
 *
 * A held value that never expires stops being a measurement and becomes a
 * claim: the signal goes silent, or a new Session opens hours later, and the
 * first bucket of that Session records the last Session's reading as if it had
 * just been taken. [MAX_AGE_NANOS] is the bucket width, because a reading older
 * than the bucket it would land in was measured in a different bucket and
 * belongs to that one. Past it there is no reading, and a bucket with no
 * reading says so.
 *
 * ## Why the odometer is here at all
 *
 * It used to be captured inside the branch the sample deadband had already
 * decided to write:
 *
 * ```
 * if (entity != null) {
 *     if (sample.signalId == SignalKey.ODOMETER) { lastOdometerKm = it }
 * }
 * ```
 *
 * So the accumulator did not see the odometer the car reported; it saw the last
 * odometer that earned a `Sample` row. The declared band is 0.1 km, and on the
 * 2026-08-26 snapshot the gap between two written odometer rows on a trip runs
 * to a median of 13 s, a 95th percentile of 46 s and a ceiling of 300 s — the
 * maximum-gap rule. For all of that the held value stood still while the
 * vehicle moved, and `odometerDistanceKm` arrived in lumps aligned to when the
 * deadband agreed rather than to when the vehicle drove.
 *
 * The row is a record; the bucket is a measurement, and the bucket cannot wait
 * for the deadband to agree. See issue 188, split out of 182 where the state of
 * charge was moved for the same reason.
 *
 * ## Not thread confined
 *
 * Written on the receiver's tick, read on the Roadcast thread. Every field is
 * `@Volatile` and every write replaces the whole reading, so a reader sees a
 * value and its stamp together or neither.
 */
internal class HeldVehicleReadings(
    private val maxAgeNanos: Long = MAX_AGE_NANOS
) {
    @Volatile
    private var soc: HeldReading? = null

    @Volatile
    private var odometer: HeldReading? = null

    /**
     * Takes whatever [snapshot] reports, on every tick.
     *
     * Deliberately unconditional. A signal that is absent or unreadable leaves
     * the previous reading standing until it expires, which is what "held"
     * means; it does not clear it, because one unreadable tick is not a
     * statement that the vehicle stopped reporting.
     */
    fun observe(snapshot: Map<SignalKey, SignalSample>, elapsedNanos: Long) {
        snapshot[SignalKey.HV_BATTERY_SOC]?.numericDoubleValue()?.toFloat()?.let {
            soc = HeldReading(it, elapsedNanos)
        }
        snapshot[SignalKey.ODOMETER]?.numericDoubleValue()?.toFloat()?.let {
            odometer = HeldReading(it, elapsedNanos)
        }
    }

    /** Takes one signal, for the per-signal path that has no snapshot. */
    fun observeOne(key: SignalKey, value: Double?, elapsedNanos: Long) {
        val reading = value?.toFloat() ?: return
        when (key) {
            SignalKey.HV_BATTERY_SOC -> soc = HeldReading(reading, elapsedNanos)
            SignalKey.ODOMETER -> odometer = HeldReading(reading, elapsedNanos)
            else -> Unit
        }
    }

    /** The held charge, or null once it is older than one bucket. */
    fun socPercentAt(nowElapsedNanos: Long): Float? = valueAt(soc, nowElapsedNanos)

    /** The held odometer, or null once it is older than one bucket. */
    fun odometerKmAt(nowElapsedNanos: Long): Float? = valueAt(odometer, nowElapsedNanos)

    fun reset() {
        soc = null
        odometer = null
    }

    private fun valueAt(held: HeldReading?, nowElapsedNanos: Long): Float? {
        val reading = held ?: return null
        if (nowElapsedNanos <= 0L || reading.elapsedRealtimeNanos <= 0L) return null
        val age = nowElapsedNanos - reading.elapsedRealtimeNanos
        if (age < 0L || age > maxAgeNanos) return null
        return reading.value
    }

    companion object {
        /**
         * How long a reading may be held before it stops counting as one: the
         * width of the bucket it would land in.
         */
        const val MAX_AGE_NANOS = EnergyBucket.BUCKET_MILLIS * 1_000_000L
    }
}

/** One reading with the monotonic clock that measured it. */
internal data class HeldReading(
    val value: Float,
    val elapsedRealtimeNanos: Long
)
