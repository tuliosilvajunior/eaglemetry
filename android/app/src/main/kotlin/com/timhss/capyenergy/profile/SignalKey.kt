package com.timhss.capyenergy.profile

/**
 * The canonical vocabulary. One name per quantity, for every vehicle.
 *
 * A key names what the product measures. It never names a VHAL property, a CAN
 * frame or a vendor constant: which of those answers a key is a statement about
 * one vehicle, and it belongs to a [VehicleProfile]. That is the whole point of
 * layer 0 — a second vehicle changes the profile and nothing above it.
 *
 * [unit] is the canonical unit. Every source of a key is transformed into it
 * before the value leaves collection, so a reader never asks which unit it got.
 * An enumerated or boolean key carries [UNIT_NONE]: a count of gear positions
 * has no unit, and inventing one would make it look like a measurement.
 *
 * **The member names are on disk.** `telemetry_events.signalId` stores
 * `SignalKey.name`, and the export and the sync carry the same strings. Rename a
 * member and every recorded row stops matching. Several names below read as bus
 * names for that reason — `BMSH_BAT_SOE`, `PEPS_USAGE_MODE` — and they stay
 * until a schema baseline can rename them together with the rows. New members
 * are named for the product.
 */
enum class SignalKey(val unit: String) {

    // --- Energy and motion -------------------------------------------------

    HV_BATTERY_SOC(UNIT_PERCENT),
    VEHICLE_SPEED(UNIT_KMH),
    ODOMETER(UNIT_KM),
    HV_BATTERY_VOLTAGE(UNIT_VOLT),
    HV_BATTERY_CURRENT(UNIT_AMPERE),
    EV_BATTERY_INSTANTANEOUS_POWER(UNIT_KW),
    ED_DRIVING_ENERGY_FLOW(UNIT_NONE),
    TRIP_ED_DRIVING_ENERGY_FLOW(UNIT_NONE),
    TRIP_ED_DRIVING_ENERGY_FLOW_VENDOR(UNIT_NONE),
    HYBRID_POWER_FLOW(UNIT_NONE),
    RANGE_REMAINING(UNIT_KM),
    BATTERY_SOH_PERCENT(UNIT_PERCENT),

    // --- Charging ----------------------------------------------------------

    EV_CHARGE_PORT_CONNECTED(UNIT_NONE),
    EV_CHARGE_STATE(UNIT_NONE),
    EV_DC_CHARGE_POWER(UNIT_KW),
    EV_CHARGE_PLUG_TYPE(UNIT_NONE),
    EV_CHARGE_ESTIMATED_TIME(UNIT_MINUTE),

    // --- Cabin and environment ---------------------------------------------

    GEAR(UNIT_NONE),
    AMBIENT_AIR_TEMPERATURE(UNIT_CELSIUS),
    OUTSIDE_TEMPERATURE(UNIT_CELSIUS),

    // --- Consumption candidates from the IHU629G catalogue -----------------
    // Raw counts. Their scale is unknown until observed while driving, so the
    // profile declares no transform for them and they stay counts.

    BMSH_BAT_CURRENT(UNIT_NONE),
    BMSH_PACK_VOLT(UNIT_NONE),
    BMSH_BUS_VOLT(UNIT_NONE),
    BMSH_BAT_SOE(UNIT_NONE),
    DISCHARGING_CURRENT_PWR(UNIT_NONE),
    DRIVE_POWER_OUT_PUT(UNIT_NONE),
    VCU_AC_VCU_POWER_ACTUAL(UNIT_NONE),
    GCU_ACT_INPUT_VOLT(UNIT_NONE),
    GCU_ACT_INPUT_CURRENT(UNIT_NONE),
    IPU_MOTOR_TQ(UNIT_NONE),
    IPU_MOTOR_SPD(UNIT_NONE),
    BATTERY_CURR(UNIT_NONE),
    VCU_ACC_PEDAL_POSITION(UNIT_NONE),
    IPK_AVERAGE_POWER_CONSUMPTION(UNIT_NONE),

    // --- Steering-wheel and ADAS channels ----------------------------------

    MCU_KEY_CODE_RESUME_CRUISE_INCREASE(UNIT_NONE),
    MCU_KEY_CODE_RESUME_CRUISE_DECREASE(UNIT_NONE),
    MCU_KEY_CODE_CRUISE_DISTANCE_INCREASE(UNIT_NONE),
    MCU_KEY_CODE_CRUISE_DISTANCE_DECREASE(UNIT_NONE),
    CRUISE_SWITCH_STATUS(UNIT_NONE),
    ADAS_ACC_CRUISE_MODE(UNIT_NONE),
    ADAS_ACC_SPEED_VALUE(UNIT_NONE),

