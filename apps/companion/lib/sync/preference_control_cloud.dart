import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../auth/supabase_config.dart';
import 'cloud_sync_config.dart';
import 'cloud_uploader.dart';
import 'supabase_cloud_sink.dart';

///
/// Two tables, one writer each:
///   `preference_desired`  — what the phone wants    (written by the phone)
///   `preference_reported` — what the car actually did (written by the car)
///
/// joined by a read-only view, `preference_control_status`, that derives one
/// of five statuses per `(vehicle_id, key)`. This file is the phone-side
/// read/write path to those tables (Step 3 of Phase 3; Step 2 already wired
/// the car). It deliberately mirrors the car-side `PreferenceControlCloud`
/// (Kotlin) seam: one interface, a real implementation over the collector's
/// own cloud client, and a fake in tests — nothing here touches a network in
/// a unit test.
///
/// The phone differs from the car in exactly the two ways the RLS expects:
///
/// * The phone runs as `authenticated` (a real signed-in session, Phase 1/2),
///   never as `anon` with an `x-car-token`. Every desired row is scoped by
///   `account_id = auth.uid()`, written `to authenticated`.
/// * Step 1b's RLS also requires an **active `vehicle_ownership` row** for the
///   target vehicle. The phone must therefore write only vehicles it owns;
///   the write is refused by RLS (`42501`) otherwise. This side never fights
///   that rule — it names an owned vehicle or it does not write.
///
/// The read path goes through `preference_control_status` — the join view,
/// not the raw tables — because the view is the one place the two facts meet
/// and the one place the "a desire with no report is `pending`, never
/// `confirmed`" rule lives. Deriving it in the client would mean re-implement
/// the rule this lane exists to keep single-sourced.
///
/// The local mDNS proposal channel stays as the fallback through Phases 1–3,
/// so this cloud path is additive, never a replacement.

/// The five statuses the `preference_control_status` view derives.
///
/// The phone never infers one of these from local state. Each value comes from
/// the view's own `status` column; this enum is only a typed spelling of what
/// the database already decided. An unknown or absent value is an error, never
/// a guess at `confirmed`.
enum PreferenceControlStatus {
  /// The phone proposed, the car has not decided. Never applied.
  pending,

  /// The car accepted, and the accepted value equals the desired value.
  confirmed,

  /// The car's last decision predates a newer proposal: the desire is fresh
  /// or superseded, and even a matching value is NOT applied to it. Never
  /// auto-merge.
  stale,

  /// The car refused, or accepted a different value than desired.
  refused,

  /// The car runs a value the phone never (re)proposed. Informational.
  reportedOnly;

  /// The SQL value the migration's view emits, verbatim.
  String get wire => switch (this) {
    pending => 'pending',
    confirmed => 'confirmed',
    stale => 'stale',
    refused => 'refused',
    reportedOnly => 'reported_only',
  };

  /// Parses the view's `status` value.
  ///
  /// Throws [FormatException] on anything the view does not emit. There is no
  /// "unknown" fallback: mapping an unrecognized status to `confirmed` would
  /// be exactly the optimistic display the project's safety rule forbids.
  static PreferenceControlStatus parse(String? raw) {
    switch (raw) {
      case 'pending':
        return pending;
      case 'confirmed':
        return confirmed;
      case 'stale':
        return stale;
      case 'refused':
        return refused;
      case 'reported_only':
        return reportedOnly;
      default:
        throw FormatException(
          'preference_control_status returned an unknown status: $raw',
        );
    }
  }
}

/// One row of `preference_control_status`, as the view spells it.
///
/// Both raw sides are carried (desired and reported) plus the derived
/// [status], so a reader can show the value the car actually confirmed next
/// to the value the phone hoped for — the issue's "never the value my phone
/// hopes for" rule.
class PreferenceControlStatusRow {
  const PreferenceControlStatusRow({
    required this.vehicleId,
    required this.key,
    required this.status,
    this.accountId,
    this.desiredValue,
    this.proposedAtUtcMillis,
    this.reportedValue,
    this.reportedStatus,
    this.decidedAtUtcMillis,
    this.reportedAtUtcMillis,
  });

  /// Parses one row the view returned through the cloud client.
  ///
  /// Column names are the view's, snake_case as PostgREST spells them. A row
  /// with no `status` is a shape this side does not recognise and is rejected
  /// as malformed rather than defaulted to `pending` — the view always emits
  /// one of the five statuses, so anything else is a drift to surface, not to
  /// paper over.
  factory PreferenceControlStatusRow.fromViewMap(Map<String, Object?> map) {
    final vehicleId = map['vehicle_id'] as String?;
    final key = map['key'] as String?;
    if (vehicleId == null || vehicleId.isEmpty || key == null || key.isEmpty) {
      throw FormatException('preference_control_status row lacks key fields');
    }
    return PreferenceControlStatusRow(
      accountId: map['account_id'] as String?,
      vehicleId: vehicleId,
      key: key,
      desiredValue: map['desired_value'] as String?,
      proposedAtUtcMillis: (map['proposed_at_utc_millis'] as num?)?.toInt(),
      reportedValue: map['reported_value'] as String?,
      reportedStatus: map['reported_status'] as String?,
      decidedAtUtcMillis: (map['decided_at_utc_millis'] as num?)?.toInt(),
      reportedAtUtcMillis: (map['reported_at_utc_millis'] as num?)?.toInt(),
      status: PreferenceControlStatus.parse(map['status'] as String?),
    );
  }

  final String vehicleId;
  final String key;

