package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey

import com.timhss.capyenergy.concurrent.namedSingleThreadExecutor
import com.timhss.capyenergy.profile.GeelyProfile
import com.timhss.capyenergy.profile.VehicleProfile
import com.timhss.capyenergy.roadcast.RoadcastCadence
import com.timhss.capyenergy.roadcast.RoadcastRepository
import com.timhss.capyenergy.roadcast.RoadcastSignalProvider
import com.timhss.capyenergy.roadcast.RoadcastSnapshot
import com.timhss.capyenergy.roadcast.RoadcastSnapshotState
import com.timhss.capyenergy.roadcast.RoadcastSubscription
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

/** Validated CAN readings copied into active trip and charge frames. */
data class RoadcastTripMetrics(
    val drivePowerKw: Float?,
    val packVoltageV: Float?,
    val packCurrentA: Float?,
    val packCurrentRaw: Long?,
    val packCurrentEstimated: Boolean?,
    /**
     * Diagnostic only. Nothing consumes this: the energy integral and the
     * efficiency card read the VHAL's `VEHICLE_SPEED` instead — see
     * [com.timhss.capyenergy.telemetry.FrameRepository]. Kept so the Trace
     * screen can still show what the bus says, and so a later repair of the
     * signal can be measured against the source that replaced it.
     */
    val vehicleSpeedKmh: Float?,
    /**
     * The second drive-power signal, on its own frame. Recorded to settle which
     * of the two is correctly scaled — see [RoadcastTripMetricsProvider].
     *
     * Defaulted because nothing outside that question reads these: a caller
     * building metrics for the energy path should not have to name them.
     */
    val totalDrivePowerKw: Float? = null,
    val totalDrivePowerRaw: Long? = null,
    /** The charger's own measurement of what it is drawing from the mains. */
    val acInputVoltageV: Float? = null,
    val acInputCurrentA: Float? = null,
    /**
     * Signal Lab stage 1. The road-load terms the energy model has never had,
     * and the raw counts behind three power signals whose scale is assumed.
     *
     * Defaulted for the same reason as [totalDrivePowerKw]: a caller building
     * metrics for the energy path should not have to name a diagnostic.
     *
     * The three `*Raw` counts carry no scaled companion: the scale is
     * unknown or assumed, and a count stored today can be rescaled later.
     */
    val roadInclinePercent: Float? = null,
    val roadInclineRaw: Long? = null,
    val brakePedalOn: Boolean? = null,
    val regenTorqueNm: Float? = null,
    val regenTorqueRaw: Long? = null,
    val accelPedalPercent: Float? = null,
    val accelPedalInvalid: Boolean? = null,
    val regenLevel: Int? = null,
    /**
     * Climate power, in kW, once the daemon carries a verified scale for it.
     *
     * The parked bench on 2026-08-08 measured 0.08 kW per count over 89 samples
     * spanning counts 0 to 32, R2 0.9945, and the compressor was confirmed off
     * throughout, so the signal is electrical rather than thermal output. That
     * calibration belongs in the Roadcast catalog, not here: this stays null
     * until the daemon publishes the signal as calibrated, exactly as
     * [DRIVE_POWER] does. Applying the scale in the app would give the app and
     * the daemon two answers for one signal.
     *
     * Two limits travel with the number, both recorded in
     * The counter has a deadband of
     * roughly 100 W, and in cooling it under-declares the package by about 39 %
     * because something outside the counter — the condenser fan is the
     * candidate — runs with the compressor. The remainder lands in the system
     * share, which is where an unattributed load belongs.
     */
    val thermalPowerKw: Float? = null,
    val thermalPowerRaw: Long? = null,
    val dcDcPowerRaw: Long? = null,
    val drivePowerRaw: Long? = null,
    /**
     * What the driver asked the climate system for, and what the compressor is
     * doing about it.
     *
     * These say why the thermal and DC-DC counts moved. Climate power alone
     * reports an amount; these report the demand behind it, so a heavy minute
     * can be read as "the cabin was set to 28.5 with the blower at 8" instead
     * of as an unexplained load. [climateCompressorOn] separates cooling from
     * heating, which is the split the bench on 2026-08-08 could only hold
     * fixed rather than measure.
     *
     * They are recorded on charges as well as on trips: the climate system
     * runs while the car is plugged in, and that load lands on the charge.
     */
    val climateOn: Boolean? = null,
    val climateCompressorOn: Boolean? = null,
    val blowerLevel: Int? = null,
    val cabinSetpointC: Float? = null,
    val rearDefrosterState: Int? = null,
    /**
     * The drive mode the body controller reports: 0 NORMAL, 1 ECO, 2 SPORT.
     *
     * Read from `BCM_DM_TargetModeReq` and not from the `VCU_ePTMode` pair,
     * which carries a different enumeration and is not calibrated. Trip-only,
     * with [regenLevel], for the reason given above [roadInclinePercent].
     *
     * Stored as the count. Nothing here maps it to a name: a mapping is a
     * presentation choice, and a count kept today survives a correction to
     * that mapping.
     */
    val driveMode: Int? = null,
    val receivedAtElapsedNanos: Long,
    val sourceAgeNanos: Long,
)

