package com.timhss.capyenergy.vehicle

import com.timhss.capyenergy.profile.GeelyProfile

import com.timhss.capyenergy.profile.GeelyProperties
import android.car.Car
import android.car.hardware.property.CarPropertyManager
import android.content.Context
import android.util.Log
import kotlin.math.abs

/**
 * @param packCapacityWhProvider the pack capacity in Wh, from Settings. Only
 *   the state-of-charge fallback needs it, and it must not be read from the
 *   car; see [GeelyProfile.battery].
 */
class VehiclePropertyHelper(
    context: Context,
    private val packCapacityWhProvider: () -> Double = { GeelyProfile.battery.defaultCapacityWh }
) :
    HvacPropertyAccess, VehiclePropertyAccess {
    private val appContext = context.applicationContext
    private var car: Car? = null
    private var cachedPropertyManager: CarPropertyManager? = null

    /**
     * The snapshot carries no pack capacity, and must not carry one again.
     *
     * The car publishes no capacity that can be believed, so the app does not
     * read one. Capacity comes from Settings through
     * `TelemetryGraph.resolveCapacityWh`; see [GeelyProfile.battery].
     */
    fun readTelemetrySnapshot(): TelemetrySnapshot {
        return TelemetrySnapshot(
            timestampMillis = System.currentTimeMillis(),
            batteryPercent = readBatteryPercent(),
            speedKmh = readVehicleSpeed(),
            odometerKm = readOdometer(),
            charging = readCharging(),
            gear = readGear()
        )
    }

    fun disconnect() {
        try {
            car?.disconnect()
        } catch (e: Exception) {
            Log.w(TAG, "Error disconnecting car service", e)
        } finally {
            cachedPropertyManager = null
            car = null
        }
    }

    override fun readIntProperty(propertyId: Int, areaId: Int): Int? {
        val pm = propertyManager() ?: return null
        return runCatching { pm.getIntProperty(propertyId, areaId) }
            .recoverCatching { pm.getFloatProperty(propertyId, areaId).toInt() }
            .onFailure { Log.w(TAG, "Failed to read int property ${propertyId.toHexPropertyId()} area $areaId", it) }
            .getOrNull()
    }

    fun readVin(): String? {
        val pm = propertyManager() ?: return null
        return runCatching {
            pm.getProperty<String>(GeelyProperties.VehicleIdentifier.propertyId, GeelyProperties.VehicleIdentifier.areaId)?.value
        }.recoverCatching {
            val method = pm.javaClass.getMethod("getStringProperty", Integer.TYPE, Integer.TYPE)
            method.invoke(pm, GeelyProperties.VehicleIdentifier.propertyId, GeelyProperties.VehicleIdentifier.areaId) as? String
        }.recoverCatching {
            val getPropMethod = pm.javaClass.getMethod("getProperty", Class::class.java, Integer.TYPE, Integer.TYPE)
            val carProp = getPropMethod.invoke(pm, String::class.java, GeelyProperties.VehicleIdentifier.propertyId, GeelyProperties.VehicleIdentifier.areaId)
            carProp?.javaClass?.getMethod("getValue")?.invoke(carProp) as? String
        }.onFailure {
            Log.w(TAG, "Failed to read VIN property ${GeelyProperties.VehicleIdentifier.propertyId.toHexPropertyId()}", it)
        }.getOrNull()?.trim()?.takeIf { it.isNotBlank() }
    }

    override fun readFloatProperty(propertyId: Int, areaId: Int): Float? {
        val pm = propertyManager() ?: return null
        return runCatching { pm.getFloatProperty(propertyId, areaId) }
            .recoverCatching { pm.getIntProperty(propertyId, areaId).toFloat() }
            .onFailure { Log.w(TAG, "Failed to read float property ${propertyId.toHexPropertyId()} area $areaId", it) }
            .getOrNull()
    }

    override fun setIntProperty(propertyId: Int, areaId: Int, value: Int): Boolean {
        val pm = propertyManager() ?: return false
        return runCatching {
            Log.i(TAG, "Setting int property ${propertyId.toHexPropertyId()} area $areaId to $value")
            pm.setIntProperty(propertyId, areaId, value)
            true
        }.onFailure {
            Log.w(TAG, "Failed to set int property ${propertyId.toHexPropertyId()} area $areaId to $value", it)
        }.getOrDefault(false)
    }

    fun setBoolProperty(propertyId: Int, areaId: Int, value: Boolean): Boolean {
        val pm = propertyManager() ?: return false
        return runCatching {
            Log.i(TAG, "Setting bool property ${propertyId.toHexPropertyId()} area $areaId to $value")
            pm.setBooleanProperty(propertyId, areaId, value)
            true
        }.onFailure {
            Log.w(TAG, "Failed to set bool property ${propertyId.toHexPropertyId()} area $areaId to $value", it)
        }.getOrDefault(false)
    }

    override fun setFloatProperty(propertyId: Int, areaId: Int, value: Float): Boolean {
        val pm = propertyManager() ?: return false
        return runCatching {
            Log.i(TAG, "Setting float property ${propertyId.toHexPropertyId()} area $areaId to $value")
            pm.setFloatProperty(propertyId, areaId, value)
            true
        }.onFailure {
            Log.w(TAG, "Failed to set float property ${propertyId.toHexPropertyId()} area $areaId to $value", it)
        }.getOrDefault(false)
    }

    private fun propertyManager(): CarPropertyManager? {
        cachedPropertyManager?.let { return it }
        return try {
            val connectedCar = car ?: Car.createCar(appContext).also { car = it }
            (connectedCar.getCarManager(Car.PROPERTY_SERVICE) as? CarPropertyManager).also {
                cachedPropertyManager = it
                if (it == null) Log.w(TAG, "CarPropertyManager unavailable")
            }
        } catch (e: Throwable) {
            Log.w(TAG, "Failed to connect to CarPropertyManager", e)
            null
        }
    }

    private fun readBatteryPercent(): NumericReading {
        val pm = propertyManager()
            ?: return unavailableReading("battery SOC", "CarPropertyManager unavailable")

        val oem = readFloatish(pm, "ED_EV_BATTERY_PERCENTAGE", GeelyProperties.EdEvBatteryPercentage.propertyId)
        val level = readFloatish(pm, "EV_BATTERY_LEVEL", GeelyProperties.EvBatteryLevel.propertyId)
        val decoded = decodeBatteryPercent(
            oemPercent = oem.valueIfOk()?.let { if (it > 100f) it / 10f else it },
            batteryLevel = level.valueIfOk(),
            packCapacityWh = packCapacityWhProvider().toFloat()
        )
        val details = listOf(oem, level).joinToString("\n") { it.line() }
        return if (decoded != null) {
            NumericReading(
                ok = true,
                value = decoded,
                source = if (oem.ok) "ED_EV_BATTERY_PERCENTAGE 0x2140a6ed" else "EV battery fallback",
                details = "$details\nbatteryPercent=$decoded"
            )
        } else {
            NumericReading(false, null, "battery SOC unreadable", details)
        }
    }

    private fun readVehicleSpeed(): NumericReading {
        val pm = propertyManager()
            ?: return unavailableReading("vehicle speed", "CarPropertyManager unavailable")
        val probe = readFloatish(pm, "PERF_VEHICLE_SPEED", GeelyProperties.VehicleSpeedPerf.propertyId)
        val decoded = probe.valueIfOk()?.let { decodeVehicleSpeed(it) }
        return if (decoded != null) {
            NumericReading(true, decoded, "PERF_VEHICLE_SPEED 0x11600207", "${probe.line()}\nspeedKmh=$decoded")
        } else {
            NumericReading(false, null, "vehicle speed unreadable", probe.line())
        }
    }

    private fun readOdometer(): NumericReading {
        val pm = propertyManager()
            ?: return unavailableReading("odometer", "CarPropertyManager unavailable")
        val probe = readFloatish(pm, "PERF_ODOMETER", GeelyProperties.PerfOdometer.propertyId)
        val value = probe.valueIfOk()?.takeIf { it.isFinite() && it >= 0f }
        return if (value != null) {
            NumericReading(true, value, "PERF_ODOMETER 0x11600204", "${probe.line()}\nodometerKm=$value")
        } else {
            NumericReading(false, null, "odometer unreadable", probe.line())
        }
    }

    private fun readGear(): NumericReading {
        val pm = propertyManager()
            ?: return unavailableReading("gear", "CarPropertyManager unavailable")
        val probes = listOf(
            readIntish(pm, "CURRENT_GEAR area=-1", GeelyProperties.CurrentGear.propertyId, GeelyProperties.CurrentGear.areaId),
            readIntish(pm, "CURRENT_GEAR area=0", GeelyProperties.CurrentGearArea0.propertyId, GeelyProperties.CurrentGearArea0.areaId),
            readIntish(pm, "GEAR_SELECTION area=-1", GeelyProperties.GearSelection.propertyId, GeelyProperties.GearSelection.areaId),
            readIntish(pm, "GEAR_SELECTION area=0", GeelyProperties.GearSelectionArea0.propertyId, GeelyProperties.GearSelectionArea0.areaId)
        )
        val selected = probes.firstOrNull { it.ok && isKnownGear(it.value) }
            ?: probes.firstOrNull { it.ok && it.value != 0 }
            ?: probes.firstOrNull { it.ok }
        val details = buildString {
            probes.forEach { appendLine(it.line()) }
            append("gearLabel=${gearLabel(selected?.value)}")
        }
        return if (selected != null) {
            NumericReading(true, selected.value?.toFloat(), "${selected.name} ${selected.propertyId.toHexPropertyId()}", details)
        } else {
            NumericReading(false, null, "gear unreadable", details)
        }
    }

    private fun isKnownGear(value: Int?): Boolean =
        value != null &&
            ((value and GeelyProperties.GEAR_DRIVE) != 0 ||
                (value and GeelyProperties.GEAR_PARK) != 0 ||
                (value and GeelyProperties.GEAR_REVERSE) != 0 ||
                (value and GeelyProperties.GEAR_NEUTRAL) != 0)

    private fun gearLabel(value: Int?): String = when {
        value == null -> "?"
        (value and GeelyProperties.GEAR_DRIVE) != 0 -> "D"
        (value and GeelyProperties.GEAR_PARK) != 0 -> "P"
        (value and GeelyProperties.GEAR_REVERSE) != 0 -> "R"
        (value and GeelyProperties.GEAR_NEUTRAL) != 0 -> "N"
        else -> "?"
    }

    private fun readCharging(): ChargingReading {
        val pm = propertyManager()
            ?: return ChargingReading(
                ok = false,
                isCharging = null,
                stateRaw = null,
                stateLabel = null,
                plugRaw = null,
                plugLabel = null,
                acPowerKw = null,
                dcPowerKw = null,
                currentA = null,
                voltageV = null,
                estimatedTimeMinutes = null,
                workTimeMinutes = null,
                source = "CarPropertyManager unavailable",
                details = "CarPropertyManager unavailable"
            )

        val directState = readIntish(pm, "CHARGING_DISCHARGING_STATE direct", GeelyProperties.ChargingDischargingState.propertyId)
        val state = readWrappedIntishProbe(pm, "CHARGING_DISCHARGING_STATE", GeelyProperties.ChargingDischargingStateLogical, adaptValue = true)
            .takeIf { it.ok } ?: directState
        val directPlug = readIntish(pm, "CHARGING_PLUG_STATE direct", GeelyProperties.ChargingPlugState.propertyId)
        val plug = readWrappedIntishProbe(pm, "CHARGING_PLUG_STATE", GeelyProperties.ChargingPlugStateLogical, adaptValue = true)
            .takeIf { it.ok } ?: directPlug
        val acPower = readFloatish(pm, "BATTERY_CHARGING_CURRENT_POWER", GeelyProperties.BatteryChargingCurrentPower.propertyId)
        val dcPower = readFloatish(pm, "DC_CHARGING_POWER", GeelyProperties.DcChargingPower.propertyId)
        val current = readFloatish(pm, "CHARGING_WORK_CURRENT", GeelyProperties.ChargingWorkCurrent.propertyId)
        val voltage = readFloatish(pm, "CHARGING_WORK_VOLTAGE", GeelyProperties.ChargingWorkVoltage.propertyId)
        val estimatedTime = readFloatish(pm, "CHARGING_ESTIMATED_TIME", GeelyProperties.ChargingEstimatedTime.propertyId)
        val workTime = readFloatish(pm, "CHARGING_WORK_TIME", GeelyProperties.ChargingWorkTime.propertyId)

        val stateRaw = state.valueIfOk()
        val plugRaw = plug.valueIfOk()
        val acPowerKw = ChargeSidePower.acPowerKw(stateRaw, acPower.valueIfOk())
        val dcPowerKw = ChargeSidePower.dcPowerKw(stateRaw, dcPower.valueIfOk())
        val currentA = current.valueIfOk()
        val voltageV = voltage.valueIfOk()
        val derivedPowerKw = derivedChargePowerKw(currentA, voltageV)
        val plugged = plugRaw == GeelyProperties.ChargePlugStateAcConnected ||
            plugRaw == GeelyProperties.ChargePlugStateDcConnected ||
            plugRaw == GeelyProperties.ChargePlugStateIntegrationConnected
        val hasElectricalActivity = acPowerKw != null || dcPowerKw != null || derivedPowerKw != null
        val isCharging = stateRaw?.let {
            it == GeelyProperties.ChargeStateAcCharging || it == GeelyProperties.ChargeStateDcCharging
        } ?: hasElectricalActivity.takeIf { it && (plugRaw == null || plugged) }
        val details = buildString {
            appendLine(state.line())
            if (state.propertyId != directState.propertyId) appendLine(directState.line())
            appendLine(plug.line())
            if (plug.propertyId != directPlug.propertyId) appendLine(directPlug.line())
            appendLine(acPower.line())
            appendLine(dcPower.line())
            appendLine(current.line())
            appendLine(voltage.line())
            appendLine(estimatedTime.line())
            appendLine(workTime.line())
            append("derivedPowerKw=${derivedPowerKw?.let { String.format(java.util.Locale.US, "%.2f", it) }}")
        }

        return ChargingReading(
            ok = state.ok || plug.ok || acPower.ok || dcPower.ok || current.ok || voltage.ok || estimatedTime.ok || workTime.ok,
            isCharging = isCharging,
            stateRaw = stateRaw,
            stateLabel = stateRaw?.let(::chargingStateLabel),
            plugRaw = plugRaw,
            plugLabel = plugRaw?.let(::chargingPlugLabel),
            acPowerKw = acPowerKw ?: derivedPowerKw?.takeIf { stateRaw != GeelyProperties.ChargeStateDcCharging },
            dcPowerKw = dcPowerKw ?: derivedPowerKw?.takeIf { stateRaw == GeelyProperties.ChargeStateDcCharging },
            currentA = currentA,
            voltageV = voltageV,
            estimatedTimeMinutes = estimatedTime.valueIfOk(),
            workTimeMinutes = workTime.valueIfOk(),
            source = if (state.ok) "CHARGING_DISCHARGING_STATE wrapped 0x2140737e" else "charging fallback",
            details = "$details\nisCharging=$isCharging state=${stateRaw?.let(::chargingStateLabel)} plug=${plugRaw?.let(::chargingPlugLabel)}"
        )
    }

    private fun unavailableReading(source: String, details: String): NumericReading {
        return NumericReading(ok = false, value = null, source = source, details = details)
    }

    private fun readFloatish(pm: CarPropertyManager, name: String, propertyId: Int): Probe<Float> {
        return try {
            Probe(name, propertyId, true, pm.getFloatProperty(propertyId, 0), "float", null)
        } catch (floatError: Throwable) {
            try {
                Probe(name, propertyId, true, pm.getIntProperty(propertyId, 0).toFloat(), "int", null)
            } catch (intError: Throwable) {
                Probe(name, propertyId, false, null, "", "${shortError(floatError)}; ${shortError(intError)}")
            }
        }
    }

    private fun readIntish(pm: CarPropertyManager, name: String, propertyId: Int, areaId: Int = 0): Probe<Int> {
        return try {
            Probe(name, propertyId, true, pm.getIntProperty(propertyId, areaId), "int", null)
        } catch (intError: Throwable) {
            try {
                Probe(name, propertyId, true, pm.getFloatProperty(propertyId, areaId).toInt(), "float", null)
            } catch (floatError: Throwable) {
                Probe(name, propertyId, false, null, "", "${shortError(intError)}; ${shortError(floatError)}")
            }
        }
    }

    private data class WrappedPropertyRef(
        val logicalId: Int,
        val idType: Int,
        val propertyId: Int,
        val propertyIdObject: Any,
        val propertyIdInterface: Class<*>
    )

    private fun resolveWrappedProperty(idType: Int, adaptId: Int): WrappedPropertyRef? {
        return try {
            val ecarxCar = Class.forName("com.ecarx.xui.adaptapi.car.Car")
            val wrapper = ecarxCar
                .getMethod("createWrapper", Context::class.java)
                .invoke(null, appContext)
                ?: run {
                    Log.w(TAG, "ECARX wrapper unavailable for adapt ${adaptId.toHexPropertyId()}")
                    return null
                }

            val iWrapper = Class.forName("com.ecarx.xui.adaptapi.car.IWrapper")
            val propertyIdObject = iWrapper
                .getMethod("getWrappedPropertyId", Integer.TYPE, Integer.TYPE)
                .invoke(wrapper, idType, adaptId)
                ?: run {
                    Log.w(TAG, "ECARX wrapper returned null for adapt ${adaptId.toHexPropertyId()} idType=$idType")
                    return null
                }

            val iPropertyId = Class.forName("com.ecarx.xui.adaptapi.car.IWrapper\$IPropertyId")
            val propertyId = iPropertyId.getMethod("getPropertyId").invoke(propertyIdObject) as? Int
            if (propertyId == null || propertyId == 0) {
                Log.w(TAG, "ECARX wrapper returned invalid propertyId=$propertyId for adapt ${adaptId.toHexPropertyId()} idType=$idType")
                null
            } else {
                Log.i(TAG, "ECARX wrapper resolved adapt ${adaptId.toHexPropertyId()} idType=$idType to ${propertyId.toHexPropertyId()}")
                WrappedPropertyRef(
                    logicalId = adaptId,
                    idType = idType,
                    propertyId = propertyId,
                    propertyIdObject = propertyIdObject,
                    propertyIdInterface = iPropertyId
                )
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to resolve ECARX wrapped property for adapt ${adaptId.toHexPropertyId()} idType=$idType", e)
            null
        }
    }

    private fun readWrappedIntishProbe(
        pm: CarPropertyManager,
        name: String,
        logicalId: Int,
        adaptValue: Boolean,
        idType: Int = ECARX_ID_TYPE_FUNCTION
    ): Probe<Int> {
        val wrapped = resolveWrappedProperty(idType, logicalId)
            ?: return Probe(name, logicalId, false, null, "", "ECARX wrapper unavailable")
        val direct = readIntish(pm, "$name wrapped", wrapped.propertyId)
        if (!direct.ok || !adaptValue) {
            return direct.copy(
                name = name,
                error = direct.error?.let { "wrapped=${wrapped.propertyId.toHexPropertyId()}: $it" }
            )
        }
        return try {
            val adapted = wrapped.propertyIdInterface
                .getMethod("getPropertyAdaptValue", Integer.TYPE)
                .invoke(wrapped.propertyIdObject, direct.value) as? Int
            if (adapted == null) {
                direct.copy(name = name, error = "wrapped=${wrapped.propertyId.toHexPropertyId()}: null adapted value")
            } else {
                direct.copy(name = name, value = adapted, type = "${direct.type}+adapt")
            }
        } catch (e: Exception) {
            direct.copy(name = name, error = "wrapped=${wrapped.propertyId.toHexPropertyId()}: adapt failed ${shortError(e)}")
        }
    }

    private fun decodeVehicleSpeed(rawKmh: Float): Float {
        val normalized = abs(rawKmh).coerceIn(0f, 140f)
        return if (normalized >= 10f) (normalized + 1f).coerceIn(0f, 140f) else normalized
    }

    private fun derivedChargePowerKw(currentA: Float?, voltageV: Float?): Float? {
        val current = currentA?.takeIf { it.isFinite() } ?: return null
        val voltage = voltageV?.takeIf { it.isFinite() && it > 0f } ?: return null
        val powerKw = abs(current) * voltage / 1_000f
        return powerKw.takeIf { it.isFinite() && it > MIN_CHARGE_POWER_KW }
    }

    private fun chargingStateLabel(value: Int): String {
        return when (value) {
            GeelyProperties.ChargeStateNoCharging -> "No charging"
            GeelyProperties.ChargeStateAcCharging -> "AC charging"
            GeelyProperties.ChargeStateChargingEnd -> "Charging end"
            GeelyProperties.ChargeStateChargingComplete -> "Charging complete"
            GeelyProperties.ChargeStateHeating -> "Heating"
            GeelyProperties.ChargeStateBooking -> "Booking"
            GeelyProperties.ChargeStateDischarging -> "Discharging"
            GeelyProperties.ChargeStateDcCharging -> "DC charging"
            GeelyProperties.ChargeStateAcChargingSuspend -> "AC charging suspend"
            GeelyProperties.ChargeStateDcChargingEnd -> "DC charging end"
            else -> "Unknown $value"
        }
    }

    private fun chargingPlugLabel(value: Int): String {
        return when (value) {
            GeelyProperties.ChargePlugStateNone -> "No plug"
            GeelyProperties.ChargePlugStateAcConnected -> "AC plug connected"
            GeelyProperties.ChargePlugStateDcConnected -> "DC plug connected"
            GeelyProperties.ChargePlugStateDischargeConnected -> "Discharge plug connected"
            GeelyProperties.ChargePlugStateIntegrationConnected -> "Integration plug connected"
            else -> "Unknown $value"
        }
    }

    private fun shortError(throwable: Throwable): String {
        var root = throwable
        while (root.cause != null) root = root.cause!!
        val message = root.message
        return if (message.isNullOrBlank()) root::class.java.simpleName else "${root::class.java.simpleName}: $message"
    }

    private fun Int.toHexPropertyId(): String = "0x" + toUInt().toString(16).padStart(8, '0')

    private data class Probe<T>(
        val name: String,
        val propertyId: Int,
        val ok: Boolean,
        val value: T?,
        val type: String,
        val error: String?
    ) {
        fun valueIfOk(): T? = value.takeIf { ok }

        fun line(): String {
            return if (ok) {
                "$name ${propertyId.toHexPropertyId()}: $type $value"
            } else {
                "$name ${propertyId.toHexPropertyId()}: ERROR $error"
            }
        }

        private fun Int.toHexPropertyId(): String = "0x" + toUInt().toString(16).padStart(8, '0')
    }

    companion object {
        private const val TAG = "VehiclePropertyHelper"
        private const val MIN_CHARGE_POWER_KW = 0.2f
        private const val ECARX_ID_TYPE_FUNCTION = 2
    }
}
