package com.timhss.capyenergy.telemetry


import android.content.Context
import android.os.SystemClock
import android.util.Log
import com.timhss.capyenergy.roadcast.RoadcastClient
import com.timhss.capyenergy.roadcast.RoadcastDaemon
import java.util.concurrent.Callable
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * Lifecycle and commands for the telemetry engine.
 *
 * Construction and wiring live in [TelemetryGraph]; the read surface the method
 * channel calls lives in [TelemetryFacade]; the start and stop order lives in
 * [CollectionSequence]. This class owns what is left: the schedules, the
 * mutating commands, and the process-wide instance.
 *
 * The read functions are delegated rather than moved, so `TelemetryBridge` and
 * the Dart side see the same surface they saw before the split.
 */
class TelemetryRuntime internal constructor(
    context: Context,
    injectedNow: () -> Long = System::currentTimeMillis,
) {

    /**
     * Clock for boot registration timestamps. Injected for tests so a test
     * can prove that a registration that failed before the VIN landed is
     * re-keyed under the VIN the moment the upgrade happened — the B1 race
     * the runtime wiring must survive. Defaults to wall time.
     */
    private var bootRegistrationClock: () -> Long = injectedNow

    private val graph = TelemetryGraph(context)
    private val sequence = CollectionSequence(Participants())
    private val facade = TelemetryFacade(graph) { sequence.running }

    // A proposal acceptance runs the car's write path, which lives on this
    // object (it owns the settings and the cycle refold). The repository
    // cannot reach it, so the handler is set after construction.
    init {
        graph.preferenceRepository.setProposalAcceptedHandler { key, value ->
            applyPreferenceWrite(key, value)
        }
        // Fresh pairing: the approval credential is already persisted when
        // this fires (the coordinator hook runs after its settings writes),
        // so the first pass runs now — not on the next 15-minute tick — and
        // retries transient failures instead of fire-and-forget hoping.
        // Runs on the graph job thread; further attempts reschedule there.
        graph.onPairingApproved = { _ -> runPairingUpload(attempt = 0) }
    }

    private var collectorTick: ScheduledFuture<*>? = null

    @Volatile
    private var cloudUploadTick: ScheduledFuture<*>? = null

    /**
     * Finding 10: retention otherwise runs only at startup, so a run that
     * starts with an active session never gets another chance. The daily
     * timer retries it; [runRetention][com.timhss.capyenergy.telemetry.TelemetryRetentionManager.runRetention]
     * itself skips while a session is active and is cooldown-gated, so an
     * idle tick is a cheap no-op.
     */
    @Volatile
    private var retentionTick: ScheduledFuture<*>? = null

    @Volatile
    private var rangeRefresh: ScheduledFuture<*>? = null

    val publisher = LiveTelemetryPublisher(graph.store) { facade.liveMetadataMap() }

    /**
     * The account the car is currently paired to, or null when it is not
     * approved. Consumed by the read surface so the history lists can apply
     * the local ownership stamp without any hiding behaviour — the stamping
     * and adoption rules live in the DAO queries.
     */
    fun partialCurrentAccountId(): String? = graph.partialCurrentAccountId()

    /** Session writes, for the bridge to push to Flutter. */
    val sessionChanges: SessionChangeBroadcaster get() = graph.sessionChanges

    /** Annotation writes, for the bridge to push to Flutter. */
    val annotationChanges: AnnotationChangeBroadcaster get() = graph.annotationChanges
    val vehicleSpeedPublisher = VehicleSpeedPublisher(graph.store)
    val database: com.timhss.capyenergy.telemetry.db.TelemetryDatabase get() = graph.database

    init {
        graph.chargeControlIpcClient.start()
    }

    fun start() = sequence.start()

    fun stop() = sequence.stop()

    /**
     * One upload pass right after a fresh pairing approval, with bounded
     * retries on transient failure — a cold auth token or a network blip at
     * the moment of pairing must not silently drop the first delivery. The
     * 15-minute background tick remains the ultimate fallback; this only
     * closes the "how long before the FIRST attempt" gap.
     *
     * Permanent faults (401/403, schema) stop immediately: a retry would
     * just repeat them. Attempts run on the graph job thread via the same
     * pass the tick runs — no second upload path.
     */
    private fun runPairingUpload(attempt: Int) {
        if (triggerCloudUpload()) {
            if (attempt < PAIRING_UPLOAD_MAX_RETRIES) {
                graph.maintenanceExecutor.schedule(
                    { graph.jobExecutor.execute { runPairingUpload(attempt + 1) } },
                    pairingUploadRetryDelayMillis(attempt),
                    TimeUnit.SECONDS,
                )
            } else {
                Log.w(TAG, "Pairing upload still failing after retries; background tick stays the fallback")
            }
        }
    }

    /**
     * Boot-time pre-claim registration (issue #236 P2-T6 / B1).
     *
     * Owned by [BootRegistrationDriver] and called at startup (before the
     * first upload) and on the 15-minute cloud tick. Re-registers when the
     * credential was minted under a retired id, so an android_id-bound token
     * is re-keyed under the VIN the moment the identity upgrade lands.
     */
    private val bootRegistration: BootRegistrationDriver by lazy {
        BootRegistrationDriver(
            coordinator = graph.pairingCoordinator,
            settings = graph.settings,
            vehicleIdProvider = { graph.resolveVehicleId() },
            nowMillis = { bootRegistrationClock() },
            scheduleRetry = { delayMillis ->
                graph.maintenanceExecutor.schedule(
                    { graph.jobExecutor.execute { bootRegistration.run() } },
                    delayMillis,
                    TimeUnit.MILLISECONDS,
                )
            },
        )
    }

    private fun runBootRegistrationIfNeeded() = bootRegistration.run()

    internal val revocationDetector: RevocationDetector by lazy {
        RevocationDetector(
            settings = graph.settings,
            vehicleIdProvider = { graph.resolveVehicleId() },
            cloudSinkProvider = { graph.cloudSink },
        )
    }

    internal fun isRlsDenial(error: Throwable): Boolean = revocationDetector.isRlsDenial(error)
    internal fun handlePermanentUploadFailure(error: Throwable) = revocationDetector.handlePermanentUploadFailure(error)
    internal fun onRevoked() = revocationDetector.onRevoked()
    internal suspend fun updateCutoverReadiness(active: Boolean) = revocationDetector.updateCutoverReadiness(active, propagateFailure = active)

    /**
     * One upload pass over telemetry, annotations and preference control
     * sync, catching all failures so the caller never crashes.
     *
     * All faults set failed, including permanent faults (401/403, constraint);
     * transient faults set [CloudUploadPass.retrySoon] so the pairing retry
     * loop can come back sooner. The 15-minute tick ignores that flag.
     */
    internal fun runCloudUploadPass(): CloudUploadPass = runCloudUploadPass(
        uploadTelemetry = {
            kotlinx.coroutines.runBlocking { graph.telemetryCloudUploader.upload() }.perStream.values.sum()
        },
        uploadAnnotations = {
            kotlinx.coroutines.runBlocking { graph.annotationCloudUploader.upload() }.perStream.values.sum()
        },
        syncPreferences = {
            kotlinx.coroutines.runBlocking { graph.preferenceControlSync.sync() }
            Unit
        },
        handlePermanentUploadFailure = { handlePermanentUploadFailure(it) },
        updateReadiness = {
            if (graph.settings.pairingStatus() == TelemetrySettings.PAIRING_STATUS_APPROVED) {
                kotlinx.coroutines.runBlocking { updateCutoverReadiness(active = true) }
            }
        },
    )

    /**
     * Triggers one cloud upload run, catching all failures so the background
     * runner never crashes.
     *
     * @return true when a pass failed transiently and a sooner retry is
     *   worthwhile (used by [runPairingUpload]); the tick ignores it.
     */
    private fun triggerCloudUpload(): Boolean = runCloudUploadPass().retrySoon

    /**
     * Runs one cloud upload pass right now for the FORCE SYNC button, and
     * says what the car did.
     *
     * Runs on the caller's thread: the bridge already puts this on a
     * background thread, and the pass itself blocks on the network. A build
     * with cloud sync off says so plainly instead of pretending to sync and
     * silently doing nothing. A car that is not paired (unpaired, pending, or
     * revoked) says that too: nothing was attempted, so nothing failed.
     */
    fun forceCloudSyncNow(): Map<String, Any?> {
        if (!graph.isCloudReady()) {
            return mapOf("cloudReady" to false, "paired" to true, "movedRows" to 0, "failed" to false)
        }
        if (!graph.isUploadEligible()) {
            return mapOf("cloudReady" to true, "paired" to false, "movedRows" to 0, "failed" to false)
        }
        val pass = runCatching {
            // Promote ended pending sessions and intervals from prior boots so
            // any un-anchored completed sessions are eligible to upload.
            graph.telemetryCloudUploader.promoteEndedPending()
            runCloudUploadPass()
        }.getOrElse { error ->
            Log.w(TAG, "Force cloud upload failed", error)
            return mapOf("cloudReady" to true, "paired" to true, "movedRows" to 0, "failed" to true)
        }
        return pass.forceSyncResult()
    }

    /**
     * Marks the whole local telemetry history for upload again.
     *
     * A developer tool, reached only from the developer settings: after a
     * cloud copy is wiped for a test, the car's rows still carry dirty=0 and
     * no ordinary path resends them. Pairing and FORCE SYNC must not do this
     * for every user, because it re-sends the whole database. The next upload
     * pass (tick or FORCE SYNC) carries the rows.
     */
    fun markCloudHistoryDirty(): Map<String, Any?> {
        val marked = graph.telemetryCloudUploader.markHistoryDirty()
        return mapOf("markedRows" to marked.values.sum())
    }

    /**
     * The lifecycle calls, kept off the public surface.
     *
     * They are steps of [CollectionSequence], not operations a caller may invoke
     * on their own: starting the Roadcast repository without its trip-metrics
     * monitor is exactly the state that produced four days of null CAN columns.
     */
    private inner class Participants : CollectionParticipants {
        override var collectionRunning: Boolean
            get() = graph.state.running
            set(value) {
                graph.state.running = value
            }

        override fun markCollectionStarted() {
            graph.state.startedAtElapsedNanos = SystemClock.elapsedRealtimeNanos()
        }

        override fun markCollectionStopped() {
            graph.state.startedAtElapsedNanos = null
        }

        override fun startRangeRefresh() {
            rangeRefresh = graph.rangeExecutor.scheduleWithFixedDelay(
                { runCatching { graph.rangeEstimateMonitor.refreshEfficiency() } },
                // Immediate first refresh, then fixed delay: the efficiency behind
                // the estimate must not sit at EFFICIENCY_LOADING for a minute.
                0L,
                RANGE_EFFICIENCY_REFRESH_SECONDS,
                TimeUnit.SECONDS
            )
        }

        override fun stopRangeRefresh() {
            rangeRefresh?.cancel(false)
            rangeRefresh = null
        }

        override fun startVhalSubscriptions() {
            graph.vhalSubscriptionManager.start()
        }

        override fun stopVhalSubscriptions() {
            graph.vhalSubscriptionManager.stop()
        }

        override fun startRoadcastRepository() {
            graph.roadcastRepository.start()
        }

        override fun stopRoadcastRepository() {
            graph.roadcastRepository.stop()
        }

        override fun startRoadcastTripMetrics() {
            graph.roadcastTripMetricsMonitor.start()
        }

        override fun stopRoadcastTripMetrics() {
            graph.roadcastTripMetricsMonitor.stop()
        }

        override fun startParkedSessionDetector() {
        }

        override fun stopParkedSessionDetector() {
        }

        override fun startContinuousSessionDetector() {
        }

        override fun stopContinuousSessionDetector() {
            graph.continuousSessionDetector.stop()
        }

        override fun gpsEnabled(): Boolean = graph.settings.gpsEnabled()

        override fun startLocation() {
            graph.locationSignalProvider.start()
        }

        override fun stopLocation() {
            graph.locationSignalProvider.stop()
        }

        override fun startCollectorTick() {
            collectorTick = graph.maintenanceExecutor.scheduleAtFixedRate(
                { runCatching { onCollectorTick() } },
                COLLECTOR_TICK_SECONDS,
                COLLECTOR_TICK_SECONDS,
                TimeUnit.SECONDS
            )
            // Periodic cloud upload alongside the collector. It runs on the
            // job executor (never the scheduler thread) and catches all
            // failures so it cannot crash the maintenance runner.
            cloudUploadTick = graph.maintenanceExecutor.scheduleWithFixedDelay(
                {
                    graph.jobExecutor.execute {
                        // Registration is idempotent and self-gated, so the
                        // tick is the backstop after the startup retries run
                        // out: an unregistered car keeps trying until a token
                        // lands or the next boot.
                        runCatching { runBootRegistrationIfNeeded() }
                            .onFailure { error -> Log.w(TAG, "Scheduled boot registration failed", error) }
                        runCatching { triggerCloudUpload() }
                            .onFailure { error ->
                                Log.w(TAG, "Scheduled cloud upload failed", error)
                            }
                    }
                },
                CLOUD_UPLOAD_INITIAL_DELAY_SECONDS,
                CLOUD_UPLOAD_INTERVAL_SECONDS,
                TimeUnit.SECONDS
            )
            // Finding 10: startup retention skips while a session is active
            // and never retries within the process. This re-runs it daily;
            // on the job executor so a long sweep never blocks the scheduler.
            retentionTick = graph.maintenanceExecutor.scheduleWithFixedDelay(
                {
                    graph.jobExecutor.execute {
                        runCatching { graph.retentionManager.runRetention(force = false) }
                            .onFailure { error -> Log.w(TAG, "Scheduled retention failed", error) }
                    }
                },
                RETENTION_INTERVAL_SECONDS,
                RETENTION_INTERVAL_SECONDS,
                TimeUnit.SECONDS
            )
        }

        override fun stopCollectorTick() {
            collectorTick?.cancel(false)
            collectorTick = null
            cloudUploadTick?.cancel(false)
            cloudUploadTick = null
            retentionTick?.cancel(false)
            retentionTick = null
        }

        override fun runStartupMaintenance() {
            graph.jobExecutor.execute {
                // Pre-claim registration first: a brand-new car has no token,
                // so the upload gate (REGISTERED or APPROVED) would refuse the
                // startup pass below. Registering is what makes this boot's
                // upload possible at all. It never blocks: failures schedule
                // bounded backoff retries and are logged here.
                runCatching { runBootRegistrationIfNeeded() }
                    .onFailure { error -> Log.w(TAG, "Boot registration failed", error) }
                // Cloud upload precedes retention: retention is gated on
                // `dirty = 0`, so a pending queue must be drained first or
                // eligible rows would be retained longer than needed. Both
                // are wrapped in runCatching so a transient network failure
                // does not abort the other.
                runCatching { triggerCloudUpload() }
                    .onFailure { error -> Log.w(TAG, "Cloud upload failed (startup)", error) }
                // Backfill first and unconditionally: retention is rate limited to
                // once a day, so sessions left without permanent metrics —
                // everything that predates session_aggregates — would otherwise
                // wait for a run that may not happen today, and the lists would
                // read null energy until it did.
                runCatching { graph.retentionManager.backfillAggregates() }
                    .onFailure { error -> Log.w(TAG, "Aggregate backfill failed", error) }
                runCatching { graph.retentionManager.runRetention(force = false) }
            }
            graph.maintenanceExecutor.execute { graph.databaseHealthReporter.refreshIfStale() }
        }

        override fun ensureRoadcastDaemon() {
            // Daemon installation and local ADB I/O stay off the service start thread.
            graph.jobExecutor.execute {
                graph.state.roadcastStatus = runCatching { graph.roadcastDaemon.ensureRunning() }
                    .getOrElse { error ->
                        RoadcastDaemon.Status(
                            running = false,
                            socketReachable = false,
                            error = error.message ?: error::class.java.simpleName
                        )
                    }
            }
        }


        override fun startBleServer() {
            // Started here rather than with the server: the v2 shell shows the
            // CarPlay and Android Auto destinations from this monitor, and one
            // that has never bound answers UNKNOWN forever.
            graph.projectionPresenceMonitor?.start()
            graph.jobExecutor.execute {
                try {
                    graph.liveTelemetryBleServer.start()
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to start BLE live stream server", e)
                }
            }
        }

        override fun stopBleServer() {
            try {
                graph.liveTelemetryBleServer.stop()
            } catch (e: Exception) {
                Log.w(TAG, "Failed to stop BLE live stream server", e)
            }
        }

        override fun restoreKeyserver() {
            graph.temperatureModeHelperMonitor.ensureKeyserverRestored()
        }
    }

    private fun onCollectorTick() {
        if (!sequence.running) return
        graph.databaseHealthReporter.refreshIfStale()
        val snapshot = graph.store.snapshot()
        if (snapshot.isEmpty()) return
        val timestamp = SignalTimestamp(
            receivedAtUtcMillis = System.currentTimeMillis(),
            receivedAtElapsedNanos = SystemClock.elapsedRealtimeNanos(),
            sourceTimestampNanos = null,
            accuracy = TimestampAccuracy.INFERRED,
            uncertaintyMillis = COLLECTOR_TICK_SECONDS * 1_000L
        )
        graph.detectorExecutor.execute {
            graph.tripSessionDetector.onCollectorTick(timestamp, snapshot)
            graph.frameRepository.persistActiveSnapshot(timestamp, snapshot)
            graph.roadcastTripMetricsMonitor.syncCadence()

            val liveSnapshot = LiveTelemetrySnapshotAssembler.assemble(
                wallTimeUtcMillis = timestamp.receivedAtUtcMillis,
                signalSnapshot = snapshot,
                locationSnapshot = graph.locationSignalProvider.latestSnapshot(),
                isCharging = graph.chargeSessionDetector.activeFrameSession() != null,
                isParked = graph.parkedSessionDetector.activeFrameSession() != null
            )
            graph.liveTelemetryBleServer.broadcastSnapshot(liveSnapshot)
        }
    }

    // --- read surface, delegated to the facade -------------------------------

    fun status(): CollectorStatus = facade.status()

    fun collectorStatusMap(): Map<String, Any?> = facade.collectorStatusMap()

    fun vehicleCapabilitiesMap(): Map<String, Any?> = facade.vehicleCapabilitiesMap()

    fun latestSnapshotMap(): Map<String, Any?> = facade.latestSnapshotMap()

    fun roadcastStatusMap(): Map<String, Any?> = facade.roadcastStatusMap()

    fun roadcastUpdateStatusMap(): Map<String, Any?> = facade.roadcastUpdateStatusMap()

    fun checkRoadcastUpdate(): Map<String, Any?> = facade.checkRoadcastUpdate()

    fun rangeEstimate(): NativeRangeEstimate = facade.rangeEstimate()

    fun heading(): VehicleHeading = facade.heading()

    fun recentEventsMap(limit: Int): Map<String, Any?> = facade.recentEventsMap(limit)

    fun recentChargeSessions(limit: Int): ChargeSessionPage =
        facade.recentChargeSessions(limit)

    fun chargeMergeCandidates(limit: Int): ChargeMergeCandidatePage =
        facade.chargeMergeCandidates(limit)

    fun recentTripSessions(limit: Int): TripSessionPage =
        facade.recentTripSessions(limit)

    fun insightTrips(subjectId: String?): InsightTripsPage =
        facade.insightTrips(subjectId)

    fun insightPlaces(): List<InsightPlaceRow> = facade.insightPlaces()

    fun saveInsightPlace(
        id: String?,
        name: String,
        latitude: Double,
        longitude: Double,
        radiusM: Double,
        autoName: String? = null,
        autoNameUpdatedAtUtcMillis: Long? = null,
        autoNameSource: String? = null,
    ): InsightPlaceRow = facade.saveInsightPlace(id, name, latitude, longitude, radiusM, autoName, autoNameUpdatedAtUtcMillis, autoNameSource)

    fun deleteInsightPlace(id: String) = facade.deleteInsightPlace(id)

    fun preferenceRows(): List<com.timhss.capyenergy.telemetry.db.PreferenceEntity> =
        graph.preferenceRepository.activeRows()

    fun savePreferenceFromCar(
        scope: String,
        key: String,
        value: String?
    ): com.timhss.capyenergy.telemetry.db.PreferenceEntity? =
        graph.preferenceRepository.saveFromCar(scope, key, value)

    fun pendingPreferenceProposals(): List<com.timhss.capyenergy.telemetry.db.PreferenceProposalEntity> =
        graph.preferenceRepository.pendingProposals()

    fun proposePreference(key: String, value: String?): com.timhss.capyenergy.telemetry.db.PreferenceProposalEntity? =
        graph.preferenceRepository.propose(key, value)

    fun decidePreferenceProposal(
        id: String,
        accept: Boolean
    ): com.timhss.capyenergy.telemetry.db.PreferenceProposalEntity? =
        graph.preferenceRepository.decide(id, accept)

    /**
     * The car's write path for an accepted proposal.
     *
     * A proposal is inert until a person on the car accepts it. Acceptance
     * runs the same code the settings screen runs, so the cycle refold a new
     * pack capacity causes happens exactly once, at the moment of
     * confirmation. Answers false when the value cannot be written.
     */
    fun applyPreferenceWrite(key: String, value: String?): Boolean = when (key) {
        "pack_capacity_wh" -> {
            val capacity = value?.toDoubleOrNull()
                ?.takeIf { it.isFinite() && it > 0.0 }
            if (capacity == null) return false
            graph.settings.setPackCapacityWh(capacity)
            runCatching { graph.batteryCycleRepository.refresh() }
                .onFailure { error -> Log.w(TAG, "Battery cycle refresh after capacity proposal failed", error) }
            true
        }
        "default_charge_cost_per_kwh" -> {
            val rate = value?.toDoubleOrNull()
                ?.takeIf { it.isFinite() && it >= 0.0 }
            if (rate == null) return false
            graph.settings.setDefaultChargeCostPerKwh(rate)
            true
        }
        else -> false
    }

    fun batteryCycles(limit: Int): BatteryCyclePage = facade.batteryCycles(limit)

    fun batteryCycleSessions(ordinal: Long): BatteryCycleSessionsPage =
        facade.batteryCycleSessions(ordinal)

    fun liveEnergySeries(): LiveEnergyBuckets? = facade.liveEnergySeries()

    fun liveEfficiencySeries(): LiveEnergyBuckets? = facade.liveEfficiencySeries()

    fun liveChargeEnergySeries(): LiveEnergyBuckets? = facade.liveChargeEnergySeries()

    fun liveContinuousEnergySeries(): LiveEnergyBuckets? = facade.liveContinuousEnergySeries()

    fun efficiencyBucketMillis(): Long = facade.efficiencyBucketMillis()

    fun energySeriesInWindow(
        startUtcMillis: Long,
        endUtcMillis: Long
    ): WindowEnergySeries = facade.energySeriesInWindow(startUtcMillis, endUtcMillis)

    fun parkedEnergySeriesInWindow(
        startUtcMillis: Long,
        endUtcMillis: Long
    ): WindowEnergySeries = facade.parkedEnergySeriesInWindow(startUtcMillis, endUtcMillis)

    fun settingsMap(): Map<String, Any?> = facade.settingsMap()


    // ── Cloud device pairing (issue #227) ──────────────────────────────
    // Exposed for `TelemetryBridge`'s method channel. The `device_code` is
    // memory-only in the coordinator; the facade caches `userCode`/`expiresAt`
    // in memory for the pending state.
    suspend fun startDevicePairing(): Map<String, Any?> = facade.startDevicePairing()
    suspend fun getDevicePairingState(): Map<String, Any?> = facade.getDevicePairingState()
    suspend fun cancelDevicePairing(): Map<String, Any?> = facade.cancelDevicePairing()

    fun pairedCompanionDevices(): Map<String, Any?> = facade.pairedCompanionDevices()
    fun isBleStreamActive(): Boolean = facade.isBleStreamActive()
    fun cloudSyncProgress(): Map<String, Any?> = facade.cloudSyncProgress()

    fun revokeCompanionDevice(deviceId: String): Map<String, Any?> =
        facade.revokeCompanionDevice(deviceId)

    fun activeSessionType(): String? = graph.activeSessionType()

    // --- Roadcast commands ---------------------------------------------------

    fun restartRoadcast(): Map<String, Any?> {
        graph.roadcastTripMetricsMonitor.stop()
        graph.roadcastRepository.stop()
        val status = runCatching { graph.roadcastDaemon.restart() }
            .getOrElse { error ->
                RoadcastDaemon.Status(
                    running = false,
                    socketReachable = false,
                    error = error.message ?: error::class.java.simpleName
                )
            }
        graph.state.roadcastStatus = status
        graph.roadcastRepository.start()
        graph.roadcastTripMetricsMonitor.start()
        return facade.roadcastStatusMap()
    }

    /**
     * Makes the external Roadcast service current before an app APK is installed.
     * The app update must stop if the edge service cannot be verified or applied.
     */
    fun ensureRoadcastUpdatedForAppInstall(): Map<String, Any?> {
        activeSessionType()?.let { type ->
            error("Roadcast cannot update while a $type session is active")
        }
        val status = graph.roadcastUpdateManager.check(facade.installedRoadcastSha256())
        check(status.compatible) {
            "Roadcast update required by the app is incompatible: " +
                (status.error ?: "unknown compatibility error")
        }
        return if (status.updateAvailable) updateRoadcast() else status.toMap()
    }

    fun updateRoadcast(): Map<String, Any?> {
        activeSessionType()?.let { type ->
            error("Roadcast cannot update while a $type session is active")
        }
        val prepared = graph.roadcastUpdateManager.prepare(facade.installedRoadcastSha256())
        activeSessionType()?.let { type ->
            graph.roadcastUpdateManager.discard(prepared)
            error("Roadcast cannot update while a $type session is active")
        }

        graph.roadcastTripMetricsMonitor.stop()
        graph.roadcastRepository.stop()
        try {
            val updated = try {
                graph.roadcastDaemon.installAndRestart(
                    prepared.release.daemonFile,
                    prepared.release.manifest.daemon.sha256
                )
            } catch (error: Throwable) {
                graph.roadcastUpdateManager.discard(prepared)
                val rollback = runCatching { graph.roadcastDaemon.reinstallPreferred() }.getOrNull()
                graph.state.roadcastStatus = rollback
                throw IllegalStateException(
                    "Roadcast update activation failed; " +
                        if (rollback?.running == true) {
                            "previous release restored"
                        } else {
                            "rollback failed: ${rollback?.error ?: "unknown error"}"
                        },
                    error
                )
            }
            if (!updated.running) {
                graph.roadcastUpdateManager.discard(prepared)
                graph.state.roadcastStatus = graph.roadcastDaemon.reinstallPreferred()
                error(updated.error ?: "Roadcast update failed to start")
            }
            validateUpdatedRoadcast()?.let { validationError ->
                graph.roadcastUpdateManager.discard(prepared)
                val rollback = graph.roadcastDaemon.reinstallPreferred()
                graph.state.roadcastStatus = rollback
                check(rollback.running) {
                    "Roadcast update validation failed: $validationError; rollback failed: " +
                        (rollback.error ?: "unknown error")
                }
                error("Roadcast update validation failed: $validationError; previous release restored")
            }
            try {
                graph.roadcastUpdateManager.activate(prepared)
            } catch (error: Throwable) {
                runCatching { graph.roadcastUpdateManager.restorePrevious(prepared) }
                graph.roadcastUpdateManager.discard(prepared)
                graph.state.roadcastStatus = graph.roadcastDaemon.reinstallPreferred()
                throw error
            }
            graph.state.roadcastStatus = updated
            return graph.roadcastUpdateManager.completed(prepared).toMap()
        } finally {
            graph.roadcastRepository.start()
            graph.roadcastTripMetricsMonitor.start()
        }
    }

    private fun validateUpdatedRoadcast(): String? {
        val client = RoadcastClient.connect().getOrElse { error ->
            return error.message ?: "Roadcast client handshake failed"
        }
        return try {
            val status = client.status()
                ?: return "Roadcast client returned no status after handshake"
            if (!status.connected) {
                "Roadcast client disconnected after handshake"
            } else if (status.signalCount <= 0 || status.frameCount <= 0) {
                "Roadcast returned an empty schema after handshake"
            } else {
                val schema = runCatching { client.schema() }.getOrElse { error ->
                    return error.message ?: "Roadcast schema validation failed"
                }
                if (schema.size != status.signalCount) {
                    "Roadcast schema count does not match client status"
                } else {
                    null
                }
            }
        } finally {
            client.close()
        }
    }

    // --- session commands ----------------------------------------------------

    fun mergeChargeSessions(ids: List<String>): ChargeMergeOutcome =
        graph.sessionRepository.mergeChargeSessions(ids)

    fun updateChargeSessionCost(
        sessionId: String,
        costPerKwh: Double?,
        paidAmount: Double?,
        currency: String?
    ): ChargeCostUpdate {
        val update = graph.sessionRepository.updateChargeSessionCost(
            sessionId,
            costPerKwh,
            paidAmount,
            currency
        )
        // Pricing a charge changes the blend of the pack from that charge
        // forward, so every cycle that ends at or after it is wrong. The
        // repository rebuilds only that tail; the cycles before it are
        // untouched, because their blend cannot have changed.
        val priced = update.session?.session
        if (update.ok && priced != null) {
            val chargeStart = priced.chargeStartedAtUtcMillis
                ?: priced.startedAtUtcMillis
            runCatching { graph.batteryCycleRepository.invalidateFrom(chargeStart) }
                .onFailure { error ->
                    Log.w(TAG, "Battery cycle invalidation failed", error)
                }
        }
        return update
    }

    /**
     * Prices every unpriced past charge at the default rate.
     *
     * The cycles are rebuilt from the oldest charge that changed, for the same
     * reason one pricing edit rebuilds a tail: a charge's price moves the pack
     * blend from that charge forward.
     */
    fun applyDefaultChargeCostToUnpriced(): DefaultChargeCostApplication {
        val outcome = graph.sessionRepository.applyDefaultCostToUnpricedCharges()
        val from = outcome.oldestPricedStartUtcMillis
        if (outcome.ok && from != null) {
            runCatching { graph.batteryCycleRepository.invalidateFrom(from) }
                .onFailure { error -> Log.w(TAG, "Battery cycle invalidation failed", error) }
        }
        return outcome
    }

    // --- database commands ---------------------------------------------------

    fun clearTelemetryDatabase(): Map<String, Any?> {
        stop()
        return graph.jobExecutor.submit(Callable {
            graph.frameRepository.awaitPendingWrites()
            val eventCount = graph.database.telemetryEventDao().count()
            val sessionCount = graph.database.sessionDao().count()
            val intervalCount = graph.database.intervalDao().count()
            // Through the queue, not around it.
            TelemetryWriteCoordinator.executor.call("clear_database", trackAsWrite = true) {
                graph.database.clearAllTables()
            }
            resetInMemoryState()
            mapOf(
                "ok" to true,
                "telemetryEventsDeleted" to eventCount,
                "sessionsDeleted" to sessionCount,
                "samplesDeleted" to 0L,
                "telemetryFramesDeleted" to 0L,
                "intervalsDeleted" to intervalCount,
                "timestampMillis" to System.currentTimeMillis()
            )
        }).get()
    }

    fun runTelemetryRetention(): Map<String, Any?> =
        graph.jobExecutor.submit(Callable {
            graph.retentionManager.runRetention(force = true)
        }).get()

    /** How much disk the app's stored history occupies, without scanning any row. */
    fun storageUsage(): Map<String, Any?> = graph.databaseHealthReporter.storageUsage()

    fun awaitCollectionQuiescence() {
        graph.maintenanceExecutor.submit {}.get()
        graph.detectorExecutor.submit {}.get()
        graph.frameRepository.awaitPendingWrites()
    }

    /**
     * Drops every in-memory copy of what the database just lost.
     *
     * A wipe and a restore both replace the rows underneath the detectors, so
     * both have to forget the same five things. They were written out twice
     * before the split, which is exactly the kind of pair that drifts.
     */
    private fun resetInMemoryState() {
        graph.eventRepository.resetInMemory()
        graph.tripSessionDetector.reset()
        graph.chargeSessionDetector.reset()
        graph.sessionRepository.resetInMemory()
        graph.frameRepository.resetInMemory()
        TelemetryWriteCoordinator.executor.resetMetrics()
    }

    // --- settings ------------------------------------------------------------

    fun setAutoStartOnBoot(enabled: Boolean): Map<String, Any?> {
        graph.settings.setAutoStartOnBoot(enabled)
        return graph.settings.toMap()
    }

    /**
     * Persists the setting, then asks for the radio at once rather than at the
     * next adapter event, so the switch has a visible effect.
     */
    fun setKeepBluetoothOnEnabled(enabled: Boolean): Map<String, Any?> {
        graph.settings.setKeepBluetoothOnEnabled(enabled)
        if (enabled) graph.liveTelemetryBleServer.applyKeepBluetoothOn()
        return graph.settings.toMap()
    }

    fun setGpsEnabled(enabled: Boolean): Map<String, Any?> {
        graph.settings.setGpsEnabled(enabled)
        if (enabled && sequence.running) {
            graph.locationSignalProvider.start()
        } else if (!enabled) {
            graph.locationSignalProvider.stop()
        }
        return graph.settings.toMap() +
            mapOf("location" to graph.locationSignalProvider.statusMap())
    }

    fun setDebugEventFileEnabled(enabled: Boolean): Map<String, Any?> {
        graph.settings.setDebugEventFileEnabled(enabled)
        if (!enabled) {
            graph.eventRepository.deleteEventFiles()
        }
        return graph.settings.toMap()
    }

    fun setTemperatureModeHelperEnabled(enabled: Boolean): Map<String, Any?> {
        graph.settings.setTemperatureModeHelperEnabled(enabled)
        graph.temperatureModeHelperMonitor.setEnabled(enabled)
        return graph.settings.toMap() +
            mapOf("helpers" to graph.temperatureModeHelperMonitor.statusMap())
    }

    fun setReplaceOemChargingEnabled(enabled: Boolean): Map<String, Any?> {
        graph.settings.setReplaceOemChargingEnabled(enabled)
        return graph.settings.toMap()
    }

    fun setExternalChargeControlEnabled(enabled: Boolean): Map<String, Any?> {
        graph.settings.setExternalChargeControlEnabled(enabled)
        // Turning the switch off ends the link with Geely Charge Control at
        // once. Leaving it registered would keep a screen the reader has
        // hidden in step with a car they asked this app to stop steering.
        graph.chargeControlIpcClient.syncToSetting()
        graph.chargeControlStateBroadcaster?.invoke(graph.chargeControlIpcClient.getState())
        return graph.settings.toMap()
    }

    /**
     * Finding 14: flips the opt-in `CONTINUOUS` recording switch and reads it
     * back. Fully wired: [com.timhss.capyenergy.telemetry.ContinuousSessionDetector]
     * reads the stored preference, cuts one wall-clock minute per awake minute
     * through `FrameRepository`, and persists it as `CONTINUOUS` sessions and
     * `interval` rows. Off by default; with it off recording is unchanged.
     */
    fun setContinuousModeEnabled(enabled: Boolean): Map<String, Any?> {
        graph.settings.setContinuousModeEnabled(enabled)
        return graph.settings.toMap()
    }

    fun getChargeControlAppStatus(): Map<String, Any?> =
        graph.chargeControlAppManager.status().toMap()

    fun checkChargeControlAppUpdate(): Map<String, Any?> =
        graph.chargeControlAppManager.checkStatus().toMap()

    fun installChargeControlApp(onProgress: ((Float) -> Unit)? = null): Map<String, Any?> =
        graph.chargeControlAppManager.downloadAndInstall(onProgress).toMap()

    var onTargetSocChangedListener: ((Int) -> Unit)?
        get() = graph.targetSocChangeBroadcaster
        set(value) {
            graph.targetSocChangeBroadcaster = value
        }

    var onChargeControlStateChanged: ((com.timhss.capyenergy.ipc.ChargeControlIpcState) -> Unit)?
        get() = graph.chargeControlStateBroadcaster
        set(value) {
            graph.chargeControlStateBroadcaster = value
        }

    fun setChargeTargetSoc(percent: Int): Map<String, Any?> {
        graph.chargeControlIpcClient.setTargetSoc(percent)
        return graph.settings.toMap()
    }

    fun getChargeTargetSoc(): Int = graph.settings.chargeTargetSocPercent()

    fun getChargeControlState(): Map<String, Any?> {
        graph.chargeControlIpcClient.start()
        graph.chargeControlIpcClient.queryState()
        return graph.chargeControlIpcClient.getState().toMap()
    }

    fun setChargingAmperage(amps: Int): Map<String, Any?> {
        graph.chargeControlIpcClient.setAmperage(amps)
        return graph.chargeControlIpcClient.getState().toMap()
    }

    fun setForceCharging(force: Boolean): Map<String, Any?> {
        graph.chargeControlIpcClient.setForceCharging(force)
        return graph.chargeControlIpcClient.getState().toMap()
    }

    fun stopCharging(): Map<String, Any?> {
        graph.chargeControlIpcClient.stopCharging()
        return mapOf("ok" to true)
    }

    fun launchChargeControlApp(): Map<String, Any?> =
        mapOf("ok" to graph.chargeControlAppManager.launchApp())

    fun setDefaultChargeCostPerKwh(value: Double?): Map<String, Any?> {
        graph.settings.setDefaultChargeCostPerKwh(value)
        return graph.settings.toMap()
    }

    /**
     * States the pack capacity. Every energy figure the app reports is scaled
     * by it, so the cycle ledger is refolded rather than left showing totals
     * that were computed against the old pack.
     */
    fun setPackCapacityWh(value: Double?): Map<String, Any?> {
        graph.settings.setPackCapacityWh(value)
        // From zero: capacity scales every cycle, not a tail of them.
        runCatching { graph.batteryCycleRepository.invalidateFrom(0L) }
            .onFailure { error -> Log.w(TAG, "Battery cycle rebuild failed", error) }
        return graph.settings.toMap()
    }

    companion object {
        private const val TAG = "TelemetryRuntime"
        private const val COLLECTOR_TICK_SECONDS = 1L
        private const val RANGE_EFFICIENCY_REFRESH_SECONDS = 60L
        private const val CLOUD_UPLOAD_INITIAL_DELAY_SECONDS = 30L
        private const val CLOUD_UPLOAD_INTERVAL_SECONDS = 900L
        // First pairing delivery: immediate attempt plus bounded retries with
        // growing delay. Small enough to finish well inside the 15-minute
        // tick; the tick itself stays the fallback after these run out.
        private const val PAIRING_UPLOAD_MAX_RETRIES = 3
        private const val PAIRING_UPLOAD_RETRY_BASE_DELAY_SECONDS = 15L
        private const val PAIRING_UPLOAD_RETRY_MAX_DELAY_SECONDS = 120L

        private fun pairingUploadRetryDelayMillis(attempt: Int): Long =
            minOf(
                PAIRING_UPLOAD_RETRY_BASE_DELAY_SECONDS shl attempt,
                PAIRING_UPLOAD_RETRY_MAX_DELAY_SECONDS,
            )

        /** Finding 10: retry startup-skipped retention once a day. */
        private const val RETENTION_INTERVAL_SECONDS = 86_400L
        @Volatile
        private var instance: TelemetryRuntime? = null

        fun get(context: Context): TelemetryRuntime =
            instance ?: synchronized(this) {
                instance ?: TelemetryRuntime(context.applicationContext).also { instance = it }
            }
    }
}
