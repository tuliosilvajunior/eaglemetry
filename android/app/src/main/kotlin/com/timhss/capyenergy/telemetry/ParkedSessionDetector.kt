package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey

import com.timhss.capyenergy.telemetry.db.SessionEntity
import com.timhss.capyenergy.profile.GeelyProfile
import kotlin.math.abs

data class SleepGapEstimate(
    val sleepSeconds: Long,
    val sleepSocDeltaPercent: Float,
    val sleepEnergyWhEstimate: Double
)

interface ParkedSessionStore {
    fun latestOpenParkedSession(): SessionEntity?

    fun createParkedSession(
        startedAt: SignalTimestamp,
        startSoc: Float?,
        startAmbientTempC: Float?,
        parkingMode: Int? = null,
        status: String = "ACTIVE"
    ): String

    fun updateParkedSessionLastSoc(
        id: String,
        lastSoc: Float?,
        updatedAt: SignalTimestamp
    )

    fun updateParkedSessionParkingMode(
        id: String,
        parkingMode: Int,
        updatedAt: SignalTimestamp
    )

    fun closeParkedSession(
        id: String?,
        endedAt: SignalTimestamp,
        endSoc: Float?,
        endAmbientTempC: Float?,
        parkingMode: Int?,
        reason: String,
        sleepSeconds: Long? = null,
        sleepSocDeltaPercent: Float? = null,
        sleepEnergyWhEstimate: Double? = null
    )

    fun updateParkedSessionSleepEstimate(
        id: String,
        sleepSeconds: Long,
        sleepSocDeltaPercent: Float,
        sleepEnergyWhEstimate: Double
    )

    fun deleteParkedSession(id: String)
}

