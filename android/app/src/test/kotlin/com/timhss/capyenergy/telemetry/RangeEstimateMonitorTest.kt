package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey

import com.timhss.capyenergy.profile.GeelyProfile
import com.timhss.capyenergy.profile.GeelyProperties
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Range validation and efficiency-state handling. Fakes supply the clock, the
 * store snapshot, the collection start time, and the efficiency repository, so
 * no real timers or database are involved.
 */
class RangeEstimateMonitorTest {
    private val nowMillis = 1_784_000_000_000L
    private val runStartNanos = 100_000_000_000L
    private val rangePropertyId = GeelyProperties.RangeRemaining.propertyId

    private fun sample(
        signalId: SignalKey,
        value: Any?,
        quality: SignalQuality = SignalQuality.MEASURED,
        source: SignalSource = SignalSource.VHAL_CALLBACK,
        propertyId: Int = 0,
        sourceTimestampNanos: Long? = 1_000L,
        receivedAtElapsedNanos: Long = runStartNanos + 1_000_000L,
        receivedAtUtcMillis: Long = nowMillis
    ) = SignalSample(
        signalId = signalId,
        value = value,
        unit = "km",
        quality = quality,
        source = source,
        propertyId = propertyId,
        propertyIdHex = "0x0",
        areaId = 0,
        timestamp = SignalTimestamp(
            receivedAtUtcMillis = receivedAtUtcMillis,
            receivedAtElapsedNanos = receivedAtElapsedNanos,
            sourceTimestampNanos = sourceTimestampNanos,
            accuracy = TimestampAccuracy.RECEIVED_EVENT,
            uncertaintyMillis = 0
        ),
        details = ""
    )

    private fun store(vararg samples: SignalSample): SignalStateStore =
        SignalStateStore().also { s -> samples.forEach(s::upsert) }

    private fun validStore(): SignalStateStore = store(
        sample(
            SignalKey.RANGE_REMAINING,
            266f,
            propertyId = 0x11400308,
        ),
        sample(SignalKey.HV_BATTERY_SOC, 72f, propertyId = 0x1160030f),
    )

    private fun defaultEfficiency() = RangeEfficiencySnapshot(
        windowDays = 7,
        tripCount = 2,
        distanceKm = 60.0,
        netEnergyKwh = 10.0,
        efficiencyKmPerKwh = 6.0,
        updatedAtUtcMillis = nowMillis
    )

    private fun monitor(
        store: SignalStateStore,
        repository: () -> RangeEfficiencySnapshot = ::defaultEfficiency,
        isCollecting: Boolean = true,
        clock: () -> Long = { nowMillis },
        runStart: () -> Long? = { runStartNanos },
        capacityWh: Double = GeelyProfile.battery.defaultCapacityWh
    ) = RangeEstimateMonitor(
        store = store,
        efficiencyProvider = repository,
        capacityWhProvider = { capacityWh },
        clockMillis = clock,
        collectionStartedAtElapsedNanos = runStart,
        isCollecting = { isCollecting }
    )

    @Test
    fun `vehicle range is available with source metadata`() {
        val estimate = monitor(validStore()).snapshot()

        assertEquals(266.0, estimate.carRangeKm!!, 1e-9)
        assertEquals(RangeAvailability.AVAILABLE, estimate.carRangeQuality)
        assertNull(estimate.carRangeReason)
        assertEquals(rangePropertyId, estimate.carRangePropertyId)
        assertEquals("VHAL_CALLBACK", estimate.carRangeSignalSource)
        assertEquals(nowMillis, estimate.carRangeReceivedAtUtcMillis)
        assertEquals(1_000L, estimate.carRangeSourceTimestampNanos)
    }

    @Test
    fun `polling source is reported`() {
        val estimate = monitor(
            store(
                sample(
                    SignalKey.RANGE_REMAINING,
                    266f,
                    source = SignalSource.VHAL_POLLING,
                    propertyId = 0x11400308,
                ),
                sample(SignalKey.HV_BATTERY_SOC, 72f),
            ),
        ).snapshot()

        assertEquals("VHAL_POLLING", estimate.carRangeSignalSource)
    }

