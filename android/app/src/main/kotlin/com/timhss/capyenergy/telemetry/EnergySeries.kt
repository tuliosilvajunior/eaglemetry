package com.timhss.capyenergy.telemetry

/**
 * The energy series as the repositories answer them.
 *
 * These carry no wire spelling. `FrameRepository` built `Map<String, Any?>`
 * directly, so a key it wrote and a key Flutter read could drift with nothing
 * to say so, and the database layer had to know what Flutter calls things.
 * The bridge now does that spelling, against the generated classes in
 * `pigeons/telemetry_wire.dart`.
 */
data class TripEnergySeries(
    val sessionId: String,
    val bucketMillis: Long,
    /**
     * True when the minutes were rebuilt from stored 1 Hz frames rather than
     * measured at CAN rate while the trip happened.
     */
    val resampled: Boolean,
    val buckets: List<EnergyBucket>,
    val lastChargeCostPerKwh: Double?,
    val lastChargeCostCurrency: String?,
)

/**
 * The minutes over a stretch of clock, across whatever trips fell in it.
 *
 * A window can span both measured and rebuilt trips, so the reconstruction is
 * a count rather than a flag: the caller can say how much of the range it
 * covers instead of having to call all of it one or the other.
 */
data class WindowEnergySeries(
    val startUtcMillis: Long,
    val endUtcMillis: Long,
    val bucketMillis: Long,
    val sessionCount: Int,
    val resampledSessionCount: Int,
    val buckets: List<EnergyBucket>,
    val lastChargeCostPerKwh: Double?,
    val lastChargeCostCurrency: String?,
)