/**
 * The CAN readings frames carry.
 *
 * Five of these serve the energy integral. The last three were added to settle
 * a suspected 3.5 % scale error between [DRIVE_POWER] and the pack pair. That
 * error turned out not to exist, so read what follows before trusting any of
 * the three.
 *
 * The suspicion came from regressing pack power on [DRIVE_POWER], which gave a
 * slope near 0.97 in traction *and* in regeneration; a deficit in both
 * directions looked like scale rather than loss. It was neither. Least squares
 * assumes the regressor is exact, and [DRIVE_POWER] carries sampling jitter of
 * its own, which biases the slope toward zero **in both directions**. Fitting
 * the reverse direction and inverting brackets the true traction slope at
 * [1.000, 1.014] on car data from 2026-08-05. There is nothing to correct.
 *
 * What that leaves:
 *
 *  * [TOTAL_DRIVE_POWER] never arrives. Frame `0x29B` is in the negotiated
 *    schema but is not transmitted to this head unit — all six of its signals
 *    report `first_ns=0` after a full drive. It is read here so the absence
 *    stays visible in recorded data rather than becoming folklore; the column
 *    is expected to be null.
 *  * [AC_INPUT_VOLTAGE] and [AC_INPUT_CURRENT] are worth keeping. They are the
 *    charger's own measurement of the mains, calibrated, and they replace the
 *    VHAL pair that reported a physically impossible 99.9 % charger efficiency.
 *    They give the only trustworthy charge-side reference the app has.
 *
 */
object RoadcastTripMetricsProvider : RoadcastSignalProvider<RoadcastTripMetrics> {

    private val profile: VehicleProfile = GeelyProfile

    // The names come from the profile. A CAN signal name is a statement about
    // one vehicle, and layer 0 is where it belongs; what stays here is how a
    // sample is judged once it arrives.
    private fun name(key: SignalKey): String = profile.busSignals.getValue(key).signalName

    private fun companion(key: SignalKey): String? = profile.busSignals[key]?.invalidCompanion

    private fun band(key: SignalKey): ClosedFloatingPointRange<Float>? =
        profile.declarationFor(key)?.band?.let { it.min.toFloat()..it.max.toFloat() }

