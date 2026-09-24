package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey

import com.timhss.capyenergy.telemetry.db.SessionEntity
import com.timhss.capyenergy.profile.GeelyProperties
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class ChargeSessionDetectorTest {
    @Test
    fun lateDcPlugTypeIsPersistedWhenChargingStateArrivesFirst() {
        val events = FakeChargeEventSink()
        val sessions = FakeChargeSessionStore()
        val detector = ChargeSessionDetector(events, sessions, locationProvider = { null })

        detector.onSignalUpdated(
            sample(0, SignalKey.EV_CHARGE_STATE, GeelyProperties.ChargeStateDcCharging),
            snapshot(0, includePlug = false, chargeState = GeelyProperties.ChargeStateDcCharging)
        )
        detector.onSignalUpdated(
            sample(1, SignalKey.HV_BATTERY_SOC, 63.4f),
            snapshot(1, includePlug = false, chargeState = GeelyProperties.ChargeStateDcCharging)
        )
        assertEquals(null, sessions.persistedPlugType)

        detector.onSignalUpdated(
            sample(2, SignalKey.EV_CHARGE_PLUG_TYPE, GeelyProperties.ChargePlugStateDcConnected),
            snapshot(
                2,
                chargeState = GeelyProperties.ChargeStateDcCharging,
                plugType = GeelyProperties.ChargePlugStateDcConnected
            )
        )

        assertEquals(GeelyProperties.ChargePlugStateDcConnected, sessions.persistedPlugType)
    }

    @Test
    fun restoredChargeSurvivesPartialSnapshotsUntilPlugSignalReturns() {
        val events = FakeChargeEventSink()
        val sessions = FakeChargeSessionStore(
            openSession = chargeSession(
                id = "charge-1",
                status = ChargeSessionState.CHARGING.name,
                connectedSecond = 0,
                startedSecond = 1
            )
        )
        val detector = ChargeSessionDetector(events, sessions, locationProvider = { null })

        detector.restoreIfNeeded()

        detector.onSignalUpdated(
            sample(100, SignalKey.HV_BATTERY_SOC, 63.3f),
            snapshot(100, includeChargeState = false, includePlug = false)
        )
        detector.onSignalUpdated(
            sample(101, SignalKey.EV_CHARGE_STATE, GeelyProperties.ChargeStateAcCharging),
            snapshot(101, includePlug = false)
        )
        detector.onSignalUpdated(
            sample(102, SignalKey.EV_CHARGE_PLUG_TYPE, GeelyProperties.ChargePlugStateAcConnected),
            snapshot(102)
        )

        assertEquals(0, sessions.closeCount)
        assertEquals("charge-1", detector.activeFrameSession()?.id)
        assertEquals(ChargeSessionState.CHARGING.name, detector.statusMap()["chargeState"])
    }

    /**
     * O carro registrou, em 2026-08-15, uma única conexão de plugue e várias
     * partidas de carga: o cabo fica no carro e a central é que liga. Se o
     * aviso só saísse na conexão, o app nunca abriria nesse caso, que é o
     * normal do usuário.
     */
    @Test
    fun chargingBeganFiresOnThePlugAndOnTheChargeStart() {
        val events = FakeChargeEventSink()
        val sessions = FakeChargeSessionStore()
        var began = 0
        val detector = ChargeSessionDetector(
            events,
            sessions,
            locationProvider = { null },
            onChargingBegan = { began += 1 }
        )

        detector.onSignalUpdated(
            sample(0, SignalKey.EV_CHARGE_PLUG_TYPE, GeelyProperties.ChargePlugStateAcConnected),
            snapshot(0)
        )
        assertEquals(1, began)

        detector.onSignalUpdated(
            sample(1, SignalKey.EV_CHARGE_STATE, GeelyProperties.ChargeStateAcCharging),
            snapshot(1)
        )
        assertEquals(2, began)

        // A carga que continua não é uma partida.
        detector.onSignalUpdated(
            sample(2, SignalKey.HV_BATTERY_SOC, 56.5f),
            snapshot(2)
        )
        assertEquals(2, began)
    }

    @Test
    fun chargingSessionClosesAfterConfirmedMissingPlugAndChargeState() {
        val events = FakeChargeEventSink()
        val sessions = FakeChargeSessionStore()
        val detector = ChargeSessionDetector(events, sessions, locationProvider = { null })

        detector.onSignalUpdated(
            sample(0, SignalKey.EV_CHARGE_PLUG_TYPE, GeelyProperties.ChargePlugStateAcConnected),
            snapshot(0)
        )
        detector.onSignalUpdated(
            sample(1, SignalKey.EV_CHARGE_STATE, GeelyProperties.ChargeStateAcCharging),
            snapshot(1)
        )
        detector.onSignalUpdated(
            sample(10, SignalKey.HV_BATTERY_SOC, 56.5f),
            snapshot(10, includeChargeState = false, includePlug = false)
        )

        assertEquals(0, sessions.closeCount)
        assertNotNull(detector.activeFrameSession())

        detector.onSignalUpdated(
            sample(26, SignalKey.HV_BATTERY_SOC, 56.5f),
            snapshot(26, includeChargeState = false, includePlug = false)
        )

        // A single persisted write: chargeEnded(persist = false) only marks the
        // end timestamp/event, and plugDisconnected() writes the terminal row.
        assertEquals(1, sessions.closeCount)
        assertEquals("DISCONNECTED", sessions.status)
        assertEquals("removed_while_charging", sessions.disconnectReason)
        // The charge's own ending survives the disconnect write that follows it.
        assertEquals(ChargeEndReason.PLUG_DISCONNECTED.name, sessions.chargeEndReason)
        assertEquals(null, detector.activeFrameSession())
    }

    /**
     * Reproduz o que aconteceu no carro em 2026-07-25: a carga foi parada pela
     * central **sem tirar o plugue**, e a tensão/corrente do carregador
     * travaram em 215.0 V / 4.8 A — ou seja, em ~1 kW, muito acima do limiar de
     * fim de carga. Antes do [ChargerReadingGuard], a sessão ficava aberta
     * indefinidamente gravando uma carga que não existia.
     */
    @Test
    fun chargingSessionClosesWhenChargerReadingsFreeze() {
        val events = FakeChargeEventSink()
        val sessions = FakeChargeSessionStore()
        val detector = ChargeSessionDetector(events, sessions, locationProvider = { null })

        detector.onSignalUpdated(
            sample(0, SignalKey.EV_CHARGE_PLUG_TYPE, GeelyProperties.ChargePlugStateAcConnected),
            snapshot(0, charger = 211.1f to 6.8f)
        )
        detector.onSignalUpdated(
            sample(1, SignalKey.EV_CHARGE_STATE, GeelyProperties.ChargeStateAcCharging),
            snapshot(1, charger = 211.6f to 6.7f)
        )
        assertNotNull(detector.activeFrameSession())

        // Carga parada pela central: o estado sai de "carregando" mas não vira
        // "completa", o plugue continua conectado, e o par do carregador para
        // no tempo.
        val frozen = 215.0f to 4.8f
        detector.onSignalUpdated(
            sample(10, SignalKey.HV_BATTERY_SOC, 63.3f),
            snapshot(10, chargeState = GeelyProperties.ChargeStateAcChargingSuspend, charger = frozen)
        )
        // Ainda dentro da janela de congelamento: nada acontece.
        detector.onSignalUpdated(
            sample(60, SignalKey.HV_BATTERY_SOC, 63.3f),
            snapshot(60, chargeState = GeelyProperties.ChargeStateAcChargingSuspend, charger = frozen)
        )
        assertEquals(0, sessions.closeCount)

        // Congelamento reconhecido; começa a confirmação de fim.
        detector.onSignalUpdated(
            sample(110, SignalKey.HV_BATTERY_SOC, 63.3f),
            snapshot(110, chargeState = GeelyProperties.ChargeStateAcChargingSuspend, charger = frozen)
        )
        assertEquals(0, sessions.closeCount)

        // Passados os 120 s de confirmação, a sessão encerra por perda de potência.
        detector.onSignalUpdated(
            sample(235, SignalKey.HV_BATTERY_SOC, 63.3f),
            snapshot(235, chargeState = GeelyProperties.ChargeStateAcChargingSuspend, charger = frozen)
        )
        assertEquals(1, sessions.closeCount)
        assertEquals("ENDED_WAITING_DISCONNECT", sessions.status)
        assertEquals(ChargeEndReason.POWER_LOST.name, sessions.chargeEndReason)
    }

    @Test
    fun chargingSessionSurvivesWhileChargerReadingsKeepMoving() {
        val events = FakeChargeEventSink()
        val sessions = FakeChargeSessionStore()
        val detector = ChargeSessionDetector(events, sessions, locationProvider = { null })

        detector.onSignalUpdated(
            sample(0, SignalKey.EV_CHARGE_PLUG_TYPE, GeelyProperties.ChargePlugStateAcConnected),
            snapshot(0, charger = 211.1f to 6.8f)
        )
        detector.onSignalUpdated(
            sample(1, SignalKey.EV_CHARGE_STATE, GeelyProperties.ChargeStateAcCharging),
            snapshot(1, charger = 211.6f to 6.7f)
        )

        // Tensão de rede oscila sempre; enquanto oscilar, é carga de verdade,
        // mesmo depois de muito mais que a janela de congelamento.
        var voltage = 211.6f
        for (second in listOf(100, 200, 300, 400, 500)) {
            voltage += 0.3f
            detector.onSignalUpdated(
                sample(second, SignalKey.HV_BATTERY_SOC, 63.3f),
                snapshot(second, charger = voltage to 6.7f)
            )
        }

        assertEquals(0, sessions.closeCount)
        assertNotNull(detector.activeFrameSession())
    }

    /**
     * Medido no carro em 2026-07-26 e encontrado no banco: uma carga AC de
     * 1.04 kW gravou `startPowerKw = 20.5`. A potência DC estava congelada em
     * 20.5 kW com o carimbo do VHAL de meia hora antes, e era aceita sem
     * nenhum teste de frescor — vencia o par AC, que estava vivo.
     */
    @Test
    fun frozenDcPowerDoesNotOutrankALiveChargerPair() {
        val events = FakeChargeEventSink()
        val sessions = FakeChargeSessionStore()
        val detector = ChargeSessionDetector(events, sessions, locationProvider = { null })

        // Publicada há uma hora: no carro, 3741 s de idade.
        val frozenDc = 20.5f to 3_741L

        detector.onSignalUpdated(
            sample(0, SignalKey.EV_CHARGE_PLUG_TYPE, GeelyProperties.ChargePlugStateAcConnected),
            snapshot(0, charger = 216.5f to 4.8f, dcPower = frozenDc)
        )
        detector.onSignalUpdated(
            sample(1, SignalKey.EV_CHARGE_STATE, GeelyProperties.ChargeStateAcCharging),
            snapshot(1, charger = 216.6f to 4.8f, dcPower = frozenDc)
        )

        // Passada a janela, a potência DC parada cede a vez. A carga continua,
        // porque a tomada continua medindo — 216 V x 4.8 A = 1.04 kW.
        var voltage = 216.6f
        for (second in listOf(100, 200, 300, 400)) {
            voltage += 0.3f
            detector.onSignalUpdated(
                sample(second, SignalKey.HV_BATTERY_SOC, 64.5f),
                snapshot(second, charger = voltage to 4.8f, dcPower = frozenDc)
            )
        }

        assertEquals(0, sessions.closeCount)
        assertNotNull(detector.activeFrameSession())
    }

    /**
     * A outra metade do mesmo estrago: com 20.5 kW congelados sempre acima do
     * limiar de fim, a sessão perdia o caminho de encerrar por potência e só
     * fechava quando o plugue saía. Com o par AC também parado, congelamento
     * dos dois lados é fim de carga.
     */
    @Test
    fun frozenDcPowerAndFrozenChargerTogetherEndTheSession() {
        val events = FakeChargeEventSink()
        val sessions = FakeChargeSessionStore()
        val detector = ChargeSessionDetector(events, sessions, locationProvider = { null })

        // Publicada há uma hora: no carro, 3741 s de idade.
        val frozenDc = 20.5f to 3_741L

        detector.onSignalUpdated(
            sample(0, SignalKey.EV_CHARGE_PLUG_TYPE, GeelyProperties.ChargePlugStateAcConnected),
            snapshot(0, charger = 216.5f to 4.8f, dcPower = frozenDc)
        )
        detector.onSignalUpdated(
            sample(1, SignalKey.EV_CHARGE_STATE, GeelyProperties.ChargeStateAcCharging),
            snapshot(1, charger = 216.6f to 4.8f, dcPower = frozenDc)
        )
        assertNotNull(detector.activeFrameSession())

        val frozenCharger = 215.0f to 4.8f
        for (second in listOf(100, 200, 260, 320)) {
            detector.onSignalUpdated(
                sample(second, SignalKey.HV_BATTERY_SOC, 64.5f),
                snapshot(
                    second,
                    chargeState = GeelyProperties.ChargeStateAcChargingSuspend,
                    charger = frozenCharger,
                    dcPower = frozenDc
                )
            )
        }

        assertEquals(1, sessions.closeCount)
        assertEquals("ENDED_WAITING_DISCONNECT", sessions.status)
    }

    @Test
    fun flickeringChargeStateDoesNotReopenAnEndedSession() {
        val events = FakeChargeEventSink()
        val sessions = FakeChargeSessionStore()
        val detector = ChargeSessionDetector(events, sessions, locationProvider = { null })

        detector.onSignalUpdated(
            sample(0, SignalKey.EV_CHARGE_PLUG_TYPE, GeelyProperties.ChargePlugStateAcConnected),
            snapshot(0, charger = 211.1f to 6.8f)
        )
        detector.onSignalUpdated(
            sample(1, SignalKey.EV_CHARGE_STATE, GeelyProperties.ChargeStateAcCharging),
            snapshot(1, charger = 211.6f to 6.7f)
        )

        // The charge ends on frozen charger readings, as in the session that
        // hit its limit and then sat plugged in.
        val frozen = 215.0f to 4.8f
        for (seconds in listOf(10, 110, 235)) {
            detector.onSignalUpdated(
                sample(seconds, SignalKey.HV_BATTERY_SOC, 70f),
                snapshot(
                    seconds,
                    chargeState = GeelyProperties.ChargeStateAcChargingSuspend,
                    charger = frozen
                )
            )
        }
        assertEquals(1, sessions.closeCount)
        assertEquals("ENDED_WAITING_DISCONNECT", sessions.status)

        // The plug is pulled: the state flickers back through "charging" while
        // the charger pair stays latched at its last value. A latched reading
        // is not energy flowing, so the session must stay closed.
        for (seconds in listOf(240, 245, 250, 255)) {
            detector.onSignalUpdated(
                sample(seconds, SignalKey.EV_CHARGE_STATE, GeelyProperties.ChargeStateAcCharging),
                snapshot(
                    seconds,
                    chargeState = GeelyProperties.ChargeStateAcCharging,
                    charger = frozen
                )
            )
        }

        assertEquals("ENDED_WAITING_DISCONNECT", sessions.status)
        assertEquals(
            0,
            events.events.count {
                it.type == TelemetryEventType.CHARGE_STARTED && it.value == "resumed"
            }
        )
    }

    @Test
    fun sustainedRealPowerStillReopensAnEndedSession() {
        val events = FakeChargeEventSink()
        val sessions = FakeChargeSessionStore()
        val detector = ChargeSessionDetector(events, sessions, locationProvider = { null })

        detector.onSignalUpdated(
            sample(0, SignalKey.EV_CHARGE_PLUG_TYPE, GeelyProperties.ChargePlugStateAcConnected),
            snapshot(0, charger = 211.1f to 6.8f)
        )
        detector.onSignalUpdated(
            sample(1, SignalKey.EV_CHARGE_STATE, GeelyProperties.ChargeStateAcCharging),
            snapshot(1, charger = 211.6f to 6.7f)
        )
        val frozen = 215.0f to 4.8f
        for (seconds in listOf(10, 110, 235)) {
            detector.onSignalUpdated(
                sample(seconds, SignalKey.HV_BATTERY_SOC, 70f),
                snapshot(
                    seconds,
                    chargeState = GeelyProperties.ChargeStateAcChargingSuspend,
                    charger = frozen
                )
            )
        }
        assertEquals("ENDED_WAITING_DISCONNECT", sessions.status)

        // Charger readings start moving again and keep moving past the start
        // confirmation window: that is a real resume.
        detector.onSignalUpdated(
            sample(240, SignalKey.HV_BATTERY_SOC, 70f),
            snapshot(240, chargeState = GeelyProperties.ChargeStateAcCharging, charger = 216.0f to 5.0f)
        )
        detector.onSignalUpdated(
            sample(250, SignalKey.HV_BATTERY_SOC, 70f),
            snapshot(250, chargeState = GeelyProperties.ChargeStateAcCharging, charger = 216.4f to 5.1f)
        )

        assertEquals(
            1,
            events.events.count {
                it.type == TelemetryEventType.CHARGE_STARTED && it.value == "resumed"
            }
        )
    }

    @Test
    fun chargeEventsCarrySessionId() {
        val events = FakeChargeEventSink()
        val sessions = FakeChargeSessionStore()
        val detector = ChargeSessionDetector(events, sessions, locationProvider = { null })

        detector.onSignalUpdated(
            sample(0, SignalKey.EV_CHARGE_PLUG_TYPE, GeelyProperties.ChargePlugStateAcConnected),
            snapshot(0)
        )

        val connectedEvent = events.events.first { it.type == TelemetryEventType.CHARGE_PLUG_CONNECTED }
        assertNotNull(connectedEvent.sessionId)
        val expectedSessionId = connectedEvent.sessionId

        detector.onSignalUpdated(
            sample(1, SignalKey.EV_CHARGE_STATE, GeelyProperties.ChargeStateAcCharging),
            snapshot(1)
        )
        val startedEvent = events.events.first { it.type == TelemetryEventType.CHARGE_STARTED }
        assertEquals(expectedSessionId, startedEvent.sessionId)

        // End charging after missing plug and charge state
        detector.onSignalUpdated(
            sample(10, SignalKey.HV_BATTERY_SOC, 56.5f),
            snapshot(10, includeChargeState = false, includePlug = false)
        )
        detector.onSignalUpdated(
            sample(26, SignalKey.HV_BATTERY_SOC, 56.5f),
            snapshot(26, includeChargeState = false, includePlug = false)
        )
        val endedEvent = events.events.first { it.type == TelemetryEventType.CHARGE_ENDED }
        assertEquals(expectedSessionId, endedEvent.sessionId)

        val disconnectedEvent = events.events.first { it.type == TelemetryEventType.CHARGE_PLUG_DISCONNECTED }
        assertEquals(expectedSessionId, disconnectedEvent.sessionId)
    }

    private fun snapshot(
        seconds: Int,
        includeChargeState: Boolean = true,
        includePlug: Boolean = true,
        soc: Float = 63.3f,
        odometer: Float = 1627.3f,
        chargeState: Int = GeelyProperties.ChargeStateAcCharging,
        plugType: Int = GeelyProperties.ChargePlugStateAcConnected,
        charger: Pair<Float, Float>? = null,
        /** Potência DC e há quantos segundos o VHAL a publicou. */
        dcPower: Pair<Float, Long>? = null
    ): Map<SignalKey, SignalSample> {
        val values = mutableMapOf<SignalKey, SignalSample>(
            SignalKey.HV_BATTERY_SOC to sample(seconds, SignalKey.HV_BATTERY_SOC, soc),
            SignalKey.ODOMETER to sample(seconds, SignalKey.ODOMETER, odometer)
        )
        dcPower?.let { (value, ageSeconds) ->
            val publishedAt = seconds * 1_000_000_000L - ageSeconds * 1_000_000_000L
            values[SignalKey.EV_DC_CHARGE_POWER] = sample(
                seconds,
                SignalKey.EV_DC_CHARGE_POWER,
                value
            ).let { it.copy(timestamp = it.timestamp.copy(sourceTimestampNanos = publishedAt)) }
        }
        charger?.let { (voltage, current) ->
            values[SignalKey.HV_BATTERY_VOLTAGE] =
                sample(seconds, SignalKey.HV_BATTERY_VOLTAGE, voltage)
            values[SignalKey.HV_BATTERY_CURRENT] =
                sample(seconds, SignalKey.HV_BATTERY_CURRENT, current)
        }
        if (includeChargeState) {
            values[SignalKey.EV_CHARGE_STATE] =
                sample(seconds, SignalKey.EV_CHARGE_STATE, chargeState)
        }
        if (includePlug) {
            values[SignalKey.EV_CHARGE_PLUG_TYPE] =
                sample(seconds, SignalKey.EV_CHARGE_PLUG_TYPE, plugType)
        }
        return values
    }

    private fun sample(seconds: Int, signalId: SignalKey, value: Any?): SignalSample {
        return SignalSample(
            signalId = signalId,
            value = value,
            unit = "",
            quality = SignalQuality.MEASURED,
            source = SignalSource.VHAL_POLLING,
            propertyId = 0,
            propertyIdHex = "0x00000000",
            areaId = 0,
            timestamp = timestamp(seconds),
            details = "test"
        )
    }

    private fun timestamp(seconds: Int): SignalTimestamp {
        return SignalTimestamp(
            receivedAtUtcMillis = 1_700_000_000_000L + seconds * 1_000L,
            receivedAtElapsedNanos = seconds * 1_000_000_000L,
            sourceTimestampNanos = null,
            accuracy = TimestampAccuracy.POLLED,
            uncertaintyMillis = 0L
        )
    }

    private fun chargeSession(
        id: String,
        status: String,
        connectedSecond: Int,
        startedSecond: Int?
    ): SessionEntity {
        val connectedAt = timestamp(connectedSecond)
        val startedAt = startedSecond?.let(::timestamp)
        return SessionEntity(
            id = id,
            vehicleId = "test-vehicle",
            kind = "CHARGE",
            status = status,
            startedAtUtcMillis = connectedAt.receivedAtUtcMillis,
            startedAtElapsedNanos = connectedAt.receivedAtElapsedNanos,
            chargeStartedAtUtcMillis = startedAt?.receivedAtUtcMillis,
            chargeStartedAtElapsedNanos = startedAt?.receivedAtElapsedNanos,
            startSocPercent = 56.4f,
            startOdometerKm = 1627.3f,
            plugType = GeelyProperties.ChargePlugStateAcConnected,
            startPowerKw = 1.05f,
            createdAtUtcMillis = connectedAt.receivedAtUtcMillis,
            updatedAtUtcMillis = System.currentTimeMillis()
        )
    }
}

