package com.timhss.capyenergy.profile

/**
 * Every identifier this vehicle answers on, in one place.
 *
 * It sits in layer 0 because it is a statement about **one** vehicle. Nothing
 * under `telemetry/`, `service/`, `helpers/` or `lib/` may name one of these:
 * a second vehicle changes this file and the profile beside it, and nothing
 * above them moves. `VehicleProfileBoundaryTest` asserts that.
 *
 * The transport packages (`vehicle/`, `roadcast/`) are exempt. Naming an
 * address is what a transport is for.
 */
object GeelyProperties {
    data class IntProperty(val propertyId: Int, val areaId: Int = 0)
    data class FloatProperty(val propertyId: Int, val areaId: Int = 0)
    data class StringProperty(val propertyId: Int, val areaId: Int = 0)

    val VehicleIdentifier = StringProperty(0x11400200)
    val VehicleSpeedPerf = FloatProperty(291504647)
    val PerfOdometer = FloatProperty(291504644)
    val EdEvBatteryPercentage = IntProperty(557885165)
    val EvBatteryLevel = FloatProperty(291504905)
    val EvBatteryInstantaneousChargeRate = FloatProperty(0x1160030C)
    val EvCurrentBatteryCapacity = FloatProperty(291504909)
    val InfoEvBatteryCapacity = FloatProperty(291504390)

    /**
     * `RANGE_REMAINING`, INT32 in kilometres, area 0. Canonical id confirmed in
     *     * and the 2026-08-04 live-car dump (0x11400308 in the config list). Only
     * this id is configured; 0x11600308 is a type-variant read artifact. The
     * car declares read/write access, but this feature is read-only.
     */
    val RangeRemaining = IntProperty(0x11400308)

    /**
     * `BMSH_BAT_SOH`, INT32, state of health in tenths of a percent.
     *
     * Reads 999 with a zero source timestamp in the 2026-07-26 property scan,
     * which is the same shape as [InfoEvBatteryCapacity]: a VHAL default, not a
     * measurement. 999 also decodes to a legitimate 99.9 %, so only the
     * timestamp separates the two. See `SignalNormalizer`.
     */
    val BmshBatSoh = IntProperty(0x2140A868)
    val EdDrivingEnergyFlowRuntime = FloatProperty(0x2160A6E9)
    val TripEdDrivingEnergyFlowDirect = FloatProperty(0x24804100)
    val TripEdDrivingEnergyFlowVendor = FloatProperty(0x216074E9)
    val HybridPowerFlow = IntProperty(0x21407173)

    val ChargingDischargingState = IntProperty(557871998)
    val ChargingPlugState = IntProperty(557871753)
    val BatteryChargingCurrentPower = FloatProperty(606098432)
    val DcChargingPower = FloatProperty(606105856)
    val ChargingWorkCurrent = FloatProperty(605291008)
    val ChargingWorkVoltage = FloatProperty(605290752)
    val ChargingEstimatedTime = FloatProperty(605291264)
    val ChargingWorkTime = FloatProperty(606098688)

    /**
     * OEM AC charging-current setting, and the bounds the car declares for it.
     *
     * `CHARGING_ALTERNATING_CURRENT_VAL/_MAX/_MIN`, INT32 in amperes, adjacent
     * to the AC soft-switch at 0x2140A6DF the app already writes. Observed in
     * Observed on the car:
     * `_VAL` = 7 idle and 5 while charging, republished with a live timestamp;
     * `_MIN` = 5 and `_MAX` = 32, static (timestamp 0).
     *
     * The bounds are read from the car rather than hardcoded: they are what
     * the car declares, and a UI range invented in Dart is how the amperage
     * tile came to advertise a 48 A maximum the car never reported.
     */
    val ChargingAlternatingCurrentVal = IntProperty(0x2140A6D8)
    val ChargingAlternatingCurrentMax = IntProperty(0x2140A6D9)
    val ChargingAlternatingCurrentMin = IntProperty(0x2140A6DA)

    // VehiclePropertyStore addresses that differ from the car_service IDs.
    // Measured during the 2026-07-25 source investigation (1804-entry scan).
    //
    // Não substituem os ids acima: o CarPropertyManager responde nos ids
    // originais porque o car_service adapta, e essa é a fonte que funciona hoje.
    // They are diagnostic metadata and are not active collection sources.
    object RamStore {
        /** `PERF_ODOMETER`, INT32 em km. O app lê 0x11600204 (FLOAT). */
        const val PerfOdometer = 0x11400204

        /**
         * `DCHA_CHARGE_ACDC_VOLT` / `_CURRENT`, FLOAT.
         *
         * Atenção: são a **rede AC** (211 V, 6.8 A medidos), não o pacote
         * (395 V). O que o app chama de HV_BATTERY_VOLTAGE/CURRENT é a entrada
         * do carregador.
         */
        const val DchaChargeAcdcVolt = 0x2160B056
        const val DchaChargeAcdcCurrent = 0x2160B055

