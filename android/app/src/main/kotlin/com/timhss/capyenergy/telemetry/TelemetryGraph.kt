package com.timhss.capyenergy.telemetry

import android.content.Context
import android.provider.Settings
import android.util.Log
import com.timhss.capyenergy.BuildConfig
import com.timhss.capyenergy.concurrent.namedSingleThreadExecutor
import com.timhss.capyenergy.concurrent.namedSingleThreadScheduledExecutor
import com.timhss.capyenergy.helpers.AudioTrackTemperatureModeFeedback
import com.timhss.capyenergy.helpers.MediaKeyserverController
import com.timhss.capyenergy.helpers.TemperatureModeHelperMonitor
import com.timhss.capyenergy.profile.SignalKey
import com.timhss.capyenergy.roadcast.RoadcastDaemon
import com.timhss.capyenergy.roadcast.RoadcastRepository
import com.timhss.capyenergy.roadcast.RoadcastUpdateManager
import com.timhss.capyenergy.service.AutoOpenLauncher
import com.timhss.capyenergy.telemetry.control.HttpPreferenceControlCloud
import com.timhss.capyenergy.telemetry.control.PreferenceControlCloud
import com.timhss.capyenergy.telemetry.control.PreferenceControlSync
import com.timhss.capyenergy.telemetry.control.SharedPreferencesReportedDecisionStore
import com.timhss.capyenergy.telemetry.db.RoomVehicleIdAliasStore
import com.timhss.capyenergy.telemetry.db.TelemetryDatabase
import com.timhss.capyenergy.telemetry.pairing.DevicePairingClient
import com.timhss.capyenergy.telemetry.pairing.HttpDevicePairingClient
import com.timhss.capyenergy.telemetry.pairing.PairingCoordinator
import com.timhss.capyenergy.telemetry.sync.CloudSink
import com.timhss.capyenergy.telemetry.sync.CompanionDeviceManager
import com.timhss.capyenergy.telemetry.sync.HttpCloudSink
import com.timhss.capyenergy.telemetry.sync.SyncCursorRepository
import com.timhss.capyenergy.telemetry.sync.TelemetryCloudUploader
import com.timhss.capyenergy.update.ChargeControlAppManager
import com.timhss.capyenergy.vehicle.HvacClimateController
import com.timhss.capyenergy.vehicle.VehiclePropertyHelper
import java.util.concurrent.TimeUnit
import com.timhss.capyenergy.projection.PresenceState
import com.timhss.capyenergy.projection.ProjectionPresenceMonitor
import com.timhss.capyenergy.projection.ProjectionPresenceSnapshot

/**
 * State the collaborators read but the lifecycle owns.
 *
 * [RangeEstimateMonitor] needs to know whether collection is running and when
 * this run began, and it is constructed long before either is true. A small
 * shared holder keeps those two facts in one place instead of threading two
 * lambdas back into the object that builds it.
 */
internal class TelemetryCollectionState {
    /**
     * When the current telemetry run began, in `elapsedRealtimeNanos`. Cleared
     * on stop so a value left in [SignalStateStore] by an earlier run cannot
     * appear during a restart before the new initial read.
     */
    @Volatile
    var startedAtElapsedNanos: Long? = null

    @Volatile
    var running = false

    /** Last known daemon status, or null before the first attempt. */
    @Volatile
    var roadcastStatus: RoadcastDaemon.Status? = null
}

/**
 * Construction and wiring for the telemetry engine.
 *
 * This is the composition root and nothing else. It holds no lifecycle (see
 * [TelemetryRuntime]) and answers no Flutter call (see [TelemetryFacade]). It
 * was split out of `TelemetryRuntime`, which had grown to 759 lines and was
 * doing all three jobs at once: the collaborators were each small and tested,
 * while the wiring that decides how they see each other was neither.
 *
 * Declaration order matters here. Several collaborators take lambdas over
 * others, so a property moved above its dependency compiles and then reads null
 * at run time.
 */
