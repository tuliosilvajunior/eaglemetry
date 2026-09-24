/// A journey: one named real-world event, a holiday, a weekend away.
///
/// The word `trip` is taken — one drive. The journey is the group, and its
/// membership model is the **time window**: this type holds no member list, so which sessions belong is
/// computed when the group is read from what the store already answers.
///
/// A journey is an annotation: a person writes it after the fact, it stays
/// editable forever, deletion is a tombstone stamp, and it crosses the
/// annotation channel with last-writer-wins (`annotationShouldReplace`).
library;

import 'package:flutter/foundation.dart';

import 'measurement.dart';
import 'session_reading.dart';
import 'sync_annotations.dart';
import 'telemetry_store.dart';

/// One journey row, as every replica of the annotation channel holds it.
@immutable
class Journey {
  const Journey({
    required this.id,
    required this.name,
    required this.startedAtUtcMillis,
    required this.endedAtUtcMillis,
    this.note,
    this.createdAtUtcMillis,
    required this.updatedAtUtcMillis,
    this.origin = kAnnotationOriginPhone,
    this.deletedAtUtcMillis,
  });

  /// Parses a wire row. Returns null when the identity, the name or the
  /// window is missing or inverted: a row without them cannot be merged and
  /// does not describe a span of time.
  static Journey? fromMap(Map<String, Object?>? map) {
    if (map == null) return null;
    final id = map['id'] as String?;
    final name = map['name'] as String?;
    final startedAtUtcMillis = (map['startedAtUtcMillis'] as num?)?.toInt();
    final endedAtUtcMillis = (map['endedAtUtcMillis'] as num?)?.toInt();
    final updatedAtUtcMillis = (map['updatedAtUtcMillis'] as num?)?.toInt();
    if (id == null ||
        id.isEmpty ||
        name == null ||
        name.trim().isEmpty ||
        startedAtUtcMillis == null ||
        endedAtUtcMillis == null ||
        endedAtUtcMillis < startedAtUtcMillis ||
        updatedAtUtcMillis == null) {
      return null;
    }
    return Journey(
      id: id,
      name: name.trim(),
      startedAtUtcMillis: startedAtUtcMillis,
      endedAtUtcMillis: endedAtUtcMillis,
      note: _cleanNote(map['note'] as String?),
      createdAtUtcMillis: (map['createdAtUtcMillis'] as num?)?.toInt(),
      updatedAtUtcMillis: updatedAtUtcMillis,
      origin: (map['origin'] as String?) ?? kAnnotationOriginPhone,
      deletedAtUtcMillis: (map['deletedAtUtcMillis'] as num?)?.toInt(),
    );
  }

  final String id;
  final String name;
  final int startedAtUtcMillis;
  final int endedAtUtcMillis;

  /// The person's remark, or null. An empty note is stored as no note.
  final String? note;
  final int? createdAtUtcMillis;
  final int updatedAtUtcMillis;
  final String origin;

  /// The tombstone moment, or null while the journey is alive. Deletion is
  /// this stamp, never a physical removal.
  final int? deletedAtUtcMillis;

  bool get deleted => deletedAtUtcMillis != null;

  /// The one edit a merge or an edit flow makes: same identity, new fields.
  /// An updated row always carries a fresh [updatedAtUtcMillis] from its
  /// writer; this copy does not stamp one for you.
  Journey copyWith({
    String? name,
    int? startedAtUtcMillis,
    int? endedAtUtcMillis,
    String? note,
    int? updatedAtUtcMillis,
    String? origin,
    int? deletedAtUtcMillis,
  }) => Journey(
    id: id,
    name: name ?? this.name,
    startedAtUtcMillis: startedAtUtcMillis ?? this.startedAtUtcMillis,
    endedAtUtcMillis: endedAtUtcMillis ?? this.endedAtUtcMillis,
    note: note ?? this.note,
    createdAtUtcMillis: createdAtUtcMillis,
    updatedAtUtcMillis: updatedAtUtcMillis ?? this.updatedAtUtcMillis,
    origin: origin ?? this.origin,
    deletedAtUtcMillis: deletedAtUtcMillis ?? this.deletedAtUtcMillis,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'startedAtUtcMillis': startedAtUtcMillis,
    'endedAtUtcMillis': endedAtUtcMillis,
    'note': note,
    'createdAtUtcMillis': createdAtUtcMillis ?? updatedAtUtcMillis,
    'updatedAtUtcMillis': updatedAtUtcMillis,
    'origin': origin,
    'deletedAtUtcMillis': deletedAtUtcMillis,
  };

  @override
  bool operator ==(Object other) =>
      other is Journey &&
      other.id == id &&
      other.name == name &&
      other.startedAtUtcMillis == startedAtUtcMillis &&
      other.endedAtUtcMillis == endedAtUtcMillis &&
      other.note == note &&
      other.updatedAtUtcMillis == updatedAtUtcMillis &&
      other.origin == origin &&
      other.deletedAtUtcMillis == deletedAtUtcMillis;
  // createdAtUtcMillis rides the row for the wire and for the merge's
  // "keep the older creation moment" rule; it does not name the journey.
  // toMap() writes a fallback when this field is null, so comparing it here
  // would make a row unequal to its own roundtrip.