        /** `CHARGING_DIRECT_CURRENT_PWR`, INT32. Escala não confirmada. */
        const val ChargingDirectCurrentPwr = 0x2140A6B4

        /** `CHARGING_ALTERNATING_CURRENT_PWR`, INT32, 0.1 kW/bit (confirmado). */
        const val ChargingAlternatingCurrentPwr = 0x2140A6B3

        /** `CHARGE_CONNECTOR_STS`, INT32. Codificação crua não decifrada. */
        const val ChargeConnectorSts = 0x2140A143
    }

    // Candidates for instantaneous consumption, discovered in the IHU629G
    // car_service property catalog (names are the car's own).
    val BmshBatCurrent = IntProperty(0x2140A836) // BMSH_BAT_CURRENT
    val BmshPackVolt = IntProperty(0x2140A837) // BMSH_PACK_VOLT
    val BmshBusVolt = IntProperty(0x2140B014) // BMSH_BUS_VOLT
    val BmshBatSoe = IntProperty(0x2140A82B) // BMSH_BAT_SOE (state of energy)
    val DischargingCurrentPwr = IntProperty(0x2140A6BB) // DISCHARGING_CURRENT_PWR
    val DrivePowerOutput = IntProperty(0x21402006) // DRIVE_POWER_OUT_PUT
    val VcuAcVcuPowerActual = IntProperty(0x2140B013) // VCU_AC_VCU_POWER_ACTUAL
    val GcuActInputVolt = IntProperty(0x2140B015) // GCU_ACT_INPUT_VOLT
    val GcuActInputCurrent = IntProperty(0x2140B016) // GCU_ACT_INPUT_CURRENT
    val IpuMotorTq = IntProperty(0x2140A856) // IPU_MOTOR_TQ
    val IpuMotorSpd = IntProperty(0x2140A857) // IPU_MOTOR_SPD
    val BatteryCurr = IntProperty(0x2140A166) // BATTERY_CURR
    val VcuAccPedalPosition = IntProperty(0x2140A85A) // VCU_ACC_PEDAL_POSITION
    val IpkAveragePowerConsumption = IntProperty(0x2140A6AA) // IPK_AVERAGE_POWER_CONSUMPTION

    // EX2 body/ADAS/PEPS diagnostics. Raw cluster/keyserver-facing values;
    // these do not feed trip, charge, or energy calculations.
    val McuKeyCodeResumeCruiseIncrease = IntProperty(0x2140A636)
    val McuKeyCodeResumeCruiseDecrease = IntProperty(0x2140A637)
    val McuKeyCodeCruiseDistanceIncrease = IntProperty(0x2140A638)
    val McuKeyCodeCruiseDistanceDecrease = IntProperty(0x2140A639)

    // Real ADAS steering-wheel channel (the MCU_KEY_CODE_* above never push).
    // CRUISE_SWITCH_STATUS carries the raw cruise-switch actuation from the VCU
    // (VCU_CruiseSwitchSts, CAN frame 0x1A5); ACC_CRUISE_MODE / ACC_SPEED_VALUE
    // are the resulting ADAS state used to corroborate which button fired.
    val CruiseSwitchStatus = IntProperty(0x2140B092)
    val AdasAccCruiseMode = IntProperty(0x2140400E)
    val AdasAccSpeedValue = IntProperty(0x21404018)

    // Temperature-mode helper diagnostics. These are read-only/diagnostic in
    // this slice; do not use them to control HVAC until live-car ranges are
    // validated.
    val McuKeyCodeVolumeIncrease = IntProperty(0x2140A640)
    val McuKeyCodeVolumeDecrease = IntProperty(0x2140A641)
    val McuKeyCodePlayPrevious = IntProperty(0x2140A642)
    val McuKeyCodePlayNext = IntProperty(0x2140A643)
    val VehicRkeLockFeedback = IntProperty(0x2140A114)
    val VehicRls = IntProperty(0x2140A113)
    val DoorMove = IntProperty(0x16400B01)
    val HeadlightsSwitch = IntProperty(0x214020A3)

    val DoorPosFrontLeft = IntProperty(0x264020A9, AREA_ROW_1_LEFT)
    val DoorPosFrontRight = IntProperty(0x264020A9, AREA_ROW_1_RIGHT)
    val DoorPosRearLeft = IntProperty(0x264020A9, AREA_ROW_2_LEFT)
    val DoorPosRearRight = IntProperty(0x264020A9, AREA_ROW_2_RIGHT)
    val BcmHoodStatus = IntProperty(0x2140801E)
    val BodyDoorTrunkDoorPos = IntProperty(0x21402013)
    val LockHood = IntProperty(0x2140A552)

