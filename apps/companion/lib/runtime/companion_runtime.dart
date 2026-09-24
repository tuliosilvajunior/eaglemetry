import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../abrp/abrp_settings_store.dart';
import '../abrp/abrp_telemetry_forwarder.dart';
import '../pairing/device_pairing_gateway.dart';
import '../pairing/supabase_device_pairing_gateway.dart';
import '../ble/ble_transport.dart';
import '../ble/live_telemetry_ble_client.dart';
import '../onboarding/onboarding_store.dart';
import '../settings/nominatim_opt_in_store.dart';
import '../sync/annotation_cloud_sync.dart';
import '../sync/cloud_migration.dart';
import '../sync/cloud_run_report.dart';
import '../sync/cloud_sync_config.dart';
import '../sync/cloud_uploader.dart';
import '../sync/companion_archive.dart';
import '../sync/companion_database.dart';
import '../sync/journey_store.dart';
import '../sync/local_telemetry_source.dart';
import '../sync/nominatim_auto_namer.dart';
import '../sync/nominatim_gateway.dart';
import '../sync/pairing_controller.dart';
import '../sync/pairing_restore.dart';
import '../sync/pairing_store.dart';
import '../sync/preference_control_cloud.dart';
import '../sync/preference_control_sync.dart';
import '../sync/sqflite_store.dart';
import '../sync/supabase_cloud_sink.dart';
import '../sync/cloud_telemetry_pull.dart';

/// One non-nullable value that `CompanionRuntime.start()` produces.
///
/// The runtime is the only place that knows how to build these eleven
/// objects. By returning one value, "not started" stops being representable
/// downstream: a screen that has a [CompanionServices] never checks for null.
class CompanionServices {
  const CompanionServices({
    required this.archive,
    required this.pairing,
    required this.pairingController,
    required this.source,
    required this.store,
    required this.journeys,
    required this.ble,
    required this.abrpSettings,
    required this.abrpForwarder,
    required this.onboarding,
    required this.nominatimOptIn,
    this.control,
    this.cloudMigration,
  });

  final CompanionArchive archive;
  final PairingStore pairing;
  final PairingController pairingController;
  final LocalTelemetrySource source;
  final TelemetryStore store;
  final JourneyStore journeys;
  final LiveTelemetryBleClient ble;
  final AbrpSettingsStore abrpSettings;
  final AbrpTelemetryForwarder abrpForwarder;
  final OnboardingStore onboarding;
  final NominatimOptInStore nominatimOptIn;

  /// The phone's Lane C control-plane state (issue #227), or null when this
  /// build cannot reach the cloud with a signed-in account.
  final PreferenceControlController? control;

  /// One-time full re-upload for existing phone-only history (Phase 4 Step 2).
  /// Null in tests that do not wire it. Gated by [CloudSyncConfig.enabled].
  final CloudMigration? cloudMigration;
}

/// The car-facing behaviours plus the local archive helpers they need.
///
/// The phone is the archive whether or not the car is there, so these are
/// the only operations that need the car. The two archive helpers are kept
/// here so [SyncController] can be tested with a fake plus an
/// in-memory archive, instead of a temp directory plus FFI sqlite.
abstract interface class CarLink {
  /// Cloud pull — the only sync path.
  ///
  /// When a cloud account is paired ([CloudSyncConfig.enabled] and a signed-in
  /// user), this pulls the vehicle's Lane A history (sessions, intervals,
  /// events, tracks, battery_cycles) from Supabase (RLS-scoped by
  /// `account_id`) and merges it into the local archive.
  Future<SyncRunReport> syncFromCloud({
    void Function(SyncProgress progress)? onProgress,
  });

  /// Lane A — telemetry/battery cycles to cloud, gated by [CloudSyncConfig].
  Future<CloudUploadReport?> uploadToCloud({
    void Function(CloudUploadProgress progress)? onProgress,
  });

