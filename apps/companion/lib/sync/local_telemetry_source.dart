import 'dart:async';

import 'package:telemetry_core/telemetry_core.dart';

import 'companion_archive.dart';

/// Reads the local archive. There is no vehicle on this target.
class LocalTelemetrySource implements HistoricalTelemetrySource {
  LocalTelemetrySource(this.archive);

  final CompanionArchive archive;
  final _changes = StreamController<SessionChange>.broadcast();
  final _annotations = StreamController<AnnotationChange>.broadcast();

  int _lastNotifiedRevision = 0;
  int _lastNotifiedAnnotationRevision = 0;

  /// Pushes a [SessionChange] when the archive revision moved.
  void notifyIfChanged() {
    if (archive.revision == _lastNotifiedRevision) return;
    _lastNotifiedRevision = archive.revision;
    _changes.add(
      SessionChange(revision: archive.revision, trips: true, charges: true),
    );
  }

  /// Pushes an [AnnotationChange] when the annotation revision moved.
  void notifyAnnotationsIfChanged() {
    if (archive.revision == _lastNotifiedAnnotationRevision) return;
    _lastNotifiedAnnotationRevision = archive.revision;
    _annotations.add(
      AnnotationChange(
        revision: archive.revision,
        places: true,
        preferences: true,
        sessionCosts: true,
        proposals: true,
        journeys: true,
      ),
    );
  }

  void dispose() {
    _changes.close();
    _annotations.close();
  }

  @override
  Stream<SessionChange> sessionChanges() => _changes.stream;

  @override
  Future<BatteryCyclesResult> batteryCycles(int limit) async {
    final rows = await archive.database.cycles(limit: limit);
    return BatteryCyclesResult(
      cycles: List.unmodifiable(rows.map(BatteryCycleSummary.fromMap)),
      totalCount: await archive.database.countCycles(),
      limit: limit,
    );
  }

  @override
  Future<BatteryCycleSessionsResult> batteryCycleSessions(int ordinal) async {
    return BatteryCycleSessionsResult(ordinal: ordinal, sessions: const []);
  }

  @override
  Future<List<Map<String, Object?>>> eventsForSession(String sessionId) =>
      archive.database.eventsForSession(sessionId);

  @override
  Future<EnergyWindowBucketsResult> energyBucketsInWindow(int minutes) async {
    final end = DateTime.now();
    return EnergyWindowBucketsResult(
      start: end.subtract(Duration(minutes: minutes)),
      end: end,
      buckets: const [],
    );
  }

  @override
  Future<EnergyWindowBucketsResult> parkedEnergyBucketsInWindow(
    int minutes,
  ) async {
    return energyBucketsInWindow(minutes);
  }

  @override
  Future<InsightTripsResult> insightTrips(String? subjectId) async {
    final rows = await archive.database.trips();
    final ids = [
      for (final row in rows)
        if ((row['id'] as String?)?.isNotEmpty == true) row['id'] as String,
    ];
    final withBuckets = await archive.database.sessionsWithIntervals(ids);
    final trips = <InsightTrip>[];
    for (final row in rows) {
      final id = (row['id'] as String?) ?? '';
      if (id.isEmpty) continue;

      var startLat = (row['startLatitude'] as num?)?.toDouble();
      var startLon = (row['startLongitude'] as num?)?.toDouble();
      var endLat = (row['endLatitude'] as num?)?.toDouble();
      var endLon = (row['endLongitude'] as num?)?.toDouble();

      if (startLat == null || startLon == null) {
        final first = await archive.database.firstGpsPoint(id);
        startLat ??= first.lat;
        startLon ??= first.lon;
      }
      if (endLat == null || endLon == null) {
        final last = await archive.database.lastGpsPoint(id);
        endLat ??= last.lat;
        endLon ??= last.lon;
      }

      var path = row['path'] as String?;
      if (path == null || path.isEmpty) {
        path = await archive.database.gpsPath(id);
      }

      final meanAmbient =
          (row['meanAmbientTempC'] as num?)?.toDouble() ??
          (row['startAmbientTempC'] as num?)?.toDouble();

      final inputs = InsightTripInputs(
        id: id,
        endedAtUtcMillis: (row['endedAtUtcMillis'] as num?)?.toInt(),
        rollupDistanceKm: (row['rollupDistanceKm'] as num?)?.toDouble(),
        startOdometerKm: (row['startOdometerKm'] as num?)?.toDouble(),
        endOdometerKm: (row['endOdometerKm'] as num?)?.toDouble(),
        rollupTractionWh: (row['rollupTractionWh'] as num?)?.toDouble(),
        rollupRegenWh: (row['rollupRegenWh'] as num?)?.toDouble(),
        rollupAuxiliaryWh: (row['rollupAuxiliaryWh'] as num?)?.toDouble(),
        socAgreesWithIntegral: row['socAgreesWithIntegral'] as String?,
        hasMinuteBuckets: withBuckets.contains(id),
        startLatitude: startLat,
        startLongitude: startLon,
        endLatitude: endLat,
        endLongitude: endLon,
        path: path,
        meanAmbientTempC: meanAmbient,
      );

      trips.add(assembleInsightTrip(inputs));
    }
    return InsightTripsResult(trips: trips, subjectId: subjectId);
  }

