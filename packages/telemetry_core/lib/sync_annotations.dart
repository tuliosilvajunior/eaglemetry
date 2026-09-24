import 'package:flutter/foundation.dart';

import 'dto/telemetry_dto.dart';
import 'efficiency_unit.dart';
import 'generated/telemetry_wire.g.dart';

/// The annotation side of the record: named places, charge costs, synced
/// preferences and preference proposals.
///
/// Annotations have many writers and are always editable. They cross the sync
/// channel in both directions with last-writer-wins per field group:
/// millis -> counter -> device_id lexicographic. The general rule is
/// device_id-only; the `auto_name*` group specifically uses car > phone >
/// cloud origin rank (per ADR 0009) via [annotationShouldReplaceWithOriginRank].
/// Measurement rows never do: that channel stays one directional with cursors
/// and acks.

/// Who wrote an annotation row last.
///
/// The strings are the wire vocabulary: they are stored on the car, on the
/// phone and later in Postgres, so a rename orphans rows the same way a
/// [SignalKey] rename would.
const String kAnnotationOriginCar = 'car';
const String kAnnotationOriginPhone = 'phone';
const String kAnnotationOriginCloud = 'cloud';

/// The standing order for a timestamp tie.
///
/// The car ranks highest because a person editing in the car and a stale
/// phone edit landing on the same millisecond have no clock to separate
/// them, and the car is where the vehicle and its settings live. The rank
/// must be the same on every replica, or two phones converge to different
/// winners.
int annotationOriginRank(String? origin) => switch (origin) {
  kAnnotationOriginCar => 2,
  kAnnotationOriginPhone => 1,
  _ => 0,
};

/// Whether an incoming annotation row replaces the one already held.
///
/// Last writer wins, field by field being the row. The HLC ordering after
/// H-1 is millis -> counter -> deviceId lexicographic (origin rank removed
/// for convergence). Still deterministic. The HLC machinery reuses the same
/// `HlcTimestamp` that guards the sync cursor.
bool annotationShouldReplace({
  required int existingHlcMillis,
  required int existingHlcCounter,
  required String existingHlcDeviceId,
  required String? existingOrigin,
  required int incomingHlcMillis,
  required int incomingHlcCounter,
  required String incomingHlcDeviceId,
  required String? incomingOrigin,
}) {
  if (incomingHlcMillis != existingHlcMillis) {
    return incomingHlcMillis > existingHlcMillis;
  }
  if (incomingHlcCounter != existingHlcCounter) {
    return incomingHlcCounter > existingHlcCounter;
  }
  if (incomingHlcDeviceId != existingHlcDeviceId) {
    return incomingHlcDeviceId.compareTo(existingHlcDeviceId) > 0;
  }
  return true;
}

/// ADR 0009: auto_name suggestion sync uses origin rank (car > phone > cloud).
/// Distinct from the general device_id-only rule. Used only for the
/// insight_places auto_name field group.
bool annotationShouldReplaceWithOriginRank({
  required int existingHlcMillis,
  required int existingHlcCounter,
  required String existingHlcDeviceId,
  required String? existingOrigin,
  required int incomingHlcMillis,
  required int incomingHlcCounter,
  required String incomingHlcDeviceId,
  required String? incomingOrigin,
}) {
  if (incomingHlcMillis != existingHlcMillis) {
    return incomingHlcMillis > existingHlcMillis;
  }
  if (incomingHlcCounter != existingHlcCounter) {
    return incomingHlcCounter > existingHlcCounter;
  }
  final incomingRank = annotationOriginRank(incomingOrigin);
  final existingRank = annotationOriginRank(existingOrigin);
  if (incomingRank != existingRank) {
    return incomingRank > existingRank;
  }
  if (incomingHlcDeviceId != existingHlcDeviceId) {
    return incomingHlcDeviceId.compareTo(existingHlcDeviceId) > 0;
  }
  return true;
}

bool annotationShouldReplaceWithOriginRankHlc({
  required HlcTimestamp existingHlc,
  required String? existingOrigin,
  required HlcTimestamp incomingHlc,
  required String? incomingOrigin,
}) => annotationShouldReplaceWithOriginRank(
  existingHlcMillis: existingHlc.millis,
  existingHlcCounter: existingHlc.counter,
  existingHlcDeviceId: existingHlc.deviceId,
  existingOrigin: existingOrigin,
  incomingHlcMillis: incomingHlc.millis,
  incomingHlcCounter: incomingHlc.counter,
  incomingHlcDeviceId: incomingHlc.deviceId,
  incomingOrigin: incomingOrigin,
);