  /// Lane B — annotation (insight_places, journeys, session_costs,
  /// preferences) push/pull to cloud, gated by [CloudSyncConfig] the same
  /// way as Lane A. Returns null when the gate is off or no account is
  /// signed in — still no-op, matching every prior phase.
  Future<AnnotationCloudSyncReport?> syncAnnotationsToCloud();

  /// Local helpers that [SyncController] needs beside the car.
  Future<void> wipeArchive();
  CompanionArchive? get archive;
}

/// Process-wide companion backend. No UI.
class CompanionRuntime implements CarLink {
  CompanionRuntime({
    this._root,

    /// The archive to run on. Production builds its own from the documents
    /// directory; a test hands in an in-memory one.
    CompanionArchive? archive,

    /// The pairing store to run on. Production builds its own under the
    /// documents directory; a test hands in one it already paired.
    PairingStore? pairing,

    /// The radio the live stream runs on. Production uses the real one; a
    /// test hands in a fake and never touches a plugin.
    BleTransport? bleTransport,
    Future<Directory> Function()? documents,
  }) : _providedArchive = archive,
       _providedPairing = pairing,
       _providedTransport = bleTransport,
       _documents = documents ?? getApplicationDocumentsDirectory;

  static final CompanionRuntime instance = CompanionRuntime();

  final Directory? _root;
  final CompanionArchive? _providedArchive;
  final PairingStore? _providedPairing;
  final BleTransport? _providedTransport;
  final Future<Directory> Function() _documents;

  /// How an uploader is built. Production reads the signed-in account through
  /// the provider; a test hands one in and never reaches a network.
  CloudUploader? Function(CompanionDatabase database)? _uploader;

  // ignore: avoid_setters_without_getters
  set uploaderFactory(CloudUploader? Function(CompanionDatabase)? factory) =>
      _uploader = factory;

  /// How Lane B annotation sync is built. Production reads the signed-in
  /// account and the Supabase sink; a test hands one in and never reaches a
  /// network. Gated by [CloudSyncConfig] the same way as Lane A — OFF still
  /// resolves to null (no-op) even when credentials are present.
  AnnotationCloudSync? Function(CompanionArchive archive)? _annotationSync;

  // ignore: avoid_setters_without_getters
  set annotationSyncFactory(
    AnnotationCloudSync? Function(CompanionArchive archive)? factory,
  ) => _annotationSync = factory;

  /// How the Lane C controller is built. Production reads the signed-in
  /// account through the cloud provider and the phone's vehicle through its
  /// own archive; a test hands one in and never reaches a network.
  PreferenceControlController? Function(CompanionArchive archive)? _control;

  // ignore: avoid_setters_without_getters
  set controlFactory(
    PreferenceControlController? Function(CompanionArchive archive)? factory,
  ) => _control = factory;

  /// How the one-time cloud migration is built (Phase 4 Step 2). Production
  /// wires real sinks gated by [CloudSyncConfig.enabled]; a test injects
  /// fakes and never reaches a network.
  CloudMigration? Function(CompanionArchive archive)? _migrationFactory;

  // ignore: avoid_setters_without_getters
  set migrationFactory(
    CloudMigration? Function(CompanionArchive archive)? factory,
  ) => _migrationFactory = factory;

  /// How the cloud telemetry pull is built. Production reads the signed-in
  /// account and the Supabase sink; a test hands one in and never reaches a
  /// network. Gated by [CloudSyncConfig] the same way as Lane A uploads.
  CloudTelemetryPull? Function(CompanionArchive archive)? _telemetryPullFactory;

  // ignore: avoid_setters_without_getters
  set telemetryPullFactory(
    CloudTelemetryPull? Function(CompanionArchive archive)? factory,
  ) => _telemetryPullFactory = factory;

  CompanionServices? _services;

  /// The started value, or null when [start] has not run.
  CompanionServices? get maybeServices => _services;

  /// The started value. Throws when [start] has not run.
  CompanionServices get services {
    final value = _services;
    if (value == null) {
      throw StateError('CompanionRuntime.start has not run');
    }
    return value;
  }

