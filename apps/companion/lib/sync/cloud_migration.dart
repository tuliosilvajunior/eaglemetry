import 'package:flutter/foundation.dart';
import 'package:telemetry_core/telemetry_core.dart';

import 'annotation_cloud_sync.dart';
import 'cloud_sync_config.dart';
import 'companion_archive.dart';
import 'companion_database.dart';
import 'preference_control_cloud.dart';

/// The persisted one-time full re-upload for existing companion-only history.
///
/// Issue #227 Phase 4 Step 2: before cloud sync was gated, the companion's
/// upload was a manual button, so some users have history that lives ONLY on
/// their phone and was never uploaded. When the gate flips, that history must
/// not be silently left behind. This class makes the mitigation real.
///
/// Contract:
/// * gated by [CloudSyncConfig.enabled] — gate off (explicit false) means
///   nothing happens, same as Step 1's real sinks;
/// * one persisted flag (`cloud_migration_v1_completed` in `meta`) decides
///   whether this install has already run its one-time pass;
/// * the pass is idempotent — every cloud write is a natural-key upsert
///   (`merge:true` with `onConflict`), so a repeat never duplicates;
/// * completion is written only after the sinks actually responded without
///   error (not fire-and-forget);
/// * interruption is safe — a partial failure leaves the flag unset, so the
///   next launch retries the whole pass (the same idempotent upserts).
enum CloudMigrationState { idle, syncing, done, failed }

class CloudMigration extends ChangeNotifier {
  CloudMigration({
    required this._archive,
    AnnotationCloudSync? Function()? annotationSyncFactory,
    PreferenceControlCloud? Function()? controlCloudFactory,
    bool Function()? enabledProvider,
  }) : _annotationSyncFactory = annotationSyncFactory,
       _controlCloudFactory = controlCloudFactory,
       _enabledProvider = enabledProvider ?? (() => CloudSyncConfig.enabled);

  final CompanionArchive _archive;
  CompanionDatabase get _db => _archive.database;
  final AnnotationCloudSync? Function()? _annotationSyncFactory;
  final PreferenceControlCloud? Function()? _controlCloudFactory;
  final bool Function() _enabledProvider;

  static const completedKey = 'cloud_migration_v1_completed';
  static const _completedValue = '1';

  CloudMigrationState _state = CloudMigrationState.idle;
  CloudMigrationState get state => _state;

  String? _error;
  String? get error => _error;

  bool _running = false;

  /// Whether the one-time pass has already verifiably completed.
  Future<bool> isCompleted() async {
    final value = await _db.readMeta(completedKey);
    return value == _completedValue;
  }

  /// Loads persisted completion into [_state] — call once at startup.
  Future<void> load() async {
    if (await isCompleted()) {
      _state = CloudMigrationState.done;
      _error = null;
    } else {
      _state = CloudMigrationState.idle;
    }
    notifyListeners();
  }

  /// Runs the one-time pass if this is the first launch with the gate enabled.
  ///
  /// Returns true when the pass ran and verifiably completed, false otherwise
  /// (already done, gate off, or not yet successful — will retry next launch).
  Future<bool> runIfNeeded() async {
    if (!_enabledProvider()) return false;
    if (await isCompleted()) {
      _state = CloudMigrationState.done;
      notifyListeners();
      return false;
    }
    if (_running) return false;
    return _run();
  }

  /// Forces the pass regardless of the gate — used only by tests that inject
  /// factories bypassing the gate. Production always goes through [runIfNeeded].
  @visibleForTesting
  Future<bool> runForTest() => _run();