/// Convenience overload that takes [HlcTimestamp] objects.
bool annotationShouldReplaceHlc({
  required HlcTimestamp existingHlc,
  required String? existingOrigin,
  required HlcTimestamp incomingHlc,
  required String? incomingOrigin,
}) => annotationShouldReplace(
  existingHlcMillis: existingHlc.millis,
  existingHlcCounter: existingHlc.counter,
  existingHlcDeviceId: existingHlc.deviceId,
  existingOrigin: existingOrigin,
  incomingHlcMillis: incomingHlc.millis,
  incomingHlcCounter: incomingHlc.counter,
  incomingHlcDeviceId: incomingHlc.deviceId,
  incomingOrigin: incomingOrigin,
);

@Deprecated('Use HLC overload; wall-clock comparison is retired in 6b')
bool annotationShouldReplaceWallClock({
  required int existingUpdatedAtUtcMillis,
  required String? existingOrigin,
  required int incomingUpdatedAtUtcMillis,
  required String? incomingOrigin,
}) {
  if (incomingUpdatedAtUtcMillis != existingUpdatedAtUtcMillis) {
    return incomingUpdatedAtUtcMillis > existingUpdatedAtUtcMillis;
  }
  return annotationOriginRank(incomingOrigin) >=
      annotationOriginRank(existingOrigin);
}

/// Wall-clock wrapper that derives an HLC (counter 0, deviceId = origin) for
/// fixture cases that lack an explicit stamp. Production code must pass the
/// real HLC via the primary overload.
bool annotationShouldReplaceWallDerived({
  required int existingUpdatedAtUtcMillis,
  required String? existingOrigin,
  required int incomingUpdatedAtUtcMillis,
  required String? incomingOrigin,
}) => annotationShouldReplace(
  existingHlcMillis: existingUpdatedAtUtcMillis,
  existingHlcCounter: 0,
  existingHlcDeviceId: existingOrigin ?? '',
  existingOrigin: existingOrigin,
  incomingHlcMillis: incomingUpdatedAtUtcMillis,
  incomingHlcCounter: 0,
  incomingHlcDeviceId: incomingOrigin ?? '',
  incomingOrigin: incomingOrigin,
);

/// A row of the `preference` table: [scope] and [key] together are its
/// identity. The value is a string whatever it names, so both sides can
/// carry it without knowing every key's type; the reader of a key parses.
@immutable
class PreferenceRow {
  const PreferenceRow({
    required this.scope,
    required this.key,
    required this.value,
    required this.updatedAtUtcMillis,
    required this.origin,
    this.deletedAtUtcMillis,
  });

  /// Parses a wire row. Returns null when the identity or the clock is
  /// missing: a row without either cannot be merged.
  static PreferenceRow? fromMap(Map<String, Object?>? map) {
    if (map == null) return null;
    final scope = map['scope'] as String?;
    final key = map['key'] as String?;
    final updatedAtUtcMillis = (map['updatedAtUtcMillis'] as num?)?.toInt();
    if (scope == null ||
        scope.isEmpty ||
        key == null ||
        key.isEmpty ||
        updatedAtUtcMillis == null) {
      return null;
    }
    return PreferenceRow(
      scope: scope,
      key: key,
      value: map['value'] as String?,
      updatedAtUtcMillis: updatedAtUtcMillis,
      origin: (map['origin'] as String?) ?? kAnnotationOriginCar,
      deletedAtUtcMillis: (map['deletedAtUtcMillis'] as num?)?.toInt(),
    );
  }

  final String scope;
  final String key;
  final String? value;
  final int updatedAtUtcMillis;
  final String origin;

  /// The tombstone moment, or null while the row is alive. Deletion is this
  /// stamp, never a physical removal: a stale replica resurrects a row that
  /// vanished without one.
  final int? deletedAtUtcMillis;

  bool get deleted => deletedAtUtcMillis != null;

  Map<String, Object?> toMap() => {
    'scope': scope,
    'key': key,
    'value': value,
    'updatedAtUtcMillis': updatedAtUtcMillis,
    'origin': origin,
    'deletedAtUtcMillis': deletedAtUtcMillis,
  };

  @override
  bool operator ==(Object other) =>
      other is PreferenceRow &&
      other.scope == scope &&
      other.key == key &&
      other.value == value &&
      other.updatedAtUtcMillis == updatedAtUtcMillis &&
      other.origin == origin &&
      other.deletedAtUtcMillis == deletedAtUtcMillis;

  @override
  int get hashCode =>
      Object.hash(scope, key, value, updatedAtUtcMillis, origin);
}

