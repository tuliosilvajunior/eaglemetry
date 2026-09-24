package com.timhss.capyenergy.bridge

import com.timhss.capyenergy.telemetry.ChargeCostUpdate
import com.timhss.capyenergy.telemetry.ChargeMergeOutcome
import com.timhss.capyenergy.telemetry.ChargeSessionRow
import com.timhss.capyenergy.telemetry.ClockAnchorStore
import com.timhss.capyenergy.telemetry.EnergyBucket
import com.timhss.capyenergy.telemetry.LiveEnergyBuckets
import com.timhss.capyenergy.telemetry.NativeRangeEstimate
import com.timhss.capyenergy.telemetry.RangeAvailability
import com.timhss.capyenergy.telemetry.TripEnergySeries
import com.timhss.capyenergy.telemetry.TripSessionRow
import com.timhss.capyenergy.telemetry.WindowEnergySeries
import com.timhss.capyenergy.telemetry.db.SessionEntity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The native half of the typed wire.
 *
 * These mappings replaced `toMap()` calls whose keys nothing checked. The
 * compiler now checks the names, so what is left to check is that every value
 * reaches the field it belongs in — a swap between two fields of the same type
 * compiles and would ship silently.
 */
class TelemetryWireMappingTest {

    @Test
    fun `every energy column reaches its own field`() {
        // Distinct values throughout: two columns that swapped would still
        // compile, and only different numbers can catch that.
        val wire = EnergyBucket(
            startUtcMillis = 1_735_689_600_000L,
            tractionWh = 1.0,
            regeneratedWh = 2.0,
            auxiliaryWh = 3.0,
            integratedSeconds = 4.0,
            speedDistanceKm = 5.0,
            odometerDistanceKm = 6.0,
            speedIntegratedSeconds = 7.0,
            climateWh = 8.0,
            climateIntegratedSeconds = 9.0,
            deliveredWh = 10.0,
            startSoc = 85.0,
            endSoc = 84.5,
            startVoltage = 380.0,
            endVoltage = 385.0,
        ).toWire()

        assertEquals(1_735_689_600_000L, wire.startUtcMillis)
        assertEquals(1.0, wire.tractionWh, 0.0)
        assertEquals(2.0, wire.regeneratedWh, 0.0)
        assertEquals(3.0, wire.auxiliaryWh, 0.0)
        assertEquals(4.0, wire.integratedSeconds, 0.0)
        assertEquals(5.0, wire.speedDistanceKm, 0.0)
        assertEquals(6.0, wire.odometerDistanceKm, 0.0)
        assertEquals(7.0, wire.speedIntegratedSeconds, 0.0)
        assertEquals(8.0, wire.climateWh, 0.0)
        assertEquals(9.0, wire.climateIntegratedSeconds, 0.0)
        assertEquals(10.0, wire.deliveredWh, 0.0)
        assertEquals(85.0, wire.startSoc!!, 0.0)
        assertEquals(84.5, wire.endSoc!!, 0.0)
        assertEquals(380.0, wire.startVoltage!!, 0.0)
        assertEquals(385.0, wire.endVoltage!!, 0.0)
    }

