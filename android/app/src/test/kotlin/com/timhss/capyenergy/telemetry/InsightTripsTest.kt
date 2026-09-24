package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.SessionEntity
import com.timhss.capyenergy.telemetry.db.TripSegmentEntity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InsightTripsTest {
    @Test
    fun `no rollup preserves nulls and raw odometer`() {
        val row = InsightTrips.row(
            trip = trip(startOdometer = 10f, endOdometer = 20f),
            hasMinuteBuckets = false,
        )
        assertNull(row.rollupTractionWh)
        assertNull(row.socAgreesWithIntegral)
        assertFalse(row.hasMinuteBuckets)
        assertEquals(10.0, row.startOdometerKm!!, 1e-9)
        assertEquals(20.0, row.endOdometerKm!!, 1e-9)
    }

    @Test
    fun `segment ends become the trip path, never frames`() {
        val geometry = InsightTrips.geometryOf(
            listOf(
                segment(0, -10.18, -48.33, -10.185, -48.335),
                segment(1, -10.185, -48.335, -10.19, -48.34),
            )
        )
        assertEquals(-10.18, geometry.startLatitude!!, 1e-9)
        assertEquals(-48.34, geometry.endLongitude!!, 1e-9)
        assertEquals(
            "-10.18,-48.33;-10.185,-48.335;-10.19,-48.34",
            geometry.path,
        )
    }

    @Test
    fun `the raw CAN fields come from the session rollup, the buckets flag from intervalDao`() {
        val row = InsightTrips.row(
            trip = trip(
                startOdometer = null,
                endOdometer = null,
                rollupDistanceKm = 7.25,
                rollupTractionWh = 900.0,
                rollupRegenWh = 100.0,
                rollupAuxiliaryWh = 12.5,
                socAgreesWithIntegral = "agrees"
            ),
            hasMinuteBuckets = true,
        )
        assertEquals(900.0, row.rollupTractionWh!!, 1e-9)
        assertEquals(100.0, row.rollupRegenWh!!, 1e-9)
        assertEquals(12.5, row.rollupAuxiliaryWh!!, 1e-9)
        assertEquals("agrees", row.socAgreesWithIntegral)
        assertTrue(row.hasMinuteBuckets)
        assertEquals(7.25, row.rollupDistanceKm!!, 1e-9)
    }

    private fun segment(
        ordinal: Int,
        startLat: Double,
        startLon: Double,
        endLat: Double,
        endLon: Double,
    ) = TripSegmentEntity(
        sessionId = "trip-1",
        ordinal = ordinal,
        startUtcMillis = 1,
        endUtcMillis = 2,
        distanceKm = 0.2,
        packWh = null,
        tractionWh = null,
        regeneratedWh = null,
        auxiliaryWh = null,
        integratedSeconds = 0.0,
        elapsedSeconds = 10.0,
        meanSpeedKmh = null,
        altitudeGainM = null,
        altitudeLossM = null,
        ambientTempC = null,
        startLatitude = startLat,
        startLongitude = startLon,
        endLatitude = endLat,
        endLongitude = endLon,
        path = "$startLat,$startLon;$endLat,$endLon",
    )

    private fun trip(
        startOdometer: Float?,
        endOdometer: Float?,
        rollupDistanceKm: Double? = null,
        rollupTractionWh: Double? = null,
        rollupRegenWh: Double? = null,
        rollupAuxiliaryWh: Double? = null,
        socAgreesWithIntegral: String? = null
    ) = SessionEntity(
        id = "trip-1",
        vehicleId = "test-vehicle",
        kind = "TRIP",
        status = "ENDED",
        startedAtUtcMillis = 1_000L,
        startedAtElapsedNanos = 1,
        startedAtBootCount = 1,
        endedAtUtcMillis = 2_000L,
        endedAtElapsedNanos = 2,
        endedAtBootCount = 1,
        startSocPercent = 80f,
        endSocPercent = 74f,
        startOdometerKm = startOdometer,
        endOdometerKm = endOdometer,
        rollupDistanceKm = rollupDistanceKm,
        rollupTractionWh = rollupTractionWh,
        rollupRegenWh = rollupRegenWh,
        rollupAuxiliaryWh = rollupAuxiliaryWh,
        rollupIntegratedSeconds = if (rollupTractionWh != null) 60.0 else null,
        socAgreesWithIntegral = socAgreesWithIntegral,
        startGear = 8,
        endReason = "PARK_CONFIRMED",
        createdAtUtcMillis = 1,
        updatedAtUtcMillis = 2,
    )
}
