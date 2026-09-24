package com.timhss.capyenergy.vehicle

import com.timhss.capyenergy.profile.GeelyProfile

/**
 * State of charge from whichever battery property answered.
 *
 * `ED_EV_BATTERY_PERCENTAGE` is the vendor percentage and wins whenever it is
 * in range. `EV_BATTERY_LEVEL` is the fallback, and it is ambiguous: this car
 * answers it either as a percentage or as absolute remaining energy in Wh. A
 * value above 100 is read as Wh, which is the only reading that can be true.
 *
 * [packCapacityWh] is what an absolute level is divided by. It comes from
 * Settings, the app's one capacity route, and never from the car: the vehicle
 * property answers 150 000 Wh against a 39.6 kWh pack, which would report a
 * full battery as 26 %. See [GeelyProfile.battery].
 */
internal fun decodeBatteryPercent(
    oemPercent: Float?,
    batteryLevel: Float?,
    packCapacityWh: Float
): Float? {
    oemPercent?.takeIf { it.isFinite() && it in 0f..100f }?.let { return it.coerceIn(0f, 100f) }
    val level = batteryLevel?.takeIf { it.isFinite() } ?: return null
    if (level > 100f) {
        if (!packCapacityWh.isFinite() || packCapacityWh <= 0f) return null
        return ((level / packCapacityWh) * 100f).coerceIn(0f, 100f)
    }
    return level.takeIf { it in 0f..100f }?.coerceIn(0f, 100f)
}