internal class TelemetryGraph(
    context: Context,
    injectedProjectionPresence: (() -> ProjectionPresenceSnapshot)? = null,
    /**
     * Cloud-sync gate — defaults to [BuildConfig.CLOUD_SYNC_ENABLED] (ON
     * unless explicitly disabled via `local.properties` / gradle property /
     * env).
     *
     * Standing decision from the owner: the cloud stays on. An unconfigured
     * build still moves nothing because the Supabase URL/key are empty unless
     * a project is wired. When false the graph behaves exactly as before.
     *
     * Injected for JVM tests; production passes null and reads BuildConfig.
     */
    private val injectedCloudSyncEnabled: Boolean? = null,
    private val injectedDevicePairingClient: DevicePairingClient? = null,
) {
    val appContext: Context = context.applicationContext
    val database = TelemetryDatabase.get(appContext)
    val state = TelemetryCollectionState()

    val maintenanceExecutor = namedSingleThreadScheduledExecutor("maintenance")

    /**
     * Long jobs, off the scheduler thread.
     *
     * The collector tick is what drives 1 Hz frame persistence, and it used to
     * share one thread with retention, export and the Roadcast install. A
     * streaming export of a full database holds that thread for minutes, so the
     * cadence it was supposed to protect stopped for the whole export and the
     * missed fixed-rate ticks then fired back to back. Jobs still share one
     * thread with each other, because export, retention and wipe must not
     * overlap.
     */
    val jobExecutor = namedSingleThreadExecutor("telemetry-job")
    val detectorExecutor = namedSingleThreadExecutor("detectors")
    val identityExecutor = namedSingleThreadScheduledExecutor("veh-identity")

    /**
     * Dedicated single-thread scheduled executor for the closed-trip efficiency
     * behind the range estimate. It stays alive across start/stop cycles; only
     * the scheduled task is cancelled on stop, so a restart can schedule again.
     */
    val rangeExecutor = namedSingleThreadScheduledExecutor("range-refresh")

    val policy = TelemetryPolicy()
    val normalizer = SignalNormalizer()
    val store = SignalStateStore(detectorExecutor)
    val settings = TelemetrySettings(appContext)

    // Phantom pending: if the process died between start() and the first
    // poll/cancel, pairing_status stays "pending" in SharedPreferences forever
    // but device_code is memory-only and lost. No poll can ever succeed;
    // reset to unpaired at boot so a future direct reader does not see a
    // phantom pending. Doc also notes this.
    private val pairingBootReset: Unit = run {
        if (settings.pairingStatus() == TelemetrySettings.PAIRING_STATUS_PENDING) {
            settings.clearPairing()
        }
    }

    /**
     * Layered vehicle identity, resolved before the first session of a boot
     * is recorded. See [VehicleIdentityResolver] for the anchor order.
     */
    val vehicleIdentity = VehicleIdentityResolver(
        settings = settings,
        aliases = RoomVehicleIdAliasStore(database.vehicleIdAliasDao(), database.sessionDao()),
        identityFile = defaultIdentityFile(),
        vinReader = { vehiclePropertyHelper.readVin() },
        androidIdProvider = {
            Settings.Secure.getString(appContext.contentResolver, Settings.Secure.ANDROID_ID)
        },
        hasRecordedSessions = { database.sessionDao().count() > 0 },
        legacyVehicleIdsProvider = { database.sessionDao().distinctVehicleIds() }
    )

    /**
     * Presence of a projection session, for the sync gate alone.
     *
     * This is a **second** monitor. `ProjectionPresenceBridge` owns one for the
     * Flutter screens, and that one lives with the activity and starts on the
     * first Dart listener. The sync server runs in the foreground service, which
     * outlives every activity, so it cannot read that instance. Both are cheap:
     * one receiver and two probe bindings each, and `start()` is idempotent.
     *
     * Null when a caller injects its own reading, which is how a test states a
     * presence without binding to an OEM service that a JVM does not have.
     */
    val projectionPresenceMonitor: ProjectionPresenceMonitor? =
        if (injectedProjectionPresence == null) {
            ProjectionPresenceMonitor(appContext) { /* the gate polls; it does not listen */ }
        } else {
            null
        }

    /**
     * What the sync gate reads. `UNKNOWN` permits: by design: this head unit answers `UNKNOWN`
     * permanently when the OEM binder is absent, and a gate that waited for
     * `DISCONNECTED` would never sync on such a car.
     */
    val projectionPresenceSnapshotProvider: () -> ProjectionPresenceSnapshot =
        injectedProjectionPresence
            ?: { projectionPresenceMonitor?.snapshot() ?: ProjectionPresenceSnapshot.unknown }

    val companionDeviceManager = CompanionDeviceManager(appContext)
    val syncCursorRepository = SyncCursorRepository(
        syncCursorDao = database.syncCursorDao(),
        isDevicePaired = { deviceId -> companionDeviceManager.findDevice(deviceId) != null },
        sessionDao = database.sessionDao(),
        intervalDao = database.intervalDao(),
        batteryCycleDao = database.batteryCycleDao(),
        telemetryEventDao = database.telemetryEventDao(),
        insightPlaceDao = database.insightPlaceDao(),
        sessionCostDao = database.sessionCostDao(),
        preferenceDao = database.preferenceDao(),
        preferenceProposalDao = database.preferenceProposalDao(),
        journeyDao = database.journeyDao(),
        trackDao = database.trackDao()
    )
    val eventRepository = EventRepository(
        appContext,
        { settings.debugEventFileEnabled() },
        accountIdProvider = {
            AccountIdProvider.of(
                cloudSyncEnabled,
                settings.pairingStatus(),
                settings.accountId()
            )
        },
    )
    /** Told after every session write; the bridge turns it into an event. */
    val sessionChanges = SessionChangeBroadcaster()

    val sessionRepository = SessionRepository(
        context = appContext,
        capacityWhProvider = { resolveCapacityWh() },
        vehicleIdProvider = { resolveVehicleId() },
        defaultChargeCostPerKwhProvider = { settings.defaultChargeCostPerKwh() },
        chargeCostCurrencyProvider = { settings.chargeCostCurrency() },
        changes = sessionChanges,
        accountIdProvider = {
            AccountIdProvider.of(
                cloudSyncEnabled,
                settings.pairingStatus(),
                settings.accountId()
            )
        },
    )

    val batteryCycleRepository = BatteryCycleRepository(
        context = appContext,
        capacityWhProvider = { resolveCapacityWh() },
        accountIdProvider = {
            AccountIdProvider.of(
                cloudSyncEnabled,
                settings.pairingStatus(),
                settings.accountId()
            )
        },
    )

    val annotationChanges = AnnotationChangeBroadcaster()
    val insightRepository = InsightRepository(
        appContext,
        accountIdProvider = {
            AccountIdProvider.of(
                cloudSyncEnabled,
                settings.pairingStatus(),
                settings.accountId()
            )
        },
    )
    val journeyRepository = JourneyRepository(
        context = appContext,
        annotationChanges = annotationChanges,
        accountIdProvider = {
            AccountIdProvider.of(
                cloudSyncEnabled,
                settings.pairingStatus(),
                settings.accountId()
            )
        },
    )
    val preferenceRepository = PreferenceRepository(
        context = appContext,
        annotationChanges = annotationChanges,
        accountIdProvider = {
            AccountIdProvider.of(
                cloudSyncEnabled,
                settings.pairingStatus(),
                settings.accountId()
            )
        },
    )
    val retentionManager = TelemetryRetentionManager(appContext, capacityWhProvider = { resolveCapacityWh() })

    /**
     * Cloud-sync gate for Lanes A/B/C: real Supabase sinks are wired and
     * default ON. Sourcing follows the already-established pattern —
     * [BuildConfig.SUPABASE_URL] / [BuildConfig.SUPABASE_ANON_KEY] via
     * `local.properties` → gradle property → env — so no new credential
     * mechanism is invented. When false the graph is inert exactly as before.
     */
    val cloudSyncEnabled: Boolean get() = injectedCloudSyncEnabled ?: BuildConfig.CLOUD_SYNC_ENABLED
    /**
     * Whether the real cloud path could actually reach Supabase if asked.
     *
     * Gate ON plus non-empty URL/key means the build *can* sync; a paired
     * car also needs [TelemetrySettings.accountId] and [TelemetrySettings.carToken]
     * (saved by [com.timhss.capyenergy.telemetry.pairing.PairingCoordinator]
     * on `Approved`) plus a resolved [vehicleId] (from [VehicleIdentityResolver]).
     * Gate OFF or missing Supabase config → no-op, matching every prior phase.
     */
    fun isCloudReady(): Boolean =
        cloudSyncEnabled && BuildConfig.SUPABASE_URL.isNotBlank() && BuildConfig.SUPABASE_ANON_KEY.isNotBlank()

    /**
     * Resolves the sink for Lanes A/B. When the gate is on and Supabase is
     * configured, returns a real [HttpCloudSink] that carries the anon key and
     * the car token (for future device-token RLS on telemetry/annotation
     * tables); otherwise returns the no-op sink that every prior phase shipped
     * with. Tests may still call [setCloudSink] to inject a fake.
     */
    private fun resolveCloudSink(): CloudSink =
        if (isCloudReady()) {
            HttpCloudSink(
                baseUrl = BuildConfig.SUPABASE_URL,
                anonKey = BuildConfig.SUPABASE_ANON_KEY,
                carTokenProvider = { settings.carToken() },
            )
        } else {
            NoOpCloudSink
        }

    /**
     * Car-side cloud uploader for Phase 1 direct upload.
     *
     * The sink is pluggable for tests; the production sink is a no-op when
     * the gate is off or Supabase credentials are missing. The uploader is
     * still scheduled alongside retention so the queue drains as soon as a
     * sink is present, without changing the schedule.
     */
    var cloudSink: CloudSink = resolveCloudSink()
        private set

    fun setCloudSink(sink: CloudSink) {
        cloudSink = sink
    }

    /** Re-resolves [cloudSink] from the current gate/config. For tests. */
    fun refreshCloudSink() {
        cloudSink = resolveCloudSink()
    }
    val telemetryCloudUploader: TelemetryCloudUploader by lazy {
        val forwardingSink = object : CloudSink {
            override suspend fun upsert(
                table: String,
                rows: List<Map<String, Any?>>,
                conflictColumns: List<String>,
                merge: Boolean
            ) = cloudSink.upsert(table, rows, conflictColumns, merge)
            override suspend fun delete(
                table: String,
                vehicleId: String,
                keys: List<Triple<String, String, Long>>
            ) = cloudSink.delete(table, vehicleId, keys)
        }
        TelemetryCloudUploader(
            sessionDao = database.sessionDao(),
            intervalDao = database.intervalDao(),
            trackDao = database.trackDao(),
            telemetryEventDao = database.telemetryEventDao(),
            batteryCycleDao = database.batteryCycleDao(),
            intervalReplacedKeyDao = database.intervalReplacedKeyDao(),
            sink = forwardingSink,
            vehicleIdProvider = { resolveVehicleId() },
            // Alias-canonicalize before upload: rows recorded under a retired
            // id (android_id) upload under the canonical VIN, matching the
            // vehicle the device token is bound to (B1). Same store the
            // identity resolver writes on an upgrade.
            aliases = RoomVehicleIdAliasStore(database.vehicleIdAliasDao(), database.sessionDao()),
            // account_id is the pairing credential (Phase 2's PairingCoordinator
            // saves it to TelemetrySettings on Approved). It stays null until
            // approval — including while registered-but-unclaimed, when the
            // uploader still runs and writes account_id = null rows (Phase 1
            // RLS accepts them; the server stamps the column from the device
            // token). When the gate is off we answer null AND report ineligible
            // below, preserving the inert behavior (no sink writes, dirty kept)
            // that every prior phase relies on.
            accountIdProvider = {
                AccountIdProvider.of(
                    cloudSyncEnabled,
                    settings.pairingStatus(),
                    settings.accountId()
                )
            },
            // Upload eligibility, not identity: only an APPROVED (claimed) car
            // uploads. Unclaimed uploads (REGISTERED with account_id = null)
            // are disabled: unclaimed rows are unreadable by every client and
            // were the main database-growth source. Unpaired/pending/revoked
            // cars upload nothing either way.
            uploadEnabledProvider = { isUploadEligible() },
        )
    }

    fun isUploadEligible(): Boolean =
        cloudSyncEnabled && settings.pairingStatus() == TelemetrySettings.PAIRING_STATUS_APPROVED

    val annotationCloudUploader: com.timhss.capyenergy.telemetry.sync.AnnotationCloudUploader by lazy {
        val forwardingSink = object : CloudSink {
            override suspend fun upsert(
                table: String,
                rows: List<Map<String, Any?>>,
                conflictColumns: List<String>,
                merge: Boolean
            ) = cloudSink.upsert(table, rows, conflictColumns, merge)
            override suspend fun delete(
                table: String,
                vehicleId: String,
                keys: List<Triple<String, String, Long>>
            ) = cloudSink.delete(table, vehicleId, keys)
        }
        com.timhss.capyenergy.telemetry.sync.AnnotationCloudUploader(
            insightPlaceDao = database.insightPlaceDao(),
            sessionCostDao = database.sessionCostDao(),
            journeyDao = database.journeyDao(),
            preferenceDao = database.preferenceDao(),
            sessionDao = database.sessionDao(),
            sink = forwardingSink,
            vehicleIdProvider = { resolveVehicleId() },
            // Annotations stay claimed-account-only (#236 P2-T5): OFF → null
            // (inert via this uploader's own null short-circuit), ON → real
            // account only when approved. Registered-but-unclaimed cars never
            // upload annotations, and a null account never reaches the sink.
            accountIdProvider = {
                AccountIdProvider.of(
                    cloudSyncEnabled,
                    settings.pairingStatus(),
                    settings.accountId()
                )
            },
            aliases = RoomVehicleIdAliasStore(database.vehicleIdAliasDao(), database.sessionDao())
        )
    }

    /**
     * The car's Lane C (issue #227) control-plane client.
     *
     * The seam is pluggable for tests; the production impl is real and reachable
     * but inert until a Supabase project AND a paired car_token are present —
     * the same gate that keeps Lane A/B uploaders inert until credentials are
     * wired. The token is the credential [PairingCoordinator] saved on an
     * approved pairing, so an unpaired car simply moves nothing.
     */
    var preferenceControlCloud: PreferenceControlCloud = HttpPreferenceControlCloud(
        carTokenProvider = { settings.carToken() },
    )
        private set

    val preferenceControlSync: PreferenceControlSync by lazy {
        PreferenceControlSync(
            cloud = preferenceControlCloud,
            proposalDao = database.preferenceProposalDao(),
            surfaceProposal = { row -> preferenceRepository.mergeIncomingProposal(row) },
            reportedStore = SharedPreferencesReportedDecisionStore.from(appContext),
            vehicleIdProvider = { resolveVehicleId() },
            accountIdProvider = { settings.accountId() },
        )
    }

    /**
     * Cloud device-pairing coordinator (issue #227).
     *
     * Production wiring uses the real [HttpDevicePairingClient] (JDK HTTP
     * against `POST {base}/device-pairing/start` and `/poll`). The seam is
     * pluggable like [cloudSink] / [preferenceControlCloud] so JVM tests can
     * substitute a [com.timhss.capyenergy.telemetry.pairing.FakeDevicePairingClient].
     *
     * `device_code` (the polling secret) lives only in [PairingCoordinator.currentDeviceCode]
     * in memory and is never persisted — only the terminal credential
     * (`car_token`/`account_id`/`pairing_status`) is written to [TelemetrySettings].
     */
    var devicePairingClient: DevicePairingClient = injectedDevicePairingClient ?: HttpDevicePairingClient()
        private set

    /**
     * Fired on a [jobExecutor] thread right after a fresh pairing approval,
     * once history has been re-marked dirty for a changed account.
     *
     * Set by [TelemetryRuntime] to run the first upload pass immediately
     * (with bounded retries) instead of waiting for the 15-minute tick.
     * Null until the runtime wires it — the coordinator hook below tolerates
     * that and still performs the dirty backfill.
     */
    var onPairingApproved: ((accountChanged: Boolean) -> Unit)? = null

    var pairingCoordinator: PairingCoordinator = PairingCoordinator(
        client = devicePairingClient,
        settings = settings,
    ).also { coordinator ->
        // Fresh pairing: notify the runtime for an immediate upload pass.
        // Unsynced local records already carry dirty=1 and upload naturally as
        // O(delta); markHistoryDirty is decoupled so re-pairing does not force
        // re-uploading the entire database.
        // The hook runs on the poller's thread, so this only schedules background
        // work here.
        coordinator.onApprovedHook = { _, accountChanged ->
            jobExecutor.execute {
                runCatching { onPairingApproved?.invoke(accountChanged) }
                    .onFailure { error -> Log.w(TAG, "Pairing upload trigger failed", error) }
            }
        }
    }
        private set

    private object NoOpCloudSink : CloudSink {
        override suspend fun upsert(
            table: String,
            rows: List<Map<String, Any?>>,
            conflictColumns: List<String>,
            merge: Boolean
        ) {
            Log.i("TelemetryGraph", "Cloud upload skipped (no sink) for $table: ${rows.size} rows")
        }
        override suspend fun delete(
            table: String,
            vehicleId: String,
            keys: List<Triple<String, String, Long>>
        ) {
            Log.i("TelemetryGraph", "Cloud delete skipped (no sink) for $table: ${keys.size} keys")
        }
    }


    val databaseHealthReporter = DatabaseHealthReporter(appContext, database)
    val locationSignalProvider = LocationSignalProvider(appContext)
    val vehicleActivityDetector = VehicleActivityDetector()
    val vehiclePropertyHelper = VehiclePropertyHelper(appContext) { settings.packCapacityWh() }
    val chargeControlAppManager = ChargeControlAppManager(appContext)
    var targetSocChangeBroadcaster: ((Int) -> Unit)? = null
    var chargeControlStateBroadcaster: ((com.timhss.capyenergy.ipc.ChargeControlIpcState) -> Unit)? = null
    val chargeControlIpcClient = com.timhss.capyenergy.ipc.ChargeControlIpcClient(
        context = appContext,
        settings = settings,
        onTargetSocChanged = { targetSoc ->
            targetSocChangeBroadcaster?.invoke(targetSoc)
        },
        onStateChanged = { state ->
            chargeControlStateBroadcaster?.invoke(state)
        }
    )
    val temperatureModeHelperMonitor = TemperatureModeHelperMonitor(
        keyserverController = MediaKeyserverController(appContext),
        hvacClimateController = HvacClimateController(vehiclePropertyHelper),
        audioFeedback = AudioTrackTemperatureModeFeedback(),
        enabledProvider = { settings.temperatureModeHelperEnabled() }
    )
    val tripSessionDetector = TripSessionDetector(
        eventRepository,
        sessionRepository,
        { locationSignalProvider.latestSnapshot() }
    )

    /**
     * Um só para os dois consumidores: o detector e o repositório de frames
     * precisam concordar sobre quando a leitura do carregador congelou, senão
     * um encerra a sessão enquanto o outro ainda grava potência. Os dois rodam
     * no `detectorExecutor`, que é de uma thread só.
     */
    val chargerReadingGuard = ChargerReadingGuard()

    /** Mesmo motivo, para a potência DC. Ver [SignalFreezeGuard]. */
    val dcChargePowerGuard = SignalFreezeGuard(SignalKey.EV_DC_CHARGE_POWER)
    /**
     * Opens the app on the plug, in place of the factory charging screen.
     *
     * It reads nothing: the detector below tells it when the plug went in.
     */
    val chargingAutoOpenLauncher = AutoOpenLauncher(
        context = appContext,
        tag = AutoOpenLauncher.TAG_CHARGING,
        destination = AutoOpenLauncher.DESTINATION_CHARGING,
        enabled = { settings.replaceOemChargingEnabled() },
        restingModeActive = { ParkedSessionDetector.someoneIsRestingInside(store.snapshot()) }
    )

    val chargeSessionDetector = ChargeSessionDetector(
        eventRepository,
        sessionRepository,
        chargerReadingGuard,
        dcChargePowerGuard,
        { locationSignalProvider.latestSnapshot() },
        onChargingBegan = chargingAutoOpenLauncher::requestOpen,
    )

    val parkedSessionDetector = ParkedSessionDetector(
        sessionRepository = sessionRepository,
        tripActiveProvider = { tripSessionDetector.activeFrameSession() != null },
        chargeActiveProvider = { chargeSessionDetector.activeFrameSession() != null },
        capacityWhProvider = { resolveCapacityWh() }
    )

    val continuousSessionDetector = ContinuousSessionDetector(
        sessionRepository = sessionRepository,
        enabledProvider = { settings.continuousModeEnabled() }
    )

    // A signal event now knows which session it happened in. It is wired here,
    // after the detectors exist, because the repository is built before them.
    init {
        eventRepository.activeSessionProvider = {
            chargeSessionDetector.activeFrameSession()
                ?: tripSessionDetector.activeFrameSession()
                ?: parkedSessionDetector.activeFrameSession()
        }
    }

    // Explicit type: this and roadcastTripMetricsMonitor each hold a lambda over
    // the other, which leaves inference chasing its own tail.
    val frameRepository: FrameRepository = FrameRepository(
        context = appContext,
        activeSessionProvider = {
            chargeSessionDetector.activeFrameSession() ?: tripSessionDetector.activeFrameSession()
        },
        parkedSessionProvider = {
            parkedSessionDetector.activeFrameSession()
        },
        continuousSessionProvider = {
            continuousSessionDetector.activeFrameSession()
        },
        locationProvider = { locationSignalProvider.latestSnapshot() },
        roadcastTripMetricsProvider = { roadcastTripMetricsMonitor.latest() },
        capacityWhProvider = { resolveCapacityWh() },
        chargerReadingGuard = chargerReadingGuard,
        dcChargePowerGuard = dcChargePowerGuard,
        activeAccountIdProvider = {
            AccountIdProvider.of(
                cloudSyncEnabled,
                settings.pairingStatus(),
                settings.accountId()
            )
        },
    )

    val ecarxSignalProvider = EcarxSignalProvider(appContext)

    // Roadcast stays independent from Flutter so native collection continues when
    val roadcastDaemon = RoadcastDaemon(appContext)
    val roadcastUpdateManager = RoadcastUpdateManager(appContext)
    val roadcastRepository = RoadcastRepository()
    val roadcastTripMetricsMonitor = RoadcastTripMetricsMonitor(
        roadcastRepository,
        // A trip and a charge, and deliberately **not** a parked session.
        // `ParkedSessionDetector` opens one after 30 s in P and keeps it open
        // for as long as the car sits there, so counting it would leave the
        // garage at 60 Hz — which is the whole case this cadence exists to
        // cut. The bus-rate argument does not hold parked either: traction
        // power is zero and pack current is small and slow, so `pack - drive`
        // is no longer a small remainder between two large signals.
        // `liveParkedEnergyBuckets` therefore integrates at 1 Hz.
        sessionActive = {
            tripSessionDetector.activeFrameSession() != null ||
                chargeSessionDetector.activeFrameSession() != null
        },
        onMetrics = { frameRepository.foldCanSample(it) },
    )

    val vhalSubscriptionManager = VhalSubscriptionManager(
        context = appContext,
        policy = policy,
        normalizer = normalizer,
        store = store,
        ecarxSignalProvider = ecarxSignalProvider
    )

    val rangeEfficiencyRepository = RangeEfficiencyRepository(appContext)
    val rangeEstimateMonitor = RangeEstimateMonitor(
        store = store,
        efficiencyProvider = { rangeEfficiencyRepository.snapshot() },
        capacityWhProvider = { settings.packCapacityWh() },
        collectionStartedAtElapsedNanos = { state.startedAtElapsedNanos },
        isCollecting = { state.running }
    )

    val liveTelemetryBleServer = com.timhss.capyenergy.telemetry.ble.LiveTelemetryBleServer(
        context = appContext,
        companionDeviceManager = companionDeviceManager,
        keepBluetoothOn = { settings.keepBluetoothOnEnabled() }
    )

    init {
        sessionRepository.setFrameWriteBarrier { frameRepository.awaitPendingWrites() }
        retentionManager.setActiveSessionProvider {
            chargeSessionDetector.activeFrameSession() != null ||
                tripSessionDetector.activeFrameSession() != null
        }

        temperatureModeHelperMonitor.ensureKeyserverRestored()
        // Recovery blocks on the write queue and replays every pending session's
        // frames, so it cannot run where this object is built: TelemetryRuntime.get()
        // is reached from configureFlutterEngine and from the service, both on the
        // main thread. detectorExecutor is single-threaded, so queuing it first
        // still guarantees recovery completes before the detectors restore.
        detectorExecutor.execute {
            runCatching { vehicleIdentity.bootstrap() }
                .onFailure { error ->
                    Log.w(TAG, "Vehicle identity bootstrap failed", error)
                }
        }
        scheduleVinRetry(0)
        detectorExecutor.execute {
            runCatching { sessionRepository.recoverPendingFinalizations() }
                .onFailure { error ->
                    Log.w(TAG, "Pending session finalization recovery failed", error)
                }
        }
        detectorExecutor.execute { tripSessionDetector.restoreIfNeeded() }
        detectorExecutor.execute { chargeSessionDetector.restoreIfNeeded() }
        detectorExecutor.execute { parkedSessionDetector.restoreIfNeeded() }
        detectorExecutor.execute { continuousSessionDetector.restoreIfNeeded() }
        store.addListener(eventRepository)
        store.addListener(temperatureModeHelperMonitor)
        store.addListener(tripSessionDetector)
        store.addListener(chargeSessionDetector)
        store.addListener(parkedSessionDetector)
        store.addListener(continuousSessionDetector)
        store.addListener(frameRepository)
        chargeControlIpcClient.start()
    }

    fun activeSessionType(): String? =
        chargeSessionDetector.activeFrameSession()?.type
            ?: tripSessionDetector.activeFrameSession()?.type

    /**
     * The pairing account for the read surface, or null when the car is not
     * approved. The same authority the writers use, so a list filters by the
     * same account that stamped the rows; unowned rows stay visible to
     * whoever reads (the DAO applies the adoption rule).
     */
    fun partialCurrentAccountId(): String? =
        AccountIdProvider.of(
            cloudSyncEnabled,
            settings.pairingStatus(),
            settings.accountId()
        )

    /**
     * Pack capacity for every consumer, in Wh.
     *
     * One route, and it does not touch the car: the reader states the pack in
     * Settings. See [GeelyProfile.battery] for why the vehicle property is not
     * read here, or anywhere.
     */
    fun resolveCapacityWh(): Double = settings.packCapacityWh()

    fun resolveVehicleId(): String = settings.vehicleId() ?: "unassigned"

    /**
     * The VIN is the best anchor, so a boot that could not read it retries
     * with backoff instead of settling for a lesser anchor forever. Once the
     * VIN is adopted the upgrade has already written the alias row; the loop
     * stops.
     */
    private fun scheduleVinRetry(attempt: Int) {
        if (attempt >= VIN_RETRY_MAX_ATTEMPTS) {
            Log.i(TAG, "VIN still unreadable after retries; will try again on next boot")
            return
        }
        identityExecutor.schedule({
            runCatching { vehicleIdentity.tryVinUpgrade() }
                .onFailure { error -> Log.w(TAG, "VIN retry failed", error) }
            if (settings.vehicleIdAnchor() != VehicleIdAnchor.VIN) {
                scheduleVinRetry(attempt + 1)
            }
        }, vinRetryDelayMillis(attempt), TimeUnit.MILLISECONDS)
    }

    private fun vinRetryDelayMillis(attempt: Int): Long =
        minOf(VIN_RETRY_BASE_DELAY_MILLIS shl attempt, VIN_RETRY_MAX_DELAY_MILLIS)

    private companion object {
        const val TAG = "TelemetryGraph"
        private const val VIN_RETRY_BASE_DELAY_MILLIS = 5_000L
        private const val VIN_RETRY_MAX_DELAY_MILLIS = 60_000L
        private const val VIN_RETRY_MAX_ATTEMPTS = 20
    }
}
