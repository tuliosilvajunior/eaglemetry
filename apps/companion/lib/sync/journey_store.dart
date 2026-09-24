import 'package:telemetry_core/telemetry_core.dart';

import 'companion_archive.dart';

/// Writes and reads this phone's journeys.
///
/// The journey is an annotation written after the fact, so the phone is its
/// natural home: every edit here
/// lands locally through the last-writer-wins merge and is queued for the
/// car over the annotation outbox. A car older than this phone drops the
/// stream without failing the run, and the rows survive here.
///
/// Reading which sessions belong goes through the store's three questions —
/// [journeySessions] is a date filter the store already answers — never a
/// member list, because the window model keeps none.
class JourneyStore {
  JourneyStore(this._archive, {int Function()? nowMillis})
    : _nowMillis = nowMillis ?? (() => DateTime.now().millisecondsSinceEpoch);

  final CompanionArchive _archive;
  final int Function() _nowMillis;

  /// The live journeys, newest first. Tombstones stay out of the list.
  Future<List<Journey>> journeys() async {
    final journeys = [
      for (final row in await _archive.database.allJourneys())
        Journey.fromMap(row),
    ].whereType<Journey>().where((journey) => !journey.deleted).toList();
    journeys.sort(
      (a, b) => b.startedAtUtcMillis.compareTo(a.startedAtUtcMillis),
    );
    return journeys;
  }

  Future<Journey?> journey(String id) async {
    for (final row in await _archive.database.allJourneys()) {
      if (row['id'] == id) return Journey.fromMap(row);
    }
    return null;
  }

  /// Names a new journey. A journey is written after the fact; nothing here
  /// runs while the car is still recording the event.
  Future<Journey> create({
    required String name,
    required int startedAtUtcMillis,
    required int endedAtUtcMillis,
    String? note,
  }) async {
    final now = _nowMillis();
    final journey = Journey(
      id: 'phone-journey-$now',
      name: name.trim(),
      startedAtUtcMillis: startedAtUtcMillis,
      endedAtUtcMillis: endedAtUtcMillis,
      note: note?.trim(),
      createdAtUtcMillis: now,
      updatedAtUtcMillis: now,
      origin: kAnnotationOriginPhone,
    );
    await _write(journey);
    return journey;
  }

  Future<Journey> update(
    Journey existing, {
    String? name,
    int? startedAtUtcMillis,
    int? endedAtUtcMillis,
    String? note,
  }) async {
    final updated = Journey(
      id: existing.id,
      name: name ?? existing.name,
      startedAtUtcMillis: startedAtUtcMillis ?? existing.startedAtUtcMillis,
      endedAtUtcMillis: endedAtUtcMillis ?? existing.endedAtUtcMillis,
      note: note ?? existing.note,
      createdAtUtcMillis: existing.createdAtUtcMillis,
      updatedAtUtcMillis: _nowMillis(),
      origin: kAnnotationOriginPhone,
      deletedAtUtcMillis: existing.deletedAtUtcMillis,
    );
    if (updated.endedAtUtcMillis < updated.startedAtUtcMillis) {
      throw ArgumentError('a journey cannot end before it starts');
    }
    if (updated.name.trim().isEmpty) {
      throw ArgumentError('a journey requires a name');
    }
    await _write(updated);
    return updated;
  }

  /// The annotation delete: a tombstone, never a physical removal.
  Future<void> delete(String id) async {
    final existing = await journey(id);
    if (existing == null || existing.deleted) return;
    await _write(
      Journey(
        id: existing.id,
        name: existing.name,
        startedAtUtcMillis: existing.startedAtUtcMillis,
        endedAtUtcMillis: existing.endedAtUtcMillis,
        note: existing.note,
        createdAtUtcMillis: existing.createdAtUtcMillis,
        updatedAtUtcMillis: _nowMillis(),
        origin: kAnnotationOriginPhone,
        deletedAtUtcMillis: _nowMillis(),
      ),
    );
  }

  Future<void> _write(Journey journey) async {
    final row = journey.toMap();
    await _archive.upsertJourney(row);
    await _archive.database.enqueueAnnotationPush(
      SyncStreamType.journeys.name,
      row,
    );
  }
}
