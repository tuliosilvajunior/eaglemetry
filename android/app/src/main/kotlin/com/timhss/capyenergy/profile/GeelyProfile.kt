package com.timhss.capyenergy.profile

/**
 * The Geely / Flyme Auto head unit this app was written for.
 *
 * Everything that is true about **this** vehicle and about no other is here:
 * which property or bus signal answers a key, how a raw count becomes a
 * canonical unit, the band a reading is accepted in, how far a signal must move
 * before it is worth a row, which enum code means park, and which readings
 * describe a drive rather than a charge.
 *
 * Seven places used to hold this, and a second vehicle had to change all seven.
 */
object GeelyProfile : VehicleProfile {

    override val id: String = "geely-ex2-flyme"

    override val declarations: Map<SignalKey, SignalDeclaration> = geelyDeclarations

    /**
     * The longest a state series may go without a row.
     *
     * Measured over the slice 0 corpus: raising it to 900 s saves 1.4 %, which
     * does not pay for a chart that can hold a stale value for a quarter of an
     *
     */
    const val SAMPLE_MAX_GAP_MILLIS = 300_000L

    /**
     * How far the vehicle must move before the position tuple earns a row.
     *
     * Measured over the 26 388 fixes in `sample_2026_08`: at 10 m the tuple is
     * 58.7 % of every row stored, and the collector ticks at 1 Hz, so anything
     * above 36 km/h writes on every tick. At 20 m the same drives keep 62.9 %
     * of the fixes and a discarded point stands 14.4 m on average from the one
     * before it. The route the detail screen draws is decimated to
     * `kRouteExpandedPointLimit` = 1 200 points, and the average recorded
     * session holds 520.
     */
    const val POSITION_DISTANCE_THRESHOLD_M = 20.0

    /**
     * Speed below which the vehicle is considered standing still, in km/h.
     *
     * The speed is the car's own `VEHICLE_SPEED`, read from the bus, not the
     * Doppler speed of a GPS fix. The bus reports an exact zero when the
     * vehicle stands, so this floor only has to clear the last quantisation
     * step of the property. It stays a small positive number rather than zero
     * because comparing a float against zero tests the last bit, not the
     * vehicle.
     */
    const val POSITION_STANDING_SPEED_KMH = 0.5

    /**
     * Speed above which a standing vehicle is considered moving again, in km/h.
     *
     * Together with [POSITION_STANDING_SPEED_KMH] this forms a hysteresis band
     * (0.5..2.0 km/h) so a vehicle creeping in stop-and-go traffic does not
     * cross the boundary on every tick and write one point per tick.
     *
     * The band is tighter than the compass floors in `compass_reading.dart`
     * (1.5 and 3.0 km/h) because those read the Doppler speed of a GPS fix,
     * which flickers near zero from receiver noise and multipath, and they
     * answer a different question: whether a needle may be drawn. This band
     * reads the bus, which does not flicker.
     */
    const val POSITION_MOVING_SPEED_KMH = 2.0

    /** The coordinate tuple. Written together or not at all. */
    const val GROUP_POSITION = "position"

    /**
     * The pack, as the app is told it — never as it reads it from the car.
     *
     * `INFO_EV_BATTERY_CAPACITY` answers 150 000 Wh with a zero source
     * timestamp, a VHAL default for a property this car never writes, and every
     * energy and efficiency figure derived from it was 3.8 times too large. The
     * app does not read it at all.
     *
     * `defaultCapacityWh` is 39.6 kWh, lithium iron phosphate, from the vehicle
     * specification; a 15-trip energy balance solves for 44.1 +- 3.3 kWh, which
     * contains it. The migration at
     * database v16 keeps its own frozen copy of the figure it ran with, because
     * a migration must stay reproducible; do not point it here.
     *
     * `acceptedCapacityWh` is wide on purpose. It is the one number that lets
     * another car use the app, so it must not be anchored on the pack of this
     * one: it rejects only what cannot be a traction battery.
     */
    override val battery = BatterySpec(
        defaultCapacityWh = 39_600.0,
        acceptedCapacityWh = 5_000.0..200_000.0
    )