    val DRIVE_POWER: String get() = name(SignalKey.PACK_POWER_DRIVE)
    val PACK_VOLTAGE: String get() = name(SignalKey.PACK_VOLTAGE)
    val PACK_CURRENT: String get() = name(SignalKey.PACK_CURRENT)
    val VEHICLE_SPEED: String get() = name(SignalKey.BUS_VEHICLE_SPEED)
    val VEHICLE_SPEED_INVALID: String get() = companion(SignalKey.BUS_VEHICLE_SPEED)!!
    val TOTAL_DRIVE_POWER: String get() = name(SignalKey.TOTAL_DRIVE_POWER)
    val AC_INPUT_VOLTAGE: String get() = name(SignalKey.AC_INPUT_VOLTAGE)
    val AC_INPUT_CURRENT: String get() = name(SignalKey.AC_INPUT_CURRENT)
    val ROAD_INCLINE: String get() = name(SignalKey.ROAD_INCLINE)
    val BRAKE_PEDAL: String get() = name(SignalKey.BRAKE_PEDAL)
    val BRAKE_PEDAL_INVALID: String get() = companion(SignalKey.BRAKE_PEDAL)!!
    val REGEN_TORQUE: String get() = name(SignalKey.REGEN_TORQUE)
    val ACCEL_PEDAL: String get() = name(SignalKey.ACCEL_PEDAL)
    val ACCEL_PEDAL_INVALID: String get() = companion(SignalKey.ACCEL_PEDAL)!!
    val REGEN_LEVEL: String get() = name(SignalKey.REGEN_LEVEL)
    val THERMAL_POWER: String get() = name(SignalKey.THERMAL_POWER)
    val DCDC_POWER: String get() = name(SignalKey.DCDC_POWER)
    val CLIMATE_ON: String get() = name(SignalKey.CLIMATE_ON)
    val CLIMATE_COMPRESSOR: String get() = name(SignalKey.CLIMATE_COMPRESSOR)
    val BLOWER_LEVEL: String get() = name(SignalKey.BLOWER_LEVEL)
    val CABIN_SETPOINT: String get() = name(SignalKey.CABIN_SETPOINT)
    val REAR_DEFROSTER: String get() = name(SignalKey.REAR_DEFROSTER)
    val DRIVE_MODE: String get() = name(SignalKey.DRIVE_MODE)

    /**
     * Every name this provider asks the daemon to negotiate: the signals the
     * profile binds to the bus, plus the `*Invalid` companions that travel with
     * them. A companion is not a signal of its own — it is the bus's claim
     * about the one beside it — so it has no key and is added here.
     */
    override val requiredSignals: Set<String> =
        profile.busSignals.values.map { it.signalName }.toSet() +
            profile.busSignals.values.mapNotNull { it.invalidCompanion }.toSet()

    override fun read(snapshot: RoadcastSnapshot): RoadcastTripMetrics {
        val current = packCurrent(snapshot)
        val totalDrive = totalDrivePower(snapshot)
        return RoadcastTripMetrics(
            drivePowerKw = calibrated(snapshot, DRIVE_POWER)?.takeIf { it in band(SignalKey.PACK_POWER_DRIVE)!! },
            packVoltageV = calibrated(snapshot, PACK_VOLTAGE)?.takeIf { it in band(SignalKey.PACK_VOLTAGE)!! },
            packCurrentA = current?.amps,
            packCurrentRaw = current?.raw,
            packCurrentEstimated = current?.estimated,
            vehicleSpeedKmh = calibrated(
                snapshot,
                VEHICLE_SPEED,
                invalidCompanion = VEHICLE_SPEED_INVALID,
            )?.takeIf { it in band(SignalKey.BUS_VEHICLE_SPEED)!! },
            totalDrivePowerKw = totalDrive?.kw,
            totalDrivePowerRaw = totalDrive?.raw,
            acInputVoltageV = calibrated(snapshot, AC_INPUT_VOLTAGE)?.takeIf { it in band(SignalKey.AC_INPUT_VOLTAGE)!! },
            acInputCurrentA = calibrated(snapshot, AC_INPUT_CURRENT)?.takeIf { it in band(SignalKey.AC_INPUT_CURRENT)!! },
            roadInclinePercent = calibrated(snapshot, ROAD_INCLINE)?.takeIf { it in band(SignalKey.ROAD_INCLINE)!! },
            roadInclineRaw = rawCount(snapshot, ROAD_INCLINE),
            brakePedalOn = flag(snapshot, BRAKE_PEDAL, invalidCompanion = BRAKE_PEDAL_INVALID),
            regenTorqueNm = calibrated(snapshot, REGEN_TORQUE)?.takeIf { it in band(SignalKey.REGEN_TORQUE)!! },
            regenTorqueRaw = rawCount(snapshot, REGEN_TORQUE),
            accelPedalPercent = calibrated(
                snapshot,
                ACCEL_PEDAL,
                invalidCompanion = ACCEL_PEDAL_INVALID,
            )?.takeIf { it in band(SignalKey.ACCEL_PEDAL)!! },
            accelPedalInvalid = flag(snapshot, ACCEL_PEDAL_INVALID),
            regenLevel = level(snapshot, REGEN_LEVEL, 15L),
            // The bench maximum is 20.4 kW at the top of the 8-bit count, so a
            // reading outside this band is not this signal.
            thermalPowerKw = thermalPower(snapshot),
            thermalPowerRaw = rawCount(snapshot, THERMAL_POWER),
            dcDcPowerRaw = rawCount(snapshot, DCDC_POWER),
            drivePowerRaw = rawCount(snapshot, DRIVE_POWER),
            // Five states and a level, all read as raw counts. A state has no
            // scale to verify, so its decode is the identity and [calibrated]
            // would reject it on any daemon that has not been told to say so.
            // The bound beside each one is the field width, not a judgement:
            // it only rejects a sample that cannot be this signal.
            climateOn = flag(snapshot, CLIMATE_ON),
            climateCompressorOn = flag(snapshot, CLIMATE_COMPRESSOR),
            blowerLevel = level(snapshot, BLOWER_LEVEL, 15L),
            // The setpoint is the one climate signal with a real scale, so it
            // is the one that must come from the daemon. 15.5 to 28.5 degC is
            // what the head unit offers; a reading outside it is not this
            // signal.
            cabinSetpointC = calibrated(snapshot, CABIN_SETPOINT)?.takeIf { it in band(SignalKey.CABIN_SETPOINT)!! },
            rearDefrosterState = level(snapshot, REAR_DEFROSTER, 3L),
            driveMode = level(snapshot, DRIVE_MODE, 7L),
            receivedAtElapsedNanos = snapshot.receivedAtElapsedNanos,
            sourceAgeNanos = snapshot.sampleAgeNanos,
        )
    }

