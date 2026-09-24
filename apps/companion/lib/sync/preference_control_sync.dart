import 'package:flutter/foundation.dart';

import 'preference_control_cloud.dart';

/// The phone's Lane C control-plane state, exposed to UI and tests.
///
/// The control keys come from `kControlPreferenceKeys` (the lane
/// classification registry in telemetry_core) — issue #227's mechanical rule:
/// if it changes what the car does or records, it is control; if it only
/// changes what a screen shows, it is annotation. Exactly two keys are
/// control today; new control keys join the registry, and with it the same
/// `preference_desired`/`preference_reported` tables without a client change.

/// Why the last [PreferenceControlController.propose] wrote nothing.
enum ProposalRefusal {
  /// No signed-in session reaches the control plane.
  unconfigured,

  /// The phone cannot name the vehicle it owns, so it refuses to guess.
  unknownVehicle,
}

/// Result of one [PreferenceControlController.propose].
///
/// Carries the status the view returned **after** the write — never an
/// assumed "applied". A proposed value with no report yet surfaces as
/// [PreferenceControlStatus.pending], never [PreferenceControlStatus.confirmed].
class PreferenceControlProposalResult {
  const PreferenceControlProposalResult.wrote(this.row)
    : wrote = true,
      refusal = null;

  const PreferenceControlProposalResult.refused(this.refusal)
    : wrote = false,
      row = null;

  /// Whether a `preference_desired` row was actually written.
  final bool wrote;

  /// Why nothing was written, null when [wrote] is true.
  final ProposalRefusal? refusal;

  /// The view-derived status read back after the write, null when the row was
  /// not yet visible.
  final PreferenceControlStatusRow? row;

  @override
  String toString() => wrote
      ? 'PreferenceControlProposalResult(wrote, ${row?.status.name})'
      : 'PreferenceControlProposalResult(refused: $refusal)';
}

/// The phone's Lane C control-plane state, exposed to UI and tests.
///
/// Exactly two responsibilities, both mirroring the car-side
/// [PreferenceControlSync] (Step 2):
///
/// **Write path.** [propose] writes one `preference_desired` row — the phone
/// is the only writer of that table, scoped by `account_id = auth.uid()` and
/// enforced by Step 1b's RLS to a vehicle the phone currently owns. The target
/// vehicle comes from [vehicleIdProvider]; a phone that cannot name an owned
/// vehicle refuses rather than guesses. The local mDNS proposal channel is
/// untouched — this lane is additive beside it, never a replacement.
///
/// **Read path.** [refresh] reads the `preference_control_status` join view —
/// never the raw tables — and holds the derived rows as [rows]. The status is
/// settled by the database, not inferred here; a desire with no report stays
/// [PreferenceControlStatus.pending].
///
/// This class never merges two sources of "current proposal status". The view
/// is the one status source this phone surfaces; the mDNS proposals that
/// predate the cloud path stay where they are and are not reconciled here.
class PreferenceControlController extends ChangeNotifier {
  PreferenceControlController({
    required PreferenceControlCloud cloud,
    required String accountId,
    String? Function()? vehicleIdProvider,
    int Function()? clock,
  }) : _cloud = cloud,
       _accountId = accountId,
       _vehicleIdProvider = vehicleIdProvider ?? (() => null),
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final PreferenceControlCloud _cloud;

  /// The signed-in account the phone writes under. Its `account_id` must be
  /// `auth.uid()` for the write's RLS to admit it.
  final String _accountId;

  final String? Function() _vehicleIdProvider;
  final int Function() _clock;

  List<PreferenceControlStatusRow>? _rows;
  Object? _lastError;

  /// The latest status read from the view, or null before the first refresh.
  List<PreferenceControlStatusRow>? get rows => _rows;

  /// The last read/write-side failure, or null when the last run succeeded.
  Object? get lastError => _lastError;

  /// Whether this build reaches the control plane at all.
  bool get isConfigured => _cloud.isConfigured;

  /// The vehicle the phone names for control, when it can name one.
  String? get vehicleId => _vehicleIdProvider();

  /// The row [refresh] surfaced for [key] on the phone's vehicle, or null.
  PreferenceControlStatusRow? rowFor(String key) {
    final vehicle = vehicleId;
    final rows = _rows;
    if (rows == null) return null;
    for (final row in rows) {
      if (row.key != key) continue;
      if (vehicle == null || row.vehicleId == vehicle) return row;
    }
    return null;
  }

  /// Reads the view and replaces [rows]. Never fabricates a status.
  Future<int> refresh() async {
    _lastError = null;
    try {
      final found = await _cloud.readStatus();
      _rows = found;
      notifyListeners();
      return found.length;
    } catch (error) {
      _lastError = error;
      notifyListeners();
      rethrow;
    }
  }

  /// Proposes [value] for a control [key]: writes `preference_desired`, then
  /// reads the view back, so the surfaced status corresponds to whatever the
  /// car will actually report — never an optimistic "it took effect".
  Future<PreferenceControlProposalResult> propose({
    required String key,
    String? value,
  }) async {
    if (!_cloud.isConfigured) {
      return const PreferenceControlProposalResult.refused(
        ProposalRefusal.unconfigured,
      );
    }
    final vehicle = _vehicleIdProvider();
    if (vehicle == null || vehicle.isEmpty) {
      return const PreferenceControlProposalResult.refused(
        ProposalRefusal.unknownVehicle,
      );
    }
    _lastError = null;
    try {
      await _cloud.writeDesired(
        accountId: _accountId,
        vehicleId: vehicle,
        key: key,
        value: value,
        proposedAtUtcMillis: _clock(),
        origin: SupabasePreferenceControlCloud.kDesiredOriginPhone,
      );
    } catch (error) {
      _lastError = error;
      notifyListeners();
      rethrow;
    }
    await refresh();
    return PreferenceControlProposalResult.wrote(rowFor(key));
  }
}