    override val gearCodes = GearCodes(
        park = GeelyProperties.GEAR_PARK,
        reverse = GeelyProperties.GEAR_REVERSE,
        neutral = GeelyProperties.GEAR_NEUTRAL,
        drive = GeelyProperties.GEAR_DRIVE
    )

    override val chargeCodes = ChargeCodes(
        chargingAc = setOf(GeelyProperties.ChargeStateAcCharging),
        chargingDc = setOf(GeelyProperties.ChargeStateDcCharging),
        finished = setOf(
            GeelyProperties.ChargeStateChargingEnd,
            GeelyProperties.ChargeStateChargingComplete,
            GeelyProperties.ChargeStateDcChargingEnd
        ),
        connected = setOf(
            GeelyProperties.ChargePlugStateAcConnected,
            GeelyProperties.ChargePlugStateDcConnected,
            GeelyProperties.ChargePlugStateIntegrationConnected
        )
    )

    /**
     * What goes on a session's event list, measured rather than guessed.
     *
     * The starting set is what a recorded day actually produced that a reader
     * would recognise. `ODOMETER`, `HV_BATTERY_SOC` and the vehicle-activity
     * change are deliberately absent: they are states, they have their own
     * series, and they arrive by the dozen.
     *
     * To put a signal on the list, add its key here and
     * [com.timhss.capyenergy.telemetry.EventPersistencePolicy] starts
     * persisting it; nothing else changes.
     */
    override val sessionEventKeys = setOf(
        SignalKey.GEAR,
        SignalKey.HEADLIGHTS_SWITCH,
        SignalKey.ADAS_ACC_CRUISE_MODE,
        SignalKey.EV_CHARGE_STATE,
        SignalKey.EV_CHARGE_PLUG_TYPE,
        SignalKey.PEPS_POWER_MODE,
        SignalKey.DOOR_MOVE
    )

    override val capabilities = setOf(
        VehicleCapability.BUS_RATE_TRANSPORT,
        VehicleCapability.MEASURED_PACK_POWER,
        VehicleCapability.CLIMATE_CONTROL,
        VehicleCapability.PHONE_PROJECTION,
        VehicleCapability.LOCATION
    )

    /**
     * Whether the plug type code means DC fast charge.
     *
     * The raw value comes from `EV_CHARGE_PLUG_TYPE`. On this vehicle it is
     * the small code `2` (and `2.0` when boxed as a double) and the large
     * hardware constant `GeelyProperties.ChargePlugStateDcConnected` (and its
     * double/long variants) that the historic session table also stores. The
     * decision lives here so a code change is one edit in Layer 0.
     */
    override fun isDcFastCharge(plugTypeValue: Any?): Boolean {
        val integral = toIntegralLong(plugTypeValue) ?: return false
        return integral == 2L || integral == GeelyProperties.ChargePlugStateDcConnected.toLong()
    }

    private fun toIntegralLong(value: Any?): Long? = when (value) {
        null -> null
        is Int -> value.toLong()
        is Long -> value
        is Double -> if (value.isFinite() && value % 1.0 == 0.0) value.toLong() else null
        is Float -> if (value.isFinite() && value % 1.0 == 0.0) value.toLong() else null
        is Number -> {
            val d = value.toDouble()
            if (d.isFinite() && d % 1.0 == 0.0) d.toLong() else null
        }
        is String -> {
            val trimmed = value.trim()
            trimmed.toLongOrNull()
                ?: trimmed.toDoubleOrNull()?.takeIf { it.isFinite() && it % 1.0 == 0.0 }?.toLong()
        }
        else -> null
    }

    /**
     * The outside temperature, vendor property first.
     *
     * `AC_AMBIENT_TEMP_INVALID` reads 1 with a zero source timestamp, which is
     * the VHAL default for a property this car never writes, not a report that
     * the temperature is bad. It is therefore **not consulted**, by decision of
     * the project owner on 2026-08-07, and nothing may start consulting it: an
     * unpublished companion would suppress a good measurement for ever.
     */
    override fun trustOrder(key: SignalKey): List<SignalKey> = when (key) {
        SignalKey.AMBIENT_AIR_TEMPERATURE, SignalKey.OUTSIDE_TEMPERATURE ->
            listOf(SignalKey.AMBIENT_AIR_TEMPERATURE, SignalKey.OUTSIDE_TEMPERATURE)
        else -> listOf(key)
    }

