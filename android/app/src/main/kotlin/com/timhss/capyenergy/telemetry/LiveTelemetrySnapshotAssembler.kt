package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.GeelyProfile
import com.timhss.capyenergy.profile.SignalKey
import com.timhss.capyenergy.profile.VehicleProfile

/**
 * Pure assembler that builds a [LiveTelemetrySnapshot] from current signal and location states.
 * Respects signal validity and never invents numbers.
 */
object LiveTelemetrySnapshotAssembler {
    fun assemble(
        wallTimeUtcMillis: Long = System.currentTimeMillis(),
        signalSnapshot: Map<SignalKey, SignalSample>,
        locationSnapshot: LocationSnapshot?,
        isCharging: Boolean = false,
        isDcfc: Boolean = false,
        isParked: Boolean = false,
        profile: VehicleProfile = GeelyProfile
    ): LiveTelemetrySnapshot {
        val isDcfcEffective =
            if (signalSnapshot.containsKey(SignalKey.EV_CHARGE_PLUG_TYPE)) {
                profile.isDcFastCharge(signalSnapshot[SignalKey.EV_CHARGE_PLUG_TYPE]?.value)
            } else {
                isDcfc
            }
        val soc = signalSnapshot[SignalKey.HV_BATTERY_SOC].asDouble()
        val speed = signalSnapshot[SignalKey.VEHICLE_SPEED].asDouble()
        val power = signalSnapshot[SignalKey.EV_BATTERY_INSTANTANEOUS_POWER].asDouble()
        val voltage = signalSnapshot[SignalKey.HV_BATTERY_VOLTAGE].asDouble()
        val current = signalSnapshot[SignalKey.HV_BATTERY_CURRENT].asDouble()
        val temp = signalSnapshot[SignalKey.AMBIENT_AIR_TEMPERATURE].asDouble()
            ?: signalSnapshot[SignalKey.OUTSIDE_TEMPERATURE].asDouble()
        val odometer = signalSnapshot[SignalKey.ODOMETER].asDouble()

        return LiveTelemetrySnapshot(
            utcMillis = wallTimeUtcMillis,
            socPercent = soc,
            speedKmh = speed,
            powerKw = power,
            voltageV = voltage,
            currentA = current,
            latitude = locationSnapshot?.latitude,
            longitude = locationSnapshot?.longitude,
            altitudeM = locationSnapshot?.altitudeM,
            headingDeg = locationSnapshot?.bearingDeg?.toDouble(),
            isCharging = isCharging,
            isDcfc = isDcfcEffective,
            isParked = isParked,
            ambientTempC = temp,
            odometerKm = odometer
        )
    }

    private fun SignalSample?.asDouble(): Double? {
        if (this == null || (quality != SignalQuality.MEASURED && quality != SignalQuality.DERIVED)) return null
        return when (val v = value) {
            is Number -> v.toDouble()
            is Boolean -> if (v) 1.0 else 0.0
            is String -> v.toDoubleOrNull()
            else -> null
        }
    }
}