    @Test
    fun `stopped collection degrades both values`() {
        val estimate = monitor(validStore(), isCollecting = false).snapshot()

        assertNull(estimate.carRangeKm)
        assertEquals(RangeAvailability.UNAVAILABLE, estimate.carRangeQuality)
        assertEquals(RangeEstimateMonitor.REASON_COLLECTION_STOPPED, estimate.carRangeReason)
        assertEquals(RangeEstimateMonitor.REASON_COLLECTION_STOPPED, estimate.ownRangeReason)
        assertNull(estimate.socPercent)
    }

    @Test
    fun `missing range sample waits for the signal`() {
        val estimate = monitor(store(sample(SignalKey.HV_BATTERY_SOC, 72f))).snapshot()

        assertNull(estimate.carRangeKm)
        assertEquals(RangeEstimateMonitor.REASON_WAITING_FOR_SIGNAL, estimate.carRangeReason)
    }

    @Test
    fun `signal errors and unavailable statuses map to SIGNAL_ERROR`() {
        for (quality in listOf(SignalQuality.ERROR, SignalQuality.UNAVAILABLE)) {
            val estimate = monitor(
                store(
                    sample(
                        SignalKey.RANGE_REMAINING,
                        266f,
                        quality = quality,
                        propertyId = 0x11400308,
                    ),
                    sample(SignalKey.HV_BATTERY_SOC, 72f),
                ),
            ).snapshot()
            assertEquals(RangeEstimateMonitor.REASON_SIGNAL_ERROR, estimate.carRangeReason)
        }
    }

    @Test
    fun `zero or absent source timestamps mean unpublished`() {
        for (timestamp in listOf<Long?>(null, 0L)) {
            val estimate = monitor(
                store(
                    sample(
                        SignalKey.RANGE_REMAINING,
                        266f,
                        sourceTimestampNanos = timestamp,
                        propertyId = 0x11400308,
                    ),
                    sample(SignalKey.HV_BATTERY_SOC, 72f, sourceTimestampNanos = timestamp),
                ),
            ).snapshot()
            assertEquals(RangeEstimateMonitor.REASON_UNPUBLISHED_SIGNAL, estimate.carRangeReason)
            assertEquals(RangeEstimateMonitor.REASON_UNPUBLISHED_SIGNAL, estimate.ownRangeReason)
        }
    }

    @Test
    fun `range outside the corruption guard is out of range`() {
        for (value in listOf<Any?>(3000, -5)) {
            val estimate = monitor(
                store(
                    sample(SignalKey.RANGE_REMAINING, value, propertyId = 0x11400308),
                    sample(SignalKey.HV_BATTERY_SOC, 72f),
                ),
            ).snapshot()
            assertEquals(RangeEstimateMonitor.REASON_OUT_OF_RANGE, estimate.carRangeReason)
        }
    }

    @Test
    fun `an old-run sample is not shown until the new initial read`() {
        val estimate = monitor(
            store(
                sample(
                    SignalKey.RANGE_REMAINING,
                    266f,
                    receivedAtElapsedNanos = runStartNanos - 1_000L,
                    propertyId = 0x11400308,
                ),
                sample(SignalKey.HV_BATTERY_SOC, 72f),
            ),
        ).snapshot()

        assertEquals(RangeEstimateMonitor.REASON_WAITING_FOR_SIGNAL, estimate.carRangeReason)
    }

    @Test
    fun `a stable ON_CHANGE value with an old source timestamp stays available`() {
        val estimate = monitor(
            store(
                sample(
                    SignalKey.RANGE_REMAINING,
                    266f,
                    sourceTimestampNanos = 9L,
                    receivedAtElapsedNanos = runStartNanos + 1_000_000L,
                    propertyId = 0x11400308,
                ),
                sample(SignalKey.HV_BATTERY_SOC, 72f),
            ),
        ).snapshot()

        assertEquals(266.0, estimate.carRangeKm!!, 1e-9)
        assertEquals(RangeAvailability.AVAILABLE, estimate.carRangeQuality)
    }

