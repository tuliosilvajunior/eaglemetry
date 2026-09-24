package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey

import com.timhss.capyenergy.profile.GeelyProfile
import com.timhss.capyenergy.profile.VehicleProfile

enum class RangeAvailability { AVAILABLE, DEGRADED, UNAVAILABLE }

/**
 * Typed result of [RangeEstimateMonitor.snapshot]. [TelemetryRuntime] converts
 * it to the bridge map; nothing in the monitor builds a map itself.
 */
data class NativeRangeEstimate(
    val timestampMillis: Long,
    val carRangeKm: Double?,
    val carRangeQuality: RangeAvailability,
    val carRangeReason: String?,
    val carRangePropertyId: Int,
    val carRangeSignalSource: String?,
    val carRangeReceivedAtUtcMillis: Long?,
    val carRangeSourceTimestampNanos: Long?,
    val socPercent: Double?,
    val capacityKwh: Double,
    val capacitySource: String,
    val efficiencyKmPerKwh: Double?,
    val efficiencySource: String?,
    val efficiencyWindowDays: Int?,
    val efficiencyTripCount: Int,
    val efficiencyDistanceKm: Double?,
    val efficiencyNetEnergyKwh: Double?,
    val efficiencyUpdatedAtUtcMillis: Long?,
    val fullRangeKm: Double?,
    val ownRangeKm: Double?,
    val ownRangeQuality: RangeAvailability,
    val ownRangeReason: String?
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "timestampMillis" to timestampMillis,
        "carRangeKm" to carRangeKm,
        "carRangeQuality" to carRangeQuality.name,
        "carRangeReason" to carRangeReason,
        "carRangePropertyId" to carRangePropertyId,
        "carRangeSignalSource" to carRangeSignalSource,
        "carRangeReceivedAtUtcMillis" to carRangeReceivedAtUtcMillis,
        "carRangeSourceTimestampNanos" to carRangeSourceTimestampNanos,
        "socPercent" to socPercent,
        "capacityKwh" to capacityKwh,
        "capacitySource" to capacitySource,
        "efficiencyKmPerKwh" to efficiencyKmPerKwh,
        "efficiencySource" to efficiencySource,
        "efficiencyWindowDays" to efficiencyWindowDays,
        "efficiencyTripCount" to efficiencyTripCount,
        "efficiencyDistanceKm" to efficiencyDistanceKm,
        "efficiencyNetEnergyKwh" to efficiencyNetEnergyKwh,
        "efficiencyUpdatedAtUtcMillis" to efficiencyUpdatedAtUtcMillis,
        "fullRangeKm" to fullRangeKm,
        "ownRangeKm" to ownRangeKm,
        "ownRangeQuality" to ownRangeQuality.name,
        "ownRangeReason" to ownRangeReason
    )
}

/**
 * Validates range inputs and owns the efficiency cache behind the app estimate.
 *
 * Owned by [TelemetryRuntime]. It reads a current [SignalStateStore] snapshot at
 * [snapshot] time and never queries Room from that path. The 60-second
 * efficiency refresh runs on the runtime's dedicated single-thread executor and
 * lands here through [refreshEfficiency]; that executor serializes the work, so
 * refreshes cannot overlap.
 *
 * A failed refresh keeps the last valid cache for [CACHE_MAX_AGE_MILLIS] and
 * marks the app result DEGRADED with REASON_EFFICIENCY_REFRESH_FAILED. After
 * expiry or a later success the state resolves accordingly.
 */