    @Test
    fun `interval record wire carries startSoc and endSoc measurements`() {
        val interval = com.timhss.capyenergy.telemetry.db.IntervalEntity(
            sessionId = "trip-1",
            startUtcMillis = 1_735_689_600_000L,
            tractionWh = 100.0,
            startSoc = 80.0,
            endSoc = 79.5,
            startVoltage = 380.0,
            endVoltage = 385.0
        )
        val wire = interval.toRecordWire()
        assertEquals(80.0, wire.startSoc?.value!!, 1e-6)
        assertEquals("%", wire.startSoc?.unit)
        assertEquals("measured", wire.startSoc?.validity)
        assertEquals(79.5, wire.endSoc?.value!!, 1e-6)
        assertEquals("%", wire.endSoc?.unit)
        assertEquals("measured", wire.endSoc?.validity)
        assertEquals(380.0, wire.startVoltage?.value!!, 1e-6)
        assertEquals("V", wire.startVoltage?.unit)
        assertEquals("measured", wire.startVoltage?.validity)
        assertEquals(385.0, wire.endVoltage?.value!!, 1e-6)
        assertEquals("V", wire.endVoltage?.unit)
        assertEquals("measured", wire.endVoltage?.validity)

        val unmeasured = com.timhss.capyenergy.telemetry.db.IntervalEntity(
            sessionId = "trip-2",
            startUtcMillis = 1_735_689_600_000L,
            startSoc = null,
            endSoc = null,
            startVoltage = null,
            endVoltage = null
        ).toRecordWire()
        assertNull(unmeasured.startSoc?.value)
        assertEquals("unreported", unmeasured.startSoc?.validity)
        assertNull(unmeasured.endSoc?.value)
        assertEquals("unreported", unmeasured.endSoc?.validity)
        assertNull(unmeasured.startVoltage?.value)
        assertEquals("unreported", unmeasured.startVoltage?.validity)
        assertNull(unmeasured.endVoltage?.value)
        assertEquals("unreported", unmeasured.endVoltage?.validity)
    }

    @Test
    fun `a window reports how many of its trips were rebuilt`() {
        val wire = WindowEnergySeries(
            startUtcMillis = 1_735_689_600_000L,
            endUtcMillis = 1_735_693_200_000L,
            bucketMillis = 60_000L,
            sessionCount = 4,
            resampledSessionCount = 1,
            buckets = listOf(bucket(1_735_689_600_000L)),
            lastChargeCostPerKwh = null,
            lastChargeCostCurrency = null,
        ).toWire()

        assertEquals(1_735_689_600_000L, wire.startUtcMillis)
        assertEquals(1_735_693_200_000L, wire.endUtcMillis)
        assertEquals(4L, wire.sessionCount)
        assertEquals(1L, wire.resampledSessionCount)
        assertNull(wire.lastChargeCostPerKwh)
    }

    @Test
    fun `a live series states the width it was cut to`() {
        val wire = LiveEnergyBuckets(
            sessionId = "trip-1",
            startedAtUtcMillis = 1_735_689_600_000L,
            buckets = listOf(bucket(1_735_689_600_000L)),
            bucketMillis = 10_000L,
        ).toWire()

        assertEquals("trip-1", wire.sessionId)
        assertEquals(1_735_689_600_000L, wire.startedAtUtcMillis)
        assertEquals(10_000L, wire.bucketMillis)
        assertEquals(1, wire.buckets.size)
    }
    @Test
    fun `a live series from an unlearned boot says the time is not synced`() {
        ClockAnchorStore.reset()
        val wire = LiveEnergyBuckets(
            sessionId = "trip-1",
            startedAtUtcMillis = 1_746_000_000_000L,
            buckets = listOf(bucket(1_746_000_000_000L)),
            bucketMillis = 10_000L,
        ).toWire()

        assertEquals(true, wire.timeUnsynced)
        ClockAnchorStore.reset()
    }

    @Test
    fun `a live series from a learned boot reads as synced`() {
        ClockAnchorStore.reset()
        val now = System.currentTimeMillis()
        val elapsed = 100_000_000_000L
        ClockAnchorStore.offerServerDate(now - 60_000L, elapsed - 60_000_000_000L)
        ClockAnchorStore.offerGpsFix(now, elapsed)
        val wire = LiveEnergyBuckets(
            sessionId = "trip-1",
            startedAtUtcMillis = now,
            buckets = listOf(bucket(now)),
            bucketMillis = 10_000L,
        ).toWire()

        assertEquals(false, wire.timeUnsynced)
        ClockAnchorStore.reset()
    }