private class FakeChargeEventSink : ChargeEventSink {
    val events = mutableListOf<TelemetryEvent>()

    override fun appendEvent(event: TelemetryEvent) {
        events.add(event)
    }

    override fun sessionEvent(
        type: TelemetryEventType,
        timestamp: SignalTimestamp,
        value: Any?,
        previousValue: Any?,
        source: SignalSource?,
        details: String,
        sessionId: String?
    ): TelemetryEvent {
        return TelemetryEvent(
            id = UUID.randomUUID().toString(),
            type = type,
            timestamp = timestamp,
            signalId = null,
            value = value,
            previousValue = previousValue,
            quality = null,
            source = source,
            details = details,
            sessionId = sessionId
        )
    }
}

private class FakeChargeSessionStore(
    private val openSession: SessionEntity? = null
) : ChargeSessionStore {
    var closeCount = 0
    var chargeEndReason: String? = null
    var disconnectReason: String? = null
    var status: String? = null
    var persistedPlugType: Int? = null
    private var activeId = openSession?.id

    override fun latestOpenChargeSession(): SessionEntity? = openSession

    override fun createChargeSession(
        plugConnectedAt: SignalTimestamp,
        startSoc: Float?,
        startOdometerKm: Float?,
        plugType: Int?,
        startLocation: LocationSnapshot?,
        startAmbientTempC: Float?
    ): String {
        activeId = UUID.randomUUID().toString()
        return activeId!!
    }

    override fun updateChargeStarted(
        id: String?,
        plugConnectedAt: SignalTimestamp?,
        chargeStartedAt: SignalTimestamp,
        startSoc: Float?,
        startOdometerKm: Float?,
        plugType: Int?,
        startPowerKw: Float?,
        startLocation: LocationSnapshot?,
        startAmbientTempC: Float?
    ): String {
        persistedPlugType = plugType
        activeId = id ?: UUID.randomUUID().toString()
        return activeId!!
    }

    override fun updateChargePlugType(id: String?, plugType: Int) {
        persistedPlugType = plugType
    }

    override fun closeChargeSession(
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
        chargeEndReason: String?,
        disconnectReason: String?,
        status: String
    ) {
        closeCount += 1
        this.chargeEndReason = chargeEndReason ?: this.chargeEndReason
        this.disconnectReason = disconnectReason ?: this.disconnectReason
        this.status = status
    }
}
