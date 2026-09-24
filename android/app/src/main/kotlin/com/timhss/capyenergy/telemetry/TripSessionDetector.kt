package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey

import com.timhss.capyenergy.telemetry.db.SessionEntity

interface TripEventSink {
    fun appendEvent(event: TelemetryEvent)

    fun sessionEvent(
        type: TelemetryEventType,
        timestamp: SignalTimestamp,
        value: Any?,
        previousValue: Any? = null,
        source: SignalSource? = null,
        details: String,
        sessionId: String? = null
    ): TelemetryEvent

    /**
     * Claims the declared events already written inside a session's window.
     *
     * A gear change is what arms a trip, and it reaches the event repository
     * before the detector has a session to name — so without this the one
     * event that explains the drive would be the one missing from it.
     */
    fun backStampSession(sessionId: String, fromUtcMillis: Long, toUtcMillis: Long) {}
}

interface TripSessionStore {
    fun latestOpenTripSession(): SessionEntity?

    fun createTripSession(
        startedAt: SignalTimestamp,
        movementStartedAt: SignalTimestamp?,
        startSoc: Float?,
        startOdometerKm: Float?,
        startGear: Int?,
        startLocation: LocationSnapshot?,
        status: String = "ACTIVE"
    ): String

    fun closeTripSession(
        id: String?,
        startedAt: SignalTimestamp?,
        movementStartedAt: SignalTimestamp?,
        endedAt: SignalTimestamp,
        startSoc: Float?,
        endSoc: Float?,
        startOdometerKm: Float?,
        endOdometerKm: Float?,
        startGear: Int?,
        reason: TripEndReason
    )

    fun markTripActive(id: String, movementStartedAt: SignalTimestamp)

    fun deleteTripSession(id: String)
}

