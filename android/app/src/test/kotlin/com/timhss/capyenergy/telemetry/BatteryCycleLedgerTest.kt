package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.BatteryCycleLedger.Event
import com.timhss.capyenergy.telemetry.BatteryCycleLedger.EventKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the battery cycle rules (boundary in SOC percent, parked loss
 * counted but not boundary-moving, moving weighted average pack price).
 *
 * Every expected value here was derived by hand from the rules above, not
 * captured from this implementation, so a failure states that the model
 * changed rather than that the code moved.
 *
 * The model is implemented once, in Kotlin, so these cases live in a test and
 * not in a shared JSON fixture. `testdata/trip_energy_cases.json` is shared
 * because the trip energy model is implemented twice, in Kotlin and in Dart.
 * That reason does not apply here.
 */
class BatteryCycleLedgerTest {

    private val delta = 1e-6
    private val packWh = 40_000.0
    private var clock = 0L

    /** One hour per event, so the order is the only thing the times encode. */
    private fun event(
        kind: EventKind,
        startSoc: Double,
        endSoc: Double,
        capacityWh: Double? = packWh,
        distanceKm: Double? = null,
        costPerKwh: Double? = null,
        costCurrency: String? = "BRL",
        sessionId: String? = null
    ): Event {
        val start = clock
        clock += 3_600_000L
        return Event(
            kind = kind,
            // The default names the event by when it happened, so a test that
            // does not care about identity still gets a unique one.
            sessionId = sessionId ?: "$kind-$start",
            startUtcMillis = start,
            endUtcMillis = clock,
            startSoc = startSoc,
            endSoc = endSoc,
            capacityWh = capacityWh,
            distanceKm = distanceKm,
            costPerKwh = costPerKwh,
            costCurrency = costCurrency
        )
    }

    @Test
    fun `no events give no cycles`() {
        assertTrue(BatteryCycleLedger.fold(emptyList()).isEmpty())
    }

    @Test
    fun `the pack blends the price of two charges and a trip draws at the blend`() {
        // Worked example: 20 kWh at 0.50 plus 15 kWh at 1.20 blends to 0.80 over 35 kWh.
        // A trip that takes 10 kWh therefore costs 8.00.
        val cycles = BatteryCycleLedger.fold(
            listOf(
                event(EventKind.CHARGE, 0.0, 50.0, costPerKwh = 0.50),
                event(EventKind.CHARGE, 50.0, 87.5, costPerKwh = 1.20),
                event(EventKind.TRIP, 87.5, 62.5, distanceKm = 100.0)
            )
        )

        assertEquals(1, cycles.size)
        val cycle = cycles.single()
        assertEquals(25.0, cycle.dischargePercent, delta)
        assertEquals(10.0, cycle.tripEnergyKwh, delta)
        assertEquals(8.0, cycle.cost!!, delta)
        assertEquals(1.0, cycle.costCoverage!!, delta)
        assertEquals("BRL", cycle.costCurrency)
        assertTrue("the newest cycle is open", cycle.isOpen)
    }

    @Test
    fun `a trip that crosses one hundred percent is split in proportion`() {
        // 40 kWh pack, every kWh bought at 1.00, so money tracks energy exactly
        // and the split is visible in the cost as well as in the distance.
        val cycles = BatteryCycleLedger.fold(
            listOf(
                event(EventKind.CHARGE, 0.0, 100.0, costPerKwh = 1.0),
                event(EventKind.TRIP, 100.0, 10.0, distanceKm = 360.0),
                event(EventKind.CHARGE, 10.0, 100.0, costPerKwh = 1.0),
                // 20 % of SOC, of which 10 % closes the first cycle and 10 %
                // opens the second. Half the distance belongs to each.
                event(EventKind.TRIP, 100.0, 80.0, distanceKm = 80.0)
            )
        )

        assertEquals(2, cycles.size)

        val closed = cycles[0]
        assertEquals(100.0, closed.dischargePercent, delta)
        assertEquals(400.0, closed.distanceKm, delta)
        assertEquals(40.0, closed.tripEnergyKwh, delta)
        assertEquals(40.0, closed.cost!!, delta)
        assertEquals(10.0, closed.efficiencyKmPerKwh!!, delta)
        assertEquals(40.0, closed.measuredCapacityKwh!!, delta)
        assertFalse(closed.isOpen)

        val open = cycles[1]
        assertEquals(10.0, open.dischargePercent, delta)
        assertEquals(40.0, open.distanceKm, delta)
        assertEquals(4.0, open.tripEnergyKwh, delta)
        assertEquals(4.0, open.cost!!, delta)
        assertTrue(open.isOpen)
    }