    /**
     * [TOTAL_DRIVE_POWER] with the scale the DBC documents but Roadcast has not
     * verified, so the raw count is kept beside it.
     *
     * In practice this returns null on every frame, because `0x29B` does not
     * reach this head unit. The decode is kept correct anyway: the frame exists
     * on other builds of this platform, and a null here should mean "the bus
     * was silent", never "the app could not read it". If a raw count ever does
     * appear, it must sit at 1 024 with the drivetrain idle — that is where this
     * offset puts zero, and a standstill saying otherwise invalidates the
     * assumed scale rather than the signal.
     */
    private fun totalDrivePower(snapshot: RoadcastSnapshot): TotalDrivePower? {
        val sample = snapshot.sample(TOTAL_DRIVE_POWER) ?: return null
        if (!sample.valid) return null
        val kw = if (sample.calibrated) {
            sample.physical.toFloat()
        } else {
            (sample.raw * TOTAL_DRIVE_KW_PER_BIT + TOTAL_DRIVE_OFFSET_KW).toFloat()
        }
        if (!kw.isFinite() || kw !in band(SignalKey.TOTAL_DRIVE_POWER)!!) return null
        return TotalDrivePower(kw = kw, raw = sample.raw)
    }

    private fun thermalPower(snapshot: RoadcastSnapshot): Float? {
        val sample = snapshot.sample(THERMAL_POWER) ?: return null
        if (!sample.valid) return null
        val kw = if (sample.calibrated) {
            sample.physical.toFloat()
        } else {
            (sample.raw * THERMAL_POWER_KW_PER_BIT).toFloat()
        }
        if (!kw.isFinite() || kw !in band(SignalKey.THERMAL_POWER)!!) return null
        return kw
    }

    private fun packCurrent(snapshot: RoadcastSnapshot): PackCurrent? {
        val sample = snapshot.sample(PACK_CURRENT) ?: return null
        if (!sample.valid) return null
        val amps = if (sample.calibrated) {
            sample.physical.toFloat()
        } else {
            ((sample.raw - BATT_CURRENT_ZERO_COUNT) * BATT_CURRENT_AMPS_PER_BIT).toFloat()
        }
        if (!amps.isFinite() || amps !in band(SignalKey.PACK_CURRENT)!!) return null
        return PackCurrent(
            amps = amps,
            raw = sample.raw,
            estimated = !sample.calibrated,
        )
    }

