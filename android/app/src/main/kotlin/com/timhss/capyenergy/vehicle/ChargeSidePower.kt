package com.timhss.capyenergy.vehicle

import com.timhss.capyenergy.profile.GeelyProperties
import kotlin.math.abs

/**
 * Which side's power reading describes the charge in progress.
 *
 * The car publishes an AC power and a DC power at all times, and the side it is
 * *not* charging on keeps a value that describes nothing. Measured on
 * 2026-08-11 while charging on AC at 1.0 kW: `CHARGING_DIRECT_CURRENT_PWR` held
 * raw 25 -> 12.5 kW for the whole session, unmoving. Taken as the charge rate,
 * it made a 1.5 kW climate load look like an eighth of the charge instead of
 * half again as much as it.
 *
 * This is the same defect as `INFO_EV_BATTERY_CAPACITY` answering 150 000 Wh:
 * a property the car never writes for this situation, holding a value that is
 * wrong rather than absent. The guard is the same in shape — refuse the reading
 * on the evidence that it cannot apply.
 *
 * Only a **known** charging state rejects a reading. With no state the car has
 * not said which side is live, so neither reading can be ruled out and both are
 * passed on as before.
 */
object ChargeSidePower {
    /** Below this the reading is noise around zero rather than a charge. */
    const val MIN_CHARGE_POWER_KW = 0.2f

    /** The AC reading, unless the car says it is charging on DC. */
    fun acPowerKw(stateRaw: Int?, value: Float?): Float? =
        usable(value)?.takeIf { stateRaw != GeelyProperties.ChargeStateDcCharging }

    /** The DC reading, unless the car says it is charging on AC. */
    fun dcPowerKw(stateRaw: Int?, value: Float?): Float? =
        usable(value)?.takeIf { stateRaw != GeelyProperties.ChargeStateAcCharging }

    private fun usable(value: Float?): Float? =
        value?.takeIf { it.isFinite() && abs(it) > MIN_CHARGE_POWER_KW }
}