  // ---------------------------------------------------------------------------
  // Backward-compatible nullable surface.
  //
  // New code takes the [CompanionServices] value returned by [start] and
  // never reads these. Old tests and `main.dart` still do, so they delegate
  // to [_services] until the call sites are migrated. The interface shrinks
  // to one non-nullable value; these remain only for compatibility.
  @override
  CompanionArchive? get archive => _services?.archive;
  PairingStore? get pairing => _services?.pairing;
  PairingController? get pairingController => _services?.pairingController;
  LocalTelemetrySource? get source => _services?.source;
  TelemetryStore? get store => _services?.store;
  JourneyStore? get journeys => _services?.journeys;
  LiveTelemetryBleClient? get ble => _services?.ble;
  AbrpSettingsStore? get abrpSettings => _services?.abrpSettings;
  AbrpTelemetryForwarder? get abrpForwarder => _services?.abrpForwarder;
  OnboardingStore? get onboarding => _services?.onboarding;
  NominatimOptInStore? get nominatimOptIn => _services?.nominatimOptIn;
  PreferenceControlController? get control => _services?.control;
  CloudMigration? get cloudMigration => _services?.cloudMigration;

  bool get isReady => _services != null;

  VoidCallback? _follow;
  PairingController? _followPairing;
  AbrpSettingsStore? _followAbrp;
  StreamSubscription<LiveTelemetrySnapshot>? _bleForwarderSub;

  Future<CompanionServices> start() async {
    final existing = _services;
    if (existing != null) return existing;
    final root = _root ?? Directory('${(await _documents()).path}/companion');
    root.createSync(recursive: true);
    final pairingStore = _providedPairing ?? PairingStore(directory: root);
    final onboardingStore = OnboardingStore(directory: root);
    final abrpStore = FileAbrpSettingsStore(directory: root);
    final archiveDbFuture = _providedArchive != null
        ? Future.value(null)
        : CompanionDatabase.open('${root.path}/archive.db');

    final (archiveDb, _, _, _) = await (
      archiveDbFuture,
      onboardingStore.load(),
      pairingStore.load(),
      abrpStore.load(),
    ).wait;

    final archiveStore = _providedArchive ?? CompanionArchive(archiveDb!);
    await archiveStore.load();
    final nominatimOptIn = NominatimOptInStore(archiveStore);
    await nominatimOptIn.load();
    final DevicePairingGateway? pairingGateway =
        SupabaseDevicePairingGateway.current;
    final controller = PairingController(
      store: pairingStore,
      gateway: pairingGateway,
      isSignedIn: () {
        try {
          // Supabase global; when not configured or not signed in, currentSession is null.
          return Supabase.instance.client.auth.currentSession != null;
        } catch (_) {
          return false;
        }
      },
      restoreLookup: _pairingRestoreLookup,
    );
    final localSource = LocalTelemetrySource(archiveStore);
    final telemetryStore = SqfliteStore(archiveStore.database);
    final journeyStore = JourneyStore(archiveStore);

    final bleClient = LiveTelemetryBleClient(transport: _providedTransport);
    final forwarder = AbrpTelemetryForwarder.create(settingsStore: abrpStore);
    final sub = bleClient.snapshotStream.listen((snapshot) {
      forwarder.onSnapshotReceived(snapshot);
    });

    final control =
        await _defaultControlController(archiveStore) ??
        _control?.call(archiveStore);

    final migration = _buildMigration(archiveStore);
    if (migration != null) {
      await migration.load();
      // One-time full re-upload for existing phone-only history (Phase 4 Step 2).
      // Gated by CloudSyncConfig — no-op until deliberately enabled.
      // Fire-and-forget but verifiably completed: the flag is set only after
      // real sink responses, so an offline first launch retries next time.
      unawaited(migration.runIfNeeded());
    }

    final built = CompanionServices(
      archive: archiveStore,
      pairing: pairingStore,
      pairingController: controller,
      source: localSource,
      store: telemetryStore,
      journeys: journeyStore,
      ble: bleClient,
      abrpSettings: abrpStore,
      abrpForwarder: forwarder,
      onboarding: onboardingStore,
      nominatimOptIn: nominatimOptIn,
      control: control,
      cloudMigration: migration,
    );
    _services = built;
    _bleForwarderSub = sub;

    void follow() => _followBleGates(bleClient, pairingStore, abrpStore);
    _follow = follow;
    _followPairing = controller;
    _followAbrp = abrpStore;
    follow();
    controller.addListener(follow);
    abrpStore.addListener(follow);
    // Earliest auto-name: as soon as archive is ready and opt-in is on,
    // fill existing empty places and create entries for candidates without
    // waiting for the user to open the Places screen.
    unawaited(_runAutoName(built));
    // Re-run when the toggle flips on.
    nominatimOptIn.addListener(() {
      if (nominatimOptIn.enabled) unawaited(_runAutoName(built));
    });
    return built;
  }

