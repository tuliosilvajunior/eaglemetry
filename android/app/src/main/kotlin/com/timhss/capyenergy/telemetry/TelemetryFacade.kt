package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.GeelyProfile
import com.timhss.capyenergy.profile.VehicleProfile

/**
 * The read side of the telemetry engine, shaped for the method channel.
 *
 * Every function here answers one Flutter call and returns the wire map for it.
 * It was split out of `TelemetryRuntime` so the presentation surface is a
 * distinct object from the wiring ([TelemetryGraph]) and the lifecycle
 * ([TelemetryRuntime]).
 *
 * These maps are the hand-written wire format the Pigeon migration replaces.
 * Keep new keys out of the repositories and inside this file, so the eventual
 * generated DTOs have one place to take over from.
 */
internal class TelemetryFacade(
    private val graph: TelemetryGraph,
    private val profile: VehicleProfile = GeelyProfile,
    // Wall clock for the registered-claim window; injected so tests freeze it.
    private val nowMillis: () -> Long = System::currentTimeMillis,
    // Last, so the trailing-lambda call site stays readable.
    private val isRunning: () -> Boolean,
) {
    fun status(): CollectorStatus {
        val snapshot = graph.store.snapshot()
        val lastUpdate = snapshot.values.maxOfOrNull { it.timestampMillis } ?: 0L
        val running = isRunning()
        return CollectorStatus(
            running = running,
            collectorStatus = if (running) "running" else "stopped",
            vehicleActivity = graph.vehicleActivityDetector.classify(snapshot),
            tripState = TripState.valueOf(
                graph.tripSessionDetector.statusMap()["tripState"].toString()
            ),
            chargeState = ChargeSessionState.valueOf(
                graph.chargeSessionDetector.statusMap()["chargeState"].toString()
            ),
            callbackSignals = graph.vhalSubscriptionManager.callbackSignalCount(),
            pollingSignals = graph.vhalSubscriptionManager.pollingSignalCount(),
            lastUpdateMillis = lastUpdate,
            signalCount = snapshot.size
        )
    }

    /**
     * What this vehicle can do, as opposed to what it is measuring now.
     *
     * The shell reads it to decide which destinations exist. It is a profile
     * fact and never changes while the process runs, so it carries no
     * timestamp: a capability that came and went would be a fault report, and
     * this is not one.
     *
     * The names on the wire are the enum names. A side that does not know one
     * must ignore it and keep the rest, never drop the whole answer — that is
     * the 2026-08-15 range-estimate defect, where an unknown source name
     * dropped a whole estimate.
     */
    fun vehicleCapabilitiesMap(): Map<String, Any?> = mapOf(
        "profileId" to profile.id,
        "capabilities" to profile.capabilities.map { it.name }.sorted()
    )

    fun collectorStatusMap(): Map<String, Any?> = status().toMap() + mapOf(
        "persistence" to mapOf(
            "writer" to TelemetryWriteCoordinator.executor.statusMap(),
            "frames" to graph.frameRepository.statusMap(),
            "events" to graph.eventRepository.statusMap(),
            "sessions" to graph.sessionRepository.statusMap(),
            "retention" to graph.retentionManager.statusMap(),
            "database" to graph.databaseHealthReporter.statusMap()
        )
    )

    fun liveMetadataMap(): Map<String, Any?> = mapOf(
        "status" to status().toMap(),
        "trip" to graph.tripSessionDetector.statusMap(),
        "charge" to graph.chargeSessionDetector.statusMap(),
        "location" to graph.locationSignalProvider.statusMap() + mapOf(
            "gpsEnabled" to graph.settings.gpsEnabled()
        ),
        "sessions" to graph.sessionRepository.statusMap(),
        "frames" to graph.frameRepository.statusMap(),
        "events" to graph.eventRepository.statusMap(),
        "retention" to graph.retentionManager.statusMap(),
        "database" to graph.databaseHealthReporter.statusMap(),
        "persistenceWriter" to TelemetryWriteCoordinator.executor.statusMap(),
        "helpers" to graph.temperatureModeHelperMonitor.statusMap(),
        "roadcast" to roadcastStatusMap(),
        "recentEvents" to graph.eventRepository.recent(20).map { it.toMap() }
    )

    fun latestSnapshotMap(): Map<String, Any?> {
        val snapshot = graph.store.snapshot()
        return mapOf(
            "timestampMillis" to System.currentTimeMillis(),
            "signals" to snapshot.values.map { it.toMap() },
        ) + liveMetadataMap()
    }

    fun roadcastStatusMap(): Map<String, Any?> {
        val client = graph.roadcastRepository.statusMap()
        return (graph.state.roadcastStatus ?: graph.roadcastDaemon.status()).toMap() +
            mapOf(
                "signalCount" to client["signalCount"],
                "frameCount" to client["frameCount"],
                "hz" to client["hz"],
                "client" to client
            )
    }

    fun roadcastUpdateStatusMap(): Map<String, Any?> =
        graph.roadcastUpdateManager.localStatus(installedRoadcastSha256()).toMap()

    fun checkRoadcastUpdate(): Map<String, Any?> =
        graph.roadcastUpdateManager.check(installedRoadcastSha256()).toMap()

    fun installedRoadcastSha256(): String? =
        runCatching { graph.roadcastDaemon.installedSha256() }.getOrNull()

    /** Typed: the bridge spells it, against the generated class. */
    fun rangeEstimate(): NativeRangeEstimate = graph.rangeEstimateMonitor.snapshot()

    /**
     * The GNSS course over ground. Typed, and it reads no database, so it
     * answers on the platform thread.
     */
    fun heading(): VehicleHeading =
        graph.locationSignalProvider.heading(graph.settings.gpsEnabled())

    fun recentEventsMap(limit: Int): Map<String, Any?> =
        graph.eventRepository.recentMap(limit)

    // The session lists answer typed; the bridge spells them.
    fun recentChargeSessions(limit: Int): ChargeSessionPage =
        graph.sessionRepository.recentChargeSessions(limit)

    fun chargeMergeCandidates(limit: Int): ChargeMergeCandidatePage =
        graph.sessionRepository.chargeMergeCandidates(limit)

    fun recentTripSessions(limit: Int): TripSessionPage =
        graph.sessionRepository.recentTripSessions(limit)

    /**
     * Closed trips the Insights engine may compare. Session aggregates and
     * minute-bucket presence only — never frames.
     */
    fun insightTrips(subjectId: String?): InsightTripsPage =
        graph.insightRepository.trips(subjectId)

    fun insightPlaces(): List<InsightPlaceRow> = graph.insightRepository.places()

    fun saveInsightPlace(
        id: String?,
        name: String,
        latitude: Double,
        longitude: Double,
        radiusM: Double,
        autoName: String? = null,
        autoNameUpdatedAtUtcMillis: Long? = null,
        autoNameSource: String? = null,
    ): InsightPlaceRow = graph.insightRepository.savePlace(
        id = id,
        name = name,
        latitude = latitude,
        longitude = longitude,
        radiusM = radiusM,
        autoName = autoName,
        autoNameUpdatedAtUtcMillis = autoNameUpdatedAtUtcMillis,
        autoNameSource = autoNameSource,
    )

    fun deleteInsightPlace(id: String) = graph.insightRepository.deletePlace(id)

    /**
     * The battery cycles, newest first. The read folds any new sessions first,
     * so the open cycle is current.
     */
    fun batteryCycles(limit: Int): BatteryCyclePage =
        graph.batteryCycleRepository.cycles(limit)

    /**
     * What one cycle is made of, oldest session first.
     *
     * Two reads, joined here rather than in either repository: the membership
     * is the fold's own attribution and belongs to the cycles, the sessions
     * belong to the session repository, and neither may reach into the other.
     *
     * A session the retention has deleted keeps its row, marked deleted, with
     * the window the fold stored. It is still part of what the cycle counted,
     * and dropping it would make a short list look like a whole one.
     */
    fun batteryCycleSessions(ordinal: Long): BatteryCycleSessionsPage {
        val sessions = graph.batteryCycleRepository.sessions(ordinal).map { member ->
            when (member.kind) {
                "TRIP" -> graph.sessionRepository.tripSession(member.sessionId).let { trip ->
                    member.copy(trip = trip, deleted = trip == null)
                }

                "CHARGE" -> graph.sessionRepository.chargeSession(member.sessionId)
                    .let { charge -> member.copy(charge = charge, deleted = charge == null) }

                // A parked session has no list row, so whether it is still
                // there is all there is to say about it.
                else -> member.copy(
                    deleted = !graph.sessionRepository.parkedSessionExists(member.sessionId)
                )
            }
        }
        return BatteryCycleSessionsPage(ordinal = ordinal, sessions = sessions)
    }

    // The energy series answer typed, not as wire maps: they are spelled by
    // the bridge, against the generated classes.
    fun liveEnergySeries(): LiveEnergyBuckets? = graph.frameRepository.liveEnergySeries()

    fun liveEfficiencySeries(): LiveEnergyBuckets? =
        graph.frameRepository.liveEfficiencySeries()

    fun liveChargeEnergySeries(): LiveEnergyBuckets? =
        graph.frameRepository.liveChargeEnergySeries()

    fun liveContinuousEnergySeries(): LiveEnergyBuckets? =
        graph.frameRepository.liveContinuousEnergySeries()

    fun efficiencyBucketMillis(): Long = graph.frameRepository.efficiencyBucketMillis()

    fun energySeriesInWindow(
        startUtcMillis: Long,
        endUtcMillis: Long
    ): WindowEnergySeries =
        graph.frameRepository.energySeriesInWindow(startUtcMillis, endUtcMillis)

    fun parkedEnergySeriesInWindow(
        startUtcMillis: Long,
        endUtcMillis: Long
    ): WindowEnergySeries =
        graph.frameRepository.parkedEnergySeriesInWindow(startUtcMillis, endUtcMillis)

    fun settingsMap(): Map<String, Any?> = graph.settings.toMap()

    fun isBleStreamActive(): Boolean =
        graph.liveTelemetryBleServer.hasConnectedClients()

    fun pairedCompanionDevices(): Map<String, Any?> {
        val streamActive = isBleStreamActive()
        return mapOf(
            "isBleStreamActive" to streamActive,
            "devices" to graph.companionDeviceManager.pairedDevices().map { device ->
                device.toPublicMap() + mapOf("isBleStreamActive" to streamActive)
            }
        )
    }

    fun cloudSyncProgress(): Map<String, Any?> {
        val db = graph.database
        val totalSessions = db.sessionDao().count()
        val dirtySessions = db.sessionDao().dirtySessionCount()
        val pendingSessions = db.sessionDao().pendingSessionCount()

        val totalIntervals = db.intervalDao().count()
        val dirtyIntervals = db.intervalDao().dirtyIntervalCount()
        val pendingIntervals = db.intervalDao().pendingIntervalCount()

        val totalTracks = db.trackDao().count()
        val dirtyTracks = db.trackDao().dirtyTrackCount()

        val totalEvents = db.telemetryEventDao().count()
        val dirtyEvents = db.telemetryEventDao().dirtyEventCount()

        val totalCycles = db.batteryCycleDao().count()
        val dirtyCycles = db.batteryCycleDao().dirtyCycleCount()

        val total = totalSessions + totalIntervals + totalTracks + totalEvents + totalCycles
        val dirty = dirtySessions + dirtyIntervals + dirtyTracks + dirtyEvents + dirtyCycles
        val pending = pendingSessions + pendingIntervals

        return mapOf(
            "totalCount" to total,
            "dirtyCount" to dirty,
            "pendingCount" to pending
        )
    }

    fun revokeCompanionDevice(deviceId: String): Map<String, Any?> {
        val revoked = graph.companionDeviceManager.revokeDevice(deviceId)
        if (revoked) {
            graph.syncCursorRepository.clearForDevice(deviceId)
        }
        return mapOf("revoked" to revoked)
    }

    // ── Cloud device pairing (issue #227) ──────────────────────────────
    // The pairing secret (`device_code`) lives only in
    // `PairingCoordinator.currentDeviceCode` (memory). `userCode` / `expiresAt`
    // are cached here in memory so the pending screen can render without
    // persisting the secret. Approved credential lives in TelemetrySettings.
    private var pendingCloudPairing: com.timhss.capyenergy.telemetry.pairing.PairingStartResult? = null
    private var lastCloudPairingTerminal: String? = null // "expired" | "rejected" | "invalidCode"

    suspend fun startDevicePairing(): Map<String, Any?> {
        val vehicleId = graph.resolveVehicleId()
        val result = graph.pairingCoordinator.start(vehicleId)
        pendingCloudPairing = result
        lastCloudPairingTerminal = null
        return com.timhss.capyenergy.telemetry.pairing.PairingStateMapper.startToMap(result, vehicleId)
    }

    suspend fun getDevicePairingState(): Map<String, Any?> {
        // Approved is persisted — always wins.
        if (graph.settings.pairingStatus() == TelemetrySettings.PAIRING_STATUS_APPROVED) {
            pendingCloudPairing = null
            lastCloudPairingTerminal = null
            return com.timhss.capyenergy.telemetry.pairing.PairingStateMapper.approvedToMap(
                graph.resolveVehicleId(), graph.settings.accountId()
            )
        }
        // A registered-but-unclaimed car holds a token with no account: show
        // the registered state instead of falling through to idle, so the
        // screen does not offer to pair a car that has already registered.
        // The claim window matches the pairing-code TTL (5 minutes): past it
        // the phone will never claim this registration, so drop the orphan
        // token and fall through to idle (the "new code" retry button).
        if (graph.settings.pairingStatus() == TelemetrySettings.PAIRING_STATUS_REGISTERED) {
            if (registeredClaimLive(graph.settings.registeredAtUtcMillis(), nowMillis())) {
                pendingCloudPairing = null
                lastCloudPairingTerminal = null
                return com.timhss.capyenergy.telemetry.pairing.PairingStateMapper.registeredToMap()
            }
            pendingCloudPairing = null
            lastCloudPairingTerminal = null
            graph.settings.resetRegistration()
        }
        if (graph.settings.pairingStatus() == TelemetrySettings.PAIRING_STATUS_REVOKED) {
            pendingCloudPairing = null
            lastCloudPairingTerminal = null
            return com.timhss.capyenergy.telemetry.pairing.PairingStateMapper.revokedToMap()
        }
        if (graph.pairingCoordinator.currentDeviceCode != null) {
            val pendingSnapshot = pendingCloudPairing
            val result = graph.pairingCoordinator.pollOnce()
            when (result) {
                is com.timhss.capyenergy.telemetry.pairing.PairingPollResult.Pending -> {
                    // keep pending cache
                }
                is com.timhss.capyenergy.telemetry.pairing.PairingPollResult.Approved -> {
                    pendingCloudPairing = null
                    lastCloudPairingTerminal = null
                }
                is com.timhss.capyenergy.telemetry.pairing.PairingPollResult.Expired -> {
                    pendingCloudPairing = null
                    lastCloudPairingTerminal = "expired"
                }
                is com.timhss.capyenergy.telemetry.pairing.PairingPollResult.Rejected -> {
                    pendingCloudPairing = null
                    lastCloudPairingTerminal = "rejected"
                }
                is com.timhss.capyenergy.telemetry.pairing.PairingPollResult.InvalidCode -> {
                    pendingCloudPairing = null
                    lastCloudPairingTerminal = "invalidCode"
                }
            }
            return com.timhss.capyenergy.telemetry.pairing.PairingStateMapper.pollResultToMap(
                result,
                if (result is com.timhss.capyenergy.telemetry.pairing.PairingPollResult.Pending) pendingSnapshot else null,
                graph.resolveVehicleId()
            )
        }
        // No active secret but we remember the last terminal so the screen
        // can distinguish expired vs rejected vs invalid after the poll cleared the code.
        lastCloudPairingTerminal?.let { terminal ->
            return com.timhss.capyenergy.telemetry.pairing.PairingStateMapper.terminalToMap(terminal)
        }
        return com.timhss.capyenergy.telemetry.pairing.PairingStateMapper.idleToMap()
    }

    suspend fun cancelDevicePairing(): Map<String, Any?> {
        graph.pairingCoordinator.cancel()
        pendingCloudPairing = null
        // Preserve approved: coordinator does not clear approved credential.
        if (graph.settings.pairingStatus() == TelemetrySettings.PAIRING_STATUS_APPROVED) {
            lastCloudPairingTerminal = null
            return com.timhss.capyenergy.telemetry.pairing.PairingStateMapper.approvedToMap(
                graph.resolveVehicleId(), graph.settings.accountId()
            ) + mapOf("cancelled" to true)
        }
        lastCloudPairingTerminal = null
        return com.timhss.capyenergy.telemetry.pairing.PairingStateMapper.idleToMap() + mapOf("cancelled" to true)
    }

    companion object {
        /**
         * How long a registered-but-unclaimed car keeps showing "registered"
         * before the orphan token is dropped and the screen offers a new code.
         * Matches the pairing-code TTL (`device_pairing_sessions.expires_at`
         * defaults to `now() + interval '5 minutes'` server-side): past this
         * window no phone claim can still land, so keeping the token only
         * strands the car on a dead-end screen.
         */
        const val REGISTERED_CLAIM_WINDOW_MILLIS = 5 * 60 * 1_000L

        /**
         * Pure claim-window check, extracted for tests. A missing timestamp
         * (pre-field installs) reads as expired: resetting to unpaired lets
         * the boot driver re-register honestly instead of stranding the car.
         */
        @JvmStatic
        fun registeredClaimLive(registeredAtUtcMillis: Long?, nowUtcMillis: Long): Boolean =
            registeredAtUtcMillis != null && nowUtcMillis - registeredAtUtcMillis < REGISTERED_CLAIM_WINDOW_MILLIS
    }
}