    /**
     * Which readings describe which session.
     *
     * The drivetrain controllers go quiet when the car is parked on a charger,
     * and the charger goes quiet while the car is driving. A value landing in
     * the wrong kind of session is the last thing that ECU sent before it
     * stopped, not a measurement of the session it lands in.
     *
     * The climate signals are deliberately ungated: the climate system runs
     * while the car is plugged in, so that load belongs to the charge.
     */
    override fun recordsDuring(key: SignalKey, kind: SessionKind): Boolean = when (key) {
        SignalKey.PACK_POWER_DRIVE,
        SignalKey.TOTAL_DRIVE_POWER,
        SignalKey.ROAD_INCLINE,
        SignalKey.BRAKE_PEDAL,
        SignalKey.REGEN_TORQUE,
        SignalKey.ACCEL_PEDAL,
        SignalKey.REGEN_LEVEL,
        SignalKey.THERMAL_POWER,
        SignalKey.DCDC_POWER,
        SignalKey.DRIVE_MODE -> kind == SessionKind.TRIP

        SignalKey.AC_INPUT_VOLTAGE,
        SignalKey.AC_INPUT_CURRENT -> kind == SessionKind.CHARGE

        else -> true
    }

    // --- The bus ------------------------------------------------------------

    /**
     * The CAN signals this vehicle publishes, under the names the daemon
     * negotiated for them.
     *
     * Decoding is the daemon's job. A binding that asks for a calibrated value
     * gets null until the daemon carries a verified scale, which is right for a
     * number the app publishes. An enumerated count sets `requiresCalibration`
     * false, because the decode of an enumeration is the identity and no daemon
     * has a scale to verify there.
     */
    override val busSignals: Map<SignalKey, BusBinding> = mapOf(
        SignalKey.PACK_POWER_DRIVE to BusBinding("VCU_DrvPwrAct", keepRawCount = true),
        SignalKey.PACK_VOLTAGE to BusBinding("BMSH_BattVolt"),
        SignalKey.PACK_CURRENT to BusBinding("BMSH_BattCurr", keepRawCount = true),
        SignalKey.BUS_VEHICLE_SPEED to BusBinding(
            "ESC_VehicleSpeed",
            invalidCompanion = "ESC_VehicleSpeedInvalid"
        ),
        SignalKey.TOTAL_DRIVE_POWER to BusBinding("TotDrvPwrAct", keepRawCount = true),
        SignalKey.AC_INPUT_VOLTAGE to BusBinding("OBC_uInAct"),
        SignalKey.AC_INPUT_CURRENT to BusBinding("OBC_iInAct"),
        SignalKey.ROAD_INCLINE to BusBinding("ESC_RoadInclnRoadIncln", keepRawCount = true),
        SignalKey.BRAKE_PEDAL to BusBinding(
            "ESC_BrakePedalSwitchStatus",
            invalidCompanion = "ESC_BrakePedalSwitchInvalid",
            requiresCalibration = false
        ),
        SignalKey.REGEN_TORQUE to BusBinding("VCU_RegenTrqAct", keepRawCount = true),
        SignalKey.ACCEL_PEDAL to BusBinding(
            "VCU_AccelPedalPosition",
            invalidCompanion = "VCU_AccelPedalPositionInvalid"
        ),
        SignalKey.REGEN_LEVEL to BusBinding("VCU_ePTRegencyLevInd", requiresCalibration = false),
        SignalKey.THERMAL_POWER to BusBinding("VCU_ThermalPwrAct", keepRawCount = true),
        SignalKey.DCDC_POWER to BusBinding("VCU_DCDCPwrAct", keepRawCount = true),
        SignalKey.CLIMATE_ON to BusBinding("AC_OnState", requiresCalibration = false),
        SignalKey.CLIMATE_COMPRESSOR to BusBinding("AC_ACCompReq", requiresCalibration = false),
        SignalKey.BLOWER_LEVEL to BusBinding("AC_BlowerLevel", requiresCalibration = false),
        SignalKey.CABIN_SETPOINT to BusBinding("AC_LeftSetTemperature"),
        SignalKey.REAR_DEFROSTER to BusBinding("BCM_RearDefrosterSts", requiresCalibration = false),
        SignalKey.DRIVE_MODE to BusBinding("BCM_DM_TargetModeReq", requiresCalibration = false)
    )