    @Test
    fun `a stale line stays unsynced even after the anchor learns`() {
        // The accumulator keeps its first sample's anchor for the session, so
        // a birth-clock line outlives the learn event until the session
        // rotates. Skew past the guard tolerance names it (G5, boot 142).
        ClockAnchorStore.reset()
        val now = System.currentTimeMillis()
        val elapsed = 100_000_000_000L
        ClockAnchorStore.offerServerDate(now - 60_000L, elapsed - 60_000_000_000L)
        ClockAnchorStore.offerGpsFix(now, elapsed)
        val wire = LiveEnergyBuckets(
            sessionId = "trip-1",
            startedAtUtcMillis = 1_746_000_000_000L,
            buckets = listOf(bucket(1_746_000_000_000L)),
            bucketMillis = 10_000L,
        ).toWire()

        assertEquals(true, wire.timeUnsynced)
        ClockAnchorStore.reset()
    }

    @Test
    fun `a range estimate crosses as the enum name Flutter reads`() {
        val wire = NativeRangeEstimate(
            timestampMillis = 1_735_689_600_000L,
            carRangeKm = 210.0,
            carRangeQuality = RangeAvailability.AVAILABLE,
            carRangeReason = null,
            carRangePropertyId = 0x11400308,
            carRangeSignalSource = "VHAL_CALLBACK",
            carRangeReceivedAtUtcMillis = 1_735_689_599_000L,
            carRangeSourceTimestampNanos = 12_345L,
            socPercent = 64.8,
            capacityKwh = 39.6,
            capacitySource = "SETTINGS",
            efficiencyKmPerKwh = 6.2,
            efficiencySource = "CLOSED_TRIPS_7D",
            efficiencyWindowDays = 7,
            efficiencyTripCount = 11,
            efficiencyDistanceKm = 412.5,
            efficiencyNetEnergyKwh = 66.5,
            efficiencyUpdatedAtUtcMillis = 1_735_689_000_000L,
            fullRangeKm = 245.5,
            ownRangeKm = 159.1,
            ownRangeQuality = RangeAvailability.AVAILABLE,
            ownRangeReason = null,
        ).toWire()

        // The Dart side gates on these exact strings, so the enum name is part
        // of the contract rather than an implementation detail of the monitor.
        assertEquals("AVAILABLE", wire.carRangeQuality)
        assertEquals("AVAILABLE", wire.ownRangeQuality)
        assertEquals(0x11400308L, wire.carRangePropertyId)
        assertEquals("VHAL_CALLBACK", wire.carRangeSignalSource)
        assertEquals("SETTINGS", wire.capacitySource)
        assertEquals(39.6, wire.capacityKwh, 0.0)
        assertEquals(11L, wire.efficiencyTripCount)
        assertEquals(7L, wire.efficiencyWindowDays)
        assertEquals(210.0, wire.carRangeKm!!, 0.0)
        assertEquals(159.1, wire.ownRangeKm!!, 0.0)
        assertEquals(245.5, wire.fullRangeKm!!, 0.0)
    }

    @Test
    fun `a row's live overrides win over the stored session`() {
        // While a session is open its ends come from the newest frame. The map
        // merge this replaced could shadow any key; these four are the only
        // ones that may, and the test says which.
        val stored = tripEntity(endSoc = 74.0f, endOdometerKm = 12800.0f)
        val wire = TripSessionRow(
            session = stored,
            durationMillis = 1_200_000L,
            endSoc = 69.0f,
            endOdometerKm = 12_812.4f,
            updatedAtUtcMillis = 1_735_690_800_000L,
        ).toWire()

        assertEquals(69.0, wire.endSoc!!, 1e-6)
        assertEquals(12_812.4, wire.endOdometerKm!!, 1e-3)
        assertEquals(1_735_690_800_000L, wire.updatedAtUtcMillis)
        assertEquals(1_200_000L, wire.durationMillis)
        // Everything else still comes from the stored row.
        assertEquals("trip-1", wire.id)
        assertEquals(74.0, wire.startSoc!!, 1e-6)
    }