    @Test
    fun `missing SOC blocks the app estimate but not the vehicle range`() {
        val estimate = monitor(store(sample(SignalKey.RANGE_REMAINING, 266f))).snapshot()

        assertEquals(266.0, estimate.carRangeKm!!, 1e-9)
        assertNull(estimate.ownRangeKm)
        assertEquals(RangeEstimateMonitor.REASON_WAITING_FOR_SIGNAL, estimate.ownRangeReason)
    }

    @Test
    fun `capacity comes from the setting, and the car cannot move it`() {
        val stated = monitor(validStore(), capacityWh = 60_000.0).snapshot()
        assertEquals(60.0, stated.capacityKwh, 1e-9)
        assertEquals("SETTINGS", stated.capacitySource)
    }

    /**
     * The setting is guarded like any other input. A value that cannot be a
     * traction battery falls to the default pack rather than scaling every
     * range by it.
     */
    @Test
    fun `an impossible setting falls to the default pack`() {
        val estimate = monitor(validStore(), capacityWh = 300_000.0).snapshot()
        assertEquals(
            GeelyProfile.battery.defaultCapacityWh / 1000.0,
            estimate.capacityKwh,
            1e-9,
        )
        assertEquals("SETTINGS", estimate.capacitySource)
    }

    @Test
    fun `before the first refresh the app estimate is loading`() {
        val estimate = monitor(validStore()).snapshot()

        assertNull(estimate.ownRangeKm)
        assertEquals(RangeEstimateMonitor.REASON_EFFICIENCY_LOADING, estimate.ownRangeReason)
        assertNull(estimate.efficiencySource)
        assertEquals(0, estimate.efficiencyTripCount)
    }

    @Test
    fun `a completed refresh with no valid efficiency is reported`() {
        val none = RangeEfficiencySnapshot(updatedAtUtcMillis = nowMillis)
        val estimate = monitor(validStore(), repository = { none }).apply {
            refreshEfficiency()
        }.snapshot()

        assertNull(estimate.ownRangeKm)
        assertEquals(RangeEstimateMonitor.REASON_NO_VALID_EFFICIENCY, estimate.ownRangeReason)
        assertNull(estimate.efficiencySource)
    }

    @Test
    fun `valid efficiency computes the app estimate`() {
        val estimate = monitor(validStore()).apply {
            refreshEfficiency()
        }.snapshot()

        // 39.6 kWh * 6.0 km/kWh = 237.6 km full; 72% of that is 171.072 km.
        assertEquals(237.6, estimate.fullRangeKm!!, 1e-9)
        assertEquals(171.072, estimate.ownRangeKm!!, 1e-9)
        assertEquals(RangeAvailability.AVAILABLE, estimate.ownRangeQuality)
        assertNull(estimate.ownRangeReason)
        assertEquals("CLOSED_TRIPS_7D", estimate.efficiencySource)
        assertEquals(7, estimate.efficiencyWindowDays)
        assertEquals(2, estimate.efficiencyTripCount)
        assertEquals(72.0, estimate.socPercent!!, 1e-9)
    }

    @Test
    fun `a failed refresh flags the cache degraded within the window`() {
        var fail = false
        val estimate = monitor(
            validStore(),
            repository = {
                if (fail) throw IllegalStateException("boom")
                defaultEfficiency()
            },
        ).apply {
            refreshEfficiency()
            fail = true
            refreshEfficiency()
        }.snapshot()

        assertEquals(RangeAvailability.DEGRADED, estimate.ownRangeQuality)
        assertEquals(RangeEstimateMonitor.REASON_EFFICIENCY_REFRESH_FAILED, estimate.ownRangeReason)
        assertEquals(171.072, estimate.ownRangeKm!!, 1e-9)
    }

