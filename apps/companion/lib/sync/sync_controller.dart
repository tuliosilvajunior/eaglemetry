import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../runtime/companion_runtime.dart';
import 'cloud_run_report.dart';
import 'cloud_sync_config.dart';
import 'supabase_cloud_sink.dart';
import 'companion_archive.dart';

/// Runs one cloud pull on demand and holds what the last one did.
///
/// The pull returns a report and remembers nothing.
/// A screen needs both — what is happening now, and what the last run left
/// behind — so the memory lives here rather than in the widget, which the
/// shell is free to rebuild or drop.
class SyncController extends ChangeNotifier {
  SyncController({
    CarLink? car,
    CompanionRuntime? runtime,
    Future<SyncRunReport> Function({
      void Function(SyncProgress progress)? onProgress,
    })?
    runner,
    // Test seam for the automatic pull: production reads
    // [CloudSyncConfig.enabled] (a compile-time const, true in tests).
    bool Function()? autoSyncGate,
  }) : assert(car != null || runtime != null, 'car or runtime required'),
       car = car ?? runtime!,
       _cloudRunner = runner ?? (car ?? runtime!).syncFromCloud,
       _autoSyncGate = autoSyncGate ?? (() => CloudSyncConfig.enabled);

  /// Whether the automatic pull may run. Production reads
  /// [CloudSyncConfig.enabled]; a test hands in `() => true`.
  final bool Function() _autoSyncGate;

  /// The narrow car link. The controller owns nothing else: the archive is
  /// reachable through the link when it needs counts, and the tests can fake
  /// just these methods.
  final CarLink car;

  /// Cloud pull — the only sync path. `runNow()` calls [_cloudRunner]
  /// ([CarLink.syncFromCloud]) and its answer is final: the local Wi-Fi
  /// path is removed, so there is nothing to fall back to.
  final Future<SyncRunReport> Function({
    void Function(SyncProgress progress)? onProgress,
  })
  _cloudRunner;

  bool busy = false;

  /// The last page that landed, while a run is in flight. Null when nothing is
  /// running, so a card cannot draw a stale bar over an idle screen.
  SyncProgress? progress;

  /// The newest page of every stream this run has reached, keyed by stream.
  ///
  /// [progress] is one page and cannot say what the other streams are
  /// doing. A card that lists all streams needs the run's whole standing, and
  /// the pull runs them in a fixed order, so a stream absent from this map is
  /// one the run has not started rather than one that failed.
  final Map<SyncStreamType, SyncProgress> pages = {};

  /// How often the phone pulls from the cloud on its own.
  ///
  /// Ten minutes: the car's background cadence is on this order, trips only
  /// land when the car uploads anyway, and a sub-minute timer would burn the
  /// radio for nothing. Battery-friendly by default, as the task requires.
  static const Duration autoSyncInterval = Duration(minutes: 10);

  /// The periodic cloud pull.
  ///
  /// A `PollLoop` rather than a timer, for the rules it already carries: one
  /// pull in flight at a time, no tick while the app is off screen, and an
  /// immediate pull when the app comes back — the "user re-opens the app"
  /// trigger. The manual "Sincronizar" button still calls [runNow] directly;
  /// this loop is additive, never a replacement.
  late final PollLoop _autoSyncLoop = PollLoop(
    interval: autoSyncInterval,
    read: _autoSyncTick,
    debugLabel: 'SyncController.autoSync',
    onError: (_, _) {
      // The failure is already in `lastReport` for the card to draw. A
      // periodic tick has no caller to answer to.
    },
  );

  /// Starts the automatic cloud pull: one pull at once, then one every
  /// [autoSyncInterval] while the app is in the foreground.
  ///
  /// Called once from `main()` after the first frame. Nothing else should
  /// start it: the loop is process-wide, like the controller.
  void startAutoSync() {
    if (_autoSyncLoop.isRunning) return;
    _autoSyncLoop.start();
  }

  /// Stops the automatic pull. Kept for tests; production never stops it.
  void stopAutoSync() {
    if (!_autoSyncLoop.isRunning) return;
    _autoSyncLoop.stop();
  }

  /// One automatic pull. Skipped when the cloud gate is off: [runNow] would
  /// report a failure for a pull that has nothing to pull with.
  ///
  /// `runNow` itself guards the rest — `busy` drops the tick when the manual
  /// button is mid-run.
  Future<void> _autoSyncTick() async {
    if (!_autoSyncGate()) return;
    await runNow();
  }

  @override
  void dispose() {
    _autoSyncLoop.dispose();
    super.dispose();
  }

  /// The last run, or null before the first one.
  SyncRunReport? lastReport;

  /// When the last run finished, in local time.
  DateTime? lastRunAt;

  CompanionArchive? get archive => car.archive;

  /// How many sessions the phone holds. It is the store's own count, not a
  /// total the car reported: the phone states what it has, never what it
  /// expects to get. Counted after a run rather than on every rebuild, so
  /// drawing the card touches no database.
  int tripCount = 0;
  int chargeCount = 0;

  /// How many of this phone's own edits have not reached the cloud yet.
  ///
  /// It is the annotation outbox's own length. The outbox is cleared by a
  /// successful push, so zero means "nothing is waiting" and is answerable
  /// without asking the car. The old inventory could not say this: it came
  /// from the car over the local link, which production retired, so in a real
  /// build it was never answered at all and the card drew nothing.
  int pendingCount = 0;

  /// Progress state of local records versus the cloud (dirty vs clean).
  SyncProgressData? syncProgress;