class RangeEstimateMonitor(
    private val store: SignalStateStore,
    private val efficiencyProvider: () -> RangeEfficiencySnapshot,
    /** Pack capacity in Wh, from Settings. The app has no other source. */
    private val capacityWhProvider: () -> Double,
    private val clockMillis: () -> Long = System::currentTimeMillis,
    private val collectionStartedAtElapsedNanos: () -> Long?,
    private val isCollecting: () -> Boolean,
    private val profile: VehicleProfile = GeelyProfile
) {
    private val stateLock = Any()

    @Volatile
    private var efficiency: RangeEfficiencySnapshot? = null

    /** Clock millis of the last failed refresh, null when the last one succeeded. */
    @Volatile
    private var refreshFailedAtMillis: Long? = null

    /** Callable only from the dedicated range-efficiency executor (serialized). */
    fun refreshEfficiency() {
        val snapshot = runCatching { efficiencyProvider() }.getOrNull()
        synchronized(stateLock) {
            // G3: an empty window (e.g. the newest trip is still pending) is
            // not a new truth — the last valid estimate stays, and the empty
            // refresh starts the staleness window that expires it.
            if (snapshot != null && snapshot.efficiencyKmPerKwh != null) {
                efficiency = snapshot
                refreshFailedAtMillis = null
            } else {
                if (snapshot != null && efficiency == null) efficiency = snapshot
                if (refreshFailedAtMillis == null) refreshFailedAtMillis = clockMillis()
            }
        }
    }

    fun snapshot(): NativeRangeEstimate {
        val now = clockMillis()
        val collecting = isCollecting()
        val storeSnapshot = store.snapshot()

        val car = vehicleRange(storeSnapshot, collecting)
        val capacity = resolveCapacity()
        val soc = liveSignal(
            storeSnapshot[SignalKey.HV_BATTERY_SOC],
            collecting,
            maxValue = SOC_MAX_PERCENT
        )
        val efficiencyState = currentEfficiencyState()
        val own = appRange(soc, capacity.capacityKwh, efficiencyState)

        return NativeRangeEstimate(
            timestampMillis = now,
            carRangeKm = car.km,
            carRangeQuality = if (car.km != null) RangeAvailability.AVAILABLE else RangeAvailability.UNAVAILABLE,
            carRangeReason = car.reason,
            carRangePropertyId = profile.propertyIdFor(SignalKey.RANGE_REMAINING) ?: 0,
            carRangeSignalSource = car.signalSource,
            carRangeReceivedAtUtcMillis = car.receivedAtUtcMillis,
            carRangeSourceTimestampNanos = car.sourceTimestampNanos,
            socPercent = soc.value,
            capacityKwh = capacity.capacityKwh,
            capacitySource = capacity.source,
            efficiencyKmPerKwh = efficiencyState.kmPerKwh,
            efficiencySource = efficiencyState.source,
            efficiencyWindowDays = efficiencyState.windowDays,
            efficiencyTripCount = efficiencyState.tripCount,
            efficiencyDistanceKm = efficiencyState.distanceKm,
            efficiencyNetEnergyKwh = efficiencyState.netEnergyKwh,
            efficiencyUpdatedAtUtcMillis = efficiencyState.updatedAtUtcMillis,
            fullRangeKm = own.fullRangeKm,
            ownRangeKm = own.ownRangeKm,
            ownRangeQuality = own.quality,
            ownRangeReason = own.reason
        )
    }

    private fun vehicleRange(
        snapshot: Map<SignalKey, SignalSample>,
        collecting: Boolean
    ): VehicleRange {
        if (!collecting) return VehicleRange(reason = REASON_COLLECTION_STOPPED)
        val sample = snapshot[SignalKey.RANGE_REMAINING]
            ?: return VehicleRange(reason = REASON_WAITING_FOR_SIGNAL)
        if (sample.quality != SignalQuality.MEASURED) {
            return VehicleRange(reason = REASON_SIGNAL_ERROR)
        }
        if (!isCurrentRun(sample)) return VehicleRange(reason = REASON_WAITING_FOR_SIGNAL)
        val sourceTimestamp = sample.sourceTimestampNanos
        if (sourceTimestamp == null || sourceTimestamp <= 0L) {
            return VehicleRange(reason = REASON_UNPUBLISHED_SIGNAL)
        }
        val km = sample.floatValue()
        if (km == null || !km.isFinite() || km < 0f || km > RANGE_MAX_KM) {
            return VehicleRange(reason = REASON_OUT_OF_RANGE)
        }
        return VehicleRange(
            km = km.toDouble(),
            signalSource = sample.source.name,
            receivedAtUtcMillis = sample.timestamp.receivedAtUtcMillis,
            sourceTimestampNanos = sample.sourceTimestampNanos
        )
    }

    private fun liveSignal(
        sample: SignalSample?,
        collecting: Boolean,
        maxValue: Float
    ): ValidatedSignal {
        if (!collecting) return ValidatedSignal(null, REASON_COLLECTION_STOPPED)
        if (sample == null) return ValidatedSignal(null, REASON_WAITING_FOR_SIGNAL)
        if (sample.quality != SignalQuality.MEASURED) return ValidatedSignal(null, REASON_SIGNAL_ERROR)
        if (!isCurrentRun(sample)) return ValidatedSignal(null, REASON_WAITING_FOR_SIGNAL)
        val sourceTimestamp = sample.sourceTimestampNanos
        if (sourceTimestamp == null || sourceTimestamp <= 0L) {
            return ValidatedSignal(null, REASON_UNPUBLISHED_SIGNAL)
        }
        val value = sample.floatValue()
        if (value == null || !value.isFinite() || value < 0f || value > maxValue) {
            return ValidatedSignal(null, REASON_OUT_OF_RANGE)
        }
        return ValidatedSignal(value.toDouble(), null)
    }

    /** Old-run samples must not appear during a restart before the new read. */
    private fun isCurrentRun(sample: SignalSample): Boolean {
        val start = collectionStartedAtElapsedNanos() ?: return false
        return sample.timestamp.receivedAtElapsedNanos >= start
    }

    /**
     * Pack capacity, in kWh.
     *
     * One source: the reader states it in Settings. The two vehicle properties
     * that used to be tried first answered a factory default with no source
     * timestamp, so the rule that chose between them only ever produced the
     * fallback. See [GeelyProfile.battery].
     */
    private fun resolveCapacity(): Capacity {
        val wh = capacityWhProvider()
        val believable = if (wh.isFinite() && wh in GeelyProfile.battery.acceptedCapacityWh) {
            wh
        } else {
            GeelyProfile.battery.defaultCapacityWh
        }
        return Capacity(believable / 1000.0, CAPACITY_SOURCE_SETTINGS)
    }

    private fun currentEfficiencyState(): EfficiencyState {
        val now = clockMillis()
        val eff = efficiency ?: return EfficiencyState(
            reason = if (refreshFailedAtMillis == null) {
                REASON_EFFICIENCY_LOADING
            } else {
                REASON_EFFICIENCY_REFRESH_FAILED
            }
        )
        val failedAt = refreshFailedAtMillis
        if (eff.efficiencyKmPerKwh == null) {
            return EfficiencyState(
                distanceKm = eff.distanceKm,
                netEnergyKwh = eff.netEnergyKwh,
                updatedAtUtcMillis = eff.updatedAtUtcMillis,
                reason = REASON_NO_VALID_EFFICIENCY
            )
        }
        return when {
            failedAt != null && (now - failedAt) > CACHE_MAX_AGE_MILLIS ->
                efficiencyStateFrom(eff, REASON_EFFICIENCY_REFRESH_FAILED)
            failedAt != null -> efficiencyStateFrom(eff, degraded = true)
            else -> efficiencyStateFrom(eff)
        }
    }

    private fun efficiencyStateFrom(
        eff: RangeEfficiencySnapshot,
        reason: String? = null,
        degraded: Boolean = false
    ) = EfficiencyState(
        kmPerKwh = eff.efficiencyKmPerKwh,
        source = sourceFor(eff.windowDays),
        windowDays = eff.windowDays,
        tripCount = eff.tripCount,
        distanceKm = eff.distanceKm,
        netEnergyKwh = eff.netEnergyKwh,
        updatedAtUtcMillis = eff.updatedAtUtcMillis,
        degraded = degraded,
        reason = reason
    )

    private fun appRange(
        soc: ValidatedSignal,
        capacityKwh: Double,
        eff: EfficiencyState
    ): AppRange {
        if (soc.reason != null) {
            return AppRange(null, null, RangeAvailability.UNAVAILABLE, soc.reason)
        }
        val socPercent = soc.value!!
        // The efficiency gate: a reason here means the estimate is unavailable
        // (loading, no valid data, or a failed refresh past cache expiry).
        if (eff.reason != null) {
            return AppRange(null, null, RangeAvailability.UNAVAILABLE, eff.reason)
        }
        val kmPerKwh = eff.kmPerKwh
        if (kmPerKwh == null) {
            return AppRange(null, null, RangeAvailability.UNAVAILABLE, REASON_NO_VALID_EFFICIENCY)
        }
        val full = fullRangeKm(capacityKwh, kmPerKwh)
        val own = full?.let { ownRangeKm(socPercent, it) }
        if (full == null || own == null) {
            return AppRange(null, null, RangeAvailability.UNAVAILABLE, REASON_OUT_OF_RANGE)
        }
        return AppRange(
            fullRangeKm = full,
            ownRangeKm = own,
            quality = if (eff.degraded) RangeAvailability.DEGRADED else RangeAvailability.AVAILABLE,
            reason = if (eff.degraded) REASON_EFFICIENCY_REFRESH_FAILED else null
        )
    }

    private fun fullRangeKm(capacityKwh: Double, efficiencyKmPerKwh: Double): Double? {
        val full = capacityKwh * efficiencyKmPerKwh
        return full.takeIf { it.isFinite() && it >= 0.0 }
    }

    private fun ownRangeKm(socPercent: Double, fullRangeKm: Double): Double? {
        val own = socPercent / 100.0 * fullRangeKm
        return own.takeIf { it.isFinite() && it >= 0.0 }
    }

    private data class VehicleRange(
        val km: Double? = null,
        val reason: String? = null,
        val signalSource: String? = null,
        val receivedAtUtcMillis: Long? = null,
        val sourceTimestampNanos: Long? = null
    )

    private data class ValidatedSignal(val value: Double?, val reason: String?)

    private data class Capacity(val capacityKwh: Double, val source: String)

    private data class AppRange(
        val fullRangeKm: Double?,
        val ownRangeKm: Double?,
        val quality: RangeAvailability,
        val reason: String?
    )

    private data class EfficiencyState(
        val kmPerKwh: Double? = null,
        val source: String? = null,
        val windowDays: Int? = null,
        val tripCount: Int = 0,
        val distanceKm: Double? = null,
        val netEnergyKwh: Double? = null,
        val updatedAtUtcMillis: Long? = null,
        val degraded: Boolean = false,
        val reason: String? = null
    )

    companion object {
        /** How long a valid efficiency cache survives a refresh failure. */
        const val CACHE_MAX_AGE_MILLIS = 10 * 60 * 1000L
        const val RANGE_MAX_KM = com.timhss.capyenergy.profile.RANGE_MAX_KM
        const val SOC_MAX_PERCENT = 100f

        /**
         * The band a stated capacity must fall in. One source, in the profile:
         * this used to be a second copy of it, and a copy is how the two drift.
         */
        val ACCEPTED_CAPACITY_WH: ClosedFloatingPointRange<Double> =
            GeelyProfile.battery.acceptedCapacityWh

        const val REASON_COLLECTION_STOPPED = "COLLECTION_STOPPED"
        const val REASON_WAITING_FOR_SIGNAL = "WAITING_FOR_SIGNAL"
        const val REASON_SIGNAL_ERROR = "SIGNAL_ERROR"
        const val REASON_UNPUBLISHED_SIGNAL = "UNPUBLISHED_SIGNAL"
        const val REASON_OUT_OF_RANGE = "OUT_OF_RANGE"
        const val REASON_EFFICIENCY_LOADING = "EFFICIENCY_LOADING"
        const val REASON_NO_VALID_EFFICIENCY = "NO_VALID_EFFICIENCY"
        const val REASON_EFFICIENCY_REFRESH_FAILED = "EFFICIENCY_REFRESH_FAILED"

        const val CAR_SOURCE_VHAL_CALLBACK = "VHAL_CALLBACK"
        const val CAR_SOURCE_VHAL_POLLING = "VHAL_POLLING"

        const val CAPACITY_SOURCE_SETTINGS = "SETTINGS"

        const val EFFICIENCY_SOURCE_7D = "CLOSED_TRIPS_7D"
        const val EFFICIENCY_SOURCE_30D = "CLOSED_TRIPS_30D"

        internal fun sourceFor(windowDays: Int?): String? = when (windowDays) {
            7 -> EFFICIENCY_SOURCE_7D
            30 -> EFFICIENCY_SOURCE_30D
            else -> null
        }
    }
}