    @Test
    fun `the degraded cache expires and the estimate becomes unavailable`() {
        var fail = false
        val now = arrayOf(nowMillis)
        val estimate = monitor(
            validStore(),
            repository = {
                if (fail) throw IllegalStateException("boom")
                defaultEfficiency()
            },
            clock = { now[0] },
        ).apply {
            refreshEfficiency()
            fail = true
            refreshEfficiency()
            // Past the 10-minute cache window with no newer success.
            now[0] = now[0] + RangeEstimateMonitor.CACHE_MAX_AGE_MILLIS + 1L
        }.snapshot()

        assertNull(estimate.ownRangeKm)
        assertEquals(RangeAvailability.UNAVAILABLE, estimate.ownRangeQuality)
        assertEquals(RangeEstimateMonitor.REASON_EFFICIENCY_REFRESH_FAILED, estimate.ownRangeReason)
    }

    @Test
    fun `a refresh failure with no valid cache is unavailable`() {
        val estimate = monitor(
            validStore(),
            repository = { throw IllegalStateException("boom") },
        ).apply { refreshEfficiency() }.snapshot()

        assertNull(estimate.ownRangeKm)
        assertEquals(RangeEstimateMonitor.REASON_EFFICIENCY_REFRESH_FAILED, estimate.ownRangeReason)
    }

    @Test
    fun `a later successful refresh clears the degraded state`() {
        var fail = true
        val estimate = monitor(
            validStore(),
            repository = {
                if (fail) throw IllegalStateException("boom")
                defaultEfficiency()
            },
        ).apply {
            refreshEfficiency()
            fail = false
            refreshEfficiency()
        }.snapshot()

        assertEquals(RangeAvailability.AVAILABLE, estimate.ownRangeQuality)
        assertNull(estimate.ownRangeReason)
    }

    @Test
    fun `an empty refresh keeps the last valid estimate degraded`() {
        // G3: the newest trip still pending empties the window — the estimate
        // from the other trips stays instead of vanishing.
        var empty = false
        val estimate = monitor(
            validStore(),
            repository = {
                if (empty) RangeEfficiencySnapshot(updatedAtUtcMillis = nowMillis)
                else defaultEfficiency()
            },
        ).apply {
            refreshEfficiency()
            empty = true
            refreshEfficiency()
        }.snapshot()

        assertEquals(171.072, estimate.ownRangeKm!!, 1e-9)
        assertEquals(RangeAvailability.DEGRADED, estimate.ownRangeQuality)
        assertEquals(RangeEstimateMonitor.REASON_EFFICIENCY_REFRESH_FAILED, estimate.ownRangeReason)
    }

    @Test
    fun `bridge map carries stable keys and enum strings`() {
        val estimate = monitor(validStore()).apply { refreshEfficiency() }.snapshot()
        val map = estimate.toMap()

        val expectedKeys = setOf(
            "timestampMillis",
            "carRangeKm",
            "carRangeQuality",
            "carRangeReason",
            "carRangePropertyId",
            "carRangeSignalSource",
            "carRangeReceivedAtUtcMillis",
            "carRangeSourceTimestampNanos",
            "socPercent",
            "capacityKwh",
            "capacitySource",
            "efficiencyKmPerKwh",
            "efficiencySource",
            "efficiencyWindowDays",
            "efficiencyTripCount",
            "efficiencyDistanceKm",
            "efficiencyNetEnergyKwh",
            "efficiencyUpdatedAtUtcMillis",
            "fullRangeKm",
            "ownRangeKm",
            "ownRangeQuality",
            "ownRangeReason",
        )
        assertEquals(expectedKeys, map.keys)

        assertEquals("AVAILABLE", map["carRangeQuality"])
        assertEquals("AVAILABLE", map["ownRangeQuality"])
        assertEquals("CLOSED_TRIPS_7D", map["efficiencySource"])
        assertEquals("SETTINGS", map["capacitySource"])

        assertEquals("DEGRADED", RangeAvailability.DEGRADED.name)
        assertEquals("UNAVAILABLE", RangeAvailability.UNAVAILABLE.name)
    }
}