class TripSessionDetector(
    private val eventRepository: TripEventSink,
    private val sessionRepository: TripSessionStore,
    /**
     * Where the trip began.
     *
     * A charge has had this since it was written; a trip never did, which is
     * why `session.startLatitude` was null on every recorded drive. The
     * default keeps a test that only exercises the state machine free of a
     * receiver.
     */
    private val locationProvider: () -> LocationSnapshot? = { null }
) : SignalStateStore.Listener {
    private var state = TripState.IDLE
    private var activeSessionId: String? = null
    private var previousGear: Int? = null
    private var armedAt: SignalTimestamp? = null
    private var armedGear: Int? = null
    private var provisionalSoc: Float? = null
    private var provisionalOdometer: Float? = null
    private var movementCandidateAt: SignalTimestamp? = null
    private var lastMovementSampleAt: SignalTimestamp? = null
    private var lastMovementSpeedKmh: Float? = null
    private var armedEstimatedDistanceKm: Double = 0.0
    private var armedPeakSpeedKmh: Float = 0f
    private var tripStartedAt: SignalTimestamp? = null
    private var movementStartedAt: SignalTimestamp? = null
    private var possibleTripEndAt: SignalTimestamp? = null
    private var pendingEndGear: Int? = null
    private var lastGearChangedAt: SignalTimestamp? = null
    private var lastOdometerKm: Float? = null
    private var lastSoc: Float? = null
    private var restored = false

    fun restoreIfNeeded() {
        if (restored) return
        restored = true
        restoreOpenSession(sessionRepository.latestOpenTripSession())
    }

    @Synchronized
    override fun onSignalUpdated(sample: SignalSample, snapshot: Map<SignalKey, SignalSample>) {
        val gear = snapshot[SignalKey.GEAR]?.intValue()
        val speed = snapshot[SignalKey.VEHICLE_SPEED]?.floatValue() ?: 0f
        val odometer = snapshot[SignalKey.ODOMETER]?.floatValue()
        val soc = snapshot[SignalKey.HV_BATTERY_SOC]?.floatValue()
        val plugConnected = isPlugConnected(snapshot[SignalKey.EV_CHARGE_PLUG_TYPE]?.intValue())
        val charging = isChargingState(snapshot[SignalKey.EV_CHARGE_STATE]?.intValue())

        if (gear != null && gear != previousGear) {
            lastGearChangedAt = sample.timestamp
        }

        when (state) {
            TripState.IDLE -> maybeArmTrip(sample, gear, soc, odometer)
            TripState.ARMED -> handleArmed(sample, gear, speed, odometer)
            TripState.ACTIVE -> handleActive(sample, gear, speed)
            TripState.PENDING_END -> handlePendingEnd(sample, gear, speed, odometer, plugConnected || charging)
        }

        if (odometer != null) lastOdometerKm = odometer
        if (soc != null) lastSoc = soc
        previousGear = gear ?: previousGear
    }

    @Synchronized
    fun onCollectorTick(timestamp: SignalTimestamp, snapshot: Map<SignalKey, SignalSample>) {
        if (state != TripState.PENDING_END) return
        val gear = snapshot[SignalKey.GEAR]?.intValue()
        val speed = snapshot[SignalKey.VEHICLE_SPEED]?.floatValue() ?: 0f
        val odometer = snapshot[SignalKey.ODOMETER]?.floatValue()
        val plugConnected = isPlugConnected(snapshot[SignalKey.EV_CHARGE_PLUG_TYPE]?.intValue())
        val charging = isChargingState(snapshot[SignalKey.EV_CHARGE_STATE]?.intValue())
        handlePendingEnd(tickSample(timestamp, gear), gear, speed, odometer, plugConnected || charging)
    }

    @Synchronized
    fun statusMap(): Map<String, Any?> = mapOf(
        "tripState" to state.name,
        "activeSessionId" to activeSessionId,
        "tripStartedAtUtcMillis" to tripStartedAt?.receivedAtUtcMillis,
        "movementStartedAtUtcMillis" to movementStartedAt?.receivedAtUtcMillis,
        "armedEstimatedDistanceKm" to armedEstimatedDistanceKm,
        "armedPeakSpeedKmh" to armedPeakSpeedKmh,
        "possibleTripEndAtUtcMillis" to possibleTripEndAt?.receivedAtUtcMillis,
        "pendingEndGear" to pendingEndGear,
        "lastGearChangedAtUtcMillis" to lastGearChangedAt?.receivedAtUtcMillis
    )

    @Synchronized
    fun activeFrameSession(): ActiveFrameSession? {
        val id = activeSessionId ?: return null
        return if (state == TripState.ACTIVE || state == TripState.PENDING_END || state == TripState.ARMED) {
            ActiveFrameSession(id = id, type = "TRIP")
        } else {
            null
        }
    }

    @Synchronized
    fun reset() {
        state = TripState.IDLE
        activeSessionId = null
        previousGear = null
        armedAt = null
        armedGear = null
        provisionalSoc = null
        provisionalOdometer = null
        movementCandidateAt = null
        lastMovementSampleAt = null
        lastMovementSpeedKmh = null
        armedEstimatedDistanceKm = 0.0
        armedPeakSpeedKmh = 0f
        tripStartedAt = null
        movementStartedAt = null
        possibleTripEndAt = null
        pendingEndGear = null
        lastGearChangedAt = null
        lastOdometerKm = null
        lastSoc = null
    }

    private fun isStaleOpenSession(session: SessionEntity): Boolean {
        val lastActivityUtcMillis = session.updatedAtUtcMillis
        return lastActivityUtcMillis > 0 &&
            System.currentTimeMillis() - lastActivityUtcMillis > STALE_OPEN_SESSION_THRESHOLD_MILLIS
    }

    private fun closeStaleOpenSession(session: SessionEntity) {
        val started = timestampOrNull(session.startedAtUtcMillis, session.startedAtElapsedNanos)
        val endedAt = timestampOrNull(
            session.updatedAtUtcMillis,
            session.startedAtElapsedNanos
        ) ?: inferredNow()
        sessionRepository.closeTripSession(
            id = session.id,
            startedAt = started,
            movementStartedAt = timestampOrNull(
                session.movementStartedAtUtcMillis,
                session.movementStartedAtElapsedNanos
            ),
            endedAt = endedAt,
            startSoc = session.startSocPercent,
            endSoc = session.endSocPercent,
            startOdometerKm = session.startOdometerKm,
            endOdometerKm = session.endOdometerKm,
            startGear = session.startGear,
            reason = TripEndReason.APP_RESTART_RECOVERY
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
        state = when (session.status) {
            TripState.PENDING_END.name -> TripState.PENDING_END
            TripState.ARMED.name -> TripState.ARMED
            else -> TripState.ACTIVE
        }
        tripStartedAt = timestampOrNull(session.startedAtUtcMillis, session.startedAtElapsedNanos)
        movementStartedAt = timestampOrNull(
            session.movementStartedAtUtcMillis,
            session.movementStartedAtElapsedNanos
        )
        armedAt = tripStartedAt
        armedGear = session.startGear
        provisionalSoc = session.startSocPercent
        provisionalOdometer = session.startOdometerKm
        previousGear = session.startGear
        lastSoc = session.endSocPercent ?: session.startSocPercent
        lastOdometerKm = session.endOdometerKm ?: session.startOdometerKm
        eventRepository.appendEvent(
            eventRepository.sessionEvent(
                type = TelemetryEventType.TRIP_RECOVERED,
                timestamp = tripStartedAt ?: inferredNow(),
                value = session.id,
                source = SignalSource.SNAPSHOT_FALLBACK,
                details = "status=${session.status} startedAt=${session.startedAtUtcMillis}",
                sessionId = session.id
            )
        )
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

    private fun maybeArmTrip(sample: SignalSample, gear: Int?, soc: Float?, odometer: Float?) {
        val previous = previousGear
        // Arm on entering Drive from any non-Drive gear. The common real-world
        // departure is Park -> Reverse -> Drive (backing out of a spot first);
        // the earlier Neutral/Park-only check missed it because the gear right
        // before Drive is Reverse, leaving whole trips unattributed. Arming is
        // cheap and reversible: cancelArmed()/movement confirmation reject a
        // spurious Drive blip that never actually moves.
        if (!isDriveGear(previous) && isDriveGear(gear)) {
            state = TripState.ARMED
            armedAt = sample.timestamp
            armedGear = gear
            provisionalSoc = soc
            provisionalOdometer = odometer
            movementCandidateAt = null
            lastMovementSampleAt = null
            lastMovementSpeedKmh = null
            armedEstimatedDistanceKm = 0.0
            armedPeakSpeedKmh = 0f
            activeSessionId = sessionRepository.createTripSession(
                startedAt = sample.timestamp,
                movementStartedAt = null,
                startSoc = soc,
                startOdometerKm = odometer,
                startGear = gear,
                startLocation = locationProvider(),
                status = "ARMED"
            )
            activeSessionId?.let { id ->
                eventRepository.backStampSession(
                    sessionId = id,
                    fromUtcMillis = sample.timestamp.receivedAtUtcMillis,
                    toUtcMillis = sample.timestamp.receivedAtUtcMillis
                )
            }
            eventRepository.appendEvent(
                eventRepository.sessionEvent(
                    type = TelemetryEventType.TRIP_ARMED,
                    timestamp = sample.timestamp,
                    value = state.name,
                    source = sample.source,
                    details = "gear=$gear previousGear=$previous soc=$soc odometer=$odometer",
                    sessionId = activeSessionId
                )
            )
        }
    }

    private fun handleArmed(sample: SignalSample, gear: Int?, speed: Float, odometer: Float?) {
        if (isParkGear(gear) && speed <= MOVEMENT_SPEED_KMH) {
            cancelArmed(sample, "returned_to_park")
            return
        }

        val odometerMoved = odometer != null &&
            provisionalOdometer != null &&
            odometer >= provisionalOdometer!! + MIN_TRIP_ODOMETER_DELTA_KM
        if (odometerMoved && hasMaterialMovement(sample)) {
            startTrip(sample, "odometer_delta")
            return
        }

        if (speed > MOVEMENT_SPEED_KMH) {
            val candidate = movementCandidateAt
            if (candidate == null) {
                movementCandidateAt = sample.timestamp
            }
            updateArmedMovement(sample, speed)
            if (hasMaterialMovement(sample)) {
                startTrip(sample, "speed_confirmed")
            }
        } else if (movementCandidateAt != null) {
            updateArmedMovement(sample, speed)
        }
    }

    private fun updateArmedMovement(sample: SignalSample, speed: Float) {
        val previousAt = lastMovementSampleAt
        val previousSpeed = lastMovementSpeedKmh
        if (previousAt != null && previousSpeed != null) {
            val deltaSeconds =
                (sample.timestamp.receivedAtElapsedNanos - previousAt.receivedAtElapsedNanos) / 1_000_000_000.0
            if (deltaSeconds > 0.0 && deltaSeconds <= MAX_MOVEMENT_SAMPLE_GAP_SECONDS) {
                val averageSpeed = ((previousSpeed.coerceAtLeast(0f) + speed.coerceAtLeast(0f)) / 2.0)
                armedEstimatedDistanceKm += averageSpeed * (deltaSeconds / 3600.0)
            }
        }
        armedPeakSpeedKmh = maxOf(armedPeakSpeedKmh, speed)
        lastMovementSampleAt = sample.timestamp
        lastMovementSpeedKmh = speed
    }

    private fun hasMaterialMovement(sample: SignalSample): Boolean {
        val candidate = movementCandidateAt ?: return false
        val movementMillis = elapsedMillis(candidate, sample.timestamp)
        return armedEstimatedDistanceKm >= MIN_TRIP_ESTIMATED_DISTANCE_KM ||
            (movementMillis >= LONG_LOW_SPEED_MOVEMENT_CONFIRM_MILLIS &&
                armedEstimatedDistanceKm >= MIN_LONG_MOVEMENT_DISTANCE_KM &&
                armedPeakSpeedKmh >= LONG_LOW_SPEED_PEAK_KMH)
    }

    private fun handleActive(sample: SignalSample, gear: Int?, speed: Float) {
        if (isParkGear(gear) && speed <= MOVEMENT_SPEED_KMH) {
            state = TripState.PENDING_END
            possibleTripEndAt = sample.timestamp
            pendingEndGear = gear
            eventRepository.appendEvent(
                eventRepository.sessionEvent(
                    type = TelemetryEventType.TRIP_PENDING_END,
                    timestamp = sample.timestamp,
                    value = state.name,
                    source = sample.source,
                    details = "gear=$gear speed=$speed",
                    sessionId = activeSessionId
                )
            )
        }
    }

    private fun handlePendingEnd(
        sample: SignalSample,
        gear: Int?,
        speed: Float,
        odometer: Float?,
        chargingStarted: Boolean
    ) {
        if (chargingStarted) {
            endTrip(sample, TripEndReason.CHARGING_STARTED)
            return
        }

        if (isDriveGear(gear)) {
            state = TripState.ACTIVE
            possibleTripEndAt = null
            pendingEndGear = null
            return
        }

        val possibleEnd = possibleTripEndAt ?: return
        if (gear != null && !isParkGear(gear)) {
            state = TripState.ACTIVE
            possibleTripEndAt = null
            pendingEndGear = null
            return
        }

        val odometerStable = odometer == null ||
            lastOdometerKm == null ||
            odometer <= lastOdometerKm!! + MIN_ODOMETER_DELTA_KM
        val gearStableSincePark = pendingEndGear != null &&
            gear == pendingEndGear &&
            elapsedMillis(lastGearChangedAt ?: possibleEnd, sample.timestamp) >= PARK_GEAR_STABLE_CONFIRM_MILLIS
        if (isParkGear(gear) &&
            speed <= MOVEMENT_SPEED_KMH &&
            odometerStable &&
            gearStableSincePark
        ) {
            endTripAt(possibleEnd, sample, TripEndReason.PARK_CONFIRMED)
        }
    }

    private fun cancelArmed(sample: SignalSample, reason: String) {
        val sid = activeSessionId
        state = TripState.IDLE
        eventRepository.appendEvent(
            eventRepository.sessionEvent(
                type = TelemetryEventType.TRIP_CANCELLED,
                timestamp = sample.timestamp,
                value = reason,
                source = sample.source,
                details = "armedGear=$armedGear",
                sessionId = sid
            )
        )
        armedAt = null
        armedGear = null
        provisionalSoc = null
        provisionalOdometer = null
        movementCandidateAt = null
        lastMovementSampleAt = null
        lastMovementSpeedKmh = null
        armedEstimatedDistanceKm = 0.0
        armedPeakSpeedKmh = 0f
        activeSessionId = null
        if (sid != null) {
            sessionRepository.deleteTripSession(sid)
        }
    }

    private fun startTrip(sample: SignalSample, reason: String) {
        state = TripState.ACTIVE
        tripStartedAt = armedAt ?: sample.timestamp
        movementStartedAt = sample.timestamp
        val armedSessionId = activeSessionId
        if (armedSessionId != null) {
            sessionRepository.markTripActive(armedSessionId, sample.timestamp)
        } else {
            activeSessionId = sessionRepository.createTripSession(
                startedAt = tripStartedAt ?: sample.timestamp,
                movementStartedAt = movementStartedAt,
                startSoc = provisionalSoc,
                startOdometerKm = provisionalOdometer,
                startGear = armedGear,
                startLocation = locationProvider()
            )
            // A trip that was never armed is back-dated to when movement
            // began, so every declared event since then belongs to it.
            activeSessionId?.let { id ->
                eventRepository.backStampSession(
                    sessionId = id,
                    fromUtcMillis = (tripStartedAt ?: sample.timestamp).receivedAtUtcMillis,
                    toUtcMillis = sample.timestamp.receivedAtUtcMillis
                )
            }
        }
        eventRepository.appendEvent(
            eventRepository.sessionEvent(
                type = TelemetryEventType.TRIP_STARTED,
                timestamp = tripStartedAt ?: sample.timestamp,
                value = state.name,
                source = sample.source,
                details = "reason=$reason movementStartedAt=${movementStartedAt?.receivedAtUtcMillis} soc=$provisionalSoc odometer=$provisionalOdometer armedDistanceKm=$armedEstimatedDistanceKm armedPeakSpeedKmh=$armedPeakSpeedKmh",
                sessionId = activeSessionId
            )
        )
    }

    private fun endTrip(sample: SignalSample, reason: TripEndReason) {
        endTripAt(sample.timestamp, sample, reason)
    }

    private fun endTripAt(endedAt: SignalTimestamp, sample: SignalSample, reason: TripEndReason) {
        sessionRepository.closeTripSession(
            id = activeSessionId,
            startedAt = tripStartedAt,
            movementStartedAt = movementStartedAt,
            endedAt = endedAt,
            startSoc = provisionalSoc,
            endSoc = lastSoc,
            startOdometerKm = provisionalOdometer,
            endOdometerKm = lastOdometerKm,
            startGear = armedGear,
            reason = reason
        )
        eventRepository.appendEvent(
            eventRepository.sessionEvent(
                type = TelemetryEventType.TRIP_ENDED,
                timestamp = endedAt,
                value = reason.name,
                source = sample.source,
                details = "startedAt=${tripStartedAt?.receivedAtUtcMillis} movementStartedAt=${movementStartedAt?.receivedAtUtcMillis}",
                sessionId = activeSessionId
            )
        )
        state = TripState.IDLE
        activeSessionId = null
        armedAt = null
        armedGear = null
        provisionalSoc = null
        provisionalOdometer = null
        movementCandidateAt = null
        lastMovementSampleAt = null
        lastMovementSpeedKmh = null
        armedEstimatedDistanceKm = 0.0
        armedPeakSpeedKmh = 0f
        tripStartedAt = null
        movementStartedAt = null
        possibleTripEndAt = null
        pendingEndGear = null
    }

    private fun elapsedMillis(start: SignalTimestamp, end: SignalTimestamp): Long {
        return ((end.receivedAtElapsedNanos - start.receivedAtElapsedNanos) / 1_000_000L).coerceAtLeast(0L)
    }

    private fun tickSample(timestamp: SignalTimestamp, gear: Int?): SignalSample {
        return SignalSample(
            signalId = SignalKey.GEAR,
            value = gear,
            unit = "",
            quality = if (gear == null) SignalQuality.UNAVAILABLE else SignalQuality.MEASURED,
            source = SignalSource.SNAPSHOT_FALLBACK,
            propertyId = 0,
            propertyIdHex = "0x00000000",
            areaId = 0,
            timestamp = timestamp,
            details = "collector_tick"
        )
    }

    companion object {
        private const val MOVEMENT_SPEED_KMH = 2f
        private const val PARK_GEAR_STABLE_CONFIRM_MILLIS = 30_000L
        private const val MIN_ODOMETER_DELTA_KM = 0.001f
        private const val MIN_TRIP_ODOMETER_DELTA_KM = 0.2f
        private const val MIN_TRIP_ESTIMATED_DISTANCE_KM = 0.2
        private const val LONG_LOW_SPEED_MOVEMENT_CONFIRM_MILLIS = 120_000L
        private const val MIN_LONG_MOVEMENT_DISTANCE_KM = 0.05
        private const val LONG_LOW_SPEED_PEAK_KMH = 8f
        private const val MAX_MOVEMENT_SAMPLE_GAP_SECONDS = 10.0
        private const val STALE_OPEN_SESSION_THRESHOLD_MILLIS = 24L * 60L * 60L * 1_000L
    }
}
