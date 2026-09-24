import 'package:telemetry_core/telemetry_core.dart';

import 'companion_database.dart';

/// Local copy of what this phone has pulled from the car.
///
/// Holds the Annotation channel (mutable user metadata with Last-Writer-Wins
/// conflict resolution, per ADR-0003), measurement upsert revision tracking,
/// and sync stream cursors. Read operations go directly to [CompanionDatabase]
/// or via [TelemetryStore] (ADR-0005).
class CompanionArchive {
  CompanionArchive(this._db, {String Function()? deviceIdProvider})
    : _deviceIdProvider = deviceIdProvider ?? (() => kAnnotationOriginPhone);

  final CompanionDatabase _db;
  CompanionDatabase get database => _db;
  final String Function() _deviceIdProvider;

  /// In-memory HLC for annotation writes. Local writes tick (send), remote
  /// merges (receive). Mirrors the car's `AnnotationHlcClock`.
  HlcTimestamp? _annotationHlc;

  /// For tests.
  HlcTimestamp? get annotationHlcForTest => _annotationHlc;
  void resetAnnotationHlcForTest() => _annotationHlc = null;

  HlcTimestamp _tickAnnotationHlc({required int physicalWallMillis}) {
    final now = physicalWallMillis;
    final current = _annotationHlc;
    final next =
        current?.send(physicalWallMillis: now) ??
        HlcTimestamp(millis: now, counter: 0, deviceId: _deviceIdProvider());
    _annotationHlc = next;
    return next;
  }