    val BodyBuckleSwitchStatus = IntProperty(0x214020A1)
    val AcuPassSeatOccupantSensorStatus = IntProperty(0x2140A676)
    val IpkWarnDriverSeatBelt = IntProperty(0x2140A594)
    val IpkWarnPassengerSeatBelt = IntProperty(0x2140A595)
    val AcuDriverSeatBeltBuckleInvalid = IntProperty(0x2140B012)

    val PepsPowerMode = IntProperty(0x2140A331)
    val PepsPowerModeValid = IntProperty(0x2140A332)
    val PepsUsageMode = IntProperty(0x2140A822)
    val PepsUsageModeValidity = IntProperty(0x2140A823)
    val PepsRemoteControlStatus = IntProperty(0x2140A330)
    val PepsResponseStatus = IntProperty(0x2170A062)

    // Outside temperature. The vendor int is the reliable source on Flyme Auto
    // (validated in the geelycontrol app); raw value decodes as (raw - 80) / 2 °C.
    // The AOSP float property is a fallback and is already in °C.
    val AcAmbientTemp = IntProperty(0x2140A377) // AC_AMBIENT_TEMP
    val EnvOutsideTemperature = FloatProperty(0x11600703) // ENV_OUTSIDE_TEMPERATURE

    val ParkingComfortSwt = IntProperty(0x2140A6CF)
    val ParkingNapSwt = IntProperty(0x2140A6D0)
    val AcParkingClimateSet = IntProperty(0x2140A355)
    val AcParkingClimateFailSts = IntProperty(0x2140A356)

    val GearSelection = IntProperty(0x11400400, -1)
    val GearSelectionArea0 = IntProperty(0x11400400, 0)
    val CurrentGear = IntProperty(0x11400401, -1)
    val CurrentGearArea0 = IntProperty(0x11400401, 0)
    val GearLever = CurrentGear

    const val GEAR_NEUTRAL = 0x1
    const val GEAR_REVERSE = 0x2
    const val GEAR_PARK = 0x4
    const val GEAR_DRIVE = 0x8

    const val ChargeStateNoCharging = 606100481
    const val ChargeStateAcCharging = 606100482
    const val ChargeStateChargingEnd = 606100483
    const val ChargeStateChargingComplete = 606100484
    const val ChargeStateHeating = 606100485
    const val ChargeStateBooking = 606100486
    const val ChargeStateDischarging = 606100488
    const val ChargeStateDcCharging = 606100501
    const val ChargeStateAcChargingSuspend = 606100517
    const val ChargeStateDcChargingEnd = 606100518

    const val ChargingDischargingStateLogical = 606100480
    const val ChargingPlugStateLogical = 605225472
    const val TripEdDrivingEnergyFlowLogical = 612385024

    // ECARX ISensor SENSOR_TYPE_* logical ids (resolve with ID_TYPE_SENSOR).
    // These carry the PEPS power/key state through the wrapper's adapt value,
    // which decodes to ISensorEvent.IGNITION_STATE_* / USG_MODE_* constants
    // instead of the raw 0/1/2 VHAL enum.
    const val IgnitionStateSensorLogical = 0x200100 // SENSOR_TYPE_IGNITION_STATE
    const val UsageModeSensorLogical = 0x201300 // SENSOR_TYPE_USG_MODE

    // Adapted values (ISensorEvent) for IgnitionStateSensorLogical.
    const val IgnitionStateUndefined = 0x200101
    const val IgnitionStateLock = 0x200102
    const val IgnitionStateOff = 0x200103
    const val IgnitionStateAcc = 0x200104
    const val IgnitionStateOn = 0x200105
    const val IgnitionStateStart = 0x200106
    const val IgnitionStateDriving = 0x200107

    // Adapted values (ISensorEvent) for UsageModeSensorLogical. ACTV/DRKVG mean
    // an authenticated key is present in the cabin.
    const val UsgModeAbandoned = 0x201301
    const val UsgModeInactive = 0x201302
    const val UsgModeConvenience = 0x201303
    const val UsgModeActive = 0x201304
    const val UsgModeDriving = 0x201305

    const val ChargePlugStateNone = 605225490
    const val ChargePlugStateAcConnected = 605225491
    const val ChargePlugStateDcConnected = 605225492
    const val ChargePlugStateDischargeConnected = 605225494
    const val ChargePlugStateIntegrationConnected = 605225499

    // Standard VehicleArea-style bitmasks used by EX2 area properties. Kept
    // local because android.car framework constants vary across SDK levels.
    const val AREA_ROW_1_LEFT = 0x00000001
    const val AREA_ROW_1_RIGHT = 0x00000004
    const val AREA_ROW_2_LEFT = 0x00000010
    const val AREA_ROW_2_RIGHT = 0x00000040
}