    private fun calibrated(
        snapshot: RoadcastSnapshot,
        name: String,
        invalidCompanion: String? = null,
    ): Float? {
        val sample = snapshot.sample(name) ?: return null
        if (!sample.valid || !sample.calibrated) return null
        if (invalidCompanion != null) {
            val invalid = snapshot.sample(invalidCompanion) ?: return null
            if (!invalid.valid || invalid.raw != 0L) return null
        }
        return sample.physical.toFloat().takeIf { it.isFinite() }
    }

    /**
     * The raw count, with no scale applied and none assumed.
     *
     * [calibrated] returns null unless the daemon has a verified scale, which is
     * right for a number the app publishes. It is wrong for a number the app
     * only stores: a raw count kept today is what lets a scale found next month
     * be applied to this month's drives instead of re-logging them. So this
     * asks only that the sample be valid.
     *
     * Nothing may print the result as a measurement.
     */
    private fun rawCount(snapshot: RoadcastSnapshot, name: String): Long? =
        snapshot.sample(name)?.takeIf { it.valid }?.raw

    /**
     * A small enumerated count — a level, a mode, a multi-state switch.
     *
     * Read through [rawCount] rather than [calibrated] for the reason given
     * there: the decode of an enumeration is the identity, so there is no
     * scale for the daemon to verify and requiring one would null the column
     * on every daemon build that has not been told to declare it.
     *
     * [maximum] is the largest value the field can hold, so this rejects only
     * a sample that cannot be this signal. It does not check that the count is
     * one the vehicle assigns a meaning to: an unassigned count is a fact
     * about the car and must reach storage rather than be silently dropped.
     */
    private fun level(snapshot: RoadcastSnapshot, name: String, maximum: Long): Int? =
        rawCount(snapshot, name)?.takeIf { it in 0L..maximum }?.toInt()

    /**
     * A one-bit state, read as a raw count because a switch has no scale to
     * verify and [calibrated] would therefore reject every sample of it.
     *
     * The companion rule is deliberately weaker here than in [calibrated],
     * which rejects a value whose `*Invalid` companion is **missing** as well as
     * one whose companion is set. That is right for speed, where the companion
     * arrives on every frame. It is wrong for the brake switch:
     * `ESC_BrakePedalSwitchInvalid` has never published on this head unit, so
     * the strict rule would null the column for the life of the feature while
     * `ESC_BrakePedalSwitchStatus` itself publishes normally.
     *
     * So a missing companion is accepted and a *set* companion still rejects.
     * The cost is that the validity of the brake state is unverified, which is
     * why it may gate a diagnostic and must not gate a published measurement.
     * If the companion ever starts publishing, tighten this back to
     * [calibrated]'s rule.
     */
    private fun flag(
        snapshot: RoadcastSnapshot,
        name: String,
        invalidCompanion: String? = null,
    ): Boolean? {
        val sample = snapshot.sample(name)?.takeIf { it.valid } ?: return null
        if (invalidCompanion != null) {
            val invalid = snapshot.sample(invalidCompanion)
            if (invalid != null && invalid.valid && invalid.raw != 0L) return null
        }
        return sample.raw != 0L
    }

    private data class PackCurrent(
        val amps: Float,
        val raw: Long,
        val estimated: Boolean,
    )

    private data class TotalDrivePower(
        val kw: Float,
        val raw: Long,
    )

    /**
     * The zero of the uncalibrated fallback, measured rather than assumed.
     *
     * Twenty-two closed trips from 2026-08-03 to 2026-08-06 fix it at raw 5 002:
     * integrating the pack current over a trip and comparing the result against
     * the state-of-charge drop times the pack capacity leaves the zero as the
     * only free parameter, and sweeping it puts the mean ratio at 1.004 here,
     * against 0.966 at raw 5 005 and 1.029 at raw 5 000.
     *
     * It matches the offset the Roadcast catalog now carries, which is the point:
     * this path runs only when the daemon reports the sample uncalibrated, and a
     * fallback that disagreed with the calibrated decode would put a step into
     * the integral at the moment calibration appeared or went away.
     */
    private const val BATT_CURRENT_ZERO_COUNT = 5_002L
    private const val BATT_CURRENT_AMPS_PER_BIT = 0.1

