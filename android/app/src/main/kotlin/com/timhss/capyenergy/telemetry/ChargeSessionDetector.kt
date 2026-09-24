package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey

import com.timhss.capyenergy.telemetry.db.SessionEntity

interface ChargeEventSink : TripEventSink

interface ChargeSessionStore {
    fun latestOpenChargeSession(): SessionEntity?

    fun createChargeSession(
        plugConnectedAt: SignalTimestamp,
        startSoc: Float?,
        startOdometerKm: Float?,
        plugType: Int?,
        startLocation: LocationSnapshot?,
        startAmbientTempC: Float?
    ): String

    fun updateChargeStarted(
        id: String?,
        plugConnectedAt: SignalTimestamp?,
        chargeStartedAt: SignalTimestamp,
        startSoc: Float?,
        startOdometerKm: Float?,
        plugType: Int?,
        startPowerKw: Float?,
        startLocation: LocationSnapshot?,
        startAmbientTempC: Float?
    ): String

    fun updateChargePlugType(id: String?, plugType: Int)

    fun closeChargeSession(
        id: String?,
        plugConnectedAt: SignalTimestamp?,
        chargeStartedAt: SignalTimestamp?,
        chargeEndedAt: SignalTimestamp?,
        plugDisconnectedAt: SignalTimestamp?,
        startSoc: Float?,
        endSoc: Float?,
        startOdometerKm: Float?,
        endOdometerKm: Float?,
        plugType: Int?,
        startPowerKw: Float?,
        startLocation: LocationSnapshot?,
        startAmbientTempC: Float?,
        endAmbientTempC: Float?,
        /** Why the charge stopped: a [ChargeEndReason] name, or null to keep what is stored. */
        chargeEndReason: String?,
        /** How the session ended: how the plug came out, or null to keep what is stored. */
        disconnectReason: String?,
        status: String = "ENDED"
    )
}