  @override
  int get hashCode => Object.hash(
    id,
    name,
    startedAtUtcMillis,
    endedAtUtcMillis,
    updatedAtUtcMillis,
    deletedAtUtcMillis,
  );
}

String? _cleanNote(String? raw) {
  final trimmed = raw?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed;
}

/// Whether a session that started at [sessionStartedAtUtcMillis] belongs to
/// [journey].
///
/// The rule is the one the store's own date filter answers — a session
/// belongs when it **started** inside the window. Keeping the reduction and
/// the store filter the same predicate is what makes the two unable to
/// disagree: there is no second membership test a screen could skip.
bool journeyCoversSession(Journey journey, int sessionStartedAtUtcMillis) =>
    !journey.deleted &&
    sessionStartedAtUtcMillis >= journey.startedAtUtcMillis &&
    sessionStartedAtUtcMillis <= journey.endedAtUtcMillis;

/// Every session of [journey], through the store's three questions.
///
/// There is no fourth question: the window goes into [SessionFilter], the
/// pages are walked until the car says the answer ended, and nothing else is
/// asked. A late-syncing session joins by itself because nothing recorded
/// which sessions belong.
Future<List<SessionRecord>> journeySessions(
  TelemetryStore store,
  Journey journey, {
  int pageSize = 50,
}) async {
  final members = <SessionRecord>[];
  var offset = 0;
  var hasMore = true;
  while (hasMore) {
    final page = await store.listSessions(
      filter: SessionFilter(
        fromUtcMillis: journey.startedAtUtcMillis,
        toUtcMillis: journey.endedAtUtcMillis,
      ),
      page: PageRequest(limit: pageSize, offset: offset),
    );
    members.addAll(
      page.sessions.where(
        (s) => s.kind == SessionKind.trip || s.kind == SessionKind.charge,
      ),
    );
    hasMore = page.hasMore && page.sessions.isNotEmpty;
    offset += page.sessions.length;
  }
  return members;
}

/// What a journey reads as, folded from its member sessions.
///
/// Dart reduces here — counts, adds and divides. Dart never integrates
/// (Rule 2.1): every number below is the car's own figure carried forward.
class JourneyReading {
  const JourneyReading({
    required this.tripCount,
    required this.chargeCount,
    required this.distanceKm,
    required this.netKwh,
    required this.deliveredKwh,
    required this.chargesCost,
  });

  final int tripCount;
  final int chargeCount;

  /// Odometer-first distance over every member trip, km.
  final Measurement distanceKm;

  /// Net pack energy over every member trip, kWh.
  final Measurement netKwh;

  /// Energy delivered over every member charge, kWh.
  final Measurement deliveredKwh;

  /// What the member charges cost, in their own currency.
  ///
  /// Null when any priced member is missing a computable cost or when no
  /// member was priced: a journey whose legs were not all priced is not a
  /// journey with a free leg, and printing a partial total would hide that.
  final double? chargesCost;

  bool get isEmpty => tripCount == 0 && chargeCount == 0;
}

/// Folds [sessions] into a [JourneyReading].
///
/// A total computed from anything unusable is unusable: when one member
/// cannot answer a quantity, the whole quantity prints `--` rather than a
/// partial sum that hides a missing leg.
JourneyReading foldJourneySessions(Iterable<SessionRecord> sessions) {
  var tripCount = 0;
  var chargeCount = 0;
  final distances = <Measurement>[];
  final nets = <Measurement>[];
  final delivered = <Measurement>[];
  double? costTotal;
  var costBroken = false;
  var costSeen = false;

  for (final session in sessions) {
    switch (session.kind) {
      case SessionKind.continuous:
        break;
      case SessionKind.trip:
        tripCount += 1;
        distances.add(sessionReadingDistance(session));
        nets.add(sessionReadingNetKwh(session));
      case SessionKind.charge:
        chargeCount += 1;
        delivered.add(sessionReadingDeliveredKwh(session));
        final cost = sessionReadingCost(session);
        if (cost == null) {
          costBroken = true;
        } else {
          costSeen = true;
          costTotal = (costTotal ?? 0) + cost;
        }
      case SessionKind.parked:
        break;
    }
  }

  return JourneyReading(
    tripCount: tripCount,
    chargeCount: chargeCount,
    distanceKm: _sum(distances, unit: 'km'),
    netKwh: _sum(nets, unit: 'kWh'),
    deliveredKwh: _sum(delivered, unit: 'kWh'),
    chargesCost: costSeen && !costBroken ? costTotal : null,
  );
}

Measurement _sum(List<Measurement> parts, {required String unit}) {
  if (parts.isEmpty) return Measurement.measured(0, unit: unit);
  var total = 0.0;
  for (final part in parts) {
    final value = part.displayValue;
    if (value == null) {
      return Measurement.unreported(
        unit: unit,
        note: 'one member did not report this',
      );
    }
    total += value;
  }
  final estimated = parts.any((part) => part.needsEstimateBadge);
  return estimated
      ? Measurement.estimated(
          total,
          unit: unit,
          note: 'a member is an estimate',
        )
      : Measurement.measured(total, unit: unit);
}