    // --- Media keys and body -----------------------------------------------

    MCU_KEY_CODE_VOLUME_INCREASE(UNIT_NONE),
    MCU_KEY_CODE_VOLUME_DECREASE(UNIT_NONE),
    MCU_KEY_CODE_PLAY_PREVIOUS(UNIT_NONE),
    MCU_KEY_CODE_PLAY_NEXT(UNIT_NONE),
    VEHIC_RKE_LOCK_FEEDBACK(UNIT_NONE),
    VEHIC_RLS(UNIT_NONE),
    DOOR_MOVE(UNIT_NONE),
    HEADLIGHTS_SWITCH(UNIT_NONE),

    DOOR_POS_FRONT_LEFT(UNIT_NONE),
    DOOR_POS_FRONT_RIGHT(UNIT_NONE),
    DOOR_POS_REAR_LEFT(UNIT_NONE),
    DOOR_POS_REAR_RIGHT(UNIT_NONE),
    BCM_HOOD_STATUS(UNIT_NONE),
    BODY_DOOR_TRUNK_DOOR_POS(UNIT_NONE),
    LOCK_HOOD(UNIT_NONE),

    BODY_BUCKLE_SWITCH_STATUS(UNIT_NONE),
    ACU_PASS_SEAT_OCCUPANT_SENSOR_ST(UNIT_NONE),
    IPKWARN_DRV_SEAT_BELT(UNIT_NONE),
    IPKWARN_PASS_SEAT_BELT(UNIT_NONE),
    ACU_DRV_SEAT_BELT_BUCKLE_INVALID(UNIT_NONE),

    PEPS_POWER_MODE(UNIT_NONE),
    PEPS_POWER_MODE_VAILD(UNIT_NONE),
    PEPS_USAGE_MODE(UNIT_NONE),
    PEPS_USAGE_MODE_VALIDITY(UNIT_NONE),
    PEPS_REMOTE_CTL_STS(UNIT_NONE),
    PEPS_RESPONSE_STS(UNIT_NONE),

    PARKING_COMFORT_SWT(UNIT_NONE),
    PARKING_NAP_SWT(UNIT_NONE),
    AC_PARKINGCLIMATESET(UNIT_NONE),

    // --- Bus-rate readings -------------------------------------------------
    // Reached over the bus transport, not over the property surface. They are
    // in the same enum because they are the same vocabulary: a vehicle that
    // publishes pack power on a property and one that publishes it on a bus
    // answer one key, and the profile says which.

    PACK_POWER_DRIVE(UNIT_KW),
    PACK_VOLTAGE(UNIT_VOLT),
    PACK_CURRENT(UNIT_AMPERE),
    BUS_VEHICLE_SPEED(UNIT_KMH),
    TOTAL_DRIVE_POWER(UNIT_KW),
    AC_INPUT_VOLTAGE(UNIT_VOLT),
    AC_INPUT_CURRENT(UNIT_AMPERE),
    ROAD_INCLINE(UNIT_PERCENT),
    BRAKE_PEDAL(UNIT_NONE),
    REGEN_TORQUE(UNIT_NEWTON_METRE),
    ACCEL_PEDAL(UNIT_PERCENT),
    REGEN_LEVEL(UNIT_NONE),
    THERMAL_POWER(UNIT_KW),
    DCDC_POWER(UNIT_KW),
    CLIMATE_ON(UNIT_NONE),
    CLIMATE_COMPRESSOR(UNIT_NONE),
    BLOWER_LEVEL(UNIT_NONE),
    CABIN_SETPOINT(UNIT_CELSIUS),
    REAR_DEFROSTER(UNIT_NONE),
    DRIVE_MODE(UNIT_NONE),

    // --- Receiver ----------------------------------------------------------
    // One measurement written as four rows; see the coordinate group rule in
   
    LATITUDE(UNIT_DEGREE),
    LONGITUDE(UNIT_DEGREE),
    ALTITUDE(UNIT_METRE),
    GPS_ACCURACY(UNIT_METRE);

    companion object {
        private val byName = entries.associateBy { it.name }

        /** The key a recorded row names, or null when this build does not know it. */
        fun forName(name: String?): SignalKey? = name?.let { byName[it] }
    }
}

const val UNIT_NONE = ""
const val UNIT_PERCENT = "%"
const val UNIT_KMH = "km/h"
const val UNIT_KM = "km"
const val UNIT_VOLT = "V"
const val UNIT_AMPERE = "A"
const val UNIT_KW = "kW"
const val UNIT_MINUTE = "min"
const val UNIT_CELSIUS = "°C"
const val UNIT_NEWTON_METRE = "Nm"
const val UNIT_DEGREE = "°"
const val UNIT_METRE = "m"