class ChargeSessionDetector(
    private val eventRepository: ChargeEventSink,
    private val sessionRepository: ChargeSessionStore,
    private val chargerReadingGuard: ChargerReadingGuard = ChargerReadingGuard(),
    private val dcChargePowerGuard: SignalFreezeGuard =
        SignalFreezeGuard(SignalKey.EV_DC_CHARGE_POWER),
    private val locationProvider: () -> LocationSnapshot?,
    /**
     * Called when a charge begins, for whatever the app wants to do about it —
     * today, opening the Charging tab in place of the factory screen. It must
     * return at once: this runs inside the detector's lock, on the detector's
     * thread.
     *
     * Two transitions call it, because either one alone misses a real arrival:
     * the plug going in, and the charge starting. A driver who leaves the cable
     * in and switches the wall box on never connects a plug, and the recorded
     * field data shows exactly that — one plug connect against several charge
     * starts.
     *
     * A **resume** does not call it. That is the same session drawing again
     * after a taper or a completion, so it repeats while the car balances the
     * pack, and it would take the display each time.
     *
     * This is the only place in the app that can tell any of those apart,
     * because it is the only one holding the state machine that says so.
     */
    private val onChargingBegan: () -> Unit = {},
) : SignalStateStore.Listener {
    private var state = ChargeSessionState.DISCONNECTED
    private var activeSessionId: String? = null
    private var plugConnectedAt: SignalTimestamp? = null
    private var chargeStartedAt: SignalTimestamp? = null
    private var chargeEndedAt: SignalTimestamp? = null
    /**
     * Why the current stretch of charging stopped.
     *
     * The plug-pull path ends the charge without persisting, because the
     * disconnect write that follows carries the row. That write only knows
     * how the plug came out, so the charge's own reason is held here for it
     * to pass on rather than being dropped.
     */
    private var chargeEndReason: ChargeEndReason? = null
    private var lowPowerCandidateAt: SignalTimestamp? = null
    private var powerCandidateAt: SignalTimestamp? = null
    private var disconnectCandidateAt: SignalTimestamp? = null
    private var startSoc: Float? = null
    private var startOdometer: Float? = null
    private var plugType: Int? = null
    private var startPowerKw: Float? = null
    private var startLocation: LocationSnapshot? = null
    private var startAmbientTempC: Float? = null
    private var latestSoc: Float? = null
    private var latestOdometer: Float? = null
    private var latestAmbientTempC: Float? = null
    private var restored = false

    fun restoreIfNeeded() {
        if (restored) return
        restored = true
        restoreOpenSession(sessionRepository.latestOpenChargeSession())
    }

    @Synchronized
    override fun onSignalUpdated(sample: SignalSample, snapshot: Map<SignalKey, SignalSample>) {
        val plug = snapshot[SignalKey.EV_CHARGE_PLUG_TYPE]?.intValue()
        val chargeState = snapshot[SignalKey.EV_CHARGE_STATE]?.intValue()
        val chargingState = isChargingState(chargeState)
        val completeState = isChargeCompleteState(chargeState)
        val connected = isPlugConnected(plug) || chargingState
        val power = chargePower(snapshot, sample.timestamp.receivedAtElapsedNanos)
        val powerKw = power.kwOrNull
        val soc = snapshot[SignalKey.HV_BATTERY_SOC]?.floatValue()
        val odometer = snapshot[SignalKey.ODOMETER]?.floatValue()
        val ambientTemp = ambientTempC(snapshot)
        latestSoc = soc ?: latestSoc
        latestOdometer = odometer ?: latestOdometer
        latestAmbientTempC = ambientTemp ?: latestAmbientTempC

        val confirmedPlug = plug?.takeIf(::isPlugConnected)
        if (
            state != ChargeSessionState.DISCONNECTED &&
            confirmedPlug != null &&
            confirmedPlug != plugType
        ) {
            plugType = confirmedPlug
            sessionRepository.updateChargePlugType(activeSessionId, confirmedPlug)
        }

        when (state) {
            ChargeSessionState.DISCONNECTED -> {
                if (connected) plugConnected(sample, plug, soc, odometer)
            }
            ChargeSessionState.PLUG_CONNECTED -> {
                if (!connected) {
                    handleDisconnectCandidate(sample) {
                        plugDisconnected(sample, "removed_before_charge")
                    }
                } else if (chargingState) {
                    clearDisconnectCandidate()
                    chargeStarted(sample, "state", powerKw)
                } else {
                    clearDisconnectCandidate()
                    handlePowerStartCandidate(sample, powerKw)
                }
            }
            ChargeSessionState.CHARGING -> {
                if (!connected) {
                    handleDisconnectCandidate(sample) {
                        // The subsequent plugDisconnected() persists the final
                        // row (with chargeEndedAt), so skip the redundant write.
                        chargeEnded(sample, ChargeEndReason.PLUG_DISCONNECTED, persist = false)
                        plugDisconnected(sample, "removed_while_charging")
                    }
                } else if (completeState) {
                    clearDisconnectCandidate()
                    chargeEnded(sample, ChargeEndReason.COMPLETED)
                } else if (power is ChargePower.Frozen || (powerKw != null && powerKw < END_POWER_KW)) {
                    clearDisconnectCandidate()
                    val candidate = lowPowerCandidateAt
                    if (candidate == null) {
                        lowPowerCandidateAt = sample.timestamp
                    } else if (elapsedMillis(candidate, sample.timestamp) >= END_CONFIRM_MILLIS) {
                        chargeEnded(sample, ChargeEndReason.POWER_LOST)
                    }
                } else {
                    clearDisconnectCandidate()
                    lowPowerCandidateAt = null
                }
            }
            ChargeSessionState.ENDED_WAITING_DISCONNECT -> {
                if (!connected) {
                    handleDisconnectCandidate(sample) {
                        plugDisconnected(sample, "removed_after_end")
                    }
                } else {
                    clearDisconnectCandidate()
                    handleResumeCandidate(sample, powerKw)
                }
            }
        }
    }

    @Synchronized
    fun statusMap(): Map<String, Any?> = mapOf(
        "chargeState" to state.name,
        "activeSessionId" to activeSessionId,
        "plugConnectedAtUtcMillis" to plugConnectedAt?.receivedAtUtcMillis,
        "chargeStartedAtUtcMillis" to chargeStartedAt?.receivedAtUtcMillis,
        "chargeEndedAtUtcMillis" to chargeEndedAt?.receivedAtUtcMillis
    )

    @Synchronized
    fun activeFrameSession(): ActiveFrameSession? {
        val id = activeSessionId ?: return null
        return if (state == ChargeSessionState.DISCONNECTED) {
            null
        } else {
            ActiveFrameSession(id = id, type = "CHARGE")
        }
    }

    @Synchronized
    fun reset() {
        clearSessionState()
    }

    private fun clearSessionState() {
        state = ChargeSessionState.DISCONNECTED
        activeSessionId = null
        plugConnectedAt = null
        chargeStartedAt = null
        chargeEndedAt = null
        chargeEndReason = null
        lowPowerCandidateAt = null
        powerCandidateAt = null
        disconnectCandidateAt = null
        startSoc = null
        startOdometer = null
        plugType = null
        startPowerKw = null
        startLocation = null
        startAmbientTempC = null
        latestSoc = null
        latestOdometer = null
        latestAmbientTempC = null
    }

    private fun plugConnected(sample: SignalSample, plug: Int?, soc: Float?, odometer: Float?) {
        state = ChargeSessionState.PLUG_CONNECTED
        plugConnectedAt = sample.timestamp
        startSoc = soc
        startOdometer = odometer
        plugType = plug
        startLocation = locationProvider()
        startAmbientTempC = latestAmbientTempC
        activeSessionId = sessionRepository.createChargeSession(
            plugConnectedAt = sample.timestamp,
            startSoc = soc,
            startOdometerKm = odometer,
            plugType = plug,
            startLocation = startLocation,
            startAmbientTempC = startAmbientTempC
        )
        eventRepository.appendEvent(
            eventRepository.sessionEvent(
                type = TelemetryEventType.CHARGE_PLUG_CONNECTED,
                timestamp = sample.timestamp,
                value = plug,
                source = sample.source,
                details = "soc=$soc odometer=$odometer",
                sessionId = activeSessionId
            )
        )
        onChargingBegan()
    }

    private fun isStaleOpenSession(session: SessionEntity): Boolean {
        val lastActivityUtcMillis = session.updatedAtUtcMillis
        return lastActivityUtcMillis > 0 &&
            System.currentTimeMillis() - lastActivityUtcMillis > STALE_OPEN_SESSION_THRESHOLD_MILLIS
    }

    private fun closeStaleOpenSession(session: SessionEntity) {
        val lastActivity = session.updatedAtUtcMillis
        val endedAt = timestampOrNull(lastActivity, session.startedAtElapsedNanos) ?: inferredNow()
        sessionRepository.closeChargeSession(
            id = session.id,
            plugConnectedAt = timestampOrNull(session.startedAtUtcMillis, session.startedAtElapsedNanos),
            chargeStartedAt = timestampOrNull(session.chargeStartedAtUtcMillis, session.chargeStartedAtElapsedNanos),
            chargeEndedAt = endedAt,
            plugDisconnectedAt = endedAt,
            startSoc = session.startSocPercent,
            endSoc = session.endSocPercent ?: session.startSocPercent,
            startOdometerKm = session.startOdometerKm,
            endOdometerKm = session.endOdometerKm ?: session.startOdometerKm,
            plugType = session.plugType,
            startPowerKw = session.startPowerKw,
            startLocation = sessionStartLocation(session),
            startAmbientTempC = session.startAmbientTempC,
            endAmbientTempC = session.endAmbientTempC ?: session.startAmbientTempC,
            chargeEndReason = ChargeEndReason.APP_RESTART_RECOVERY.name,
            disconnectReason = null,
            status = "ENDED"
        )
        eventRepository.appendEvent(
            eventRepository.sessionEvent(
                type = TelemetryEventType.CHARGE_RECOVERED,
                timestamp = endedAt,
                value = session.id,
                source = SignalSource.SNAPSHOT_FALLBACK,
                details = "status=${session.status} staleOpenSessionClosed " +
                    "plugConnectedAt=${session.startedAtUtcMillis} " +
                    "lastActivityUtcMillis=$lastActivity",
                sessionId = session.id
            )
        )
    }

    @Synchronized
    private fun restoreOpenSession(session: SessionEntity?) {
        if (session == null) return
        if (isStaleOpenSession(session)) {
            closeStaleOpenSession(session)
            return
        }
        activeSessionId = session.id
        state = restoredState(session)
        plugConnectedAt = timestampOrNull(
            session.startedAtUtcMillis,
            session.startedAtElapsedNanos
        )
        chargeStartedAt = timestampOrNull(
            session.chargeStartedAtUtcMillis,
            session.chargeStartedAtElapsedNanos
        )
        chargeEndedAt = timestampOrNull(
            session.chargeEndedAtUtcMillis,
            session.chargeEndedAtElapsedNanos
        )
        startSoc = session.startSocPercent
        startOdometer = session.startOdometerKm
        plugType = session.plugType
        startPowerKw = session.startPowerKw
        startLocation = sessionStartLocation(session)
        startAmbientTempC = session.startAmbientTempC
        latestSoc = session.endSocPercent ?: session.startSocPercent
        latestOdometer = session.endOdometerKm ?: session.startOdometerKm
        latestAmbientTempC = session.endAmbientTempC ?: session.startAmbientTempC
        disconnectCandidateAt = null
        eventRepository.appendEvent(
            eventRepository.sessionEvent(
                type = TelemetryEventType.CHARGE_RECOVERED,
                timestamp = plugConnectedAt ?: inferredNow(),
                value = session.id,
                source = SignalSource.SNAPSHOT_FALLBACK,
                details = "status=${session.status} plugConnectedAt=${session.startedAtUtcMillis}",
                sessionId = session.id
            )
        )
    }

    private fun restoredState(session: SessionEntity): ChargeSessionState {
        return when (session.status) {
            ChargeSessionState.PLUG_CONNECTED.name -> ChargeSessionState.PLUG_CONNECTED
            ChargeSessionState.CHARGING.name -> ChargeSessionState.CHARGING
            ChargeSessionState.ENDED_WAITING_DISCONNECT.name -> ChargeSessionState.ENDED_WAITING_DISCONNECT
            else -> when {
                session.chargeEndedAtUtcMillis != null -> ChargeSessionState.ENDED_WAITING_DISCONNECT
                session.chargeStartedAtUtcMillis != null -> ChargeSessionState.CHARGING
                else -> ChargeSessionState.PLUG_CONNECTED
            }
        }
    }

    private fun timestampOrNull(utcMillis: Long?, elapsedNanos: Long?): SignalTimestamp? {
        if (utcMillis == null || elapsedNanos == null) return null
        return SignalTimestamp(
            receivedAtUtcMillis = utcMillis,
            receivedAtElapsedNanos = elapsedNanos,
            sourceTimestampNanos = null,
            accuracy = TimestampAccuracy.INFERRED,
            uncertaintyMillis = 0L
        )
    }

    private fun inferredNow(): SignalTimestamp = SignalTimestamp(
        receivedAtUtcMillis = System.currentTimeMillis(),
        receivedAtElapsedNanos = android.os.SystemClock.elapsedRealtimeNanos(),
        sourceTimestampNanos = null,
        accuracy = TimestampAccuracy.INFERRED,
        uncertaintyMillis = 0L
    )

    private fun handlePowerStartCandidate(sample: SignalSample, powerKw: Float?) {
        if (powerKw == null || powerKw < START_POWER_KW) {
            powerCandidateAt = null
            return
        }
        val candidate = powerCandidateAt
        if (candidate == null) {
            powerCandidateAt = sample.timestamp
        } else if (elapsedMillis(candidate, sample.timestamp) >= START_CONFIRM_MILLIS) {
            chargeStarted(sample, "power", powerKw)
        }
    }

    /**
     * Reopens an ended session only once energy is actually flowing again.
     *
     * The old rule reopened on the charge-state signal alone, on the first
     * sample that carried it. That state flickers while the plug is being
     * pulled — one captured session went COMPLETE, then briefly back, then
     * disconnected, and the sixteen seconds of flicker relabelled a charge
     * that had finished two hours earlier as "removed_while_charging".
     *
     * A state code is a claim; measured power is evidence. This mirrors
     * [handlePowerStartCandidate], which already starts a charge on sustained
     * power rather than on the state, and it inherits that function's immunity
     * to [ChargePower.Frozen]: charger voltage and current latch high when a
     * charge stops with the plug in, and a latched reading is not a resume.
     */
    private fun handleResumeCandidate(sample: SignalSample, powerKw: Float?) {
        if (powerKw == null || powerKw < START_POWER_KW) {
            powerCandidateAt = null
            return
        }
        val candidate = powerCandidateAt
        if (candidate == null) {
            powerCandidateAt = sample.timestamp
        } else if (elapsedMillis(candidate, sample.timestamp) >= START_CONFIRM_MILLIS) {
            resumeCharging(sample, powerKw)
        }
    }

    private fun handleDisconnectCandidate(sample: SignalSample, onConfirmed: () -> Unit) {
        val candidate = disconnectCandidateAt
        if (candidate == null) {
            disconnectCandidateAt = sample.timestamp
            return
        }
        if (elapsedMillis(candidate, sample.timestamp) >= DISCONNECT_CONFIRM_MILLIS) {
            clearDisconnectCandidate()
            onConfirmed()
        }
    }

    private fun clearDisconnectCandidate() {
        disconnectCandidateAt = null
    }

    private fun chargeStarted(sample: SignalSample, reason: String, powerKw: Float?) {
        if (state == ChargeSessionState.CHARGING) return
        state = ChargeSessionState.CHARGING
        chargeStartedAt = sample.timestamp
        if (startPowerKw == null) startPowerKw = powerKw
        if (startAmbientTempC == null) startAmbientTempC = latestAmbientTempC
        activeSessionId = sessionRepository.updateChargeStarted(
            id = activeSessionId,
            plugConnectedAt = plugConnectedAt,
            chargeStartedAt = sample.timestamp,
            startSoc = startSoc,
            startOdometerKm = startOdometer,
            plugType = plugType,
            startPowerKw = startPowerKw,
            startLocation = startLocation ?: locationProvider(),
            startAmbientTempC = startAmbientTempC
        )
        lowPowerCandidateAt = null
        powerCandidateAt = null
        eventRepository.appendEvent(
            eventRepository.sessionEvent(
                type = TelemetryEventType.CHARGE_STARTED,
                timestamp = sample.timestamp,
                value = reason,
                source = sample.source,
                details = "plugConnectedAt=${plugConnectedAt?.receivedAtUtcMillis} soc=$startSoc odometer=$startOdometer",
                sessionId = activeSessionId
            )
        )
        onChargingBegan()
    }

    private fun chargeEnded(
        sample: SignalSample,
        reason: ChargeEndReason,
        persist: Boolean = true
    ) {
        if (state == ChargeSessionState.ENDED_WAITING_DISCONNECT) return
        state = ChargeSessionState.ENDED_WAITING_DISCONNECT
        chargeEndedAt = sample.timestamp
        chargeEndReason = reason
        lowPowerCandidateAt = null
        if (persist) {
            sessionRepository.closeChargeSession(
                id = activeSessionId,
                plugConnectedAt = plugConnectedAt,
                chargeStartedAt = chargeStartedAt,
                chargeEndedAt = chargeEndedAt,
                plugDisconnectedAt = null,
                startSoc = startSoc,
                endSoc = latestSoc,
                startOdometerKm = startOdometer,
                endOdometerKm = latestOdometer,
                plugType = plugType,
                startPowerKw = startPowerKw,
                startLocation = startLocation,
                startAmbientTempC = startAmbientTempC,
                endAmbientTempC = latestAmbientTempC,
                chargeEndReason = reason.name,
                disconnectReason = null,
                status = "ENDED_WAITING_DISCONNECT"
            )
        }
        eventRepository.appendEvent(
            eventRepository.sessionEvent(
                type = TelemetryEventType.CHARGE_ENDED,
                timestamp = sample.timestamp,
                value = reason.name,
                source = sample.source,
                details = "chargeStartedAt=${chargeStartedAt?.receivedAtUtcMillis}",
                sessionId = activeSessionId
            )
        )
    }

    // Charging resumed after an end (e.g. taper/complete followed by another
    // draw) while the plug is still connected: reopen the same session, clear
    // the stale end timestamp, and persist it back to CHARGING so a subsequent
    // disconnect doesn't record an end time that predates the real activity.
    private fun resumeCharging(sample: SignalSample, powerKw: Float?) {
        state = ChargeSessionState.CHARGING
        chargeEndedAt = null
        chargeEndReason = null
        lowPowerCandidateAt = null
        powerCandidateAt = null
        if (startPowerKw == null) startPowerKw = powerKw
        if (startAmbientTempC == null) startAmbientTempC = latestAmbientTempC
        val startedAt = chargeStartedAt ?: sample.timestamp
        chargeStartedAt = startedAt
        activeSessionId = sessionRepository.updateChargeStarted(
            id = activeSessionId,
            plugConnectedAt = plugConnectedAt,
            chargeStartedAt = startedAt,
            startSoc = startSoc,
            startOdometerKm = startOdometer,
            plugType = plugType,
            startPowerKw = startPowerKw,
            startLocation = startLocation ?: locationProvider(),
            startAmbientTempC = startAmbientTempC
        )
        eventRepository.appendEvent(
            eventRepository.sessionEvent(
                type = TelemetryEventType.CHARGE_STARTED,
                timestamp = sample.timestamp,
                value = "resumed",
                source = sample.source,
                details = "chargeStartedAt=${startedAt.receivedAtUtcMillis}",
                sessionId = activeSessionId
            )
        )
    }

    private fun plugDisconnected(sample: SignalSample, reason: String) {
        val disconnectedSessionId = activeSessionId
        sessionRepository.closeChargeSession(
            id = disconnectedSessionId,
            plugConnectedAt = plugConnectedAt,
            chargeStartedAt = chargeStartedAt,
            chargeEndedAt = chargeEndedAt,
            plugDisconnectedAt = sample.timestamp,
            startSoc = startSoc,
            endSoc = latestSoc,
            startOdometerKm = startOdometer,
            endOdometerKm = latestOdometer,
            plugType = plugType,
            startPowerKw = startPowerKw,
            startLocation = startLocation,
            startAmbientTempC = startAmbientTempC,
            endAmbientTempC = latestAmbientTempC,
            chargeEndReason = chargeEndReason?.name,
            disconnectReason = reason,
            status = "DISCONNECTED"
        )
        eventRepository.appendEvent(
            eventRepository.sessionEvent(
                type = TelemetryEventType.CHARGE_PLUG_DISCONNECTED,
                timestamp = sample.timestamp,
                value = reason,
                source = sample.source,
                details = "plugConnectedAt=${plugConnectedAt?.receivedAtUtcMillis} chargeStartedAt=${chargeStartedAt?.receivedAtUtcMillis} chargeEndedAt=${chargeEndedAt?.receivedAtUtcMillis}",
                sessionId = disconnectedSessionId
            )
        )
        clearSessionState()
    }

    private fun sessionStartLocation(session: SessionEntity): LocationSnapshot? {
        val latitude = session.startLatitude ?: return null
        val longitude = session.startLongitude ?: return null
        return LocationSnapshot(
            latitude = latitude,
            longitude = longitude,
            altitudeM = session.startAltitudeM,
            accuracyM = session.startGpsAccuracyM,
            provider = session.startLocationProvider,
            elapsedRealtimeNanos = session.startLocationElapsedRealtimeNanos ?: 0L,
            wallTimeUtcMillis = session.startedAtUtcMillis
        )
    }

    private fun ambientTempC(snapshot: Map<SignalKey, SignalSample>): Float? {
        return selectedAmbientTemperatureC(snapshot)
    }

    /**
     * O que a potência da carga está dizendo.
     *
     * [ChargePower.Frozen] é o caso que este tipo existe para carregar: a
     * tensão e a corrente do carregador travam no último valor quando a carga
     * para com o plugue conectado, e travam **alto** (~1 kW), bem acima de
     * [END_POWER_KW]. Lido como número, isso mantinha a sessão aberta para
     * sempre; lido como ausência, também. O que ele de fato é: prova de que
     * quem publicava parou — ou seja, um fim de carga, confirmado pela mesma
     * janela de [END_CONFIRM_MILLIS] que confirma queda de potência.
     */
    private sealed interface ChargePower {
        data class Measured(val kw: Float) : ChargePower
        data object Frozen : ChargePower
        data object Unknown : ChargePower

        val kwOrNull: Float? get() = (this as? Measured)?.kw
    }

    /**
     * A potência DC vem primeiro por ser a medida direta do pacote, mas só
     * enquanto for medição: em 2026-07-26, com o carro em carga AC de 1.04 kW,
     * ela estava congelada em 20.5 kW com o carimbo do VHAL meia hora atrás e
     * vencia o par AC, que estava vivo. Congelada, ela cede a vez em vez de
     * mandar — e só vira fim de carga se o par AC também não estiver medindo.
     */
    private fun chargePower(
        snapshot: Map<SignalKey, SignalSample>,
        nowElapsedNanos: Long
    ): ChargePower {
        val dcPower = dcChargePowerGuard.read(snapshot, nowElapsedNanos)
        if (dcPower is SignalFreezeGuard.Result.Measuring) {
            return ChargePower.Measured(dcPower.value)
        }
        return when (val charger = chargerReadingGuard.read(snapshot, nowElapsedNanos)) {
            is ChargerReadingGuard.Result.Measuring ->
                ChargePower.Measured(charger.readings.inputPowerKw)
            ChargerReadingGuard.Result.Frozen -> ChargePower.Frozen
            ChargerReadingGuard.Result.Absent ->
                if (dcPower is SignalFreezeGuard.Result.Frozen) {
                    ChargePower.Frozen
                } else {
                    ChargePower.Unknown
                }
        }
    }

    private fun elapsedMillis(start: SignalTimestamp, end: SignalTimestamp): Long {
        return ((end.receivedAtElapsedNanos - start.receivedAtElapsedNanos) / 1_000_000L).coerceAtLeast(0L)
    }

    companion object {
        private const val START_POWER_KW = 0.5f
        private const val START_CONFIRM_MILLIS = 3_000L
        private const val END_POWER_KW = 0.2f
        private const val END_CONFIRM_MILLIS = 120_000L
        private const val DISCONNECT_CONFIRM_MILLIS = 15_000L
        private const val STALE_OPEN_SESSION_THRESHOLD_MILLIS = 24L * 60L * 60L * 1_000L
    }
}