  /// Unhooks the two listeners registered in [start] and cancels the
  /// forwarder subscription. Call when the runtime is discarded, so a
  /// discarded runtime stops opening the radio after pairing or the beta
  /// switch changes.
  Future<void> dispose() async {
    final follow = _follow;
    final pairing = _followPairing;
    final abrp = _followAbrp;
    if (follow != null && pairing != null) {
      pairing.removeListener(follow);
    }
    if (follow != null && abrp != null) {
      abrp.removeListener(follow);
    }
    _follow = null;
    _followPairing = null;
    _followAbrp = null;
    await _bleForwarderSub?.cancel();
    _bleForwarderSub = null;
  }

  void _followBleGates(
    LiveTelemetryBleClient client,
    PairingStore pairingStore,
    AbrpSettingsStore abrpStore,
  ) {
    final record = pairingStore.current;
    final allowed =
        abrpStore.enabled &&
        record != null &&
        record.isPaired &&
        record.sharedSecret.isNotEmpty;
    if (allowed == client.isRunning) return;
    if (allowed) {
      unawaited(client.start(sharedSecretBase64: record.sharedSecret));
    } else {
      unawaited(client.stop());
    }
  }

  /// The Lane C control controller for a production build, or null when it
  /// cannot reach the cloud with a signed-in account.
  ///
  /// The target vehicle is the phone's own: the phone learns which cars it
  /// controls from the sessions it holds. Exactly one known vehicle is named
  /// plainly; none or several make the provider answer null, which the
  /// controller turns into a refusal rather than a guess.
  CloudMigration? _buildMigration(CompanionArchive archive) {
    if (_migrationFactory != null) return _migrationFactory!(archive);
    return CloudMigration(
      archive: archive,
      annotationSyncFactory: () => _defaultAnnotationSync(archive),
      controlCloudFactory: () => SupabasePreferenceControlCloud.controlFor(),
    );
  }

  Future<PreferenceControlController?> _defaultControlController(
    CompanionArchive archive,
  ) async {
    final cloud = SupabasePreferenceControlCloud.controlFor();
    if (cloud == null) return null;
    final known = await archive.database.knownVehicleIds();
    return PreferenceControlController(
      cloud: cloud,
      accountId: cloud.accountId,
      vehicleIdProvider: () => known.length == 1 ? known.first : null,
    );
  }

  Future<void> _runAutoName(CompanionServices services) async {
    if (!services.nominatimOptIn.enabled) return;
    try {
      final gateway = NominatimGateway(database: services.archive.database);
      final namer = NominatimAutoNamer(
        source: services.source,
        gateway: gateway,
        optInStore: services.nominatimOptIn,
      );
      final report = await namer.runOnce();
      if (report.didWork) services.source.notifyAnnotationsIfChanged();
    } catch (_) {
      // Best-effort: never crashes startup or sync.
    }
  }

