package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.SessionEntity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RangeEfficiencyRepositoryTest {
    private val now = 1_784_000_000_000L
    private val dayMillis = 24L * 60L * 60L * 1_000L

    private fun trip(
        id: String,
        status: String = "ENDED",
        startOdometer: Float? = 1000f,
        endOdometer: Float? = 1010f,
        daysAgo: Long = 1,
        energyKwh: Double? = 3.0,
        speedDistance: Double? = null,
        timeState: String = "known"
    ) = SessionEntity(
        id = id,
        vehicleId = "test-vehicle",
        kind = "TRIP",
        status = status,
        startedAtUtcMillis = now - daysAgo * dayMillis - 3_600_000L,
        startedAtElapsedNanos = 1,
        startedAtBootCount = 1,
        endedAtUtcMillis = now - daysAgo * dayMillis,
        endedAtElapsedNanos = 2,
        endedAtBootCount = 1,
        startSocPercent = 60f,
        endSocPercent = 50f,
        startOdometerKm = startOdometer,
        endOdometerKm = endOdometer,
        rollupDistanceKm = speedDistance,
        rollupTractionWh = energyKwh?.let { it * 1000.0 },
        rollupRegenWh = if (energyKwh != null) 0.0 else null,
        rollupAuxiliaryWh = if (energyKwh != null) 0.0 else null,
        rollupIntegratedSeconds = if (energyKwh != null) 3600.0 else null,
        startGear = 8,
        endReason = "PARK_CONFIRMED",
        createdAtUtcMillis = 1,
        updatedAtUtcMillis = now - daysAgo * dayMillis,
        timeState = timeState
    )

    @Test
    fun `7-day window is selected when it qualifies`() {
        val requestedWindows = mutableListOf<Int>()
        val t1 = trip("t1")
        val t2 = trip("t2")
        val result = RangeEfficiencyRepository.compute(
            loadWindow = { days ->
                requestedWindows.add(days)
                listOf(t1, t2)
            },
            nowMillis = now
        )

        assertEquals(listOf(7), requestedWindows)
        assertEquals(7, result.windowDays)
        assertEquals(2, result.tripCount)
        assertEquals(20.0, result.distanceKm!!, 1e-9)
        assertEquals(6.0, result.netEnergyKwh!!, 1e-9)
        assertEquals(20.0 / 6.0, result.efficiencyKmPerKwh!!, 1e-9)
        assertEquals(now, result.updatedAtUtcMillis)
    }

    @Test
    fun `30-day fallback when 7-day is empty`() {
        val requestedWindows = mutableListOf<Int>()
        val result = RangeEfficiencyRepository.compute(
            loadWindow = { days ->
                requestedWindows.add(days)
                if (days == 7) {
                    emptyList()
                } else {
                    listOf(trip("old", energyKwh = 2.0))
                }
            },
            nowMillis = now
        )

        assertEquals(listOf(7, 30), requestedWindows)
        assertEquals(30, result.windowDays)
        assertEquals("CLOSED_TRIPS_30D", RangeEstimateMonitor.sourceFor(result.windowDays))
        assertEquals(10.0 / 2.0, result.efficiencyKmPerKwh!!, 1e-9)
    }

    @Test
    fun `invalid 7-day result falls through to 30-day`() {
        val requestedWindows = mutableListOf<Int>()
        val result = RangeEfficiencyRepository.compute(
            loadWindow = { days ->
                requestedWindows.add(days)
                if (days == 7) {
                    val stalled = trip("stalled", startOdometer = 1000f, endOdometer = 1000f)
                    listOf(stalled)
                } else {
                    listOf(trip("good", energyKwh = 2.0))
                }
            },
            nowMillis = now
        )

        assertEquals(listOf(7, 30), requestedWindows)
        assertEquals(30, result.windowDays)
        assertEquals(10.0 / 2.0, result.efficiencyKmPerKwh!!, 1e-9)
    }

    @Test
    fun `pending-finalization trips are excluded`() {
        val pending = trip("pending", status = "FINALIZATION_PENDING")
        val result = RangeEfficiencyRepository.computeWindow(
            trips = listOf(pending),
            windowDays = 7,
            updatedAtUtcMillis = now
        )

        assertNull(result.efficiencyKmPerKwh)
        assertEquals(0, result.tripCount)
    }

    @Test
    fun `energy and distance must belong to the same trip`() {
        val noDistance = trip("no-distance", startOdometer = null, endOdometer = null, energyKwh = 3.0)
        val noEnergy = trip("no-energy", energyKwh = null)
        val good = trip("good", energyKwh = 2.0)

        val result = RangeEfficiencyRepository.computeWindow(
            trips = listOf(noDistance, noEnergy, good),
            windowDays = 7,
            updatedAtUtcMillis = now
        )

        assertEquals(1, result.tripCount)
        assertEquals(10.0, result.distanceKm!!, 1e-9)
        assertEquals(2.0, result.netEnergyKwh!!, 1e-9)
    }

    @Test
    fun `odometer distance wins over speed distance`() {
        val trip = trip("t1", startOdometer = 1000f, endOdometer = 1010f, speedDistance = 9.0, energyKwh = 2.0)
        val result = RangeEfficiencyRepository.computeWindow(
            trips = listOf(trip),
            windowDays = 7,
            updatedAtUtcMillis = now
        )

        assertEquals(10.0, result.distanceKm!!, 1e-9)
    }

    @Test
    fun `speed distance is the fallback when odometer is missing`() {
        val trip = trip("t1", startOdometer = null, endOdometer = null, speedDistance = 8.0, energyKwh = 2.0)
        val result = RangeEfficiencyRepository.computeWindow(
            trips = listOf(trip),
            windowDays = 7,
            updatedAtUtcMillis = now
        )

        assertEquals(8.0, result.distanceKm!!, 1e-9)
        assertEquals(8.0 / 2.0, result.efficiencyKmPerKwh!!, 1e-9)
    }

    @Test
    fun `speed distance is the fallback when odometer did not advance`() {
        val trip = trip("t1", startOdometer = 1000f, endOdometer = 1000f, speedDistance = 6.0, energyKwh = 1.0)
        val result = RangeEfficiencyRepository.computeWindow(
            trips = listOf(trip),
            windowDays = 7,
            updatedAtUtcMillis = now
        )

        assertEquals(6.0, result.distanceKm!!, 1e-9)
        assertEquals(6.0, result.efficiencyKmPerKwh!!, 1e-9)
    }

    @Test
    fun `short matched trips qualify when their total distance reaches the minimum`() {
        val first = trip("first", startOdometer = 1000f, endOdometer = 1000.6f, energyKwh = 0.1)
        val second = trip("second", startOdometer = 2000f, endOdometer = 2000.6f, energyKwh = 0.1)
        val result = RangeEfficiencyRepository.computeWindow(
            trips = listOf(first, second),
            windowDays = 7,
            updatedAtUtcMillis = now
        )

        assertEquals(2, result.tripCount)
        assertEquals(1.2, result.distanceKm!!, 0.001)
        assertEquals(6.0, result.efficiencyKmPerKwh!!, 0.01)
    }

    @Test
    fun `a window below the minimum total distance is rejected`() {
        val short = trip("short", startOdometer = 1000f, endOdometer = 1000.3f, energyKwh = 2.0)
        val result = RangeEfficiencyRepository.computeWindow(
            trips = listOf(short),
            windowDays = 7,
            updatedAtUtcMillis = now
        )

        assertEquals(0, result.tripCount)
        assertNull(result.efficiencyKmPerKwh)
    }

    @Test
    fun `implausible efficiency is rejected`() {
        val high = trip("high", energyKwh = 0.3)
        val highResult = RangeEfficiencyRepository.computeWindow(
            trips = listOf(high),
            windowDays = 7,
            updatedAtUtcMillis = now
        )
        assertNull(highResult.efficiencyKmPerKwh)

        val low = trip("low", energyKwh = 30.0)
        val lowResult = RangeEfficiencyRepository.computeWindow(
            trips = listOf(low),
            windowDays = 7,
            updatedAtUtcMillis = now
        )
        assertNull(lowResult.efficiencyKmPerKwh)
    }

    @Test
    fun `no qualifying window returns an unusable snapshot`() {
        val result = RangeEfficiencyRepository.compute(
            loadWindow = { emptyList() },
            nowMillis = now
        )

        assertNull(result.windowDays)
        assertEquals(0, result.tripCount)
        assertNull(result.efficiencyKmPerKwh)
        assertEquals(now, result.updatedAtUtcMillis)
    }

    @Test
    fun `zero net energy does not qualify`() {
        val t = trip("zero", energyKwh = 0.0)
        val result = RangeEfficiencyRepository.computeWindow(
            trips = listOf(t),
            windowDays = 7,
            updatedAtUtcMillis = now
        )
        assertNull(result.efficiencyKmPerKwh)
        assertEquals(0, result.tripCount)
    }

    @Test
    fun `a pending trip with correct stamps stays out of the calculation`() {
        // G3: the clock stamp is not yet trustworthy, so the trip waits for
        // the sweep even when its wall stamps fall inside the window.
        val pending = trip("pending-wall-ok", timeState = "pending")
        val result = RangeEfficiencyRepository.computeWindow(
            trips = listOf(pending),
            windowDays = 7,
            updatedAtUtcMillis = now
        )

        assertNull(result.efficiencyKmPerKwh)
        assertEquals(0, result.tripCount)
    }

    @Test
    fun `other trips still qualify when the newest trip is pending`() {
        val good = trip("good")
        val pending = trip("pending-newest", daysAgo = 0, timeState = "pending")
        val result = RangeEfficiencyRepository.computeWindow(
            trips = listOf(pending, good),
            windowDays = 7,
            updatedAtUtcMillis = now
        )

        assertEquals(1, result.tripCount)
        assertEquals(10.0 / 3.0, result.efficiencyKmPerKwh!!, 1e-9)
    }

    @Test
    fun `a promoted trip enters the calculation under its corrected stamp`() {
        // The sweep flips pending to known AND rewrites the stamps; from the
        // calculator's side that arrival is a known trip like any other.
        val promoted = trip("promoted", timeState = "known")
        val result = RangeEfficiencyRepository.computeWindow(
            trips = listOf(promoted),
            windowDays = 7,
            updatedAtUtcMillis = now
        )

        assertEquals(1, result.tripCount)
        assertEquals(10.0 / 3.0, result.efficiencyKmPerKwh!!, 1e-9)
    }
}
