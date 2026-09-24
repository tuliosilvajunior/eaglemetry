package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.roadcast.RoadcastSample
import com.timhss.capyenergy.roadcast.RoadcastSnapshot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RoadcastTripMetricsProviderTest {
    @Test
    fun readsOnlyCalibratedAndPlausibleTripMetrics() {
        val metrics = RoadcastTripMetricsProvider.read(snapshot(
            RoadcastTripMetricsProvider.DRIVE_POWER to sample(12.3),
            RoadcastTripMetricsProvider.PACK_VOLTAGE to sample(397.8),
            RoadcastTripMetricsProvider.PACK_CURRENT to sample(-18.4),
            RoadcastTripMetricsProvider.VEHICLE_SPEED to sample(87.6),
            RoadcastTripMetricsProvider.VEHICLE_SPEED_INVALID to sample(0.0),
        ))

        assertEquals(12.3f, metrics.drivePowerKw)
        assertEquals(397.8f, metrics.packVoltageV)
        assertEquals(-18.4f, metrics.packCurrentA)
        assertEquals(false, metrics.packCurrentEstimated)
        assertEquals(87.6f, metrics.vehicleSpeedKmh)
    }

    @Test
    fun rejectsVehicleSpeedWhenEscInvalidBitIsSetOrMissing() {
        val invalid = RoadcastTripMetricsProvider.read(snapshot(
            RoadcastTripMetricsProvider.VEHICLE_SPEED to sample(87.6),
            RoadcastTripMetricsProvider.VEHICLE_SPEED_INVALID to sample(1.0),
        ))
        val missingInvalidBit = RoadcastTripMetricsProvider.read(snapshot(
            RoadcastTripMetricsProvider.VEHICLE_SPEED to sample(87.6),
        ))

        assertNull(invalid.vehicleSpeedKmh)
        assertNull(missingInvalidBit.vehicleSpeedKmh)
    }

    @Test
    fun rejectsInvalidUncalibratedAndImplausibleValuesIndependently() {
        val metrics = RoadcastTripMetricsProvider.read(snapshot(
            RoadcastTripMetricsProvider.DRIVE_POWER to sample(900.0),
            RoadcastTripMetricsProvider.PACK_VOLTAGE to sample(398.0, calibrated = false),
            RoadcastTripMetricsProvider.VEHICLE_SPEED to sample(300.0),
        ))

        assertNull(metrics.drivePowerKw)
        assertNull(metrics.packVoltageV)
        assertNull(metrics.vehicleSpeedKmh)
    }

    @Test
    fun estimatesUncalibratedPackCurrentFromDocumentedRawEncoding() {
        val metrics = RoadcastTripMetricsProvider.read(snapshot(
            RoadcastTripMetricsProvider.PACK_CURRENT to sample(
                physical = 4979.0,
                calibrated = false,
                raw = 4979L,
            ),
        ))

        assertEquals(-2.3f, metrics.packCurrentA!!, 0.001f)
        assertEquals(true, metrics.packCurrentEstimated)
    }

    /**
     * The measured zero reports no pack current, and it is the same count the
     * Roadcast catalog puts its offset on, so the calibrated and the fallback
     * decode agree.
     */
    @Test
    fun uncalibratedPackCurrentIsZeroAtTheMeasuredZeroCount() {
        val metrics = RoadcastTripMetricsProvider.read(snapshot(
            RoadcastTripMetricsProvider.PACK_CURRENT to sample(
                physical = 5002.0,
                calibrated = false,
                raw = 5002L,
            ),
        ))

        assertEquals(0f, metrics.packCurrentA!!, 0.001f)
    }

    /**
     * `TotDrvPwrAct` is uncalibrated, so its documented 0.1 kW / -102.4 encoding
     * is applied to the raw count and the raw count is kept. Zero power sits at
     * raw 1 024.
     *
     * No car this runs on has ever delivered the frame, so this test guards a
     * decode that production never exercises. That is deliberate: it keeps a
     * null column meaning "the bus was silent" rather than "the decode rotted
     * while nobody was looking".
     */
    @Test
    fun estimatesUncalibratedTotalDrivePowerAndKeepsTheRawCount() {
        val zero = RoadcastTripMetricsProvider.read(snapshot(
            RoadcastTripMetricsProvider.TOTAL_DRIVE_POWER to sample(
                physical = 0.0,
                calibrated = false,
                raw = 1_024L,
            ),
        ))
        val driving = RoadcastTripMetricsProvider.read(snapshot(
            RoadcastTripMetricsProvider.TOTAL_DRIVE_POWER to sample(
                physical = 0.0,
                calibrated = false,
                raw = 1_224L,
            ),
        ))

        assertEquals(0.0f, zero.totalDrivePowerKw!!, 0.001f)
        assertEquals(1_024L, zero.totalDrivePowerRaw)
        assertEquals(20.0f, driving.totalDrivePowerKw!!, 0.001f)
        assertEquals(1_224L, driving.totalDrivePowerRaw)
    }

    @Test
    fun readsTheChargerInputOnlyWhenCalibratedAndPlausible() {
        val ok = RoadcastTripMetricsProvider.read(snapshot(
            RoadcastTripMetricsProvider.AC_INPUT_VOLTAGE to sample(219.3),
            RoadcastTripMetricsProvider.AC_INPUT_CURRENT to sample(7.7),
        ))
        val rejected = RoadcastTripMetricsProvider.read(snapshot(
            RoadcastTripMetricsProvider.AC_INPUT_VOLTAGE to sample(219.3, calibrated = false),
            RoadcastTripMetricsProvider.AC_INPUT_CURRENT to sample(900.0),
        ))

        assertEquals(219.3f, ok.acInputVoltageV)
        assertEquals(7.7f, ok.acInputCurrentA)
        assertNull(rejected.acInputVoltageV)
        assertNull(rejected.acInputCurrentA)
    }

    /**
     * The new signals must not disturb the ones the energy integral depends on.
     * A snapshot without them still reads a complete power triple.
     */
    @Test
    fun theEnergyTripleSurvivesAbsentInstrumentation() {
        val metrics = RoadcastTripMetricsProvider.read(snapshot(
            RoadcastTripMetricsProvider.DRIVE_POWER to sample(12.3),
            RoadcastTripMetricsProvider.PACK_VOLTAGE to sample(397.8),
            RoadcastTripMetricsProvider.PACK_CURRENT to sample(-18.4),
        ))

        assertEquals(12.3f, metrics.drivePowerKw)
        assertEquals(397.8f, metrics.packVoltageV)
        assertEquals(-18.4f, metrics.packCurrentA)
        assertNull(metrics.totalDrivePowerKw)
        assertNull(metrics.acInputVoltageV)
    }

    /**
     * The raw counts are kept whether or not the daemon has a scale, because
     * their purpose is to make a scale found later applicable to drives
     * recorded today. The scaled companion still obeys the calibration rule.
     */
    @Test
    fun keepsRawCountsOfAssumedScaleSignalsWithoutScalingThem() {
        val metrics = RoadcastTripMetricsProvider.read(snapshot(
            RoadcastTripMetricsProvider.DRIVE_POWER to sample(
                physical = -0.8,
                calibrated = false,
                raw = 2032L,
            ),
            RoadcastTripMetricsProvider.THERMAL_POWER to sample(0.0, calibrated = false, raw = 7L),
            RoadcastTripMetricsProvider.DCDC_POWER to sample(0.0, calibrated = false, raw = 1L),
        ))

        assertEquals(2032L, metrics.drivePowerRaw)
        assertEquals(7L, metrics.thermalPowerRaw)
        assertEquals(1L, metrics.dcDcPowerRaw)
        assertNull(metrics.drivePowerKw)
    }

    @Test
    fun readsRoadLoadAndDriverIntentSignals() {
        val metrics = RoadcastTripMetricsProvider.read(snapshot(
            RoadcastTripMetricsProvider.ROAD_INCLINE to sample(3.4, raw = 1034L),
            RoadcastTripMetricsProvider.REGEN_TORQUE to sample(-42.0, raw = 4000L),
            RoadcastTripMetricsProvider.ACCEL_PEDAL to sample(18.5),
            RoadcastTripMetricsProvider.ACCEL_PEDAL_INVALID to sample(0.0, raw = 0L),
            RoadcastTripMetricsProvider.REGEN_LEVEL to sample(3.0, raw = 3L),
        ))

        assertEquals(3.4f, metrics.roadInclinePercent)
        assertEquals(1034L, metrics.roadInclineRaw)
        assertEquals(-42.0f, metrics.regenTorqueNm)
        assertEquals(4000L, metrics.regenTorqueRaw)
        assertEquals(18.5f, metrics.accelPedalPercent)
        assertEquals(false, metrics.accelPedalInvalid)
        assertEquals(3, metrics.regenLevel)
    }

    /**
     * The brake switch keeps its value when its `Invalid` companion never
     * arrives, unlike vehicle speed. `ESC_BrakePedalSwitchInvalid` has never
     * published on this head unit, so the speed rule would null the column
     * permanently.
     */
    @Test
    fun keepsBrakeStateWhenItsInvalidCompanionNeverPublishes() {
        val metrics = RoadcastTripMetricsProvider.read(snapshot(
            RoadcastTripMetricsProvider.BRAKE_PEDAL to sample(1.0, calibrated = false, raw = 1L),
        ))

        assertEquals(true, metrics.brakePedalOn)
    }

    /** A companion that does arrive and says the value is bad still rejects it. */
    @Test
    fun dropsBrakeStateWhenItsInvalidCompanionIsSet() {
        val metrics = RoadcastTripMetricsProvider.read(snapshot(
            RoadcastTripMetricsProvider.BRAKE_PEDAL to sample(1.0, calibrated = false, raw = 1L),
            RoadcastTripMetricsProvider.BRAKE_PEDAL_INVALID to sample(
                1.0,
                calibrated = false,
                raw = 1L,
            ),
        ))

        assertNull(metrics.brakePedalOn)
    }

    /**
     * The climate states and the drive mode are read as raw counts, so an
     * uncalibrated daemon still fills them. Only the cabin setpoint carries a
     * scale, and it is therefore the only one of the six that waits for the
     * daemon to declare one.
     */
    @Test
    fun readsClimateStatesAndDriveModeWithoutRequiringCalibration() {
        val metrics = RoadcastTripMetricsProvider.read(snapshot(
            RoadcastTripMetricsProvider.CLIMATE_ON to sample(1.0, calibrated = false, raw = 1L),
            RoadcastTripMetricsProvider.CLIMATE_COMPRESSOR to
                sample(0.0, calibrated = false, raw = 0L),
            RoadcastTripMetricsProvider.BLOWER_LEVEL to sample(6.0, calibrated = false, raw = 6L),
            RoadcastTripMetricsProvider.REAR_DEFROSTER to sample(1.0, calibrated = false, raw = 1L),
            RoadcastTripMetricsProvider.DRIVE_MODE to sample(2.0, calibrated = false, raw = 2L),
            RoadcastTripMetricsProvider.CABIN_SETPOINT to sample(22.5, raw = 14L),
        ))

        assertEquals(true, metrics.climateOn)
        assertEquals(false, metrics.climateCompressorOn)
        assertEquals(6, metrics.blowerLevel)
        assertEquals(1, metrics.rearDefrosterState)
        assertEquals(2, metrics.driveMode)
        assertEquals(22.5f, metrics.cabinSetpointC)
    }

    /**
     * The head unit offers 15.5 to 28.5 degC. A value outside that band is not
     * this signal, and an uncalibrated sample carries no scale at all, so the
     * raw count must not reach the column as if it were degrees.
     */
    @Test
    fun rejectsCabinSetpointOutsideTheHeadUnitBandOrWithoutAScale() {
        val tooWarm = RoadcastTripMetricsProvider.read(snapshot(
            RoadcastTripMetricsProvider.CABIN_SETPOINT to sample(31.0, raw = 31L),
        ))
        val uncalibrated = RoadcastTripMetricsProvider.read(snapshot(
            RoadcastTripMetricsProvider.CABIN_SETPOINT to
                sample(24.0, calibrated = false, raw = 24L),
        ))

        assertNull(tooWarm.cabinSetpointC)
        assertNull(uncalibrated.cabinSetpointC)
    }

    /**
     * A count the vehicle assigns no meaning to is still a fact about the car
     * and must be stored. Only a count the field cannot hold is refused.
     */
    @Test
    fun keepsAnUnassignedLevelButRefusesOneTheFieldCannotHold() {
        val unassigned = RoadcastTripMetricsProvider.read(snapshot(
            RoadcastTripMetricsProvider.DRIVE_MODE to sample(5.0, calibrated = false, raw = 5L),
        ))
        val impossible = RoadcastTripMetricsProvider.read(snapshot(
            RoadcastTripMetricsProvider.DRIVE_MODE to sample(9.0, calibrated = false, raw = 9L),
        ))

        assertEquals(5, unassigned.driveMode)
        assertNull(impossible.driveMode)
    }

    private fun snapshot(vararg entries: Pair<String, RoadcastSample>) = RoadcastSnapshot(
        sampleSequence = 1L,
        receivedAtElapsedNanos = 10L,
        sampleAgeNanos = 2L,
        samples = mapOf(*entries),
        missingSignals = emptySet(),
    )

    private fun sample(
        physical: Double,
        calibrated: Boolean = true,
        raw: Long = physical.toLong(),
    ) = RoadcastSample(
        raw = raw,
        physical = physical,
        valid = true,
        calibrated = calibrated,
        lastChangeNanos = 1L,
    )
}