  @override
  Future<InsightPlacesResult> insightPlaces() async {
    final places = await archive.database.allPlaces();
    return InsightPlacesResult(
      places: [
        for (final row in places)
          if (row['deletedAtUtcMillis'] == null)
            InsightPlace(
              id: (row['id'] as String?) ?? '',
              name: (row['name'] as String?) ?? '',
              latitude: ((row['latitude'] as num?)?.toDouble()) ?? 0,
              longitude: ((row['longitude'] as num?)?.toDouble()) ?? 0,
              radiusM:
                  ((row['radiusM'] as num?)?.toDouble()) ??
                  kInsightPlaceRadiusM,
              createdAtUtcMillis: (row['createdAtUtcMillis'] as num?)?.toInt(),
              autoName: row['autoName'] as String?,
              autoNameUpdatedAtUtcMillis:
                  (row['autoNameUpdatedAtUtcMillis'] as num?)?.toInt() ??
                  (row['autoNameUpdatedAt'] as num?)?.toInt(),
              autoNameSource: row['autoNameSource'] as String?,
            ),
      ],
    );
  }

  @override
  Future<InsightPlace> saveInsightPlace({
    String? id,
    required String name,
    required double latitude,
    required double longitude,
    double radiusM = kInsightPlaceRadiusM,
    String? autoName,
    int? autoNameUpdatedAtUtcMillis,
    String? autoNameSource,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final resolvedId = id ?? 'phone-place-$_nextPlaceId';
    final allRows = await archive.database.allPlaces();
    // A second place with one normalized name inside
    // [kPlaceDuplicateNearM] is refused: merge instead, or widen the radius.
    final blocker = findBlockingDuplicate(
      id: resolvedId,
      name: name,
      latitude: latitude,
      longitude: longitude,
      existing: [
        for (final row in allRows)
          if (row['deletedAtUtcMillis'] == null && row['id'] != resolvedId)
            InsightPlace(
              id: (row['id'] as String?) ?? '',
              name: (row['name'] as String?) ?? '',
              latitude: ((row['latitude'] as num?)?.toDouble()) ?? 0,
              longitude: ((row['longitude'] as num?)?.toDouble()) ?? 0,
              radiusM: ((row['radiusM'] as num?)?.toDouble()) ?? 0,
            ),
      ],
    );
    if (blocker != null) {
      throw DuplicatePlaceException(
        name: blocker.displayName.trim().isEmpty ? name : blocker.displayName,
        distanceM: insightDistanceM(
          latitude,
          longitude,
          blocker.latitude,
          blocker.longitude,
        ),
      );
    }
    final existing = allRows.where((r) => r['id'] == resolvedId).firstOrNull;
    final createdAt = (existing?['createdAtUtcMillis'] as num?)?.toInt() ?? now;
    // Preserve existing autoName when caller does not provide one.
    final effectiveAutoName = autoName ?? existing?['autoName'] as String?;
    final effectiveAutoNameUpdatedAt =
        autoNameUpdatedAtUtcMillis ??
        (effectiveAutoName != null ? now : null) ??
        (existing?['autoNameUpdatedAtUtcMillis'] as num?)?.toInt();
    final effectiveAutoNameSource =
        autoNameSource ?? existing?['autoNameSource'] as String?;
    final row = <String, Object?>{
      'id': resolvedId,
      'name': name,
      'latitude': latitude,
      'longitude': longitude,
      'radiusM': radiusM,
      'autoName': effectiveAutoName,
      'autoNameUpdatedAtUtcMillis': effectiveAutoNameUpdatedAt,
      'autoNameSource': effectiveAutoNameSource,
      'createdAtUtcMillis': createdAt,
      'updatedAtUtcMillis': now,
      'accountId': null,
      'origin': kAnnotationOriginPhone,
      'deletedAtUtcMillis': null,
    };
    await archive.upsertPlace(row);
    await archive.database.enqueueAnnotationPush(
      SyncStreamType.places.name,
      row,
    );
    return InsightPlace(
      id: row['id'] as String,
      name: name,
      latitude: latitude,
      longitude: longitude,
      radiusM: radiusM,
      autoName: effectiveAutoName,
      autoNameUpdatedAtUtcMillis: effectiveAutoNameUpdatedAt,
      autoNameSource: effectiveAutoNameSource,
    );
  }

  @override
  Future<void> deleteInsightPlace(String id) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = (await archive.database.allPlaces())
        .where((row) => row['id'] == id)
        .firstOrNull;
    final row = <String, Object?>{
      'id': id,
      'name': (existing?['name'] as String?) ?? '',
      'latitude': (existing?['latitude'] as num?)?.toDouble() ?? 0,
      'longitude': (existing?['longitude'] as num?)?.toDouble() ?? 0,
      'radiusM': (existing?['radiusM'] as num?)?.toDouble() ?? 150.0,
      'createdAtUtcMillis':
          (existing?['createdAtUtcMillis'] as num?)?.toInt() ?? now,
      'updatedAtUtcMillis': now,
      'origin': kAnnotationOriginPhone,
      'deletedAtUtcMillis': now,
      'autoName': existing?['autoName'] as String?,
      'autoNameUpdatedAtUtcMillis':
          existing?['autoNameUpdatedAtUtcMillis'] as num? ??
          existing?['autoNameUpdatedAt'] as num?,
      'autoNameSource': existing?['autoNameSource'] as String?,
      'accountId': existing?['accountId'] as String?,
    };
    await archive.upsertPlace(row);
    await archive.database.enqueueAnnotationPush(
      SyncStreamType.places.name,
      row,
    );
  }

