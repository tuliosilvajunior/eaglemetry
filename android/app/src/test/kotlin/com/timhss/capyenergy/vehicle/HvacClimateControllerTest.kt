package com.timhss.capyenergy.vehicle

import android.car.VehiclePropertyIds
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HvacClimateControllerTest {
    @Test
    fun temperatureIncreaseButtonUsesWholeDegreeStep() {
        val properties = FakeHvacPropertyAccess(
            floats = mutableMapOf((VehiclePropertyIds.HVAC_TEMPERATURE_SET to 1) to 17f)
        )
        val result = HvacClimateController(properties).increaseTemperature()

        assertEquals(18f, result["appliedValue"])
        assertEquals(
            listOf(PropertyWrite.FloatValue(VehiclePropertyIds.HVAC_TEMPERATURE_SET, 1, 18f)),
            properties.writes
        )
    }

    @Test
    fun temperatureButtonUsesHalfDegreeStepWithoutChangingClimateState() {
        val properties = FakeHvacPropertyAccess(
            floats = mutableMapOf((VehiclePropertyIds.HVAC_TEMPERATURE_SET to 1) to 18f)
        )
        val result = HvacClimateController(properties).decreaseTemperature()

        assertEquals(17.5f, result["appliedValue"])
        assertEquals(
            listOf(PropertyWrite.FloatValue(VehiclePropertyIds.HVAC_TEMPERATURE_SET, 1, 17.5f)),
            properties.writes
        )
    }

    @Test
    fun fanButtonChangesOnlyFanSpeed() {
        val properties = FakeHvacPropertyAccess(
            ints = mutableMapOf((VehiclePropertyIds.HVAC_FAN_SPEED to 5) to 3)
        )
        val result = HvacClimateController(properties).stepFanSpeed(1)

        assertTrue(result["ok"] as Boolean)
        assertEquals(
            listOf(PropertyWrite.IntValue(VehiclePropertyIds.HVAC_FAN_SPEED, 5, 4)),
            properties.writes
        )
    }

    @Test
    fun temperatureSetpointIsLimitedToVehicleRange() {
        val properties = FakeHvacPropertyAccess()
        val controller = HvacClimateController(properties)

        assertEquals(15.5f, controller.setTemperature(10f)["appliedValue"])
        assertEquals(33f, controller.setTemperature(35f)["appliedValue"])
    }
}

private sealed interface PropertyWrite {
    data class IntValue(val propertyId: Int, val areaId: Int, val value: Int) : PropertyWrite
    data class FloatValue(val propertyId: Int, val areaId: Int, val value: Float) : PropertyWrite
}

private class FakeHvacPropertyAccess(
    private val ints: MutableMap<Pair<Int, Int>, Int> = mutableMapOf(),
    private val floats: MutableMap<Pair<Int, Int>, Float> = mutableMapOf()
) : HvacPropertyAccess {
    val writes = mutableListOf<PropertyWrite>()

    override fun readIntProperty(propertyId: Int, areaId: Int): Int? = ints[propertyId to areaId]

    override fun readFloatProperty(propertyId: Int, areaId: Int): Float? =
        floats[propertyId to areaId]

    override fun setIntProperty(propertyId: Int, areaId: Int, value: Int): Boolean {
        writes += PropertyWrite.IntValue(propertyId, areaId, value)
        ints[propertyId to areaId] = value
        return true
    }

    override fun setFloatProperty(propertyId: Int, areaId: Int, value: Float): Boolean {
        writes += PropertyWrite.FloatValue(propertyId, areaId, value)
        floats[propertyId to areaId] = value
        return true
    }
}