    @Test
    fun `a charge row carries the energy the aggregate computed`() {
        val wire = ChargeSessionRow(
            session = chargeEntity(),
            durationMillis = 7_200_000L,
            endSoc = 80.0f,
            endOdometerKm = 12_800.0f,
            endAmbientTempC = 21.5f,
            estimatedEnergyKwh = 12.5,
            updatedAtUtcMillis = 1_735_696_800_000L,
        ).toWire()

        assertEquals(12.5, wire.estimatedEnergyKwh!!, 1e-9)
        assertEquals(21.5, wire.endAmbientTempC!!, 1e-6)
        assertEquals(2L, wire.plugType)
        assertEquals("charge-1", wire.id)
    }

    @Test
    fun `a refused merge claims nothing was changed`() {
        val wire = ChargeMergeOutcome(
            ok = false,
            error = "candidate_no_longer_valid",
            mergedSessionId = null,
            mergedCount = 0,
            framesReassigned = 0,
            deletedSessions = 0,
        ).toWire()

        assertEquals(false, wire.ok)
        assertEquals("candidate_no_longer_valid", wire.error)
        assertEquals(0L, wire.deletedSessions)
        assertNull(wire.mergedSessionId)
    }

    @Test
    fun `a failed cost update carries no row`() {
        val wire = ChargeCostUpdate(ok = false, updatedRows = 0, session = null).toWire()

        assertEquals(false, wire.ok)
        assertEquals(0L, wire.updatedRows)
        assertNull(wire.session)
    }

    private fun tripEntity(endSoc: Float?, endOdometerKm: Float?) = SessionEntity(
        id = "trip-1",
        vehicleId = "test-vehicle",
        kind = "TRIP",
        status = "ENDED",
        startedAtUtcMillis = 1_735_689_600_000L,
        startedAtElapsedNanos = 1_000_000_000L,
        startedAtBootCount = 1,
        movementStartedAtUtcMillis = null,
        movementStartedAtElapsedNanos = null,
        movementStartedAtBootCount = null,
        endedAtUtcMillis = null,
        endedAtElapsedNanos = null,
        endedAtBootCount = null,
        startSocPercent = 74.0f,
        endSocPercent = endSoc,
        startOdometerKm = endOdometerKm,
        endOdometerKm = endOdometerKm,
        startGear = 8,
        endReason = null,
        createdAtUtcMillis = 1_735_689_600_000L,
        updatedAtUtcMillis = 1_735_689_600_000L,
    )

    private fun chargeEntity() = SessionEntity(
        id = "charge-1",
        vehicleId = "test-vehicle",
        kind = "CHARGE",
        status = "ENDED",
        startedAtUtcMillis = 1_735_689_600_000L,
        startedAtElapsedNanos = 1_000_000_000L,
        startedAtBootCount = 1,
        chargeStartedAtUtcMillis = null,
        chargeStartedAtElapsedNanos = null,
        chargeStartedAtBootCount = null,
        chargeEndedAtUtcMillis = null,
        chargeEndedAtElapsedNanos = null,
        chargeEndedAtBootCount = null,
        plugDisconnectedAtUtcMillis = null,
        plugDisconnectedAtElapsedNanos = null,
        plugDisconnectedAtBootCount = null,
        startSocPercent = 20.0f,
        endSocPercent = null,
        startOdometerKm = 12_800.0f,
        endOdometerKm = null,
        plugType = 2,
        startPowerKw = 7.2f,
        costPerKwh = null,
        paidAmount = null,
        costCurrency = null,
        startAmbientTempC = 19.0f,
        endAmbientTempC = null,
        startLatitude = null,
        startLongitude = null,
        startAltitudeM = null,
        startGpsAccuracyM = null,
        startLocationProvider = null,
        startLocationElapsedRealtimeNanos = null,
        chargeEndReason = null,
        endReason = null,
        createdAtUtcMillis = 1_735_689_600_000L,
        updatedAtUtcMillis = 1_735_689_600_000L,
    )

    private fun bucket(startUtcMillis: Long) = EnergyBucket(
        startUtcMillis = startUtcMillis,
        tractionWh = 120.5,
        regeneratedWh = 40.25,
        auxiliaryWh = 12.0,
        integratedSeconds = 60.0,
    )
}