    @Test
    fun `parked loss is debited but does not move the boundary`() {
        // The decision in section 4.2. The bar must keep answering "how far
        // does one full battery go", so standing still must not fill it.
        val cycles = BatteryCycleLedger.fold(
            listOf(
                event(EventKind.CHARGE, 0.0, 100.0, costPerKwh = 1.0),
                event(EventKind.TRIP, 100.0, 50.0, distanceKm = 200.0),
                event(EventKind.PARKED, 50.0, 45.0)
            )
        )

        val cycle = cycles.single()
        assertEquals("parked SOC must not fill the bar", 50.0, cycle.dischargePercent, delta)
        assertEquals(5.0, cycle.parkedSocPercent, delta)
        assertEquals(2.0, cycle.parkedEnergyKwh, delta)
        assertEquals(200.0, cycle.distanceKm, delta)
        assertEquals(20.0, cycle.tripEnergyKwh, delta)
        // 20 kWh driven plus 2 kWh lost parked, all bought at 1.00.
        assertEquals(22.0, cycle.cost!!, delta)
    }

    @Test
    fun `an unpriced charge lowers the coverage instead of pricing energy at zero`() {
        // 20 kWh unpriced then 20 kWh at 1.00 leaves the pack half priced, so a
        // 20 kWh trip draws 10 priced kWh and costs 10.00 at 50 % coverage.
        val cycles = BatteryCycleLedger.fold(
            listOf(
                event(EventKind.CHARGE, 0.0, 50.0, costPerKwh = null),
                event(EventKind.CHARGE, 50.0, 100.0, costPerKwh = 1.0),
                event(EventKind.TRIP, 100.0, 50.0, distanceKm = 200.0)
            )
        )

        val cycle = cycles.single()
        assertEquals(10.0, cycle.pricedEnergyKwh, delta)
        assertEquals(10.0, cycle.unpricedEnergyKwh, delta)
        assertEquals(10.0, cycle.cost!!, delta)
        assertEquals(0.5, cycle.costCoverage!!, delta)
    }

    @Test
    fun `a cycle with no priced energy reports no cost rather than zero`() {
        val cycles = BatteryCycleLedger.fold(
            listOf(
                event(EventKind.CHARGE, 0.0, 100.0, costPerKwh = null),
                event(EventKind.TRIP, 100.0, 60.0, distanceKm = 160.0)
            )
        )

        val cycle = cycles.single()
        assertNull("no priced energy is not a cost of zero", cycle.cost)
        assertEquals(0.0, cycle.costCoverage!!, delta)
        assertEquals(160.0, cycle.distanceKm, delta)
    }

    @Test
    fun `unknown capacity keeps the boundary and marks the energy incomplete`() {
        // The boundary is in SOC percent, so it survives a pack capacity the
        // car never published. Only the energy is lost.
        val cycles = BatteryCycleLedger.fold(
            listOf(
                event(EventKind.CHARGE, 0.0, 100.0, capacityWh = null, costPerKwh = 1.0),
                event(EventKind.TRIP, 100.0, 30.0, capacityWh = null, distanceKm = 280.0)
            )
        )

        val cycle = cycles.single()
        assertEquals(70.0, cycle.dischargePercent, delta)
        assertEquals(280.0, cycle.distanceKm, delta)
        assertTrue(cycle.energyIncomplete)
        assertEquals(0.0, cycle.tripEnergyKwh, delta)
        assertNull(cycle.efficiencyKmPerKwh)
        assertNull(cycle.measuredCapacityKwh)
    }

    @Test
    fun `a SOC step below the noise floor is not a discharge`() {
        val cycles = BatteryCycleLedger.fold(
            listOf(
                event(EventKind.CHARGE, 0.0, 100.0, costPerKwh = 1.0),
                event(EventKind.TRIP, 100.0, 99.98, distanceKm = 0.1)
            )
        )

        val cycle = cycles.single()
        assertEquals(0.0, cycle.dischargePercent, delta)
        assertEquals(0.0, cycle.distanceKm, delta)
    }