class ParkedSessionDetector(
    private val sessionRepository: ParkedSessionStore,
    private val tripActiveProvider: () -> Boolean = { false },
    private val chargeActiveProvider: () -> Boolean = { false },
    private val capacityWhProvider: () -> Double? = { null }
) : SignalStateStore.Listener {

    private enum class State { IDLE, ARMED, ACTIVE }

    private var state = State.IDLE
    private var activeSessionId: String? = null
    private var armedAt: SignalTimestamp? = null
    private var parkedStartedAt: SignalTimestamp? = null
    private var lastSoc: Float? = null
    private var lastAmbientTempC: Float? = null
    private var lastGear: Int? = null
    private var currentParkingMode: Int? = null
    private var restored = false
    private var restoredOpenSession: SessionEntity? = null
    private var pendingSleepEstimate: SleepGapEstimate? = null
    @Synchronized
    fun activeFrameSession(): ActiveFrameSession? {
        val id = activeSessionId ?: return null
        return ActiveFrameSession(id = id, type = "PARKED")
    }

    fun restoreIfNeeded() {
        if (restored) return
        restored = true
        val openSession = sessionRepository.latestOpenParkedSession() ?: return
        val nowMs = System.currentTimeMillis()
        val ageMillis = nowMs - openSession.updatedAtUtcMillis
        if (ageMillis >= STALE_OPEN_SESSION_THRESHOLD_MILLIS) {
            sessionRepository.closeParkedSession(
                id = openSession.id,
                endedAt = SignalTimestamp(
                    receivedAtUtcMillis = openSession.updatedAtUtcMillis,
                    receivedAtElapsedNanos = openSession.updatedAtElapsedNanos ?: 0L,
                    sourceTimestampNanos = null,
                    accuracy = TimestampAccuracy.INFERRED,
                    uncertaintyMillis = 0L
                ),
                endSoc = openSession.lastSoc ?: openSession.startSocPercent,
                endAmbientTempC = openSession.startAmbientTempC,
                parkingMode = openSession.parkingMode,
                reason = "STALE_RECOVERY"
            )
            state = State.IDLE
            activeSessionId = null
        } else {
            activeSessionId = openSession.id
            state = State.ACTIVE
            restoredOpenSession = openSession
            parkedStartedAt = SignalTimestamp(
                receivedAtUtcMillis = openSession.startedAtUtcMillis,
                receivedAtElapsedNanos = openSession.startedAtElapsedNanos,
                sourceTimestampNanos = null,
                accuracy = TimestampAccuracy.POLLED,
                uncertaintyMillis = 0L
            )
            lastSoc = openSession.lastSoc ?: openSession.startSocPercent
            lastAmbientTempC = openSession.startAmbientTempC
        }
    }

    @Synchronized
    override fun onSignalUpdated(sample: SignalSample, snapshot: Map<SignalKey, SignalSample>) {
        val gearSample = snapshot[SignalKey.GEAR]
        if (gearSample != null) {
            val g = gearSample.intValue()
            if (g != null) lastGear = g
        }
        val gear = lastGear ?: return
        val speed = snapshot[SignalKey.VEHICLE_SPEED]?.floatValue() ?: 0f
        val soc = snapshot[SignalKey.HV_BATTERY_SOC]?.floatValue()
        val ambientTemp = selectedAmbientTemperatureC(snapshot, sample.timestamp)

        if (ambientTemp != null) lastAmbientTempC = ambientTemp

        if (restoredOpenSession != null) {
            checkSleepGapOnResume(sample, soc)
        }

        val isParkedGear = isParkGear(gear)
        val isStopped = speed <= 1.0f
        val isTripActive = tripActiveProvider()
        val isChargeActive = chargeActiveProvider()

        if (state == State.ACTIVE) {
            val detectedMode = resolveParkingMode(snapshot)
            if (detectedMode != null && detectedMode != currentParkingMode) {
                currentParkingMode = detectedMode
                activeSessionId?.let { id ->
                    sessionRepository.updateParkedSessionParkingMode(id, detectedMode, sample.timestamp)
                }
            }

            if (!isParkedGear || !isStopped || isTripActive || isChargeActive) {
                val reason = when {
                    isChargeActive -> "CHARGE_OPENED"
                    isTripActive -> "TRIP_STARTED"
                    !isParkedGear -> "GEAR_LEFT_P"
                    else -> "MOTION"
                }
                closeParked(sample.timestamp, reason)
            } else {
                if (soc != null && soc != lastSoc) {
                    lastSoc = soc
                    activeSessionId?.let { id ->
                        sessionRepository.updateParkedSessionLastSoc(id, soc, sample.timestamp)
                    }
                }
            }
            return
        }

        if (soc != null) lastSoc = soc

        if (isTripActive || isChargeActive || !isParkedGear || !isStopped) {
            state = State.IDLE
            armedAt = null
            return
        }

        when (state) {
            State.IDLE -> {
                state = State.ARMED
                armedAt = sample.timestamp
            }
            State.ARMED -> {
                val start = armedAt ?: sample.timestamp
                val heldMillis = sample.timestamp.receivedAtUtcMillis - start.receivedAtUtcMillis
                if (heldMillis >= PARKED_ARM_DELAY_MILLIS) {
                    currentParkingMode = resolveParkingMode(snapshot)
                    val id = sessionRepository.createParkedSession(
                        startedAt = start,
                        startSoc = lastSoc ?: soc,
                        startAmbientTempC = lastAmbientTempC ?: ambientTemp,
                        parkingMode = currentParkingMode
                    )
                    activeSessionId = id
                    parkedStartedAt = start
                    state = State.ACTIVE
                }
            }
            State.ACTIVE -> {}
        }
    }

    private fun checkSleepGapOnResume(sample: SignalSample, nowSoc: Float?) {
        val restoredSession = restoredOpenSession ?: return
        if (nowSoc == null) return
        restoredOpenSession = null

        val estimate = computeSleepGapEstimate(
            lastUtcMillis = restoredSession.updatedAtUtcMillis,
            lastElapsedNanos = restoredSession.updatedAtElapsedNanos ?: restoredSession.startedAtElapsedNanos,
            lastSoc = restoredSession.lastSoc ?: restoredSession.startSocPercent,
            nowUtcMillis = sample.timestamp.receivedAtUtcMillis,
            nowElapsedNanos = sample.timestamp.receivedAtElapsedNanos,
            nowSoc = nowSoc,
            capacityWh = capacityWhProvider()
        )
        if (estimate != null) {
            this.pendingSleepEstimate = estimate
            restoredSession.id.let { id ->
                sessionRepository.updateParkedSessionSleepEstimate(
                    id = id,
                    sleepSeconds = estimate.sleepSeconds,
                    sleepSocDeltaPercent = estimate.sleepSocDeltaPercent,
                    sleepEnergyWhEstimate = estimate.sleepEnergyWhEstimate
                )
            }
        }
    }

    fun computeSleepGapEstimate(
        lastUtcMillis: Long,
        lastElapsedNanos: Long,
        lastSoc: Float?,
        nowUtcMillis: Long,
        nowElapsedNanos: Long,
        nowSoc: Float?,
        capacityWh: Double?
    ): SleepGapEstimate? {
        if (lastSoc == null || nowSoc == null) return null

        // Gate 4 sanity check: Wall clock must advance
        if (nowUtcMillis <= lastUtcMillis) return null

        val wallGapMillis = nowUtcMillis - lastUtcMillis
        // Gate 1: Gap must be at least 30 minutes
        if (wallGapMillis < MIN_SLEEP_GAP_MILLIS) return null

        // Gate 5: Gap must be under 24 hours
        if (wallGapMillis >= STALE_OPEN_SESSION_THRESHOLD_MILLIS) return null

        // Gate 4: Clock Integrity and System Reboot Cross-Check
        if (nowElapsedNanos >= lastElapsedNanos) {
            // System did not reboot. Compare wall-clock gap with monotonic elapsed gap.
            val elapsedGapMillis = (nowElapsedNanos - lastElapsedNanos) / 1_000_000L
            val driftMillis = abs(wallGapMillis - elapsedGapMillis)
            if (driftMillis > MAX_ALLOWED_CLOCK_DRIFT_MILLIS) return null
        } else {
            // System rebooted during parking gap (elapsedRealtimeNanos reset to 0).
            // Elapsed delta cannot be compared; trusted wall-clock gap (wallGapMillis) is used.
        }

        // Gate 2: SOC delta >= 2 quantization steps (0.2%)
        val socDelta = lastSoc - nowSoc
        if (socDelta < MIN_SOC_DELTA_PERCENT) return null

        // Gate 3: the stated capacity can be a traction battery
        if (capacityWh == null || capacityWh !in GeelyProfile.battery.acceptedCapacityWh) return null

        val sleepSeconds = wallGapMillis / 1000L
        val sleepSocDeltaPercent = socDelta
        val sleepEnergyWhEstimate = (socDelta.toDouble() / 100.0) * capacityWh

        return SleepGapEstimate(
            sleepSeconds = sleepSeconds,
            sleepSocDeltaPercent = sleepSocDeltaPercent,
            sleepEnergyWhEstimate = sleepEnergyWhEstimate
        )
    }

    private fun closeParked(endedAt: SignalTimestamp, reason: String) {
        val id = activeSessionId ?: return
        val estimate = pendingSleepEstimate
        sessionRepository.closeParkedSession(
            id = id,
            endedAt = endedAt,
            endSoc = lastSoc,
            endAmbientTempC = lastAmbientTempC,
            parkingMode = currentParkingMode,
            reason = reason,
            sleepSeconds = estimate?.sleepSeconds,
            sleepSocDeltaPercent = estimate?.sleepSocDeltaPercent,
            sleepEnergyWhEstimate = estimate?.sleepEnergyWhEstimate
        )
        activeSessionId = null
        parkedStartedAt = null
        armedAt = null
        currentParkingMode = null
        restoredOpenSession = null
        pendingSleepEstimate = null
        state = State.IDLE
    }

    companion object {
        const val PARKING_MODE_COMFORT = 1
        const val PARKING_MODE_NAP = 2
        const val PARKING_MODE_CLIMATE = 3

        /**
         * Which mode keeps the car awake while it stands, or null for none.
         *
         * In the companion because two objects ask the question: this detector,
         * which records the mode on the parked session, and the charging
         * auto-open, which must not take the display from a person who is
         * resting in the car. One reading of the switches, not two.
         */
        fun resolveParkingMode(snapshot: Map<SignalKey, SignalSample>): Int? {
            val napSample = snapshot[SignalKey.PARKING_NAP_SWT]
            val nap = if (napSample != null && (napSample.sourceTimestampNanos ?: 0L) > 0L) {
                napSample.intValue()
            } else null

            val comfort = snapshot[SignalKey.PARKING_COMFORT_SWT]?.intValue()
            val climateSet = snapshot[SignalKey.AC_PARKINGCLIMATESET]?.intValue()

            return when {
                nap == 1 -> PARKING_MODE_NAP
                comfort == 1 -> PARKING_MODE_COMFORT
                climateSet == 1 -> PARKING_MODE_CLIMATE
                else -> null
            }
        }

        /**
         * True when a person is resting in the car.
         *
         * Camping and nap mode only. The factory charging screen refuses on
         * camping mode alone (`SCENE_FUNC_PARKING_COMFORT_SWITCH`), and nap
         * mode says the same thing more strongly.
         *
         * [PARKING_MODE_CLIMATE] is **not** one of them. Parking climate is
         * also how the car is made warm before a departure, with nobody in it,
         * and that commonly runs on the cable — which is exactly the arrival
         * the screen must open for.
         */
        fun someoneIsRestingInside(snapshot: Map<SignalKey, SignalSample>): Boolean =
            when (resolveParkingMode(snapshot)) {
                PARKING_MODE_COMFORT, PARKING_MODE_NAP -> true
                else -> false
            }

        private const val PARKED_ARM_DELAY_MILLIS = 30_000L
        private const val MIN_SLEEP_GAP_MILLIS = 30 * 60 * 1_000L // Gate 1: 30 min
        private const val MIN_SOC_DELTA_PERCENT = 0.2f // Gate 2: 2 steps of 0.1%
        private const val STALE_OPEN_SESSION_THRESHOLD_MILLIS = 24 * 3_600 * 1_000L
        private const val MAX_ALLOWED_CLOCK_DRIFT_MILLIS = 60_000L // Gate 4: 1 minute clock drift tolerance
    }
}