  @override
  Future<ChargeMergeCandidatesResult> chargeMergeCandidates(int limit) async {
    return ChargeMergeCandidatesResult(
      candidates: const [],
      totalCount: 0,
      limit: limit,
    );
  }

  @override
  Future<ChargeMergeResult> mergeChargeSessions(List<String> sessionIds) {
    throw const SyncWriteBackDeferred();
  }

  @override
  Future<ChargeSessionCostUpdateResult> updateChargeSessionCost({
    required String sessionId,
    required double? costPerKwh,
    required double? paidAmount,
    required String currency,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final row = <String, Object?>{
      'sessionId': sessionId,
      'costPerKwh': costPerKwh,
      'paidAmount': paidAmount,
      'costCurrency': currency,
      'updatedAtUtcMillis': now,
      'origin': kAnnotationOriginPhone,
    };
    await archive.upsertSessionCost(row);
    await archive.database.enqueueAnnotationPush(
      SyncStreamType.sessionCosts.name,
      row,
    );
    final charge = await _chargeRow(sessionId);
    return ChargeSessionCostUpdateResult(
      ok: true,
      updatedRows: 1,
      session: charge == null ? null : ChargeSessionSummary.fromMap(charge),
    );
  }

  @override
  Stream<AnnotationChange> annotationsChanged() => _annotations.stream;

  @override
  Future<List<PreferenceRow>> preferenceRows() async => [
    for (final row in await archive.database.allPreferences())
      if (row['deletedAtUtcMillis'] == null) PreferenceRow.fromMap(row)!,
  ];

  @override
  Future<PreferenceRow?> savePreferenceRow({
    required String scope,
    required String key,
    String? value,
  }) async {
    if (kSyncedPreferenceKeys[key] != scope) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    final row = <String, Object?>{
      'scope': scope,
      'key': key,
      'value': value,
      'updatedAtUtcMillis': now,
      'origin': kAnnotationOriginPhone,
      'deletedAtUtcMillis': null,
    };
    await archive.upsertPreference(row);
    await archive.database.enqueueAnnotationPush(
      SyncStreamType.preferences.name,
      row,
    );
    return PreferenceRow.fromMap(row);
  }

  @override
  Future<List<PreferenceProposal>> preferenceProposals() async => [
    for (final row in await archive.database.allPreferenceProposals())
      if ((row['status'] as String?) == 'PENDING')
        PreferenceProposal.fromMap(row)!,
  ];

  @override
  Future<PreferenceProposal?> proposePreference({
    required String key,
    String? value,
  }) {
    throw const SyncWriteBackDeferred();
  }

  @override
  Future<PreferenceProposal?> decidePreferenceProposal({
    required String id,
    required bool accept,
  }) {
    // Only the car decides: the write path lives on the car.
    throw const SyncWriteBackDeferred();
  }

  @override
  Future<StorageUsage> storageUsage() => archive.database.storageUsage();

  int get _nextPlaceId => _placeCounter++;
  int _placeCounter = 1;

  Future<Map<String, Object?>?> _chargeRow(String sessionId) =>
      archive.database.session(sessionId);
}

/// Write-back waits until the companion has an editable field.
class SyncWriteBackDeferred implements Exception {
  const SyncWriteBackDeferred();

  @override
  String toString() => 'SyncWriteBackDeferred';
}