    /** Documented for `0x29B` but not verified on car; see [totalDrivePower]. */
    private const val TOTAL_DRIVE_KW_PER_BIT = 0.1
    private const val TOTAL_DRIVE_OFFSET_KW = -102.4

    /** Bench calibration of 2026-08-08 (0.08 kW / bit, R2 0.9945). */
    private const val THERMAL_POWER_KW_PER_BIT = 0.08
}

/**
 * Keeps the newest validated CAN frame metrics in RAM; Room never polls CAN.
 *
 * Two consumers with different appetites read this one subscription. Frame
 * persistence samples [latest] once a second, because that is the rate storage
 * is sized for. The energy integral instead receives every reading through
 * [onMetrics], because `pack - drive` is a small remainder between two large
 * signals and only converges when both are integrated at bus rate.
 *
 * An **open trip or charge** therefore stays at [RoadcastCadence.sixtyHz].
 * Anything else runs at [RoadcastCadence.oneHz], which is the clock the
 * session detectors already use, so a departure is still seen. A parked
 * session counts as idle on purpose — see `TelemetryGraph`, where
 * [sessionActive] is built.
 *
 * The first moments after a trip arms integrate at the idle rate until
 * [syncCadence] raises it on the next collector tick. That is the accepted
 * cost of not folding at 60 Hz in the garage.
 */
class RoadcastTripMetricsMonitor(
    private val repository: RoadcastRepository,
    private val sessionActive: () -> Boolean = { false },
    private val onMetrics: (RoadcastTripMetrics) -> Unit = {},
    private val idleCadence: RoadcastCadence = RoadcastCadence.oneHz,
    private val liveCadence: RoadcastCadence = RoadcastCadence.sixtyHz,
) {
    private val scope = CoroutineScope(
        SupervisorJob() + namedSingleThreadExecutor("trip-metrics").asCoroutineDispatcher(),
    )
    private var job: Job? = null
    private var subscription: RoadcastSubscription? = null

    @Volatile
    private var latest: RoadcastTripMetrics? = null

    @Volatile
    var cadence: RoadcastCadence = idleCadence
        private set

    @Synchronized
    fun start() {
        if (job?.isActive == true) return
        cadence = if (sessionActive()) liveCadence else idleCadence
        val subscription = repository.subscribe(
            RoadcastTripMetricsProvider.requiredSignals,
            cadence,
        )
        this.subscription = subscription
        job = scope.launch {
            try {
                subscription.state.collect { state ->
                    val metrics = (state as? RoadcastSnapshotState.Ready)
                        ?.let { RoadcastTripMetricsProvider.read(it.snapshot) }
                    latest = metrics
                    if (metrics != null) onMetrics(metrics)
                }
            } finally {
                subscription.close()
            }
        }
    }

    /**
     * Raises or drops the JNI rate to match the open session.
     *
     * Only the collector tick calls this, after the detectors have run, so a
     * trip that just armed rises within that tick rather than waiting out the
     * idle interval. The sample loop must **not** call it: during a trip that
     * would evaluate [sessionActive] sixty times a second, taking each
     * detector's monitor from the Roadcast thread, and it would buy at most
     * one second of latency over the tick that is already there.
     *
     * [cadence] is recorded only after a subscription accepted it. Recording
     * a want this monitor could not apply would make every later call return
     * early, and the trip would then integrate at the idle rate for its whole
     * length with nothing to show that anything failed.
     */
    @Synchronized
    fun syncCadence() {
        val want = if (sessionActive()) liveCadence else idleCadence
        if (want == cadence) return
        val active = subscription ?: return
        cadence = want
        active.setCadence(want)
    }

    @Synchronized
    fun stop() {
        val active = job ?: return
        job = null
        subscription = null
        runBlocking { active.cancelAndJoin() }
        latest = null
        cadence = idleCadence
    }

    fun latest(): RoadcastTripMetrics? = latest
}
