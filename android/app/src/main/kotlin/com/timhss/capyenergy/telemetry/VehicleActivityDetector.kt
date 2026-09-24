package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey

import com.timhss.capyenergy.profile.GeelyProfile
import com.timhss.capyenergy.profile.VehicleProfile

class VehicleActivityDetector(private val profile: VehicleProfile = GeelyProfile) {
    fun classify(snapshot: Map<SignalKey, SignalSample>): VehicleActivity {
        val now = System.currentTimeMillis()
        val lastUpdate = snapshot.values.maxOfOrNull { it.timestampMillis } ?: return VehicleActivity.UNKNOWN
        if (now - lastUpdate > DATA_STALE_MILLIS) return VehicleActivity.DATA_STALE

        val chargeState = snapshot[SignalKey.EV_CHARGE_STATE]?.intValue()
        if (profile.chargeCodes.isCharging(chargeState)) {
            return VehicleActivity.CHARGING
        }

        val plug = snapshot[SignalKey.EV_CHARGE_PLUG_TYPE]?.intValue()
        if (isPlugConnected(plug)) return VehicleActivity.CHARGE_CONNECTED

        val speed = snapshot[SignalKey.VEHICLE_SPEED]?.floatValue()
        return when {
            speed == null -> VehicleActivity.UNKNOWN
            speed > MOVING_SPEED_KMH -> VehicleActivity.MOVING
            else -> VehicleActivity.STATIONARY
        }
    }

    companion object {
        private const val DATA_STALE_MILLIS = 30_000L
        private const val MOVING_SPEED_KMH = 1f
    }
}

internal fun SignalSample.floatValue(): Float? = when (val v = value) {
    is Float -> v
    is Double -> v.toFloat()
    is Int -> v.toFloat()
    is Long -> v.toFloat()
    is Number -> v.toFloat()
    else -> v?.toString()?.toFloatOrNull()
}

internal fun SignalSample.intValue(): Int? = when (val v = value) {
    is Int -> v
    is Number -> v.toInt()
    else -> v?.toString()?.toIntOrNull()
}

// What a gear or a charge code means is a statement about one vehicle, so the
// codes come from the profile. The questions below are the same on every
// vehicle, which is why they stay here.

internal fun isDriveGear(gear: Int?, profile: VehicleProfile = GeelyProfile): Boolean =
    gear != null && profile.gearCodes.isDrive(gear)

internal fun isParkGear(gear: Int?, profile: VehicleProfile = GeelyProfile): Boolean =
    gear != null && profile.gearCodes.isPark(gear)

internal fun isPlugConnected(plug: Int?, profile: VehicleProfile = GeelyProfile): Boolean =
    profile.chargeCodes.isConnected(plug)

internal fun isChargingState(state: Int?, profile: VehicleProfile = GeelyProfile): Boolean =
    profile.chargeCodes.isCharging(state)

internal fun isChargeCompleteState(state: Int?, profile: VehicleProfile = GeelyProfile): Boolean =
    profile.chargeCodes.isFinished(state)