  void _mergeAnnotationHlc(HlcTimestamp remote) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final current = _annotationHlc;
    try {
      final next =
          current?.receive(remote: remote, physicalWallMillis: now) ??
          (() {
            final highest = now > remote.millis ? now : remote.millis;
            final nextCounter = highest == remote.millis
                ? remote.counter + 1
                : 0;
            return HlcTimestamp(
              millis: highest,
              counter: nextCounter,
              deviceId: _deviceIdProvider(),
            );
          })();
      _annotationHlc = next;
    } on HlcDriftException {
      final highest = current != null && current.millis > now
          ? current.millis
          : now;
      final nextCounter = (current?.counter ?? -1) + 1;
      _annotationHlc = HlcTimestamp(
        millis: highest,
        counter: nextCounter.clamp(0, 1 << 30),
        deviceId: _deviceIdProvider(),
      );
    }
  }

  HlcTimestamp? _extractHlc(Map<String, Object?> row) {
    final millis =
        (row['hlcMillis'] as num?)?.toInt() ??
        (row['hlc'] is Map
            ? ((row['hlc'] as Map)['millis'] as num?)?.toInt()
            : null);
    final counter =
        (row['hlcCounter'] as num?)?.toInt() ??
        (row['hlc'] is Map
            ? ((row['hlc'] as Map)['counter'] as num?)?.toInt()
            : null) ??
        0;
    final deviceId =
        (row['hlcDeviceId'] as String?) ??
        (row['hlc'] is Map
            ? ((row['hlc'] as Map)['deviceId'] as String?)
            : null);
    if (millis == null || deviceId == null || deviceId.isEmpty) return null;
    if (millis < 0 || counter < 0) return null;
    return HlcTimestamp(millis: millis, counter: counter, deviceId: deviceId);
  }

  Map<String, Object?> _withHlc(Map<String, Object?> row, HlcTimestamp hlc) => {
    ...row,
    'hlcMillis': hlc.millis,
    'hlcCounter': hlc.counter,
    'hlcDeviceId': hlc.deviceId,
    'hlc': hlc.toMap(),
  };

  /// Cursors are small, bounded by the number of streams.
  final Map<SyncStreamType, String> _confirmed = {};

  int _revision = 0;

  int get revision => _revision;

  Future<void> load() async {
    _confirmed
      ..clear()
      ..addAll(await _db.cursors());
    _revision = await _db.revision();
  }

  /// Deletes everything this phone pulled, and every cursor with it.
  Future<void> wipe() async {
    await _db.wipe();
    _confirmed.clear();
    _bump();
    await _db.setRevision(_revision);
  }

  /// Kept for the callers that write in batches. Every write already landed;
  /// this only records the revision the readers watch.
  Future<void> persist() => _db.setRevision(_revision);

  // --- Measurements --------------------------------------------------------

  Future<void> upsertSession(Map<String, Object?> row) async {
    await _db.upsertSession(row);
    _bump();
  }

  Future<void> upsertTrip(Map<String, Object?> row) async {
    await _db.upsertTrip(row);
    _bump();
  }

  Future<void> upsertCharge(Map<String, Object?> row) async {
    await _db.upsertCharge(row);
    _bump();
  }

  Future<void> upsertCycle(Map<String, Object?> row) async {
    await _db.upsertCycle(row);
    _bump();
  }

  Future<void> upsertInterval(Map<String, Object?> row) async {
    await _db.upsertInterval(row);
    _bump();
  }

  Future<void> upsertEvent(Map<String, Object?> row) async {
    await _db.upsertEvent(row);
    _bump();
  }

  /// Writes one route. Keyed by the session, so a route the car rewrote
  /// replaces the one already held instead of adding a second.
  Future<void> upsertTrack(Map<String, Object?> row) async {
    await _db.upsertTrack(row);
    _bump();
  }

  Future<void> upsertSessionFromCloud(Map<String, Object?> row) async {
    await _db.upsertSessionFromCloud(row);
    _bump();
  }

  Future<void> upsertCycleFromCloud(Map<String, Object?> row) async {
    await _db.upsertCycleFromCloud(row);
    _bump();
  }

  Future<void> upsertIntervalFromCloud(Map<String, Object?> row) async {
    await _db.upsertIntervalFromCloud(row);
    _bump();
  }

  Future<void> upsertEventFromCloud(Map<String, Object?> row) async {
    await _db.upsertEventFromCloud(row);
    _bump();
  }

  Future<void> upsertTrackFromCloud(Map<String, Object?> row) async {
    await _db.upsertTrackFromCloud(row);
    _bump();
  }

  // --- Annotations ---------------------------------------------------------
  //
  // Places, preferences, session costs, proposals and journeys are written by
  // both sides, so a row that arrives from the pull is merged against the row
  // already held with last-writer-wins and the origin as the tie-break, and
  // a local edit is merged the same way before it is queued for the push.

  Future<void> upsertPlace(Map<String, Object?> row) async {
    final id = row['id'] as String?;
    if (id == null || id.isEmpty) return;
    final incoming = _annotationStamp(row) ?? 0;
    // HLC: tick for local writes, merge for remote.
    final existingHlc = _extractHlc(row);
    late Map<String, Object?> storedRow;
    if (existingHlc != null) {
      _mergeAnnotationHlc(existingHlc);
      storedRow = _withHlc(row, existingHlc);
    } else {
      final hlc = _tickAnnotationHlc(physicalWallMillis: incoming);
      storedRow = _withHlc(row, hlc);
      // Mutate original for callers that enqueue after upsert.
      row['hlcMillis'] = hlc.millis;
      row['hlcCounter'] = hlc.counter;
      row['hlcDeviceId'] = hlc.deviceId;
      row['hlc'] = hlc.toMap();
    }
    final existing = (await _db.allPlaces())
        .where((r) => r['id'] == id)
        .firstOrNull;
    if (existing != null) {
      final existingHlcForCompare =
          _extractHlc(existing) ??
          HlcTimestamp(
            millis: _annotationStamp(existing) ?? 0,
            counter: 0,
            deviceId: (existing['origin'] as String?) ?? kAnnotationOriginCar,
          );
      final incomingHlcForCompare =
          _extractHlc(storedRow) ??
          HlcTimestamp(
            millis: incoming,
            counter: 0,
            deviceId: (row['origin'] as String?) ?? kAnnotationOriginCar,
          );
      if (!annotationShouldReplaceHlc(
        existingHlc: existingHlcForCompare,
        existingOrigin: existing['origin'] as String?,
        incomingHlc: incomingHlcForCompare,
        incomingOrigin: (row['origin'] as String?) ?? kAnnotationOriginCar,
      )) {
        return;
      }
    }
    await _db.upsertPlace(
      id,
      incoming,
      (row['origin'] as String?) ?? kAnnotationOriginCar,
      storedRow,
    );
    _bump();
  }

  Future<void> upsertPreference(Map<String, Object?> row) async {
    final scope = row['scope'] as String?;
    final key = row['key'] as String?;
    if (scope == null || key == null || scope.isEmpty || key.isEmpty) return;
    final incoming = _annotationStamp(row) ?? 0;
    final existingHlc = _extractHlc(row);
    late Map<String, Object?> storedRow;
    if (existingHlc != null) {
      _mergeAnnotationHlc(existingHlc);
      storedRow = _withHlc(row, existingHlc);
    } else {
      final hlc = _tickAnnotationHlc(physicalWallMillis: incoming);
      storedRow = _withHlc(row, hlc);
      row['hlcMillis'] = hlc.millis;
      row['hlcCounter'] = hlc.counter;
      row['hlcDeviceId'] = hlc.deviceId;
      row['hlc'] = hlc.toMap();
    }
    final existing = await _db.allPreferences();
    final current = existing
        .where((r) => r['scope'] == scope && r['key'] == key)
        .firstOrNull;
    if (current != null) {
      final existingHlcForCompare =
          _extractHlc(current) ??
          HlcTimestamp(
            millis: _annotationStamp(current) ?? 0,
            counter: 0,
            deviceId: (current['origin'] as String?) ?? kAnnotationOriginCar,
          );
      final incomingHlcForCompare =
          _extractHlc(storedRow) ??
          HlcTimestamp(
            millis: incoming,
            counter: 0,
            deviceId: (row['origin'] as String?) ?? kAnnotationOriginCar,
          );
      if (!annotationShouldReplaceHlc(
        existingHlc: existingHlcForCompare,
        existingOrigin: current['origin'] as String?,
        incomingHlc: incomingHlcForCompare,
        incomingOrigin: (row['origin'] as String?) ?? kAnnotationOriginCar,
      )) {
        return;
      }
    }
    await _db.upsertPreference(
      scope,
      key,
      incoming,
      (row['origin'] as String?) ?? kAnnotationOriginCar,
      storedRow,
    );
    _bump();
  }

  Future<void> upsertSessionCost(Map<String, Object?> row) async {
    final sessionId = row['sessionId'] as String?;
    if (sessionId == null || sessionId.isEmpty) return;
    final incoming = _annotationStamp(row) ?? 0;
    final existingHlc = _extractHlc(row);
    late Map<String, Object?> storedRow;
    if (existingHlc != null) {
      _mergeAnnotationHlc(existingHlc);
      storedRow = _withHlc(row, existingHlc);
    } else {
      final hlc = _tickAnnotationHlc(physicalWallMillis: incoming);
      storedRow = _withHlc(row, hlc);
      row['hlcMillis'] = hlc.millis;
      row['hlcCounter'] = hlc.counter;
      row['hlcDeviceId'] = hlc.deviceId;
      row['hlc'] = hlc.toMap();
    }
    final existing = await _db.sessionCost(sessionId);
    if (existing != null) {
      final existingHlcForCompare =
          _extractHlc(existing) ??
          HlcTimestamp(
            millis: _annotationStamp(existing) ?? 0,
            counter: 0,
            deviceId: (existing['origin'] as String?) ?? kAnnotationOriginCar,
          );
      final incomingHlcForCompare =
          _extractHlc(storedRow) ??
          HlcTimestamp(
            millis: incoming,
            counter: 0,
            deviceId: (row['origin'] as String?) ?? kAnnotationOriginCar,
          );
      if (!annotationShouldReplaceHlc(
        existingHlc: existingHlcForCompare,
        existingOrigin: existing['origin'] as String?,
        incomingHlc: incomingHlcForCompare,
        incomingOrigin: (row['origin'] as String?) ?? kAnnotationOriginCar,
      )) {
        return;
      }
    }
    await _db.upsertSessionCost(
      sessionId,
      incoming,
      (row['origin'] as String?) ?? kAnnotationOriginCar,
      storedRow,
    );
    _bump();
  }

  Future<void> upsertPreferenceProposal(Map<String, Object?> row) async {
    final id = row['id'] as String?;
    if (id == null || id.isEmpty) return;
    final incoming = _annotationStamp(row) ?? 0;
    final existingHlc = _extractHlc(row);
    late Map<String, Object?> storedRow;
    if (existingHlc != null) {
      _mergeAnnotationHlc(existingHlc);
      storedRow = _withHlc(row, existingHlc);
    } else {
      final hlc = _tickAnnotationHlc(physicalWallMillis: incoming);
      storedRow = _withHlc(row, hlc);
      row['hlcMillis'] = hlc.millis;
      row['hlcCounter'] = hlc.counter;
      row['hlcDeviceId'] = hlc.deviceId;
      row['hlc'] = hlc.toMap();
    }
    final existing = await _db.allPreferenceProposals();
    final current = existing.where((r) => r['id'] == id).firstOrNull;
    if (current != null) {
      final existingHlcForCompare =
          _extractHlc(current) ??
          HlcTimestamp(
            millis: _annotationStamp(current) ?? 0,
            counter: 0,
            deviceId: (current['origin'] as String?) ?? kAnnotationOriginPhone,
          );
      final incomingHlcForCompare =
          _extractHlc(storedRow) ??
          HlcTimestamp(
            millis: incoming,
            counter: 0,
            deviceId: (row['origin'] as String?) ?? kAnnotationOriginPhone,
          );
      if (!annotationShouldReplaceHlc(
        existingHlc: existingHlcForCompare,
        existingOrigin: current['origin'] as String?,
        incomingHlc: incomingHlcForCompare,
        incomingOrigin: (row['origin'] as String?) ?? kAnnotationOriginPhone,
      )) {
        return;
      }
    }
    await _db.upsertPreferenceProposal(
      id,
      incoming,
      (row['origin'] as String?) ?? kAnnotationOriginPhone,
      storedRow,
    );
    _bump();
  }

  /// Writes one journey row through the annotation merge, whatever carried
  /// it here — a pull page from the car or this phone's own edit.
  Future<bool> upsertJourney(Map<String, Object?> row) async {
    if (Journey.fromMap(row) == null) return false;
    final id = row['id'] as String;
    final incoming = _annotationStamp(row) ?? 0;
    final existingHlc = _extractHlc(row);
    late Map<String, Object?> storedRow;
    if (existingHlc != null) {
      _mergeAnnotationHlc(existingHlc);
      storedRow = _withHlc(row, existingHlc);
    } else {
      final hlc = _tickAnnotationHlc(physicalWallMillis: incoming);
      storedRow = _withHlc(row, hlc);
      row['hlcMillis'] = hlc.millis;
      row['hlcCounter'] = hlc.counter;
      row['hlcDeviceId'] = hlc.deviceId;
      row['hlc'] = hlc.toMap();
    }
    final existing = await _db.allJourneys();
    final current = existing.where((r) => r['id'] == id).firstOrNull;
    if (current != null) {
      final existingHlcForCompare =
          _extractHlc(current) ??
          HlcTimestamp(
            millis: _annotationStamp(current) ?? 0,
            counter: 0,
            deviceId: (current['origin'] as String?) ?? kAnnotationOriginCar,
          );
      final incomingHlcForCompare =
          _extractHlc(storedRow) ??
          HlcTimestamp(
            millis: incoming,
            counter: 0,
            deviceId: (row['origin'] as String?) ?? kAnnotationOriginCar,
          );
      if (!annotationShouldReplaceHlc(
        existingHlc: existingHlcForCompare,
        existingOrigin: current['origin'] as String?,
        incomingHlc: incomingHlcForCompare,
        incomingOrigin: (row['origin'] as String?) ?? kAnnotationOriginCar,
      )) {
        return false;
      }
    }
    await _db.upsertJourney(
      id,
      incoming,
      (row['origin'] as String?) ?? kAnnotationOriginCar,
      storedRow,
    );
    _bump();
    return true;
  }

  static int? _annotationStamp(Map<String, Object?> row) =>
      (row['updatedAtUtcMillis'] as num?)?.toInt();

  // --- Cursors -------------------------------------------------------------

  String? confirmedId(SyncStreamType stream) => _confirmed[stream];

  Future<void> confirm(SyncStreamType stream, String recordId) async {
    _confirmed[stream] = recordId;
    await _db.setCursor(stream, recordId);
  }

  Future<void> resetCursor(SyncStreamType stream) async {
    _confirmed.remove(stream);
    await _db.clearCursor(stream);
  }

  void _bump() => _revision += 1;
}