    /** The companion bits this vehicle sends, and which must therefore be honoured. */
    val busInvalidCompanions: Set<String> =
        busSignals.values.mapNotNull { it.invalidCompanion }.toSet()

    // --- The property surface -----------------------------------------------

    override val propertySignals: List<SignalSpec> = listOf(

        SignalSpec(
            signalId = SignalKey.HV_BATTERY_SOC,
            propertyId = GeelyProperties.EdEvBatteryPercentage.propertyId,
            pollingIntervalMillis = 10_000L
        ),
        SignalSpec(
            signalId = SignalKey.VEHICLE_SPEED,
            propertyId = GeelyProperties.VehicleSpeedPerf.propertyId,
            preferredSampleRate = 5f,
            pollingIntervalMillis = 500L
        ),
        SignalSpec(
            signalId = SignalKey.ODOMETER,
            propertyId = GeelyProperties.PerfOdometer.propertyId,
            pollingIntervalMillis = 5_000L,
            ramPropertyId = GeelyProperties.RamStore.PerfOdometer
        ),
        // Distance-to-empty in km, area 0. ON_CHANGE with a 5 s polling fallback
        // that only engages when callback registration fails. The value is
        // consumed by the range-estimate surface only; it never reaches a frame.
        SignalSpec(
            signalId = SignalKey.RANGE_REMAINING,
            propertyId = GeelyProperties.RangeRemaining.propertyId,
            pollingIntervalMillis = 5_000L
        ),
        SignalSpec(
            signalId = SignalKey.GEAR,
            propertyId = GeelyProperties.GearLever.propertyId,
            areaId = GeelyProperties.GearLever.areaId,
            pollingIntervalMillis = 1_000L
        ),
        SignalSpec(
            signalId = SignalKey.PARKING_COMFORT_SWT,
            propertyId = GeelyProperties.ParkingComfortSwt.propertyId,
            pollingIntervalMillis = 1_000L
        ),
        SignalSpec(
            signalId = SignalKey.PARKING_NAP_SWT,
            propertyId = GeelyProperties.ParkingNapSwt.propertyId,
            pollingIntervalMillis = 1_000L
        ),
        SignalSpec(
            signalId = SignalKey.AC_PARKINGCLIMATESET,
            propertyId = GeelyProperties.AcParkingClimateSet.propertyId,
            pollingIntervalMillis = 1_000L
        ),
        SignalSpec(
            // O scan da store não tem CHARGING_DISCHARGING_STATE em endereço
            // nenhum: quem monta esse enum é o car_service, a partir do wrapper.
            // Não é um id errado — é um sinal sintético, e migrar exigiria
            // reconstruí-lo do CAN (`OBC_ChrgrSt`), não trocar de endereço.
            signalId = SignalKey.EV_CHARGE_STATE,
            propertyId = GeelyProperties.ChargingDischargingState.propertyId,
            pollingIntervalMillis = 1_000L,
            ecarxLogicalId = GeelyProperties.ChargingDischargingStateLogical,
            adaptEcarxValue = true,
            ramPropertyId = SignalSpec.RAM_ABSENT
        ),
        SignalSpec(
            signalId = SignalKey.EV_CHARGE_PLUG_TYPE,
            propertyId = GeelyProperties.ChargingPlugState.propertyId,
            pollingIntervalMillis = 1_000L,
            ecarxLogicalId = GeelyProperties.ChargingPlugStateLogical,
            adaptEcarxValue = true,
            ramPropertyId = GeelyProperties.RamStore.ChargeConnectorSts
        ),
        SignalSpec(
            signalId = SignalKey.EV_DC_CHARGE_POWER,
            propertyId = GeelyProperties.DcChargingPower.propertyId,
            pollingIntervalMillis = 5_000L,
            ramPropertyId = GeelyProperties.RamStore.ChargingDirectCurrentPwr
        ),
        SignalSpec(
            signalId = SignalKey.EV_BATTERY_INSTANTANEOUS_POWER,
            propertyId = GeelyProperties.EvBatteryInstantaneousChargeRate.propertyId,
            preferredSampleRate = 5f,
            pollingIntervalMillis = 500L
        ),
        SignalSpec(
            signalId = SignalKey.ED_DRIVING_ENERGY_FLOW,
            propertyId = GeelyProperties.EdDrivingEnergyFlowRuntime.propertyId,
            preferredSampleRate = 1f,
            pollingIntervalMillis = 1_000L
        ),
        SignalSpec(
            // O wrapper resolve o functionId 612385024 para ED_DRIVING_ENERGY_FLOW
            // (0x2160A6E9) — visto no logcat do carro e confirmado no scan da
            // store. Sem isso a comparação em modo sombra lia dois endereços
            // diferentes e a divergência não queria dizer nada.
            signalId = SignalKey.TRIP_ED_DRIVING_ENERGY_FLOW,
            propertyId = GeelyProperties.TripEdDrivingEnergyFlowDirect.propertyId,
            preferredSampleRate = 1f,
            pollingIntervalMillis = 1_000L,
            ecarxLogicalId = GeelyProperties.TripEdDrivingEnergyFlowLogical,
            ramPropertyId = GeelyProperties.EdDrivingEnergyFlowRuntime.propertyId
        ),
        SignalSpec(
            signalId = SignalKey.TRIP_ED_DRIVING_ENERGY_FLOW_VENDOR,
            propertyId = GeelyProperties.TripEdDrivingEnergyFlowVendor.propertyId,
            preferredSampleRate = 1f,
            pollingIntervalMillis = 1_000L
        ),
        SignalSpec(
            signalId = SignalKey.HYBRID_POWER_FLOW,
            propertyId = GeelyProperties.HybridPowerFlow.propertyId,
            pollingIntervalMillis = 1_000L
        ),
        // Apesar do nome, estas duas são a **entrada AC do carregador**
        // (DCHA_CHARGE_ACDC_*: 211 V / 6.8 A medidos), não o pacote de 395 V.
        // Só têm significado com o carregador ligado, e congelam no último valor
        // quando a carga para — ver ChargerReadingGuard.
        SignalSpec(
            signalId = SignalKey.HV_BATTERY_CURRENT,
            propertyId = GeelyProperties.ChargingWorkCurrent.propertyId,
            pollingIntervalMillis = 5_000L,
            ramPropertyId = GeelyProperties.RamStore.DchaChargeAcdcCurrent
        ),
        SignalSpec(
            signalId = SignalKey.HV_BATTERY_VOLTAGE,
            propertyId = GeelyProperties.ChargingWorkVoltage.propertyId,
            pollingIntervalMillis = 5_000L,
            ramPropertyId = GeelyProperties.RamStore.DchaChargeAcdcVolt
        ),
        SignalSpec(
            // Ausentes do scan da store: são sintetizados pelo car_service.
            signalId = SignalKey.EV_CHARGE_ESTIMATED_TIME,
            propertyId = GeelyProperties.ChargingEstimatedTime.propertyId,
            pollingIntervalMillis = 10_000L,
            ramPropertyId = SignalSpec.RAM_ABSENT
        ),
        // State of health moves over months, so ON_CHANGE carries it and the
        // poll only exists to notice a value that was already published before
        // the app started. It never reaches a trip frame; the event log records
        // each change, which is the whole history this signal needs.
        SignalSpec(
            signalId = SignalKey.BATTERY_SOH_PERCENT,
            propertyId = GeelyProperties.BmshBatSoh.propertyId,
            pollingIntervalMillis = 60_000L
        ),
        SignalSpec(
            signalId = SignalKey.AMBIENT_AIR_TEMPERATURE,
            propertyId = GeelyProperties.AcAmbientTemp.propertyId,
            pollingIntervalMillis = 10_000L
        ),
        SignalSpec(
            signalId = SignalKey.OUTSIDE_TEMPERATURE,
            propertyId = GeelyProperties.EnvOutsideTemperature.propertyId,
            pollingIntervalMillis = 30_000L
        ),
        // DRIVE_POWER_OUT_PUT (0x21402006) — cluster power bar candidate.
        // INT32 with sign, positive=accelerating, negative=regeneration.
        // Scaling unknown; raw int until confirmed by live driving read.
        SignalSpec(
            signalId = SignalKey.DRIVE_POWER_OUT_PUT,
            propertyId = GeelyProperties.DrivePowerOutput.propertyId,
            pollingIntervalMillis = 1_000L
        ),
        // Cluster average-consumption candidate. Keep the integer raw and log
        // callbacks/polls until VCU_PwrCnsAvg{,1} close its scale on the car.
        SignalSpec(
            signalId = SignalKey.IPK_AVERAGE_POWER_CONSUMPTION,
            propertyId = GeelyProperties.IpkAveragePowerConsumption.propertyId,
            pollingIntervalMillis = 1_000L,
            rawLog = true
        ),
        // ADAS steering-wheel key codes: momentary ON_CHANGE events. Latched so
        // a press stays visible, and never polled (a 250ms poll almost always
        // reads the resting 0 and masks a failed subscription).
        SignalSpec(
            signalId = SignalKey.MCU_KEY_CODE_RESUME_CRUISE_INCREASE,
            propertyId = GeelyProperties.McuKeyCodeResumeCruiseIncrease.propertyId,
            keyEventLatch = true,
            pollingFallback = false
        ),
        SignalSpec(
            signalId = SignalKey.MCU_KEY_CODE_RESUME_CRUISE_DECREASE,
            propertyId = GeelyProperties.McuKeyCodeResumeCruiseDecrease.propertyId,
            keyEventLatch = true,
            pollingFallback = false
        ),
        SignalSpec(
            signalId = SignalKey.MCU_KEY_CODE_CRUISE_DISTANCE_INCREASE,
            propertyId = GeelyProperties.McuKeyCodeCruiseDistanceIncrease.propertyId,
            keyEventLatch = true,
            pollingFallback = false
        ),
        SignalSpec(
            signalId = SignalKey.MCU_KEY_CODE_CRUISE_DISTANCE_DECREASE,
            propertyId = GeelyProperties.McuKeyCodeCruiseDistanceDecrease.propertyId,
            keyEventLatch = true,
            pollingFallback = false
        ),
        // Real ADAS steering-wheel channel. CRUISE_SWITCH_STATUS is the raw
        // switch actuation from the VCU (momentary) -> latched + raw-logged,
        // ON_CHANGE only. The two ACC_* are persistent ADAS state -> raw-logged
        // to corroborate which button fired, keep polling as a safety net.
        SignalSpec(
            signalId = SignalKey.CRUISE_SWITCH_STATUS,
            propertyId = GeelyProperties.CruiseSwitchStatus.propertyId,
            keyEventLatch = true,
            pollingFallback = false,
            rawLog = true
        ),
        SignalSpec(
            signalId = SignalKey.ADAS_ACC_CRUISE_MODE,
            propertyId = GeelyProperties.AdasAccCruiseMode.propertyId,
            pollingIntervalMillis = 1_000L,
            rawLog = true
        ),
        SignalSpec(
            signalId = SignalKey.ADAS_ACC_SPEED_VALUE,
            propertyId = GeelyProperties.AdasAccSpeedValue.propertyId,
            pollingIntervalMillis = 1_000L,
            rawLog = true
        ),
        // Temperature-mode helper probes. Media keys are momentary ON_CHANGE
        // events from the keyserver-facing VHAL path: latch + raw-log them so
        // the debug table can show press/release behavior. Lock feedback and
        // headlight knob are persistent enough to poll, but raw-log callbacks
        // too so activation detector work can be verified in the car.
        SignalSpec(
            signalId = SignalKey.MCU_KEY_CODE_VOLUME_INCREASE,
            propertyId = GeelyProperties.McuKeyCodeVolumeIncrease.propertyId,
            keyEventLatch = true,
            pollingFallback = false,
            rawLog = true
        ),
        SignalSpec(
            signalId = SignalKey.MCU_KEY_CODE_VOLUME_DECREASE,
            propertyId = GeelyProperties.McuKeyCodeVolumeDecrease.propertyId,
            keyEventLatch = true,
            pollingFallback = false,
            rawLog = true
        ),
        SignalSpec(
            signalId = SignalKey.MCU_KEY_CODE_PLAY_PREVIOUS,
            propertyId = GeelyProperties.McuKeyCodePlayPrevious.propertyId,
            keyEventLatch = true,
            pollingFallback = false,
            rawLog = true
        ),
        SignalSpec(
            signalId = SignalKey.MCU_KEY_CODE_PLAY_NEXT,
            propertyId = GeelyProperties.McuKeyCodePlayNext.propertyId,
            keyEventLatch = true,
            pollingFallback = false,
            rawLog = true
        ),
        SignalSpec(
            signalId = SignalKey.VEHIC_RKE_LOCK_FEEDBACK,
            propertyId = GeelyProperties.VehicRkeLockFeedback.propertyId,
            pollingIntervalMillis = 1_000L,
            rawLog = true
        ),
        SignalSpec(
            signalId = SignalKey.VEHIC_RLS,
            propertyId = GeelyProperties.VehicRls.propertyId,
            pollingIntervalMillis = 1_000L,
            rawLog = true
        ),
        SignalSpec(
            signalId = SignalKey.DOOR_MOVE,
            propertyId = GeelyProperties.DoorMove.propertyId,
            pollingIntervalMillis = 1_000L,
            rawLog = true
        ),
        SignalSpec(
            signalId = SignalKey.HEADLIGHTS_SWITCH,
            propertyId = GeelyProperties.HeadlightsSwitch.propertyId,
            pollingIntervalMillis = 1_000L,
            rawLog = true
        ),
        SignalSpec(
            signalId = SignalKey.DOOR_POS_FRONT_LEFT,
            propertyId = GeelyProperties.DoorPosFrontLeft.propertyId,
            areaId = GeelyProperties.DoorPosFrontLeft.areaId,
            pollingIntervalMillis = 1_000L
        ),
        SignalSpec(
            signalId = SignalKey.DOOR_POS_FRONT_RIGHT,
            propertyId = GeelyProperties.DoorPosFrontRight.propertyId,
            areaId = GeelyProperties.DoorPosFrontRight.areaId,
            pollingIntervalMillis = 1_000L
        ),
        SignalSpec(
            signalId = SignalKey.DOOR_POS_REAR_LEFT,
            propertyId = GeelyProperties.DoorPosRearLeft.propertyId,
            areaId = GeelyProperties.DoorPosRearLeft.areaId,
            pollingIntervalMillis = 1_000L
        ),
        SignalSpec(
            signalId = SignalKey.DOOR_POS_REAR_RIGHT,
            propertyId = GeelyProperties.DoorPosRearRight.propertyId,
            areaId = GeelyProperties.DoorPosRearRight.areaId,
            pollingIntervalMillis = 1_000L
        ),
        SignalSpec(
            signalId = SignalKey.BCM_HOOD_STATUS,
            propertyId = GeelyProperties.BcmHoodStatus.propertyId,
            pollingIntervalMillis = 1_000L
        ),
        SignalSpec(
            signalId = SignalKey.BODY_DOOR_TRUNK_DOOR_POS,
            propertyId = GeelyProperties.BodyDoorTrunkDoorPos.propertyId,
            pollingIntervalMillis = 1_000L
        ),
        SignalSpec(
            signalId = SignalKey.LOCK_HOOD,
            propertyId = GeelyProperties.LockHood.propertyId,
            pollingIntervalMillis = 1_000L
        ),
        SignalSpec(
            signalId = SignalKey.BODY_BUCKLE_SWITCH_STATUS,
            propertyId = GeelyProperties.BodyBuckleSwitchStatus.propertyId,
            pollingIntervalMillis = 1_000L
        ),
        SignalSpec(
            signalId = SignalKey.ACU_PASS_SEAT_OCCUPANT_SENSOR_ST,
            propertyId = GeelyProperties.AcuPassSeatOccupantSensorStatus.propertyId,
            pollingIntervalMillis = 1_000L
        ),
        SignalSpec(
            signalId = SignalKey.IPKWARN_DRV_SEAT_BELT,
            propertyId = GeelyProperties.IpkWarnDriverSeatBelt.propertyId,
            pollingIntervalMillis = 1_000L
        ),
        SignalSpec(
            signalId = SignalKey.IPKWARN_PASS_SEAT_BELT,
            propertyId = GeelyProperties.IpkWarnPassengerSeatBelt.propertyId,
            pollingIntervalMillis = 1_000L
        ),
        SignalSpec(
            signalId = SignalKey.ACU_DRV_SEAT_BELT_BUCKLE_INVALID,
            propertyId = GeelyProperties.AcuDriverSeatBeltBuckleInvalid.propertyId,
            pollingIntervalMillis = 1_000L
        ),
        SignalSpec(
            // Read through the ECARX ignition-state sensor so the value decodes
            // to ISensorEvent.IGNITION_STATE_* (e.g. IGNITION_STATE_ON =
            // 0x200105 = 2097413) instead of the ambiguous raw VHAL enum (1).
            // Falls back to the raw 0x2140A331 read if the wrapper is absent.
            signalId = SignalKey.PEPS_POWER_MODE,
            propertyId = GeelyProperties.PepsPowerMode.propertyId,
            ecarxLogicalId = GeelyProperties.IgnitionStateSensorLogical,
            ecarxIdType = ECARX_ID_TYPE_SENSOR,
            adaptEcarxValue = true,
            pollingIntervalMillis = 1_000L
        ),
        SignalSpec(
            signalId = SignalKey.PEPS_POWER_MODE_VAILD,
            propertyId = GeelyProperties.PepsPowerModeValid.propertyId,
            pollingIntervalMillis = 1_000L
        ),
        SignalSpec(
            // Usage mode is the real "authenticated key present" signal: the
            // adapt value decodes to ISensorEvent.USG_MODE_* (ACTV/DRKVG =
            // key in cabin). Falls back to raw 0x2140A822 if wrapper is absent.
            signalId = SignalKey.PEPS_USAGE_MODE,
            propertyId = GeelyProperties.PepsUsageMode.propertyId,
            ecarxLogicalId = GeelyProperties.UsageModeSensorLogical,
            ecarxIdType = ECARX_ID_TYPE_SENSOR,
            adaptEcarxValue = true,
            pollingIntervalMillis = 1_000L
        ),
        SignalSpec(
            signalId = SignalKey.PEPS_USAGE_MODE_VALIDITY,
            propertyId = GeelyProperties.PepsUsageModeValidity.propertyId,
            pollingIntervalMillis = 1_000L
        ),
        SignalSpec(
            signalId = SignalKey.PEPS_REMOTE_CTL_STS,
            propertyId = GeelyProperties.PepsRemoteControlStatus.propertyId,
            pollingIntervalMillis = 1_000L
        ),
        SignalSpec(
            signalId = SignalKey.PEPS_RESPONSE_STS,
            propertyId = GeelyProperties.PepsResponseStatus.propertyId,
            pollingIntervalMillis = 1_000L
        )

        // The IHU629G instantaneous-consumption candidates (BMSH/VCU/IPU/GCU/
        // IPK signals) were collected here for a while but read a constant
        // zero on the car, so they were dropped from routine collection.
        // They remain in GeelyProperties/PropertyConfigInspector for
        // re-probing after firmware updates.

        // The IHU629G instantaneous-consumption candidates (BMSH/VCU/IPU/GCU/
        // IPK signals) were collected here for a while but read a constant
        // zero on the car, so they were dropped from routine collection.
        // They remain in GeelyProperties for re-probing after a firmware update.
    )
}