    @Test
    fun `two currencies in one cycle give no cost`() {
        val cycles = BatteryCycleLedger.fold(
            listOf(
                event(EventKind.CHARGE, 0.0, 50.0, costPerKwh = 1.0, costCurrency = "BRL"),
                event(EventKind.CHARGE, 50.0, 100.0, costPerKwh = 1.0, costCurrency = "USD"),
                event(EventKind.TRIP, 100.0, 50.0, distanceKm = 200.0)
            )
        )

        val cycle = cycles.single()
        assertTrue(cycle.mixedCurrency)
        assertNull("BRL and USD cannot be added", cycle.cost)
        assertNull(cycle.costCurrency)
    }

    @Test
    fun `the oldest cycle is partial because collection began mid battery`() {
        val cycles = BatteryCycleLedger.fold(
            listOf(
                event(EventKind.CHARGE, 0.0, 100.0, costPerKwh = 1.0),
                event(EventKind.TRIP, 100.0, 0.0, distanceKm = 400.0),
                event(EventKind.CHARGE, 0.0, 100.0, costPerKwh = 1.0),
                event(EventKind.TRIP, 100.0, 50.0, distanceKm = 200.0)
            )
        )

        assertEquals(2, cycles.size)
        assertTrue("the first cycle does not describe a whole battery", cycles[0].isPartial)
        assertFalse(cycles[1].isPartial)
    }

    @Test
    fun `rebuilding the open cycle from its start gives the whole-history answer`() {
        // The property the incremental refresh depends on. A cycle is rebuilt
        // from its own start with the blend it opened with, so the result must
        // equal the fold that never stopped.
        val events = listOf(
            event(EventKind.CHARGE, 0.0, 100.0, costPerKwh = 0.50),
            event(EventKind.TRIP, 100.0, 0.0, distanceKm = 400.0),
            // The second cycle opens here, and is fed by a dearer charge.
            event(EventKind.CHARGE, 0.0, 100.0, costPerKwh = 1.50),
            event(EventKind.TRIP, 100.0, 40.0, distanceKm = 240.0)
        )

        val whole = BatteryCycleLedger.fold(events)
        assertEquals(2, whole.size)
        val closed = whole[0]
        val open = whole[1]

        // Replay only the sessions inside the open cycle, from the blend that
        // cycle recorded when it opened. This is exactly what the repository
        // does on every refresh.
        val rebuilt = BatteryCycleLedger.fold(
            events.subList(2, events.size),
            BatteryCycleLedger.Resume(
                pricedFraction = open.openingPricedFraction,
                blendedPrice = open.openingBlendedPrice,
                isPartial = open.isPartial
            )
        )

        assertEquals(1, rebuilt.size)
        assertEquals(open, rebuilt.single())
        // The closed cycle is never touched by a rebuild.
        assertEquals(100.0, closed.dischargePercent, delta)
        assertEquals(20.0, closed.cost!!, delta)
    }

    @Test
    fun `a rebuild that overruns one hundred percent closes and opens again`() {
        val events = listOf(
            event(EventKind.CHARGE, 0.0, 100.0, costPerKwh = 1.0),
            event(EventKind.TRIP, 100.0, 20.0, distanceKm = 320.0),
            event(EventKind.CHARGE, 20.0, 100.0, costPerKwh = 1.0),
            event(EventKind.TRIP, 100.0, 50.0, distanceKm = 200.0)
        )

        val whole = BatteryCycleLedger.fold(events)
        val rebuilt = BatteryCycleLedger.fold(
            events,
            BatteryCycleLedger.Resume(isPartial = true)
        )

        assertEquals(whole, rebuilt)
        assertEquals(2, rebuilt.size)
        assertFalse(rebuilt[0].isOpen)
        assertTrue(rebuilt[1].isOpen)
    }

    @Test
    fun `a resumed fold does not invent a partial cycle`() {
        val cycles = BatteryCycleLedger.fold(
            listOf(event(EventKind.TRIP, 100.0, 60.0, distanceKm = 160.0)),
            BatteryCycleLedger.Resume(pricedFraction = 1.0, blendedPrice = 1.0)
        )

        assertFalse(
            "only a fold from the beginning of the record knows this",
            cycles.single().isPartial
        )
    }

