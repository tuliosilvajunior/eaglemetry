package com.timhss.capyenergy.telemetry

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TripEnergyDtoTest {
    @Test
    fun `measured DTO maps the integral and derives short-trip efficiency`() {
        val result = measuredTripEnergyMap(
            integral = TripPowerIntegral(
                packWh = 394.0,
                tractionWh = 500.0,
                regeneratedWh = 125.0,
                auxiliaryWh = 19.0,
                integratedSeconds = 60.0
            ),
            agreesWithSoc = true,
            distanceKm = 0.4
        )

        assertEquals(394.0, result["measuredPackWh"] as Double, 0.0)
        assertEquals(500.0, result["measuredTractionWh"] as Double, 0.0)
        assertEquals(125.0, result["measuredRegeneratedWh"] as Double, 0.0)
        assertEquals(19.0, result["measuredAuxiliaryWh"] as Double, 0.0)
        assertEquals(60.0, result["measuredSeconds"] as Double, 0.0)
        assertEquals(true, result["measuredAgreesWithSoc"])
        assertEquals(985.0, result["measuredWhPerKm"] as Double, 0.0)
        assertEquals(0.25, result["measuredRegenerationRatio"] as Double, 0.0)
    }

    @Test
    fun `measured DTO keeps unavailable and disagreement states distinct`() {
        val unavailable = measuredTripEnergyMap(null, null, 5.0)
        assertNull(unavailable["measuredPackWh"])
        assertNull(unavailable["measuredAgreesWithSoc"])
        assertNull(unavailable["measuredWhPerKm"])

        val disagreement = measuredTripEnergyMap(
            integral = TripPowerIntegral(-100.0, 10.0, 20.0, -90.0, 30.0),
            agreesWithSoc = false,
            distanceKm = 0.009
        )
        assertEquals(false, disagreement["measuredAgreesWithSoc"])
        assertNull(disagreement["measuredWhPerKm"])
    }

    @Test
    fun `trip cost prices the integral with the preceding charge rate`() {
        val result = tripCostEstimateMap(
            costPerKwh = 0.92,
            currency = "BRL",
            netEnergyKwh = 0.394,
            measuredAgreesWithSoc = true
        )

        assertEquals(0.92, result["lastChargeCostPerKwh"] as Double, 0.0)
        assertEquals("BRL", result["lastChargeCostCurrency"])
        assertEquals(0.36248, result["estimatedTripCost"] as Double, 0.000001)
    }

    @Test
    fun `an unconfirmed sign still prices, a contradicted one does not`() {
        // SOC did not move far enough to state a direction. A short trip is not
        // a wrong trip, so it is still priced.
        val unconfirmed = tripCostEstimateMap(
            costPerKwh = 1.0,
            currency = "BRL",
            netEnergyKwh = 0.40,
            measuredAgreesWithSoc = null
        )
        // SOC says the pack fell and the integral says it rose. There is no
        // second energy to fall back on, so the cost is withheld.
        val disagreement = tripCostEstimateMap(
            costPerKwh = 1.0,
            currency = "BRL",
            netEnergyKwh = 0.40,
            measuredAgreesWithSoc = false
        )

        assertEquals(0.40, unconfirmed["estimatedTripCost"] as Double, 0.0)
        assertNull(disagreement["estimatedTripCost"])
    }
}
