package com.timhss.capyenergy.vehicle

import android.car.VehicleAreaSeat
import android.car.VehiclePropertyIds
import android.util.Log
import kotlin.math.roundToInt

interface HvacPropertyAccess {
    fun readIntProperty(propertyId: Int, areaId: Int): Int?
    fun readFloatProperty(propertyId: Int, areaId: Int): Float?
    fun setIntProperty(propertyId: Int, areaId: Int, value: Int): Boolean
    fun setFloatProperty(propertyId: Int, areaId: Int, value: Float): Boolean
}

class HvacClimateController(
    private val vehiclePropertyHelper: HvacPropertyAccess
) {
    fun statusMap(): Map<String, Any?> {
        val temp = vehiclePropertyHelper.readFloatProperty(TEMPERATURE_PROPERTY_ID, TEMPERATURE_AREA_ID)
        val fan = vehiclePropertyHelper.readIntProperty(FAN_SPEED_PROPERTY_ID, FAN_SPEED_AREA_ID)
        return resultMap(
            ok = temp != null || fan != null,
            action = "status",
            currentValue = null,
            requestedValue = null,
            appliedValue = null,
            propertyId = null,
            areaId = null,
            details = listOf(
                "temperature=${temp ?: "--"} area=$TEMPERATURE_AREA_ID property=${TEMPERATURE_PROPERTY_ID.toHexPropertyId()}",
                "fanSpeed=${fan ?: "--"} area=$FAN_SPEED_AREA_ID property=${FAN_SPEED_PROPERTY_ID.toHexPropertyId()}"
            )
        ) + mapOf(
            "temperatureC" to temp,
            "fanSpeed" to fan,
            "temperatureAreaId" to TEMPERATURE_AREA_ID,
            "fanSpeedAreaId" to FAN_SPEED_AREA_ID,
            "temperaturePropertyId" to TEMPERATURE_PROPERTY_ID,
            "temperaturePropertyIdHex" to TEMPERATURE_PROPERTY_ID.toHexPropertyId(),
            "fanSpeedPropertyId" to FAN_SPEED_PROPERTY_ID,
            "fanSpeedPropertyIdHex" to FAN_SPEED_PROPERTY_ID.toHexPropertyId()
        )
    }

    fun stepTemperature(deltaC: Float): Map<String, Any?> {
        val current = vehiclePropertyHelper.readFloatProperty(TEMPERATURE_PROPERTY_ID, TEMPERATURE_AREA_ID)
            ?: return resultMap(
                ok = false,
                action = "stepTemperature",
                currentValue = null,
                requestedValue = deltaC,
                appliedValue = null,
                propertyId = TEMPERATURE_PROPERTY_ID,
                areaId = TEMPERATURE_AREA_ID,
                details = listOf("Current HVAC_TEMPERATURE_SET is unreadable")
            )
        return setTemperature(current + deltaC, currentValue = current, action = "stepTemperature")
    }

    fun setTemperature(tempC: Float): Map<String, Any?> =
        setTemperature(tempC, currentValue = null, action = "setTemperature")

    fun increaseTemperature(): Map<String, Any?> = stepTemperature(TEMPERATURE_UP_STEP_C)

    fun decreaseTemperature(): Map<String, Any?> = stepTemperature(-TEMPERATURE_DOWN_STEP_C)

    fun stepFanSpeed(delta: Int): Map<String, Any?> {
        val current = vehiclePropertyHelper.readIntProperty(FAN_SPEED_PROPERTY_ID, FAN_SPEED_AREA_ID)
            ?: return resultMap(
                ok = false,
                action = "stepFanSpeed",
                currentValue = null,
                requestedValue = delta,
                appliedValue = null,
                propertyId = FAN_SPEED_PROPERTY_ID,
                areaId = FAN_SPEED_AREA_ID,
                details = listOf("Current HVAC_FAN_SPEED is unreadable")
            )
        return setFanSpeed(current + delta, currentValue = current, action = "stepFanSpeed")
    }

    fun setFanSpeed(speed: Int): Map<String, Any?> =
        setFanSpeed(speed, currentValue = null, action = "setFanSpeed")

    private fun setTemperature(
        tempC: Float,
        currentValue: Float?,
        action: String
    ): Map<String, Any?> {
        val target = tempC.coerceIn(MIN_TEMP_C, MAX_TEMP_C).roundToHalf()
        val written = vehiclePropertyHelper.setFloatProperty(TEMPERATURE_PROPERTY_ID, TEMPERATURE_AREA_ID, target)
        if (!written) Log.w(TAG, "Temperature write failed target=$target")
        return resultMap(
            ok = written,
            action = action,
            currentValue = currentValue,
            requestedValue = tempC,
            appliedValue = target,
            propertyId = TEMPERATURE_PROPERTY_ID,
            areaId = TEMPERATURE_AREA_ID,
            details = listOf("set HVAC_TEMPERATURE_SET=$target -> $written")
        )
    }

    private fun setFanSpeed(
        speed: Int,
        currentValue: Int?,
        action: String
    ): Map<String, Any?> {
        val target = speed.coerceIn(MIN_FAN_SPEED, MAX_FAN_SPEED)
        val written = vehiclePropertyHelper.setIntProperty(FAN_SPEED_PROPERTY_ID, FAN_SPEED_AREA_ID, target)
        if (!written) Log.w(TAG, "Fan speed write failed target=$target")
        return resultMap(
            ok = written,
            action = action,
            currentValue = currentValue,
            requestedValue = speed,
            appliedValue = target,
            propertyId = FAN_SPEED_PROPERTY_ID,
            areaId = FAN_SPEED_AREA_ID,
            details = listOf("set HVAC_FAN_SPEED=$target -> $written")
        )
    }

    private fun resultMap(
        ok: Boolean,
        action: String,
        currentValue: Number?,
        requestedValue: Number?,
        appliedValue: Number?,
        propertyId: Int?,
        areaId: Int?,
        details: List<String>
    ): Map<String, Any?> = mapOf(
        "ok" to ok,
        "action" to action,
        "currentValue" to currentValue,
        "requestedValue" to requestedValue,
        "appliedValue" to appliedValue,
        "propertyId" to propertyId,
        "propertyIdHex" to propertyId?.toHexPropertyId(),
        "areaId" to areaId,
        "details" to details,
        "timestampMillis" to System.currentTimeMillis()
    )

    private fun Float.roundToHalf(): Float = (this * 2f).roundToInt().toFloat() / 2f

    companion object {
        private const val TAG = "HvacClimateController"
        private const val MIN_TEMP_C = 15.5f
        private const val MAX_TEMP_C = 33f
        private const val TEMPERATURE_UP_STEP_C = 1f
        private const val TEMPERATURE_DOWN_STEP_C = 0.5f
        private const val MIN_FAN_SPEED = 1
        private const val MAX_FAN_SPEED = 9
        private const val TEMPERATURE_AREA_ID = VehicleAreaSeat.SEAT_ROW_1_LEFT
        private const val FAN_SPEED_AREA_ID = 5
        private const val TEMPERATURE_PROPERTY_ID = VehiclePropertyIds.HVAC_TEMPERATURE_SET
        private const val FAN_SPEED_PROPERTY_ID = VehiclePropertyIds.HVAC_FAN_SPEED
    }
}

private fun Int.toHexPropertyId(): String = "0x" + toUInt().toString(16).padStart(8, '0')
