package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.BatteryCycleLedger.EventKind
import com.timhss.capyenergy.telemetry.db.SessionEntity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BatteryCycleEventsTest {

    private val delta = 1e-6
    private val packWh = 40_000.0

    private fun trip(
        id: String,
        startedAt: Long,
        endedAt: Long?,
        startSoc: Float?,
        endSoc: Float?,
        startOdometerKm: Float? = 1_000f,
        endOdometerKm: Float? = 1_100f,
    ) = SessionEntity(
        id = id,
        vehicleId = "test-vehicle",
        kind = "TRIP",
        status = if (endedAt == null) "ACTIVE" else "ENDED",
        startedAtUtcMillis = startedAt,
        startedAtElapsedNanos = 0,
        endedAtUtcMillis = endedAt,
        startSocPercent = startSoc,
        endSocPercent = endSoc,
        startOdometerKm = startOdometerKm,
        endOdometerKm = endOdometerKm,
        createdAtUtcMillis = startedAt,
        updatedAtUtcMillis = startedAt
    )

    private fun charge(
        id: String,
        startedAt: Long,
        endedAt: Long?,
        startSoc: Float?,
        endSoc: Float?,
        costPerKwh: Double? = null,
        paidAmount: Double? = null,
        currency: String? = "BRL"
    ) = SessionEntity(
        id = id,
        vehicleId = "test-vehicle",
        kind = "CHARGE",
        status = if (endedAt == null) "CHARGING" else "ENDED",
        startedAtUtcMillis = startedAt,
        startedAtElapsedNanos = 0,
        chargeStartedAtUtcMillis = startedAt,
        endedAtUtcMillis = endedAt,
        chargeEndedAtUtcMillis = endedAt,
        startSocPercent = startSoc,
        endSocPercent = endSoc,
        costPerKwh = costPerKwh,
        paidAmount = paidAmount,
        costCurrency = currency,
        createdAtUtcMillis = startedAt,
        updatedAtUtcMillis = startedAt
    )

    private fun parked(
        id: String,
        startedAt: Long,
        endedAt: Long?,
        startSoc: Float?,
        endSoc: Float?,
        lastSoc: Float? = null
    ) = SessionEntity(
        id = id,
        vehicleId = "test-vehicle",
        kind = "PARKED",
        status = if (endedAt == null) "ACTIVE" else "ENDED",
        startedAtUtcMillis = startedAt,
        startedAtElapsedNanos = 0,
        endedAtUtcMillis = endedAt,
        startSocPercent = startSoc,
        endSocPercent = endSoc,
        lastSoc = lastSoc,
        createdAtUtcMillis = startedAt,
        updatedAtUtcMillis = startedAt
    )

    @Test
    fun `the three kinds merge into one stream in time order`() {
        val events = BatteryCycleEvents.build(
            sessions = listOf(
                trip("t", 300, 400, 90f, 70f),
                charge("c", 100, 200, 50f, 90f),
                parked("p", 200, 300, 90f, 90f)
            ),
            capacityFallbackWh = packWh
        )

        assertEquals(
            listOf(EventKind.CHARGE, EventKind.PARKED, EventKind.TRIP),
            events.map { it.kind }
        )
        assertEquals(listOf(100L, 200L, 300L), events.map { it.startUtcMillis })
        assertEquals(listOf("c", "p", "t"), events.map { it.sessionId })
    }

    @Test
    fun `an open session is not folded`() {
        val events = BatteryCycleEvents.build(
            sessions = listOf(
                trip("open", 100, null, 90f, null),
                charge("open", 100, null, 50f, null),
                parked("open", 100, null, 50f, null)
            ),
            capacityFallbackWh = packWh
        )

        assertTrue(events.isEmpty())
    }

    @Test
    fun `a trip with capacity falls back to the resolved one`() {
        val events = BatteryCycleEvents.build(
            sessions = listOf(trip("t", 100, 200, 90f, 70f)),
            capacityFallbackWh = packWh
        )

        assertEquals(packWh, events.single().capacityWh!!, delta)
    }

    @Test
    fun `trip distance is the odometer delta`() {
        val events = BatteryCycleEvents.build(
            sessions = listOf(
                trip("t", 100, 200, 90f, 70f, startOdometerKm = 1_000f, endOdometerKm = 1_080f)
            ),
            capacityFallbackWh = packWh
        )

        assertEquals(80.0, events.single().distanceKm!!, delta)
    }

    @Test
    fun `a decreasing odometer gives no distance rather than a negative one`() {
        val events = BatteryCycleEvents.build(
            sessions = listOf(
                trip("t", 100, 200, 90f, 70f, startOdometerKm = 1_100f, endOdometerKm = 1_000f)
            ),
            capacityFallbackWh = packWh
        )

        assertNull(events.single().distanceKm)
    }

    @Test
    fun `an amount paid wins over the stored rate and becomes a rate`() {
        val events = BatteryCycleEvents.build(
            sessions = listOf(
                charge("c", 100, 200, 50f, 100f, costPerKwh = 0.90, paidAmount = 30.0)
            ),
            capacityFallbackWh = packWh
        )

        assertEquals(1.50, events.single().costPerKwh!!, delta)
    }

    @Test
    fun `without a capacity the amount paid cannot become a rate`() {
        val events = BatteryCycleEvents.build(
            sessions = listOf(
                charge("c", 100, 200, 50f, 100f, costPerKwh = 0.90, paidAmount = 30.0)
            ),
            capacityFallbackWh = null
        )

        assertEquals(0.90, events.single().costPerKwh!!, delta)
    }

    @Test
    fun `a charge with no price at all stays unpriced`() {
        val events = BatteryCycleEvents.build(
            sessions = listOf(charge("c", 100, 200, 50f, 100f)),
            capacityFallbackWh = packWh
        )

        assertNull("free and unpriced cannot be told apart", events.single().costPerKwh)
    }

    @Test
    fun `a parked session with no end SOC uses the last one it saw`() {
        val events = BatteryCycleEvents.build(
            sessions = listOf(parked("p", 100, 200, 80f, null, lastSoc = 76f)),
            capacityFallbackWh = packWh
        )

        assertEquals(76.0, events.single().endSoc, delta)
    }
}