  Future<bool> _run() async {
    _running = true;
    _state = CloudMigrationState.syncing;
    _error = null;
    notifyListeners();
    try {
      // Gate could have been OFF but test injects factories — still require
      // real sinks to be available; a missing sink is a retryable "not ready".
      final annotationSync = _annotationSyncFactory?.call();
      final controlCloud = _controlCloudFactory?.call();

      // Lane B must have something to push through, Lane C must be able to
      // name vehicle + account. If neither lane has a sink yet (e.g. not
      // signed in, no vehicle), treat as not-ready — don't mark done, retry.
      final hasLaneB = annotationSync != null;
      final hasLaneC = controlCloud != null;

      if (!hasLaneB && !hasLaneC) {
        // Check if there is actually local history that needs migration.
        // If there's nothing local, we can mark done — no work to do.
        final hasLocalHistory = await _hasLocalHistory();
        if (!hasLocalHistory) {
          await _db.writeMeta(completedKey, _completedValue);
          _state = CloudMigrationState.done;
          notifyListeners();
          return true;
        }
        _state = CloudMigrationState.failed;
        _error = 'not ready: no cloud sink';
        notifyListeners();
        return false;
      }

      // ---------- Lane B: full annotation re-upload ----------
      if (annotationSync != null) {
        final report = await annotationSync.push();
        if (report.hasErrors) {
          // Per-table failure — surface first error, retry next launch.
          final first = report.errors.values.first;
          throw StateError('lane B failed: $first');
        }
        // `push()` with no local rows is also success — nothing to migrate.
      }

      // ---------- Lane C: full control-preference re-upload ----------
      if (controlCloud != null) {
        final laneCFailed = await _pushControlPreferences(controlCloud);
        if (laneCFailed != null) throw laneCFailed;
      }

      // Verifiably succeeded — mark completed only now.
      await _db.writeMeta(completedKey, _completedValue);
      _state = CloudMigrationState.done;
      _error = null;
      notifyListeners();
      return true;
    } catch (e) {
      _state = CloudMigrationState.failed;
      _error = e.toString();
      notifyListeners();
      return false;
    } finally {
      _running = false;
    }
  }

  /// Pushes every local control preference (key in [kControlPreferenceKeys])
  /// to `preference_desired` via [cloud].
  ///
  /// Returns null on success, otherwise an exception to surface.
  Future<Object?> _pushControlPreferences(PreferenceControlCloud cloud) async {
    try {
      final all = await _db.allPreferences();
      final controls = [
        for (final row in all)
          if (kControlPreferenceKeys.contains(row['key'] as String?) &&
              row['deletedAtUtcMillis'] == null)
            row,
      ];
      if (controls.isEmpty) return null;

      final vehicleIds = await _db.knownVehicleIds();
      if (vehicleIds.isEmpty) {
        return StateError(
          'lane C failed: unknown vehicle — cannot write desired',
        );
      }

      // For each owned vehicle, upsert every control preference. The cloud
      // table is keyed by (account_id, vehicle_id, key), so this is idempotent.
      for (final vehicleId in vehicleIds) {
        for (final row in controls) {
          final key = row['key'] as String;
          final rawValue = row['value'];
          final value = rawValue?.toString();
          final proposedAt =
              (row['updatedAtUtcMillis'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch;
          final origin = (row['origin'] as String?)?.isNotEmpty == true
              ? row['origin'] as String
              : kAnnotationOriginPhone;
          await cloud.writeDesired(
            accountId: cloud.accountId,
            vehicleId: vehicleId,
            key: key,
            value: value,
            proposedAtUtcMillis: proposedAt,
            origin: origin,
          );
        }
      }
      return null;
    } catch (e) {
      return e;
    }
  }

  Future<bool> _hasLocalHistory() async {
    final places = await _db.allPlaces();
    if (places.isNotEmpty) return true;
    final prefs = await _db.allPreferences();
    if (prefs.isNotEmpty) return true;
    final costs = await _db.allSessionCosts();
    if (costs.isNotEmpty) return true;
    final journeys = await _db.allJourneys();
    if (journeys.isNotEmpty) return true;
    // Also check proposal table if ever used locally
    final proposals = await _db.allPreferenceProposals();
    if (proposals.isNotEmpty) return true;
    return false;
  }

  /// Clears the persisted completion — only for tests that reuse a DB.
  @visibleForTesting
  Future<void> clearCompletedForTest() async {
    await _db.deleteMeta(completedKey);
    _state = CloudMigrationState.idle;
    _error = null;
    notifyListeners();
  }
}