    @Test
    fun `a trip larger than one cycle leaves no SOC unattributed`() {
        // Not physically reachable on this car, but the split must be a loop.
        // Two full cycles plus a remainder, from one 250 % discharge.
        val cycles = BatteryCycleLedger.fold(
            listOf(
                event(EventKind.TRIP, 250.0, 0.0, distanceKm = 500.0)
            )
        )

        assertEquals(3, cycles.size)
        assertEquals(100.0, cycles[0].dischargePercent, delta)
        assertEquals(100.0, cycles[1].dischargePercent, delta)
        assertEquals(50.0, cycles[2].dischargePercent, delta)
        assertEquals(
            "the parts must sum to the whole",
            500.0,
            cycles.sumOf { it.distanceKm },
            delta
        )
    }
    @Test
    fun `a cycle records the sessions it counted, and a split trip joins both`() {
        val cycles = BatteryCycleLedger.fold(
            listOf(
                event(EventKind.CHARGE, 0.0, 100.0, costPerKwh = 1.0, sessionId = "c1"),
                event(EventKind.TRIP, 100.0, 10.0, distanceKm = 360.0, sessionId = "t1"),
                event(EventKind.CHARGE, 10.0, 100.0, costPerKwh = 1.0, sessionId = "c2"),
                event(EventKind.PARKED, 100.0, 98.0, sessionId = "p1"),
                // 20 % of SOC: 10 % closes the first cycle and 10 % opens the
                // next. The parked 2 % does not move the boundary, so it does
                // not move the split either.
                event(EventKind.TRIP, 98.0, 78.0, distanceKm = 80.0, sessionId = "t2")
            )
        )

        assertEquals(2, cycles.size)
        assertEquals(
            listOf("c1", "t1", "c2", "p1", "t2"),
            cycles[0].members.map { it.sessionId }
        )
        assertEquals(listOf("t2"), cycles[1].members.map { it.sessionId })

        // The split trip is in both, and its two shares are the whole trip. A
        // reader that adds them must get one trip, not two.
        val shares = cycles.flatMap { it.members }.filter { it.sessionId == "t2" }
        assertEquals(2, shares.size)
        assertEquals(0.5, shares[0].share, delta)
        assertEquals(0.5, shares[1].share, delta)
        assertEquals(1.0, shares.sumOf { it.share }, delta)

        // Everything that is not a split trip is whole, wherever it sits.
        assertTrue(
            cycles[0].members.filter { it.sessionId != "t2" }.all { it.share == 1.0 }
        )
    }

    @Test
    fun `an interval below the noise floor is not a member of anything`() {
        val cycles = BatteryCycleLedger.fold(
            listOf(
                event(EventKind.CHARGE, 50.0, 50.02, sessionId = "noise-charge"),
                event(EventKind.PARKED, 50.0, 49.99, sessionId = "noise-parked"),
                event(EventKind.TRIP, 50.0, 49.98, sessionId = "noise-trip"),
                event(EventKind.TRIP, 50.0, 40.0, distanceKm = 40.0, sessionId = "real")
            )
        )

        // The fold counted none of the three, so listing them beside the real
        // one would show sessions that moved nothing.
        assertEquals(listOf("real"), cycles.single().members.map { it.sessionId })
    }

    @Test
    fun `an interval with no trustworthy capacity is still a member of its cycle`() {
        val cycles = BatteryCycleLedger.fold(
            listOf(
                event(
                    EventKind.TRIP,
                    80.0,
                    60.0,
                    capacityWh = null,
                    distanceKm = 60.0,
                    sessionId = "t-unknown"
                )
            )
        )

        val cycle = cycles.single()
        // Its energy is unknown, which the cycle already says. The drive still
        // happened, and it is what the 20 % on the bar is made of.
        assertTrue(cycle.energyIncomplete)
        assertEquals(listOf("t-unknown"), cycle.members.map { it.sessionId })
    }

    @Test
    fun `a member carries the window of the session it names`() {
        val trip = event(EventKind.TRIP, 90.0, 80.0, distanceKm = 40.0, sessionId = "t")
        val cycle = BatteryCycleLedger.fold(listOf(trip)).single()

        // Copied, not looked up: retention deletes the session and the cycle
        // outlives it, so this is all a reader will have left to place it in
        // time.
        val member = cycle.members.single()
        assertEquals(trip.startUtcMillis, member.startUtcMillis)
        assertEquals(trip.endUtcMillis, member.endUtcMillis)
        assertEquals(EventKind.TRIP, member.kind)
    }
}