  /// Reads [pendingCount]. A read that throws keeps the last count: a failed
  /// query is not an empty outbox.
  Future<void> _refreshPending() async {
    final archive = car.archive;
    if (archive == null) return;
    try {
      pendingCount = (await archive.database.pendingAnnotationPush()).length;
    } on Object {
      // Keep what it had. Stale is true of some moment; zero would not be.
    }
  }

  /// Reads the counts once, for a screen that opens without syncing.
  Future<void> refreshCounts() async {
    final archive = car.archive;
    if (archive == null) return;
    tripCount = await archive.database.countTrips();
    chargeCount = await archive.database.countCharges();
    try {
      syncProgress = await archive.database.getSyncProgress();
    } on Object {
      // Keep what it had.
    }
    await _refreshPending();
    notifyListeners();
  }

  /// Deletes everything this phone pulled, and every cursor with it.
  Future<void> wipe() async {
    if (busy) return;
    busy = true;
    notifyListeners();
    try {
      await car.wipeArchive();
      lastReport = null;
      pages.clear();
      tripCount = 0;
      chargeCount = 0;
      syncProgress = null;
    } finally {
      busy = false;
      notifyListeners();
    }
    await refreshCounts();
  }

  /// Pulls from the cloud right now: the Force Sync entry point.
  ///
  /// Sets [busy] while the pull runs and leaves the real report in
  /// [lastReport] afterward — success with a row count, clean "nothing
  /// new", or the failure — never an optimistic "done". A pull that finds
  /// nothing new because the car has not uploaded reads as "checked,
  /// nothing new yet" ([SyncOutcomeKind.carSilent]), never as a phone
  /// failure: the phone did its job, the car simply sent nothing.
  Future<void> runNow() async {
    if (busy) return;
    busy = true;
    progress = null;
    pages.clear();
    notifyListeners();
    try {
      void handleProgress(SyncProgress value) {
        progress = value;
        pages[value.stream] = value;
        notifyListeners();
      }

      lastReport = await _cloudRunner(onProgress: handleProgress);
      // Lane B in the same press: this phone's own edits go up while the
      // car's history comes down. Without it the outbox has no drain in a
      // production build, so "still to send" could never reach zero and the
      // card would ask the reader to fix something they cannot.
      try {
        await car.syncAnnotationsToCloud();
      } on Object {
        // The rows stay in the outbox, so [pendingCount] still reads
        // "waiting". A push that failed needs no second report.
      }
      final archive = car.archive;
      if (archive != null) {
        tripCount = await archive.database.countTrips();
        chargeCount = await archive.database.countCharges();
        try {
          syncProgress = await archive.database.getSyncProgress();
        } on Object {
          // Keep what it had.
        }
      }
    } finally {
      busy = false;
      // The pages are kept. The card lists what the finished run did, and
      // clearing them here would empty it in the frame the run ended.
      progress = null;
      lastRunAt = DateTime.now();
      notifyListeners();
    }
    await _refreshPending();
    notifyListeners();
  }
}

enum SyncOutcomeKind {
  neverRun,
  completed,
  nothingNew,
  carSilent,
  failed,
  phoneOffline,
  cloudDisabled,
}

/// Reads [report] as one [SyncOutcomeKind]. Screens map each kind to their
/// own localized line, so the two surfaces never drift into two meanings.
SyncOutcomeKind syncOutcomeKind(
  SyncRunReport? report, {
  bool cloudEnabled = CloudSyncConfig.enabled,
}) {
  if (report == null) return SyncOutcomeKind.neverRun;
  return switch (report.status) {
    SyncRunStatus.completed when report.ackedRecords > 0 =>
      SyncOutcomeKind.completed,
    // Reached the cloud and the car sent nothing: either the car is empty or
    // it has not uploaded (offline, gate off car-side). Both read the same:
    // the silence is the car's, not this phone's and not the build's.
    SyncRunStatus.completed when cloudEnabled => SyncOutcomeKind.carSilent,
    SyncRunStatus.completed => SyncOutcomeKind.nothingNew,
    // Gate off: the cloud was never tried, so any failure here is the build,
    // not connectivity.
    SyncRunStatus.failed when !cloudEnabled => SyncOutcomeKind.cloudDisabled,
    SyncRunStatus.failed when _isNetworkError(report.error) =>
      SyncOutcomeKind.phoneOffline,
    SyncRunStatus.failed => SyncOutcomeKind.failed,
  };
}

/// Whether [error] names this phone's link to the cloud rather than the car.
///
/// The cloud path wraps transport faults as [CloudUploadFailure] carrying the
/// thrown type's name as code. Anything else (Postgres codes, decode faults)
/// is not this phone being offline. The substring fallback covers HTTP-client
/// wrappers that rename the type but keep the words.
bool _isNetworkError(Object? error) {
  if (error == null) return false;
  if (error is SocketException ||
      error is HttpException ||
      error is TimeoutException) {
    return true;
  }
  if (error is CloudUploadFailure && _networkCodes.contains(error.code)) {
    return true;
  }
  final text = error.toString().toLowerCase();
  return text.contains('socket') ||
      text.contains('network') ||
      text.contains('connection refused') ||
      text.contains('timed out') ||
      text.contains('timeout') ||
      text.contains('unreachable') ||
      text.contains('no address associated with hostname');
}

/// Thrown-type names the sink's guard keeps as [CloudUploadFailure.code] for
/// faults that never reached Postgres.
const _networkCodes = {
  'SocketException',
  'HttpException',
  'ClientException',
  'TimeoutException',
  'TlsException',
  'HandshakeException',
  'OSError',
  'NetworkException',
};