/// The life of a preference proposal, as both replicas hold it.
@immutable
class PreferenceProposal {
  const PreferenceProposal({
    required this.id,
    required this.key,
    required this.value,
    required this.status,
    required this.proposedAtUtcMillis,
    required this.updatedAtUtcMillis,
    required this.origin,
    this.decidedAtUtcMillis,
  });

  static PreferenceProposal? fromMap(Map<String, Object?>? map) {
    if (map == null) return null;
    final id = map['id'] as String?;
    final key = map['key'] as String?;
    final rawStatus = map['status'] as String?;
    final proposedAtUtcMillis = (map['proposedAtUtcMillis'] as num?)?.toInt();
    final updatedAtUtcMillis = (map['updatedAtUtcMillis'] as num?)?.toInt();
    if (id == null ||
        id.isEmpty ||
        key == null ||
        key.isEmpty ||
        proposedAtUtcMillis == null ||
        updatedAtUtcMillis == null) {
      return null;
    }
    return PreferenceProposal(
      id: id,
      key: key,
      value: map['value'] as String?,
      status: PreferenceProposalStatus.values.firstWhere(
        (candidate) => candidate.name == rawStatus,
        orElse: () => PreferenceProposalStatus.pending,
      ),
      proposedAtUtcMillis: proposedAtUtcMillis,
      updatedAtUtcMillis: updatedAtUtcMillis,
      origin: (map['origin'] as String?) ?? kAnnotationOriginPhone,
      decidedAtUtcMillis: (map['decidedAtUtcMillis'] as num?)?.toInt(),
    );
  }

  final String id;

  /// The preference key being proposed, from [kControlPreferenceKeys].
  final String key;

  /// The value the proposer wants, as a string.
  final String? value;
  final PreferenceProposalStatus status;
  final int proposedAtUtcMillis;
  final int updatedAtUtcMillis;

  /// Who proposed it. Decisions are not the proposer's: only the car
  /// accepts or refuses, because only the car runs the write path.
  final String origin;
  final int? decidedAtUtcMillis;

  Map<String, Object?> toMap() => {
    'id': id,
    'key': key,
    'value': value,
    'status': status.name,
    'proposedAtUtcMillis': proposedAtUtcMillis,
    'updatedAtUtcMillis': updatedAtUtcMillis,
    'origin': origin,
    'decidedAtUtcMillis': decidedAtUtcMillis,
  };

  @override
  bool operator ==(Object other) =>
      other is PreferenceProposal &&
      other.id == id &&
      other.key == key &&
      other.value == value &&
      other.status == status &&
      other.proposedAtUtcMillis == proposedAtUtcMillis &&
      other.updatedAtUtcMillis == updatedAtUtcMillis &&
      other.origin == origin &&
      other.decidedAtUtcMillis == decidedAtUtcMillis;

  @override
  int get hashCode => Object.hash(id, key, value, status, updatedAtUtcMillis);
}

enum PreferenceProposalStatus { pending, accepted, refused }

/// Preference scopes, as the plan's table states them.
const String kPreferenceScopeAccount = 'account';
const String kPreferenceScopeVehicle = 'vehicle';
const String kPreferenceScopeDevice = 'device';

/// Keys both sides write, carried by the annotation channel — every one is a
/// lane B (annotation) key under [kPreferenceLane].
///
/// A key that names what the car **records** is never here: the phone only
/// reaches such a key by proposing it, and only the car's acceptance turns a
/// proposal into a write.
const Map<String, String> kSyncedPreferenceKeys = {
  'theme_id': kPreferenceScopeAccount,
  'theme_mode': kPreferenceScopeAccount,
  'efficiency_unit': kPreferenceScopeAccount,
  'charge_cost_currency': kPreferenceScopeVehicle,
  'places.nominatimOptIn': kPreferenceScopeDevice,
};

/// Issue #227, Lane C: the control/annotation boundary.
///
/// Membership is mechanical:
/// "if it changes what the car does or records, it is control;
///  if it only changes what a screen shows, it is annotation."
///
/// [kPreferenceLane] classifies every preference key this product knows, and
/// is the single source of truth for that classification on the Dart side
/// (the head unit and the companion both read it). The same catalogue lives
/// in Kotlin as `PreferenceRepository.PREFERENCE_LANE`; the shared fixture
/// `testdata/preference_lanes.json` pins the two against each other, so a
/// register added on one side without the other fails a suite.
///
/// Adding a control key is a one-line addition to [kPreferenceLane]; every
/// code path that used to name the two control keys reads
/// [kControlPreferenceKeys] instead. A car-local setting with no preference
/// row (e.g. `TelemetrySettings`' `auto_start_on_boot`, `gps_enabled`) is
/// not a lane member and is not classified — if one ever gains a phone write
/// path, this rule makes it control.
enum PreferenceLane {
  /// Lane B — many writers, merges in the database, changes only what a
  /// screen shows.
  annotation,