  @override
  Future<CloudUploadReport?> uploadToCloud({
    void Function(CloudUploadProgress progress)? onProgress,
  }) async {
    final store = _services?.archive;
    if (store == null) return null;
    final uploader =
        _uploader?.call(store.database) ??
        SupabaseCloudSink.uploaderFor(
          store.database,
          activeVehicleIdProvider: () {
            final pairing = _services?.pairing.current;
            return (pairing != null && pairing.isPaired)
                ? pairing.vehicleId
                : null;
          },
        );
    if (uploader == null) return null;
    return uploader.run(onProgress: onProgress);
  }

  @override
  Future<AnnotationCloudSyncReport?> syncAnnotationsToCloud() async {
    final archive = _services?.archive;
    if (archive == null) return null;
    final sync =
        _annotationSync?.call(archive) ?? _defaultAnnotationSync(archive);
    if (sync == null) return null;
    return sync.sync();
  }

  /// The Lane B annotation sync for a production build, or null when the gate
  /// is off or no account is signed in — still no-op, matching every prior
  /// phase. Credentials are sourced via the already-established
  /// [SupabaseConfig] → [SupabaseCloudSink] path (dart-define `SUPABASE_URL` /
  /// `SUPABASE_PUBLISHABLE_KEY`); this method only adds the production call
  /// site that prior phases deliberately left absent.
  AnnotationCloudSync? _defaultAnnotationSync(CompanionArchive archive) {
    if (!CloudSyncConfig.enabled) return null;
    final client = _supabaseClientOrNull();
    final sink = SupabaseCloudSink.of(client);
    final accountId = client?.auth.currentUser?.id;
    return AnnotationCloudSync.maybeFor(
      archive: archive,
      sink: sink,
      accountId: accountId,
      vehicleIdProvider: () => null,
    );
  }

  SupabaseClient? _supabaseClientOrNull() {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  /// The cloud lookup behind [PairingController.restore]: this account's
  /// cars through the existing [SupabaseCloudSink] seam, most recent first.
  /// Null when signed out or unconfigured; a failure answers null too, so a
  /// later start retries.
  Future<RestoredPairing?> _pairingRestoreLookup() async {
    final client = _supabaseClientOrNull();
    final sink = SupabaseCloudSink.of(client);
    final accountId = client?.auth.currentUser?.id;
    if (sink == null || accountId == null) return null;
    return restoreOwnedVehicle(sink: sink, accountId: accountId);
  }

  @override
  Future<void> wipeArchive() async {
    await _services?.archive.wipe();
    _services?.source.notifyIfChanged();
  }

  @override
  Future<SyncRunReport> syncFromCloud({
    void Function(SyncProgress progress)? onProgress,
  }) async {
    final archive = _services?.archive;
    final source = _services?.source;
    if (archive == null) {
      return SyncRunReport(
        status: SyncRunStatus.failed,
        ackedRecords: 0,
        error: StateError('CompanionRuntime.start has not run'),
      );
    }
    final pull =
        _telemetryPullFactory?.call(archive) ?? _defaultTelemetryPull(archive);
    if (pull == null) {
      // No project, nobody signed in, or gate off: nothing to pull with.
      // The controller reports the failure; there is no local path left.
      return const SyncRunReport(status: SyncRunStatus.failed, ackedRecords: 0);
    }
    final report = await pull.pull(onProgress: onProgress);
    source?.notifyIfChanged();
    // Post-sync auto-name: new sessions may have candidate places.
    final services = _services;
    if (services != null && report.status != SyncRunStatus.failed) {
      unawaited(_runAutoName(services));
    }
    return report;
  }

  CloudTelemetryPull? _defaultTelemetryPull(CompanionArchive archive) {
    if (!CloudSyncConfig.enabled) return null;
    final client = _supabaseClientOrNull();
    final sink = SupabaseCloudSink.of(client);
    final accountId = client?.auth.currentUser?.id;
    if (sink == null || accountId == null) return null;
    return CloudTelemetryPull(
      archive: archive,
      sink: sink,
      accountId: accountId,
    );
  }
}