  /// The phone's account, when the view carried one for this row.
  final String? accountId;

  /// The value the phone (or the car before it) proposed, or null.
  final String? desiredValue;
  final int? proposedAtUtcMillis;

  /// The value the car reported running, or null.
  final String? reportedValue;

  /// The raw report decision: `accepted` or `refused`. Kept beside [status] so
  /// a reader never relies on the derived label alone.
  final String? reportedStatus;
  final int? decidedAtUtcMillis;
  final int? reportedAtUtcMillis;

  /// The view-derived status. Settled by the database, never by this client.
  final PreferenceControlStatus status;
}

/// Pluggable network seam for Lane C.
///
/// The implementer attaches the phone's authenticated session; every call is
/// scoped server-side by that session and by Step 1b's RLS. Unit tests drive a
/// fake so nothing here ever touches the network in a test.
abstract interface class PreferenceControlCloud {
  /// Whether this build can reach the control plane at all.
  bool get isConfigured;

  /// The signed-in account id every desired row is stamped with.
  String get accountId;

  /// Writes one `preference_desired` row (upsert by
  /// `(account_id, vehicle_id, key)`), the phone's only control-plane write.
  ///
  /// The phone must own [vehicleId] (an active `vehicle_ownership` row);
  /// otherwise RLS refuses. [accountId] must equal `auth.uid()`; it is
  /// stamped here because the phone knows its own id while the table's other
  /// reader (the car) scopes by vehicle.
  Future<void> writeDesired({
    required String accountId,
    required String vehicleId,
    required String key,
    String? value,
    required int proposedAtUtcMillis,
    required String origin,
  });

  /// Reads the `preference_control_status` view, stripped by RLS to the
  /// phone's own account. Returns every derived row, ready to surface.
  Future<List<PreferenceControlStatusRow>> readStatus();
}

/// Thrown when the control plane cannot be reached or refuses the request.
///
/// [retryable] is true for provider/network faults a later run may recover
/// from; false for permanent faults (config, ownership, schema) that a retry
/// will repeat. Mirrors the car-side exception (Step 2) and the companion
/// uploader's failures.
class PreferenceControlCloudException implements Exception {
  const PreferenceControlCloudException(this.message, {this.retryable = true});

  final String message;
  final bool retryable;

  @override
  String toString() => 'PreferenceControlCloudException($message)';
}

/// Real implementation over the companion's [CloudSink] (Supabase).
///
/// The sink already knows the provider and guards it (`SupabaseCloudSink`), so
/// [CloudSink.fetch] against the view and [CloudSink.upsert] against the table
/// are the whole transport. The phone's signed-in session is the identity;
/// there is no `x-car-token` here, and there must not be one.
class SupabasePreferenceControlCloud implements PreferenceControlCloud {
  SupabasePreferenceControlCloud(this._sink, this._accountId);

  final CloudSink _sink;
  final String _accountId;

  static const desiredTable = 'preference_desired';
  static const statusView = 'preference_control_status';
  static const desiredConflictColumns = ['account_id', 'vehicle_id', 'key'];

  /// The origin this phone stamps on every desired row, spelled the same as
  /// the car-side surface's `ORIGIN_PHONE` (`kAnnotationOriginPhone`). The
  /// table requires an origin, and the phone is the understandable one.
  static const kDesiredOriginPhone = kAnnotationOriginPhone;

  /// The signed-in account id every desired row is stamped with. Must equal
  /// `auth.uid()` for the write's RLS to admit it.
  @override
  String get accountId => _accountId;

  /// The control-plane client for whoever is signed in, or null when nothing
  /// can reach the cloud.
  ///
  /// Null has four causes and they are one answer here, mirroring
  /// [SupabaseCloudSink.uploaderFor]: the cloud-sync gate is off, this build
  /// carries no project, nobody is signed in, or the session has no user.
  /// All four mean the phone keeps working without a control plane —
  /// proposing is simply not possible.
  static SupabasePreferenceControlCloud? controlFor() {
    // Cloud-sync gate — defaults ON. See `CloudSyncConfig`.
    if (!CloudSyncConfig.enabled) return null;
    if (!SupabaseConfig.isConfigured) return null;
    final client = Supabase.instance.client;
    final accountId = client.auth.currentUser?.id;
    if (accountId == null) return null;
    return SupabasePreferenceControlCloud(SupabaseCloudSink(client), accountId);
  }

  @override
  bool get isConfigured => _accountId.isNotEmpty;

  @override
  Future<void> writeDesired({
    required String accountId,
    required String vehicleId,
    required String key,
    String? value,
    required int proposedAtUtcMillis,
    required String origin,
  }) async {
    if (!isConfigured || accountId.isEmpty || vehicleId.isEmpty) {
      throw const PreferenceControlCloudException(
        'preference_desired write refused: no signed-in account or vehicle',
        retryable: false,
      );
    }
    await _sink.upsert(
      desiredTable,
      [
        {
          'account_id': accountId,
          'vehicle_id': vehicleId,
          'key': key,
          'value': value,
          'proposed_at_utc_millis': proposedAtUtcMillis,
          'origin': origin,
        },
      ],
      conflictColumns: desiredConflictColumns,
      // The same key/vehicle is re-proposed: the newer desire replaces the
      // older. One writer, so this is an upsert, not a merge.
      merge: true,
    );
  }

  @override
  Future<List<PreferenceControlStatusRow>> readStatus() async {
    final rows = await _sink.fetch(statusView);
    return [
      for (final row in rows) PreferenceControlStatusRow.fromViewMap(row),
    ];
  }
}