  /// Lane C — the phone proposes, the car alone writes. Changes what the car
  /// does or records; this lane must never auto-merge.
  control,
}

/// The control/annotation classification of every known preference key.
///
/// An annotation key belongs to the lane B channel; a control key belongs to
/// the proposal channel. Add new keys here (and to the Kotlin mirror and the
/// shared fixture) rather than at a call site.
const Map<String, PreferenceLane> kPreferenceLane = {
  // Lane B — keys that only change what a screen shows.
  'theme_id': PreferenceLane.annotation,
  'theme_mode': PreferenceLane.annotation,
  'efficiency_unit': PreferenceLane.annotation,
  'charge_cost_currency': PreferenceLane.annotation,
  'places.nominatimOptIn': PreferenceLane.annotation,
  'reduce_motion': PreferenceLane.annotation,
  // Lane C — keys that change what the car records.
  'pack_capacity_wh': PreferenceLane.control,
  'default_charge_cost_per_kwh': PreferenceLane.control,
};

/// The control keys — what the phone may propose and never write.
///
/// Derived from [kPreferenceLane], so a key added there as control is
/// automatically a proposal key here; there is no second list to keep in
/// step. Acceptance runs the normal car write path — for `pack_capacity_wh`
/// that refolds every battery cycle from zero, exactly once, when a person
/// confirmed it.
Set<String> get kControlPreferenceKeys => {
  for (final entry in kPreferenceLane.entries)
    if (entry.value == PreferenceLane.control) entry.key,
};

/// The theme catalogue ids the annotation channel carries.
///
/// This is a transcription of `AppThemeId` in `packages/capy_ui`. A side
/// that does not know one of them renders the default and keeps the stored
/// value; it never rejects the row. The parity test keeps this set and the
/// catalogue equal, because a drift here is exactly the 2026-08-15
/// range-estimate defect: an unknown name dropping a value while the tests
/// pass by spelling the name themselves.
const Set<String> kAnnotationAcceptedThemeIds = {
  'light',
  'dark',
  'midnight',
  'sepia',
  'nordic',
  'daylight',
  'tokyoNeon',
  'sunsetDrive',
  'bubblegum',
};

/// The efficiency units the annotation channel carries, transcribed from
/// [EfficiencyUnit]. Same rule as the theme ids.
final Set<String> kAnnotationAcceptedEfficiencyUnits = {
  for (final unit in EfficiencyUnit.values) unit.name,
};

/// That an annotation changed, not what it now is.
///
/// The same shape as [SessionChange]: a reader re-reads the surface it
/// shows. Annotations change rarer than sessions and never per frame, so a
/// push from the phone is worth one event.
class AnnotationChange {
  const AnnotationChange({
    required this.revision,
    required this.places,
    required this.preferences,
    required this.sessionCosts,
    required this.proposals,
    required this.journeys,
  });

  factory AnnotationChange.fromWire(AnnotationChangeWire wire) =>
      AnnotationChange(
        revision: wire.revision,
        places: wire.places,
        preferences: wire.preferences,
        sessionCosts: wire.sessionCosts,
        proposals: wire.proposals,
        journeys: wire.journeys,
      );

  /// Rises on every change, so a reader that missed an event can tell.
  final int revision;

  /// A place row was written or deleted.
  final bool places;

  /// A preference row was written or deleted.
  final bool preferences;

  /// A charge cost row was written.
  final bool sessionCosts;

  /// A preference proposal was created or decided.
  final bool proposals;

  /// A journey row was written or deleted.
  final bool journeys;

  @override
  bool operator ==(Object other) =>
      other is AnnotationChange &&
      other.revision == revision &&
      other.places == places &&
      other.preferences == preferences &&
      other.sessionCosts == sessionCosts &&
      other.proposals == proposals &&
      other.journeys == journeys;

  @override
  int get hashCode =>
      Object.hash(revision, places, preferences, sessionCosts, proposals);

  @override
  String toString() =>
      'AnnotationChange(revision: $revision, places: $places, '
      'preferences: $preferences, sessionCosts: $sessionCosts, '
      'proposals: $proposals, journeys: $journeys)';
}
