import 'package:telemetry_core/telemetry_core.dart';

import 'cloud_sync_config.dart';
import 'cloud_uploader.dart';
import 'companion_archive.dart';
import 'companion_database.dart';

/// Companion-side annotation cloud sync — push local writes and pull remote
/// rows, per Phase 2 Lane B Step 5.
///
/// Mirrors `AnnotationCloudUploader` on the car (Kotlin) in HLC discipline:
/// every push sends the full per-group HLC row, not just the changed field,
/// so the Postgres per-group merge trigger does not treat unlisted groups as
/// regressed to zero. Conflict columns match the cloud primary keys:
///   insight_places (account_id, id)
///   journeys       (account_id, id)
///   session_costs  (vehicle_id, session_id)
///   preferences    (account_id, scope, key)
///
/// Pull reuses `sync_annotations.dart`'s merge decision (`annotationShouldReplace*`
/// per field group) so the companion's local view converges with the DB rather
/// than blindly overwriting local state with whatever the cloud returns.
///
/// Failures are per-table/per-row: a failed table does not crash the sync and
/// does not block the other tables. An offline write is retried on the next
/// sync pass because push reads the full local set each time (no dirty mark).
class AnnotationCloudSync {
  AnnotationCloudSync({
    required CompanionArchive archive,
    required CloudSink sink,
    required String accountId,
    String? Function()? vehicleIdProvider,
    this.chunkSize = 100,
  }) : _archive = archive,
       _db = archive.database,
       _sink = sink,
       _accountId = accountId,
       _vehicleIdProvider = vehicleIdProvider ?? (() => null);

  final CompanionArchive _archive;
  final CompanionDatabase _db;
  final CloudSink _sink;
  final String _accountId;
  final String? Function() _vehicleIdProvider;
  final int chunkSize;

  static const insightPlacesTable = 'insight_places';
  static const sessionCostsTable = 'session_costs';
  static const journeysTable = 'journeys';
  static const preferencesTable = 'preferences';

  static const insightPlacesConflict = ['account_id', 'id'];
  static const journeysConflict = ['account_id', 'id'];
  static const sessionCostsConflict = ['vehicle_id', 'session_id'];
  static const preferencesConflict = ['account_id', 'scope', 'key'];

  /// Returns a sync that will no-op when no project / no account is configured,
  /// matching `SupabaseCloudSink.uploaderFor`'s contract. The cloud-sync gate
  /// ([CloudSyncConfig.enabled], default ON) also gates it — OFF still
  /// resolves to null (no-op) even when a project and account are present.
  static AnnotationCloudSync? maybeFor({
    required CompanionArchive archive,
    required CloudSink? sink,
    required String? accountId,
    String? Function()? vehicleIdProvider,
  }) {
    // Cloud-sync gate — defaults ON. See `CloudSyncConfig`.
    if (!CloudSyncConfig.enabled) return null;
    if (sink == null || accountId == null || accountId.isEmpty) return null;
    return AnnotationCloudSync(
      archive: archive,
      sink: sink,
      accountId: accountId,
      vehicleIdProvider: vehicleIdProvider,
    );
  }

  /// Pushes all local annotation rows to the cloud.
  ///
  /// Each table is attempted independently; one table's failure does not
  /// prevent the others. The full local set is pushed every pass so an offline
  /// write eventually reaches the cloud.
  /// write eventually reaches the cloud.
  Future<AnnotationCloudSyncReport> push() async {
    final perStream = <String, int>{};
    final errors = <String, Object>{};

    await _pushPlaces(perStream, errors);
    if (!errors.containsKey(insightPlacesTable)) {
      try {
        await _db.clearAnnotationOutbox(stream: 'places');
      } catch (_) {}
    }
    await _pushSessionCosts(perStream, errors);
    if (!errors.containsKey(sessionCostsTable)) {
      try {
        await _db.clearAnnotationOutbox(stream: 'sessionCosts');
      } catch (_) {}
    }
    await _pushJourneys(perStream, errors);
    if (!errors.containsKey(journeysTable)) {
      try {
        await _db.clearAnnotationOutbox(stream: 'journeys');
      } catch (_) {}
    }
    await _pushPreferences(perStream, errors);
    if (!errors.containsKey(preferencesTable)) {
      try {
        await _db.clearAnnotationOutbox(stream: 'preferences');
      } catch (_) {}
    }

    return AnnotationCloudSyncReport(perStream: perStream, errors: errors);
  }

  /// Pulls remote annotation rows and merges them into the local store using
  /// per-field-group LWW (device_id tie-break, auto_name uses origin rank).
  ///
  /// Each table is attempted independently.
  Future<AnnotationCloudSyncReport> pull() async {
    final perStream = <String, int>{};
    final errors = <String, Object>{};

    await _pullPlaces(perStream, errors);
    await _pullSessionCosts(perStream, errors);
    await _pullJourneys(perStream, errors);
    await _pullPreferences(perStream, errors);

    return AnnotationCloudSyncReport(perStream: perStream, errors: errors);
  }

  /// One full round-trip: push then pull.
  Future<AnnotationCloudSyncReport> sync() async {
    final pushReport = await push();
    final pullReport = await pull();
    final merged = <String, int>{};
    for (final entry in pushReport.perStream.entries) {
      merged[entry.key] = (merged[entry.key] ?? 0) + entry.value;
    }
    for (final entry in pullReport.perStream.entries) {
      merged[entry.key] = (merged[entry.key] ?? 0) + entry.value;
    }
    final allErrors = <String, Object>{}
      ..addAll(pushReport.errors)
      ..addAll(pullReport.errors);
    return AnnotationCloudSyncReport(perStream: merged, errors: allErrors);
  }

  // ---------------------------------------------------------------------------
  // Push helpers
  // ---------------------------------------------------------------------------

  Future<void> _pushPlaces(
    Map<String, int> perStream,
    Map<String, Object> errors,
  ) async {
    try {
      final places = await _db.allPlaces();
      if (places.isEmpty) return;
      for (final chunk in _chunks(places, chunkSize)) {
        final rows = <Map<String, Object?>>[];
        for (final row in chunk) {
          final id = row['id'] as String?;
          if (id == null || id.isEmpty) continue;
          final hlc = _localHlc(row);
          rows.add({
            'id': id,
            'account_id':
                (row['accountId'] as String?)?.trim().isNotEmpty == true
                ? row['accountId']
                : _accountId,
            'name': row['name'],
            'latitude': row['latitude'],
            'longitude': row['longitude'],
            'radius_m': row['radiusM'] ?? row['radius_m'],
            'created_at_utc_millis':
                (row['createdAtUtcMillis'] as num?)?.toInt() ??
                (row['updatedAtUtcMillis'] as num?)?.toInt(),
            'updated_at_utc_millis': row['updatedAtUtcMillis'],
            'origin': row['origin'],
            'deleted_at_utc_millis': row['deletedAtUtcMillis'],
            'auto_name': row['autoName'] ?? row['auto_name'],
            'auto_name_updated_at_utc_millis':
                row['autoNameUpdatedAtUtcMillis'] ??
                row['auto_name_updated_at_utc_millis'],
            'auto_name_source':
                row['autoNameSource'] ?? row['auto_name_source'],
            'name_hlc_millis': hlc.millis,
            'name_hlc_counter': hlc.counter,
            'name_hlc_device_id': hlc.deviceId,
            'geofence_hlc_millis': hlc.millis,
            'geofence_hlc_counter': hlc.counter,
            'geofence_hlc_device_id': hlc.deviceId,
            'auto_name_hlc_millis': hlc.millis,
            'auto_name_hlc_counter': hlc.counter,
            'auto_name_hlc_device_id': hlc.deviceId,
          });
        }
        if (rows.isEmpty) continue;
        await _sink.upsert(
          insightPlacesTable,
          rows,
          conflictColumns: insightPlacesConflict,
          merge: true,
        );
        perStream[insightPlacesTable] =
            (perStream[insightPlacesTable] ?? 0) + rows.length;
      }
    } catch (e) {
      errors[insightPlacesTable] = e;
    }
  }

  Future<void> _pushSessionCosts(
    Map<String, int> perStream,
    Map<String, Object> errors,
  ) async {
    try {
      final costs = await _db.allSessionCosts();
      if (costs.isEmpty) return;
      // Resolve vehicle per session, fallback to provider.
      final sessionIds = [
        for (final c in costs)
          c['sessionId'] as String? ?? c['session_id'] as String?,
      ].whereType<String>().toList();
      final vehicleMap = await _db.vehicleIdsForSessions(sessionIds);
      final globalVehicleId = _vehicleIdProvider();

      final scoped = <Map<String, Object?>>[];
      for (final row in costs) {
        final sessionId =
            (row['sessionId'] as String?) ?? (row['session_id'] as String?);
        if (sessionId == null || sessionId.isEmpty) continue;
        final vehicleId = vehicleMap[sessionId] ?? globalVehicleId;
        if (vehicleId == null ||
            vehicleId.isEmpty ||
            vehicleId == 'unassigned') {
          continue;
        }
        scoped.add({...row, '_resolvedVehicleId': vehicleId});
      }
      if (scoped.isEmpty) return;
      for (final chunk in _chunks(scoped, chunkSize)) {
        final rows = <Map<String, Object?>>[];
        for (final row in chunk) {
          final sessionId =
              (row['sessionId'] as String?) ?? (row['session_id'] as String?);
          if (sessionId == null) continue;
          final vehicleId = row['_resolvedVehicleId'] as String;
          final hlc = _localHlc(row);
          rows.add({
            'vehicle_id': vehicleId,
            'session_id': sessionId,
            'account_id': _accountId,
            'cost_per_kwh': row['costPerKwh'] ?? row['cost_per_kwh'],
            'paid_amount': row['paidAmount'] ?? row['paid_amount'],
            'cost_currency': row['costCurrency'] ?? row['cost_currency'],
            'updated_at_utc_millis': row['updatedAtUtcMillis'],
            'origin': row['origin'],
            'cost_hlc_millis': hlc.millis,
            'cost_hlc_counter': hlc.counter,
            'cost_hlc_device_id': hlc.deviceId,
          });
        }
        if (rows.isEmpty) continue;
        await _sink.upsert(
          sessionCostsTable,
          rows,
          conflictColumns: sessionCostsConflict,
          merge: true,
        );
        perStream[sessionCostsTable] =
            (perStream[sessionCostsTable] ?? 0) + rows.length;
      }
    } catch (e) {
      errors[sessionCostsTable] = e;
    }
  }

  Future<void> _pushJourneys(
    Map<String, int> perStream,
    Map<String, Object> errors,
  ) async {
    try {
      final journeys = await _db.allJourneys();
      if (journeys.isEmpty) return;
      for (final chunk in _chunks(journeys, chunkSize)) {
        final rows = <Map<String, Object?>>[];
        for (final row in chunk) {
          final id = row['id'] as String?;
          if (id == null || id.isEmpty) continue;
          final hlc = _localHlc(row);
          rows.add({
            'id': id,
            'account_id':
                (row['accountId'] as String?)?.trim().isNotEmpty == true
                ? row['accountId']
                : _accountId,
            'name': row['name'],
            'started_at_utc_millis':
                row['startedAtUtcMillis'] ?? row['started_at_utc_millis'],
            'ended_at_utc_millis':
                row['endedAtUtcMillis'] ?? row['ended_at_utc_millis'],
            'note': row['note'],
            'created_at_utc_millis':
                (row['createdAtUtcMillis'] as num?)?.toInt() ??
                (row['updatedAtUtcMillis'] as num?)?.toInt(),
            'updated_at_utc_millis': row['updatedAtUtcMillis'],
            'origin': row['origin'],
            'deleted_at_utc_millis': row['deletedAtUtcMillis'],
            'name_hlc_millis': hlc.millis,
            'name_hlc_counter': hlc.counter,
            'name_hlc_device_id': hlc.deviceId,
            'note_hlc_millis': hlc.millis,
            'note_hlc_counter': hlc.counter,
            'note_hlc_device_id': hlc.deviceId,
            'time_range_hlc_millis': hlc.millis,
            'time_range_hlc_counter': hlc.counter,
            'time_range_hlc_device_id': hlc.deviceId,
          });
        }
        if (rows.isEmpty) continue;
        await _sink.upsert(
          journeysTable,
          rows,
          conflictColumns: journeysConflict,
          merge: true,
        );
        perStream[journeysTable] =
            (perStream[journeysTable] ?? 0) + rows.length;
      }
    } catch (e) {
      errors[journeysTable] = e;
    }
  }

  Future<void> _pushPreferences(
    Map<String, int> perStream,
    Map<String, Object> errors,
  ) async {
    try {
      final prefs = await _db.allPreferences();
      if (prefs.isEmpty) return;
      for (final chunk in _chunks(prefs, chunkSize)) {
        final rows = <Map<String, Object?>>[];
        for (final row in chunk) {
          final scope = row['scope'] as String?;
          final key = row['key'] as String?;
          if (scope == null || scope.isEmpty || key == null || key.isEmpty) {
            continue;
          }
          final hlc = _localHlc(row);
          rows.add({
            'account_id': _accountId,
            'scope': scope,
            'key': key,
            'value': row['value'],
            'updated_at_utc_millis': row['updatedAtUtcMillis'],
            'origin': row['origin'],
            'deleted_at_utc_millis': row['deletedAtUtcMillis'],
            'hlc_millis': hlc.millis,
            'hlc_counter': hlc.counter,
            'hlc_device_id': hlc.deviceId,
          });
        }
        if (rows.isEmpty) continue;
        await _sink.upsert(
          preferencesTable,
          rows,
          conflictColumns: preferencesConflict,
          merge: true,
        );
        perStream[preferencesTable] =
            (perStream[preferencesTable] ?? 0) + rows.length;
      }
    } catch (e) {
      errors[preferencesTable] = e;
    }
  }

  // ---------------------------------------------------------------------------
  // Pull helpers — fetch + per-field-group LWW merge
  // ---------------------------------------------------------------------------

  Future<void> _pullPlaces(
    Map<String, int> perStream,
    Map<String, Object> errors,
  ) async {
    try {
      final remote = await _sink.fetch(insightPlacesTable);
      var merged = 0;
      // Hoist lookup out of loop (L-4).
      final localRows = await _db.allPlaces();
      final localById = <String, Map<String, Object?>>{
        for (final r in localRows) (r['id'] as String): r,
      };
      for (final cloudRow in remote) {
        try {
          final id = cloudRow['id'] as String?;
          if (id == null || id.isEmpty) continue;
          final local = localById[id];

          final remoteMap = _cloudPlaceToLocal(cloudRow);
          if (local == null) {
            await _archive.upsertPlace(remoteMap);
            // Keep map up to date for duplicate ids in same batch.
            localById[id] = remoteMap;
            merged++;
            continue;
          }

          final shouldReplace = _shouldReplacePlace(local, cloudRow);
          if (shouldReplace) {
            // Build merged row: per-group field merge.
            final mergedRow = _mergePlace(local, cloudRow, remoteMap);
            // Bypass archive's row-level guard by writing directly via _archive
            // but we have already decided; feed the merged row through archive
            // with an HLC that will win. Use remote's winning HLCs fanned to a
            // single winning triple (max) so the archive's LWW accepts it.
            final winningHlc = _winningPlaceHlc(local, cloudRow);
            mergedRow['hlcMillis'] = winningHlc.millis;
            mergedRow['hlcCounter'] = winningHlc.counter;
            mergedRow['hlcDeviceId'] = winningHlc.deviceId;
            mergedRow['hlc'] = winningHlc.toMap();
            // Ensure archive's merge sees this as newer by ticking if needed:
            // directly upsert via database to preserve field-level merge.
            await _db.upsertPlace(
              id,
              (mergedRow['updatedAtUtcMillis'] as num?)?.toInt() ??
                  winningHlc.millis,
              (mergedRow['origin'] as String?) ?? kAnnotationOriginCloud,
              mergedRow,
            );
            localById[id] = mergedRow;
            merged++;
          }
        } catch (_) {
          // Per-row guard: one bad row does not block the rest.
          continue;
        }
      }
      if (merged > 0) perStream[insightPlacesTable] = merged;
    } catch (e) {
      errors[insightPlacesTable] = e;
    }
  }

  Future<void> _pullSessionCosts(
    Map<String, int> perStream,
    Map<String, Object> errors,
  ) async {
    try {
      final remote = await _sink.fetch(sessionCostsTable);
      var merged = 0;
      for (final cloudRow in remote) {
        try {
          final sessionId = cloudRow['session_id'] as String?;
          if (sessionId == null || sessionId.isEmpty) continue;
          final local = await _db.sessionCost(sessionId);
          final remoteMap = _cloudSessionCostToLocal(cloudRow);
          if (local == null) {
            await _archive.upsertSessionCost(remoteMap);
            merged++;
            continue;
          }
          final existingHlc = _extractHlc(local);
          final incomingHlc = _extractHlcFromCloudCost(cloudRow);
          final existingOrigin = local['origin'] as String?;
          final incomingOrigin = cloudRow['origin'] as String?;
          final shouldReplace = _compareHlc(
            existingHlc,
            existingOrigin,
            incomingHlc,
            incomingOrigin,
            withOriginRank: false,
          );
          if (shouldReplace) {
            // Force merge win by using incoming HLC.
            remoteMap['hlcMillis'] = incomingHlc.millis;
            remoteMap['hlcCounter'] = incomingHlc.counter;
            remoteMap['hlcDeviceId'] = incomingHlc.deviceId;
            remoteMap['hlc'] = incomingHlc.toMap();
            // Direct DB path to avoid tick interfering.
            await _db.upsertSessionCost(
              sessionId,
              (remoteMap['updatedAtUtcMillis'] as num?)?.toInt() ??
                  incomingHlc.millis,
              (remoteMap['origin'] as String?) ?? kAnnotationOriginCloud,
              remoteMap,
            );
            merged++;
          }
        } catch (_) {
          continue;
        }
      }
      if (merged > 0) perStream[sessionCostsTable] = merged;
    } catch (e) {
      errors[sessionCostsTable] = e;
    }
  }

  Future<void> _pullJourneys(
    Map<String, int> perStream,
    Map<String, Object> errors,
  ) async {
    try {
      final remote = await _sink.fetch(journeysTable);
      var merged = 0;
      final localRows = await _db.allJourneys();
      final localById = <String, Map<String, Object?>>{
        for (final r in localRows) (r['id'] as String): r,
      };
      for (final cloudRow in remote) {
        try {
          final id = cloudRow['id'] as String?;
          if (id == null || id.isEmpty) continue;
          final local = localById[id];
          final remoteMap = _cloudJourneyToLocal(cloudRow);
          if (local == null) {
            if (await _archive.upsertJourney(remoteMap)) {
              merged++;
            }
            localById[id] = remoteMap;
            continue;
          }
          final shouldReplace = _shouldReplaceJourney(local, cloudRow);
          if (shouldReplace) {
            final mergedRow = _mergeJourney(local, cloudRow, remoteMap);
            final winningHlc = _winningJourneyHlc(local, cloudRow);
            mergedRow['hlcMillis'] = winningHlc.millis;
            mergedRow['hlcCounter'] = winningHlc.counter;
            mergedRow['hlcDeviceId'] = winningHlc.deviceId;
            mergedRow['hlc'] = winningHlc.toMap();
            await _db.upsertJourney(
              id,
              (mergedRow['updatedAtUtcMillis'] as num?)?.toInt() ??
                  winningHlc.millis,
              (mergedRow['origin'] as String?) ?? kAnnotationOriginCloud,
              mergedRow,
            );
            localById[id] = mergedRow;
            merged++;
          }
        } catch (_) {
          continue;
        }
      }
      if (merged > 0) perStream[journeysTable] = merged;
    } catch (e) {
      errors[journeysTable] = e;
    }
  }

  Future<void> _pullPreferences(
    Map<String, int> perStream,
    Map<String, Object> errors,
  ) async {
    try {
      final remote = await _sink.fetch(preferencesTable);
      var merged = 0;
      final allLocal = await _db.allPreferences();
      final localByKey = <String, Map<String, Object?>>{
        for (final r in allLocal) '${r['scope']}:${r['key']}': r,
      };
      for (final cloudRow in remote) {
        try {
          final scope = cloudRow['scope'] as String?;
          final key = cloudRow['key'] as String?;
          if (scope == null || key == null) continue;
          final localKey = '$scope:$key';
          final local = localByKey[localKey];
          final remoteMap = _cloudPreferenceToLocal(cloudRow);
          if (local == null) {
            await _archive.upsertPreference(remoteMap);
            localByKey[localKey] = remoteMap;
            merged++;
            continue;
          }
          final shouldReplace = _shouldReplacePreference(local, cloudRow);
          if (shouldReplace) {
            final mergedRow = _mergePreference(local, cloudRow, remoteMap);
            final winningHlc = _winningPreferenceHlc(local, cloudRow);
            mergedRow['hlcMillis'] = winningHlc.millis;
            mergedRow['hlcCounter'] = winningHlc.counter;
            mergedRow['hlcDeviceId'] = winningHlc.deviceId;
            mergedRow['hlc'] = winningHlc.toMap();
            await _db.upsertPreference(
              scope,
              key,
              (mergedRow['updatedAtUtcMillis'] as num?)?.toInt() ??
                  winningHlc.millis,
              (mergedRow['origin'] as String?) ?? kAnnotationOriginCloud,
              mergedRow,
            );
            localByKey[localKey] = mergedRow;
            merged++;
          }
        } catch (_) {
          continue;
        }
      }
      if (merged > 0) perStream[preferencesTable] = merged;
    } catch (e) {
      errors[preferencesTable] = e;
    }
  }

  // ---------------------------------------------------------------------------
  // HLC helpers
  // ---------------------------------------------------------------------------

  HlcTimestamp _localHlc(Map<String, Object?> row) {
    final millis =
        (row['hlcMillis'] as num?)?.toInt() ??
        (row['hlc'] is Map
            ? ((row['hlc'] as Map)['millis'] as num?)?.toInt()
            : null) ??
        (row['updatedAtUtcMillis'] as num?)?.toInt() ??
        0;
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
            : null) ??
        (row['origin'] as String?) ??
        kAnnotationOriginPhone;
    return HlcTimestamp(millis: millis, counter: counter, deviceId: deviceId);
  }

  HlcTimestamp _extractHlc(Map<String, Object?> row) => _localHlc(row);

  HlcTimestamp _extractHlcFromCloudCost(Map<String, Object?> cloudRow) {
    final millis = (cloudRow['cost_hlc_millis'] as num?)?.toInt() ?? 0;
    final counter = (cloudRow['cost_hlc_counter'] as num?)?.toInt() ?? 0;
    final deviceId = (cloudRow['cost_hlc_device_id'] as String?) ?? '';
    return HlcTimestamp(
      millis: millis,
      counter: counter,
      deviceId: deviceId.isEmpty
          ? (cloudRow['origin'] as String? ?? '')
          : deviceId,
    );
  }

  HlcTimestamp _extractHlcFromCloudPref(Map<String, Object?> cloudRow) {
    final millis = (cloudRow['hlc_millis'] as num?)?.toInt() ?? 0;
    final counter = (cloudRow['hlc_counter'] as num?)?.toInt() ?? 0;
    final deviceId = (cloudRow['hlc_device_id'] as String?) ?? '';
    return HlcTimestamp(
      millis: millis,
      counter: counter,
      deviceId: deviceId.isEmpty
          ? (cloudRow['origin'] as String? ?? '')
          : deviceId,
    );
  }

  bool _compareHlc(
    HlcTimestamp existing,
    String? existingOrigin,
    HlcTimestamp incoming,
    String? incomingOrigin, {
    required bool withOriginRank,
  }) {
    if (withOriginRank) {
      return annotationShouldReplaceWithOriginRankHlc(
        existingHlc: existing,
        existingOrigin: existingOrigin,
        incomingHlc: incoming,
        incomingOrigin: incomingOrigin,
      );
    }
    return annotationShouldReplaceHlc(
      existingHlc: existing,
      existingOrigin: existingOrigin,
      incomingHlc: incoming,
      incomingOrigin: incomingOrigin,
    );
  }

  bool _shouldReplacePlace(
    Map<String, Object?> local,
    Map<String, Object?> cloudRow,
  ) {
    final localHlc = _extractHlc(local);
    final localOrigin = local['origin'] as String?;
    final localDeleted = local['deletedAtUtcMillis'] != null;
    final remoteDeleted = cloudRow['deleted_at_utc_millis'] != null;
    final remoteOrigin = cloudRow['origin'] as String?;
    final remoteUpdatedAt =
        (cloudRow['updated_at_utc_millis'] as num?)?.toInt() ?? 0;

    final nameIncoming = HlcTimestamp(
      millis: (cloudRow['name_hlc_millis'] as num?)?.toInt() ?? 0,
      counter: (cloudRow['name_hlc_counter'] as num?)?.toInt() ?? 0,
      deviceId: (cloudRow['name_hlc_device_id'] as String?)?.isNotEmpty == true
          ? cloudRow['name_hlc_device_id'] as String
          : (remoteOrigin ?? ''),
    );
    final geofenceIncoming = HlcTimestamp(
      millis: (cloudRow['geofence_hlc_millis'] as num?)?.toInt() ?? 0,
      counter: (cloudRow['geofence_hlc_counter'] as num?)?.toInt() ?? 0,
      deviceId:
          (cloudRow['geofence_hlc_device_id'] as String?)?.isNotEmpty == true
          ? cloudRow['geofence_hlc_device_id'] as String
          : (remoteOrigin ?? ''),
    );
    final autoIncoming = HlcTimestamp(
      millis: (cloudRow['auto_name_hlc_millis'] as num?)?.toInt() ?? 0,
      counter: (cloudRow['auto_name_hlc_counter'] as num?)?.toInt() ?? 0,
      deviceId:
          (cloudRow['auto_name_hlc_device_id'] as String?)?.isNotEmpty == true
          ? cloudRow['auto_name_hlc_device_id'] as String
          : (remoteOrigin ?? ''),
    );

    final nameWins = _compareHlc(
      localHlc,
      localOrigin,
      nameIncoming,
      remoteOrigin,
      withOriginRank: false,
    );
    final geofenceWins = _compareHlc(
      localHlc,
      localOrigin,
      geofenceIncoming,
      remoteOrigin,
      withOriginRank: false,
    );
    final autoWins = _compareHlc(
      localHlc,
      localOrigin,
      autoIncoming,
      remoteOrigin,
      withOriginRank: true,
    );

    if (!localDeleted && !remoteDeleted) {
      return nameWins || geofenceWins || autoWins;
    }
    if (!localDeleted && remoteDeleted) {
      final tombstone = HlcTimestamp(
        millis: remoteUpdatedAt,
        counter: 0,
        deviceId: remoteOrigin ?? '',
      );
      final tombstoneWins = _compareHlc(
        localHlc,
        localOrigin,
        tombstone,
        remoteOrigin,
        withOriginRank: false,
      );
      return tombstoneWins || nameWins || geofenceWins || autoWins;
    }
    if (localDeleted && !remoteDeleted) {
      final tombMillis = (local['updatedAtUtcMillis'] as num?)?.toInt() ?? 0;
      final tombstone = HlcTimestamp(
        millis: tombMillis,
        counter: 0,
        deviceId: localOrigin ?? '',
      );
      final gatedName =
          nameWins &&
          _compareHlc(
            tombstone,
            localOrigin,
            nameIncoming,
            remoteOrigin,
            withOriginRank: false,
          );
      final gatedGeofence =
          geofenceWins &&
          _compareHlc(
            tombstone,
            localOrigin,
            geofenceIncoming,
            remoteOrigin,
            withOriginRank: false,
          );
      final gatedAuto =
          autoWins &&
          _compareHlc(
            tombstone,
            localOrigin,
            autoIncoming,
            remoteOrigin,
            withOriginRank: true,
          );
      return gatedName || gatedGeofence || gatedAuto;
    }
    // Both deleted: gate fields against old tombstone, then check newer tombstone.
    final tombMillis = (local['updatedAtUtcMillis'] as num?)?.toInt() ?? 0;
    final tombLocal = HlcTimestamp(
      millis: tombMillis,
      counter: 0,
      deviceId: localOrigin ?? '',
    );
    final gatedName =
        nameWins &&
        _compareHlc(
          tombLocal,
          localOrigin,
          nameIncoming,
          remoteOrigin,
          withOriginRank: false,
        );
    final gatedGeofence =
        geofenceWins &&
        _compareHlc(
          tombLocal,
          localOrigin,
          geofenceIncoming,
          remoteOrigin,
          withOriginRank: false,
        );
    final gatedAuto =
        autoWins &&
        _compareHlc(
          tombLocal,
          localOrigin,
          autoIncoming,
          remoteOrigin,
          withOriginRank: true,
        );
    final anyGated = gatedName || gatedGeofence || gatedAuto;
    final remoteTomb = HlcTimestamp(
      millis: remoteUpdatedAt,
      counter: 0,
      deviceId: remoteOrigin ?? '',
    );
    final tombWins = _compareHlc(
      tombLocal,
      localOrigin,
      remoteTomb,
      remoteOrigin,
      withOriginRank: false,
    );
    return anyGated || tombWins;
  }

  bool _shouldReplaceJourney(
    Map<String, Object?> local,
    Map<String, Object?> cloudRow,
  ) {
    final localHlc = _extractHlc(local);
    final localOrigin = local['origin'] as String?;
    final localDeleted = local['deletedAtUtcMillis'] != null;
    final remoteDeleted = cloudRow['deleted_at_utc_millis'] != null;
    final remoteOrigin = cloudRow['origin'] as String?;
    final remoteUpdatedAt =
        (cloudRow['updated_at_utc_millis'] as num?)?.toInt() ?? 0;

    final nameIncoming = HlcTimestamp(
      millis: (cloudRow['name_hlc_millis'] as num?)?.toInt() ?? 0,
      counter: (cloudRow['name_hlc_counter'] as num?)?.toInt() ?? 0,
      deviceId: (cloudRow['name_hlc_device_id'] as String?)?.isNotEmpty == true
          ? cloudRow['name_hlc_device_id'] as String
          : (remoteOrigin ?? ''),
    );
    final noteIncoming = HlcTimestamp(
      millis: (cloudRow['note_hlc_millis'] as num?)?.toInt() ?? 0,
      counter: (cloudRow['note_hlc_counter'] as num?)?.toInt() ?? 0,
      deviceId: (cloudRow['note_hlc_device_id'] as String?)?.isNotEmpty == true
          ? cloudRow['note_hlc_device_id'] as String
          : (remoteOrigin ?? ''),
    );
    final timeIncoming = HlcTimestamp(
      millis: (cloudRow['time_range_hlc_millis'] as num?)?.toInt() ?? 0,
      counter: (cloudRow['time_range_hlc_counter'] as num?)?.toInt() ?? 0,
      deviceId:
          (cloudRow['time_range_hlc_device_id'] as String?)?.isNotEmpty == true
          ? cloudRow['time_range_hlc_device_id'] as String
          : (remoteOrigin ?? ''),
    );

    final nameWins = _compareHlc(
      localHlc,
      localOrigin,
      nameIncoming,
      remoteOrigin,
      withOriginRank: false,
    );
    final noteWins = _compareHlc(
      localHlc,
      localOrigin,
      noteIncoming,
      remoteOrigin,
      withOriginRank: false,
    );
    final timeWins = _compareHlc(
      localHlc,
      localOrigin,
      timeIncoming,
      remoteOrigin,
      withOriginRank: false,
    );

    if (!localDeleted && !remoteDeleted) {
      return nameWins || noteWins || timeWins;
    }
    if (!localDeleted && remoteDeleted) {
      final tombstone = HlcTimestamp(
        millis: remoteUpdatedAt,
        counter: 0,
        deviceId: remoteOrigin ?? '',
      );
      final tombstoneWins = _compareHlc(
        localHlc,
        localOrigin,
        tombstone,
        remoteOrigin,
        withOriginRank: false,
      );
      return tombstoneWins || nameWins || noteWins || timeWins;
    }
    if (localDeleted && !remoteDeleted) {
      final tombMillis = (local['updatedAtUtcMillis'] as num?)?.toInt() ?? 0;
      final tombstone = HlcTimestamp(
        millis: tombMillis,
        counter: 0,
        deviceId: localOrigin ?? '',
      );
      final gatedName =
          nameWins &&
          _compareHlc(
            tombstone,
            localOrigin,
            nameIncoming,
            remoteOrigin,
            withOriginRank: false,
          );
      final gatedNote =
          noteWins &&
          _compareHlc(
            tombstone,
            localOrigin,
            noteIncoming,
            remoteOrigin,
            withOriginRank: false,
          );
      final gatedTime =
          timeWins &&
          _compareHlc(
            tombstone,
            localOrigin,
            timeIncoming,
            remoteOrigin,
            withOriginRank: false,
          );
      return gatedName || gatedNote || gatedTime;
    }
    final tombMillis = (local['updatedAtUtcMillis'] as num?)?.toInt() ?? 0;
    final tombLocal = HlcTimestamp(
      millis: tombMillis,
      counter: 0,
      deviceId: localOrigin ?? '',
    );
    final gatedName =
        nameWins &&
        _compareHlc(
          tombLocal,
          localOrigin,
          nameIncoming,
          remoteOrigin,
          withOriginRank: false,
        );
    final gatedNote =
        noteWins &&
        _compareHlc(
          tombLocal,
          localOrigin,
          noteIncoming,
          remoteOrigin,
          withOriginRank: false,
        );
    final gatedTime =
        timeWins &&
        _compareHlc(
          tombLocal,
          localOrigin,
          timeIncoming,
          remoteOrigin,
          withOriginRank: false,
        );
    final anyGated = gatedName || gatedNote || gatedTime;
    final remoteTomb = HlcTimestamp(
      millis: remoteUpdatedAt,
      counter: 0,
      deviceId: remoteOrigin ?? '',
    );
    final tombWins = _compareHlc(
      tombLocal,
      localOrigin,
      remoteTomb,
      remoteOrigin,
      withOriginRank: false,
    );
    return anyGated || tombWins;
  }

  bool _shouldReplacePreference(
    Map<String, Object?> local,
    Map<String, Object?> cloudRow,
  ) {
    final localHlc = _extractHlc(local);
    final localOrigin = local['origin'] as String?;
    final localDeleted = local['deletedAtUtcMillis'] != null;
    final remoteDeleted = cloudRow['deleted_at_utc_millis'] != null;
    final remoteOrigin = cloudRow['origin'] as String?;
    final remoteHlc = _extractHlcFromCloudPref(cloudRow);
    final localTombMillis = (local['updatedAtUtcMillis'] as num?)?.toInt() ?? 0;
    final remoteUpdatedAt =
        (cloudRow['updated_at_utc_millis'] as num?)?.toInt() ?? 0;
    final remoteTomb = HlcTimestamp(
      millis: remoteUpdatedAt,
      counter: 0,
      deviceId: remoteOrigin ?? '',
    );
    final localTomb = HlcTimestamp(
      millis: localTombMillis,
      counter: 0,
      deviceId: localOrigin ?? '',
    );
    final valueWins = _compareHlc(
      localHlc,
      localOrigin,
      remoteHlc,
      remoteOrigin,
      withOriginRank: false,
    );
    if (!localDeleted && !remoteDeleted) return valueWins;
    if (!localDeleted && remoteDeleted) {
      final tombWins = _compareHlc(
        localHlc,
        localOrigin,
        remoteTomb,
        remoteOrigin,
        withOriginRank: false,
      );
      return tombWins || valueWins;
    }
    if (localDeleted && !remoteDeleted) {
      if (!valueWins) return false;
      return _compareHlc(
        localTomb,
        localOrigin,
        remoteHlc,
        remoteOrigin,
        withOriginRank: false,
      );
    }
    // Both deleted
    final gatedValue =
        valueWins &&
        _compareHlc(
          localTomb,
          localOrigin,
          remoteHlc,
          remoteOrigin,
          withOriginRank: false,
        );
    final tombWins = _compareHlc(
      localTomb,
      localOrigin,
      remoteTomb,
      remoteOrigin,
      withOriginRank: false,
    );
    return gatedValue || tombWins;
  }

  Map<String, Object?> _mergePlace(
    Map<String, Object?> local,
    Map<String, Object?> cloudRow,
    Map<String, Object?> remoteMap,
  ) {
    final localHlc = _extractHlc(local);
    final localOrigin = local['origin'] as String?;
    final localDeleted = local['deletedAtUtcMillis'] != null;
    final remoteDeleted = cloudRow['deleted_at_utc_millis'] != null;
    final remoteOrigin = cloudRow['origin'] as String?;
    final remoteUpdatedAt =
        (cloudRow['updated_at_utc_millis'] as num?)?.toInt() ?? 0;

    final nameIncoming = HlcTimestamp(
      millis: (cloudRow['name_hlc_millis'] as num?)?.toInt() ?? 0,
      counter: (cloudRow['name_hlc_counter'] as num?)?.toInt() ?? 0,
      deviceId:
          (cloudRow['name_hlc_device_id'] as String?) ??
          (cloudRow['origin'] as String? ?? ''),
    );
    final geofenceIncoming = HlcTimestamp(
      millis: (cloudRow['geofence_hlc_millis'] as num?)?.toInt() ?? 0,
      counter: (cloudRow['geofence_hlc_counter'] as num?)?.toInt() ?? 0,
      deviceId:
          (cloudRow['geofence_hlc_device_id'] as String?) ??
          (cloudRow['origin'] as String? ?? ''),
    );
    final autoIncoming = HlcTimestamp(
      millis: (cloudRow['auto_name_hlc_millis'] as num?)?.toInt() ?? 0,
      counter: (cloudRow['auto_name_hlc_counter'] as num?)?.toInt() ?? 0,
      deviceId:
          (cloudRow['auto_name_hlc_device_id'] as String?) ??
          (cloudRow['origin'] as String? ?? ''),
    );

    final rawNameWins = _compareHlc(
      localHlc,
      localOrigin,
      nameIncoming,
      remoteOrigin,
      withOriginRank: false,
    );
    final rawGeofenceWins = _compareHlc(
      localHlc,
      localOrigin,
      geofenceIncoming,
      remoteOrigin,
      withOriginRank: false,
    );
    final rawAutoWins = _compareHlc(
      localHlc,
      localOrigin,
      autoIncoming,
      remoteOrigin,
      withOriginRank: true,
    );

    bool nameWins = rawNameWins;
    bool geofenceWins = rawGeofenceWins;
    bool autoWins = rawAutoWins;
    bool tombstoneWins = false;

    if (!localDeleted && remoteDeleted) {
      final tombstone = HlcTimestamp(
        millis: remoteUpdatedAt,
        counter: 0,
        deviceId: remoteOrigin ?? '',
      );
      tombstoneWins = _compareHlc(
        localHlc,
        localOrigin,
        tombstone,
        remoteOrigin,
        withOriginRank: false,
      );
    } else if (localDeleted && !remoteDeleted) {
      final tombMillis = (local['updatedAtUtcMillis'] as num?)?.toInt() ?? 0;
      final tombstone = HlcTimestamp(
        millis: tombMillis,
        counter: 0,
        deviceId: localOrigin ?? '',
      );
      nameWins =
          rawNameWins &&
          _compareHlc(
            tombstone,
            localOrigin,
            nameIncoming,
            remoteOrigin,
            withOriginRank: false,
          );
      geofenceWins =
          rawGeofenceWins &&
          _compareHlc(
            tombstone,
            localOrigin,
            geofenceIncoming,
            remoteOrigin,
            withOriginRank: false,
          );
      autoWins =
          rawAutoWins &&
          _compareHlc(
            tombstone,
            localOrigin,
            autoIncoming,
            remoteOrigin,
            withOriginRank: true,
          );
    } else if (localDeleted && remoteDeleted) {
      final tombMillis = (local['updatedAtUtcMillis'] as num?)?.toInt() ?? 0;
      final tombLocal = HlcTimestamp(
        millis: tombMillis,
        counter: 0,
        deviceId: localOrigin ?? '',
      );
      nameWins =
          rawNameWins &&
          _compareHlc(
            tombLocal,
            localOrigin,
            nameIncoming,
            remoteOrigin,
            withOriginRank: false,
          );
      geofenceWins =
          rawGeofenceWins &&
          _compareHlc(
            tombLocal,
            localOrigin,
            geofenceIncoming,
            remoteOrigin,
            withOriginRank: false,
          );
      autoWins =
          rawAutoWins &&
          _compareHlc(
            tombLocal,
            localOrigin,
            autoIncoming,
            remoteOrigin,
            withOriginRank: true,
          );
      final remoteTomb = HlcTimestamp(
        millis: remoteUpdatedAt,
        counter: 0,
        deviceId: remoteOrigin ?? '',
      );
      tombstoneWins = _compareHlc(
        tombLocal,
        localOrigin,
        remoteTomb,
        remoteOrigin,
        withOriginRank: false,
      );
    }

    final merged = Map<String, Object?>.from(local);
    if (nameWins) merged['name'] = cloudRow['name'];
    if (geofenceWins) {
      merged['latitude'] = cloudRow['latitude'];
      merged['longitude'] = cloudRow['longitude'];
      merged['radiusM'] = cloudRow['radius_m'];
    }
    if (autoWins) {
      merged['autoName'] = cloudRow['auto_name'];
      merged['autoNameUpdatedAtUtcMillis'] =
          cloudRow['auto_name_updated_at_utc_millis'];
      merged['autoNameSource'] = cloudRow['auto_name_source'];
    }
    // Apply tombstone/metadata when relevant.
    if (!localDeleted && !remoteDeleted) {
      if (nameWins || geofenceWins || autoWins) {
        merged['updatedAtUtcMillis'] = cloudRow['updated_at_utc_millis'];
        merged['origin'] = cloudRow['origin'];
        merged['deletedAtUtcMillis'] = null;
      }
    } else if (!localDeleted && remoteDeleted) {
      if (tombstoneWins) {
        merged['updatedAtUtcMillis'] = cloudRow['updated_at_utc_millis'];
        merged['origin'] = cloudRow['origin'];
        merged['deletedAtUtcMillis'] = cloudRow['deleted_at_utc_millis'];
      } else if (nameWins || geofenceWins || autoWins) {
        // Field wins but delete stale: apply fields only, keep alive.
        merged['updatedAtUtcMillis'] = cloudRow['updated_at_utc_millis'];
        merged['origin'] = cloudRow['origin'];
        merged['deletedAtUtcMillis'] = null;
      }
    } else if (localDeleted && !remoteDeleted) {
      if (nameWins || geofenceWins || autoWins) {
        merged['updatedAtUtcMillis'] = cloudRow['updated_at_utc_millis'];
        merged['origin'] = cloudRow['origin'];
        merged['deletedAtUtcMillis'] = null;
      }
    } else {
      // Both deleted
      if (tombstoneWins) {
        merged['updatedAtUtcMillis'] = cloudRow['updated_at_utc_millis'];
        merged['origin'] = cloudRow['origin'];
        merged['deletedAtUtcMillis'] = cloudRow['deleted_at_utc_millis'];
      }
      // Gated field wins already applied above; keep tombstone if not overwritten.
    }
    merged['id'] = cloudRow['id'] ?? local['id'];
    return merged;
  }

  Map<String, Object?> _mergeJourney(
    Map<String, Object?> local,
    Map<String, Object?> cloudRow,
    Map<String, Object?> remoteMap,
  ) {
    final localHlc = _extractHlc(local);
    final localOrigin = local['origin'] as String?;
    final localDeleted = local['deletedAtUtcMillis'] != null;
    final remoteDeleted = cloudRow['deleted_at_utc_millis'] != null;
    final remoteOrigin = cloudRow['origin'] as String?;
    final remoteUpdatedAt =
        (cloudRow['updated_at_utc_millis'] as num?)?.toInt() ?? 0;
    final nameIncoming = HlcTimestamp(
      millis: (cloudRow['name_hlc_millis'] as num?)?.toInt() ?? 0,
      counter: (cloudRow['name_hlc_counter'] as num?)?.toInt() ?? 0,
      deviceId:
          (cloudRow['name_hlc_device_id'] as String?) ??
          (cloudRow['origin'] as String? ?? ''),
    );
    final noteIncoming = HlcTimestamp(
      millis: (cloudRow['note_hlc_millis'] as num?)?.toInt() ?? 0,
      counter: (cloudRow['note_hlc_counter'] as num?)?.toInt() ?? 0,
      deviceId:
          (cloudRow['note_hlc_device_id'] as String?) ??
          (cloudRow['origin'] as String? ?? ''),
    );
    final timeIncoming = HlcTimestamp(
      millis: (cloudRow['time_range_hlc_millis'] as num?)?.toInt() ?? 0,
      counter: (cloudRow['time_range_hlc_counter'] as num?)?.toInt() ?? 0,
      deviceId:
          (cloudRow['time_range_hlc_device_id'] as String?) ??
          (cloudRow['origin'] as String? ?? ''),
    );
    final rawName = _compareHlc(
      localHlc,
      localOrigin,
      nameIncoming,
      remoteOrigin,
      withOriginRank: false,
    );
    final rawNote = _compareHlc(
      localHlc,
      localOrigin,
      noteIncoming,
      remoteOrigin,
      withOriginRank: false,
    );
    final rawTime = _compareHlc(
      localHlc,
      localOrigin,
      timeIncoming,
      remoteOrigin,
      withOriginRank: false,
    );
    bool nameWins = rawName;
    bool noteWins = rawNote;
    bool timeWins = rawTime;
    bool tombstoneWins = false;
    if (!localDeleted && remoteDeleted) {
      final tombstone = HlcTimestamp(
        millis: remoteUpdatedAt,
        counter: 0,
        deviceId: remoteOrigin ?? '',
      );
      tombstoneWins = _compareHlc(
        localHlc,
        localOrigin,
        tombstone,
        remoteOrigin,
        withOriginRank: false,
      );
    } else if (localDeleted && !remoteDeleted) {
      final tombMillis = (local['updatedAtUtcMillis'] as num?)?.toInt() ?? 0;
      final tombstone = HlcTimestamp(
        millis: tombMillis,
        counter: 0,
        deviceId: localOrigin ?? '',
      );
      nameWins =
          rawName &&
          _compareHlc(
            tombstone,
            localOrigin,
            nameIncoming,
            remoteOrigin,
            withOriginRank: false,
          );
      noteWins =
          rawNote &&
          _compareHlc(
            tombstone,
            localOrigin,
            noteIncoming,
            remoteOrigin,
            withOriginRank: false,
          );
      timeWins =
          rawTime &&
          _compareHlc(
            tombstone,
            localOrigin,
            timeIncoming,
            remoteOrigin,
            withOriginRank: false,
          );
    } else if (localDeleted && remoteDeleted) {
      final tombMillis = (local['updatedAtUtcMillis'] as num?)?.toInt() ?? 0;
      final tombLocal = HlcTimestamp(
        millis: tombMillis,
        counter: 0,
        deviceId: localOrigin ?? '',
      );
      nameWins =
          rawName &&
          _compareHlc(
            tombLocal,
            localOrigin,
            nameIncoming,
            remoteOrigin,
            withOriginRank: false,
          );
      noteWins =
          rawNote &&
          _compareHlc(
            tombLocal,
            localOrigin,
            noteIncoming,
            remoteOrigin,
            withOriginRank: false,
          );
      timeWins =
          rawTime &&
          _compareHlc(
            tombLocal,
            localOrigin,
            timeIncoming,
            remoteOrigin,
            withOriginRank: false,
          );
      final remoteTomb = HlcTimestamp(
        millis: remoteUpdatedAt,
        counter: 0,
        deviceId: remoteOrigin ?? '',
      );
      tombstoneWins = _compareHlc(
        tombLocal,
        localOrigin,
        remoteTomb,
        remoteOrigin,
        withOriginRank: false,
      );
    }
    final merged = Map<String, Object?>.from(local);
    if (nameWins) merged['name'] = cloudRow['name'];
    if (noteWins) merged['note'] = cloudRow['note'];
    if (timeWins) {
      merged['startedAtUtcMillis'] = cloudRow['started_at_utc_millis'];
      merged['endedAtUtcMillis'] = cloudRow['ended_at_utc_millis'];
    }
    if (!localDeleted && !remoteDeleted) {
      if (nameWins || noteWins || timeWins) {
        merged['updatedAtUtcMillis'] = cloudRow['updated_at_utc_millis'];
        merged['origin'] = cloudRow['origin'];
        merged['deletedAtUtcMillis'] = null;
      }
    } else if (!localDeleted && remoteDeleted) {
      if (tombstoneWins) {
        merged['updatedAtUtcMillis'] = cloudRow['updated_at_utc_millis'];
        merged['origin'] = cloudRow['origin'];
        merged['deletedAtUtcMillis'] = cloudRow['deleted_at_utc_millis'];
      } else if (nameWins || noteWins || timeWins) {
        merged['updatedAtUtcMillis'] = cloudRow['updated_at_utc_millis'];
        merged['origin'] = cloudRow['origin'];
        merged['deletedAtUtcMillis'] = null;
      }
    } else if (localDeleted && !remoteDeleted) {
      if (nameWins || noteWins || timeWins) {
        merged['updatedAtUtcMillis'] = cloudRow['updated_at_utc_millis'];
        merged['origin'] = cloudRow['origin'];
        merged['deletedAtUtcMillis'] = null;
      }
    } else {
      if (tombstoneWins) {
        merged['updatedAtUtcMillis'] = cloudRow['updated_at_utc_millis'];
        merged['origin'] = cloudRow['origin'];
        merged['deletedAtUtcMillis'] = cloudRow['deleted_at_utc_millis'];
      }
    }
    merged['id'] = cloudRow['id'] ?? local['id'];
    return merged;
  }

  Map<String, Object?> _mergePreference(
    Map<String, Object?> local,
    Map<String, Object?> cloudRow,
    Map<String, Object?> remoteMap,
  ) {
    final localHlc = _extractHlc(local);
    final localOrigin = local['origin'] as String?;
    final remoteOrigin = cloudRow['origin'] as String?;
    final localDeleted = local['deletedAtUtcMillis'] != null;
    final remoteDeleted = cloudRow['deleted_at_utc_millis'] != null;
    final remoteHlc = _extractHlcFromCloudPref(cloudRow);
    final localTombMillis = (local['updatedAtUtcMillis'] as num?)?.toInt() ?? 0;
    final remoteUpdatedAt =
        (cloudRow['updated_at_utc_millis'] as num?)?.toInt() ?? 0;
    final remoteTomb = HlcTimestamp(
      millis: remoteUpdatedAt,
      counter: 0,
      deviceId: remoteOrigin ?? '',
    );
    final localTomb = HlcTimestamp(
      millis: localTombMillis,
      counter: 0,
      deviceId: localOrigin ?? '',
    );
    final rawValueWins = _compareHlc(
      localHlc,
      localOrigin,
      remoteHlc,
      remoteOrigin,
      withOriginRank: false,
    );
    bool valueWins = rawValueWins;
    bool tombstoneWins = false;
    if (!localDeleted && remoteDeleted) {
      tombstoneWins = _compareHlc(
        localHlc,
        localOrigin,
        remoteTomb,
        remoteOrigin,
        withOriginRank: false,
      );
    } else if (localDeleted && !remoteDeleted) {
      valueWins =
          rawValueWins &&
          _compareHlc(
            localTomb,
            localOrigin,
            remoteHlc,
            remoteOrigin,
            withOriginRank: false,
          );
    } else if (localDeleted && remoteDeleted) {
      valueWins =
          rawValueWins &&
          _compareHlc(
            localTomb,
            localOrigin,
            remoteHlc,
            remoteOrigin,
            withOriginRank: false,
          );
      tombstoneWins = _compareHlc(
        localTomb,
        localOrigin,
        remoteTomb,
        remoteOrigin,
        withOriginRank: false,
      );
    }
    final merged = Map<String, Object?>.from(local);
    if (valueWins) {
      merged['value'] = cloudRow['value'];
    }
    if (!localDeleted && !remoteDeleted) {
      if (valueWins) {
        merged['updatedAtUtcMillis'] = cloudRow['updated_at_utc_millis'];
        merged['origin'] = cloudRow['origin'];
        merged['deletedAtUtcMillis'] = null;
      }
    } else if (!localDeleted && remoteDeleted) {
      if (tombstoneWins) {
        merged['updatedAtUtcMillis'] = cloudRow['updated_at_utc_millis'];
        merged['origin'] = cloudRow['origin'];
        merged['deletedAtUtcMillis'] = cloudRow['deleted_at_utc_millis'];
      } else if (valueWins) {
        merged['updatedAtUtcMillis'] = cloudRow['updated_at_utc_millis'];
        merged['origin'] = cloudRow['origin'];
        merged['deletedAtUtcMillis'] = null;
      }
    } else if (localDeleted && !remoteDeleted) {
      if (valueWins) {
        merged['updatedAtUtcMillis'] = cloudRow['updated_at_utc_millis'];
        merged['origin'] = cloudRow['origin'];
        merged['deletedAtUtcMillis'] = null;
      }
    } else {
      if (tombstoneWins) {
        merged['updatedAtUtcMillis'] = cloudRow['updated_at_utc_millis'];
        merged['origin'] = cloudRow['origin'];
        merged['deletedAtUtcMillis'] = cloudRow['deleted_at_utc_millis'];
      }
    }
    return merged;
  }

  HlcTimestamp _winningPlaceHlc(
    Map<String, Object?> local,
    Map<String, Object?> cloudRow,
  ) {
    final localHlc = _extractHlc(local);
    final localOrigin = local['origin'] as String?;
    final remoteOrigin = cloudRow['origin'] as String?;
    final localDeleted = local['deletedAtUtcMillis'] != null;
    final remoteDeleted = cloudRow['deleted_at_utc_millis'] != null;
    final remoteUpdatedAt =
        (cloudRow['updated_at_utc_millis'] as num?)?.toInt() ?? 0;
    final localUpdatedAt = (local['updatedAtUtcMillis'] as num?)?.toInt() ?? 0;

    // Collect winning field HLCs with correct per-group comparator.
    final winners = <HlcTimestamp>[];
    final nameHlc = HlcTimestamp(
      millis: (cloudRow['name_hlc_millis'] as num?)?.toInt() ?? 0,
      counter: (cloudRow['name_hlc_counter'] as num?)?.toInt() ?? 0,
      deviceId: (cloudRow['name_hlc_device_id'] as String?)?.isNotEmpty == true
          ? cloudRow['name_hlc_device_id'] as String
          : (remoteOrigin ?? ''),
    );
    final geofenceHlc = HlcTimestamp(
      millis: (cloudRow['geofence_hlc_millis'] as num?)?.toInt() ?? 0,
      counter: (cloudRow['geofence_hlc_counter'] as num?)?.toInt() ?? 0,
      deviceId:
          (cloudRow['geofence_hlc_device_id'] as String?)?.isNotEmpty == true
          ? cloudRow['geofence_hlc_device_id'] as String
          : (remoteOrigin ?? ''),
    );
    final autoHlc = HlcTimestamp(
      millis: (cloudRow['auto_name_hlc_millis'] as num?)?.toInt() ?? 0,
      counter: (cloudRow['auto_name_hlc_counter'] as num?)?.toInt() ?? 0,
      deviceId:
          (cloudRow['auto_name_hlc_device_id'] as String?)?.isNotEmpty == true
          ? cloudRow['auto_name_hlc_device_id'] as String
          : (remoteOrigin ?? ''),
    );
    if (_compareHlc(
      localHlc,
      localOrigin,
      nameHlc,
      remoteOrigin,
      withOriginRank: false,
    )) {
      winners.add(nameHlc);
    }
    if (_compareHlc(
      localHlc,
      localOrigin,
      geofenceHlc,
      remoteOrigin,
      withOriginRank: false,
    )) {
      winners.add(geofenceHlc);
    }
    if (_compareHlc(
      localHlc,
      localOrigin,
      autoHlc,
      remoteOrigin,
      withOriginRank: true,
    )) {
      winners.add(autoHlc);
    }

    // Tombstone may also be the winner.
    if (!localDeleted && remoteDeleted) {
      final tombstone = HlcTimestamp(
        millis: remoteUpdatedAt,
        counter: 0,
        deviceId: remoteOrigin ?? '',
      );
      if (_compareHlc(
        localHlc,
        localOrigin,
        tombstone,
        remoteOrigin,
        withOriginRank: false,
      )) {
        winners.add(tombstone);
      }
    } else if (localDeleted && remoteDeleted) {
      final tombLocal = HlcTimestamp(
        millis: localUpdatedAt,
        counter: 0,
        deviceId: localOrigin ?? '',
      );
      final remoteTomb = HlcTimestamp(
        millis: remoteUpdatedAt,
        counter: 0,
        deviceId: remoteOrigin ?? '',
      );
      if (_compareHlc(
        tombLocal,
        localOrigin,
        remoteTomb,
        remoteOrigin,
        withOriginRank: false,
      )) {
        winners.add(remoteTomb);
      }
    }
    if (winners.isEmpty) return localHlc;
    return winners.reduce((a, b) => a.compareTo(b) > 0 ? a : b);
  }

  HlcTimestamp _winningJourneyHlc(
    Map<String, Object?> local,
    Map<String, Object?> cloudRow,
  ) {
    final localHlc = _extractHlc(local);
    final localOrigin = local['origin'] as String?;
    final remoteOrigin = cloudRow['origin'] as String?;
    final localDeleted = local['deletedAtUtcMillis'] != null;
    final remoteDeleted = cloudRow['deleted_at_utc_millis'] != null;
    final remoteUpdatedAt =
        (cloudRow['updated_at_utc_millis'] as num?)?.toInt() ?? 0;
    final localUpdatedAt = (local['updatedAtUtcMillis'] as num?)?.toInt() ?? 0;
    final winners = <HlcTimestamp>[];
    final nameHlc = HlcTimestamp(
      millis: (cloudRow['name_hlc_millis'] as num?)?.toInt() ?? 0,
      counter: (cloudRow['name_hlc_counter'] as num?)?.toInt() ?? 0,
      deviceId: (cloudRow['name_hlc_device_id'] as String?)?.isNotEmpty == true
          ? cloudRow['name_hlc_device_id'] as String
          : (remoteOrigin ?? ''),
    );
    final noteHlc = HlcTimestamp(
      millis: (cloudRow['note_hlc_millis'] as num?)?.toInt() ?? 0,
      counter: (cloudRow['note_hlc_counter'] as num?)?.toInt() ?? 0,
      deviceId: (cloudRow['note_hlc_device_id'] as String?)?.isNotEmpty == true
          ? cloudRow['note_hlc_device_id'] as String
          : (remoteOrigin ?? ''),
    );
    final timeHlc = HlcTimestamp(
      millis: (cloudRow['time_range_hlc_millis'] as num?)?.toInt() ?? 0,
      counter: (cloudRow['time_range_hlc_counter'] as num?)?.toInt() ?? 0,
      deviceId:
          (cloudRow['time_range_hlc_device_id'] as String?)?.isNotEmpty == true
          ? cloudRow['time_range_hlc_device_id'] as String
          : (remoteOrigin ?? ''),
    );
    if (_compareHlc(
      localHlc,
      localOrigin,
      nameHlc,
      remoteOrigin,
      withOriginRank: false,
    )) {
      winners.add(nameHlc);
    }
    if (_compareHlc(
      localHlc,
      localOrigin,
      noteHlc,
      remoteOrigin,
      withOriginRank: false,
    )) {
      winners.add(noteHlc);
    }
    if (_compareHlc(
      localHlc,
      localOrigin,
      timeHlc,
      remoteOrigin,
      withOriginRank: false,
    )) {
      winners.add(timeHlc);
    }
    if (!localDeleted && remoteDeleted) {
      final tombstone = HlcTimestamp(
        millis: remoteUpdatedAt,
        counter: 0,
        deviceId: remoteOrigin ?? '',
      );
      if (_compareHlc(
        localHlc,
        localOrigin,
        tombstone,
        remoteOrigin,
        withOriginRank: false,
      )) {
        winners.add(tombstone);
      }
    } else if (localDeleted && remoteDeleted) {
      final tombLocal = HlcTimestamp(
        millis: localUpdatedAt,
        counter: 0,
        deviceId: localOrigin ?? '',
      );
      final remoteTomb = HlcTimestamp(
        millis: remoteUpdatedAt,
        counter: 0,
        deviceId: remoteOrigin ?? '',
      );
      if (_compareHlc(
        tombLocal,
        localOrigin,
        remoteTomb,
        remoteOrigin,
        withOriginRank: false,
      )) {
        winners.add(remoteTomb);
      }
    }
    if (winners.isEmpty) return localHlc;
    return winners.reduce((a, b) => a.compareTo(b) > 0 ? a : b);
  }

  HlcTimestamp _winningPreferenceHlc(
    Map<String, Object?> local,
    Map<String, Object?> cloudRow,
  ) {
    final localHlc = _extractHlc(local);
    final remoteHlc = _extractHlcFromCloudPref(cloudRow);
    final localOrigin = local['origin'] as String?;
    final remoteOrigin = cloudRow['origin'] as String?;
    final candidates = <HlcTimestamp>[];
    if (_compareHlc(
      localHlc,
      localOrigin,
      remoteHlc,
      remoteOrigin,
      withOriginRank: false,
    )) {
      candidates.add(remoteHlc);
    }
    final remoteUpdatedAt =
        (cloudRow['updated_at_utc_millis'] as num?)?.toInt() ?? 0;
    final localUpdatedAt = (local['updatedAtUtcMillis'] as num?)?.toInt() ?? 0;
    final localDeleted = local['deletedAtUtcMillis'] != null;
    final remoteDeleted = cloudRow['deleted_at_utc_millis'] != null;
    if (!localDeleted && remoteDeleted) {
      final tombstone = HlcTimestamp(
        millis: remoteUpdatedAt,
        counter: 0,
        deviceId: remoteOrigin ?? '',
      );
      if (_compareHlc(
        localHlc,
        localOrigin,
        tombstone,
        remoteOrigin,
        withOriginRank: false,
      )) {
        candidates.add(tombstone);
      }
    } else if (localDeleted && remoteDeleted) {
      final tombLocal = HlcTimestamp(
        millis: localUpdatedAt,
        counter: 0,
        deviceId: localOrigin ?? '',
      );
      final remoteTomb = HlcTimestamp(
        millis: remoteUpdatedAt,
        counter: 0,
        deviceId: remoteOrigin ?? '',
      );
      if (_compareHlc(
        tombLocal,
        localOrigin,
        remoteTomb,
        remoteOrigin,
        withOriginRank: false,
      )) {
        candidates.add(remoteTomb);
      }
    }
    if (candidates.isEmpty) return localHlc;
    return candidates.reduce((a, b) => a.compareTo(b) > 0 ? a : b);
  }

  Map<String, Object?> _cloudPlaceToLocal(Map<String, Object?> cloud) => {
    'id': cloud['id'],
    'name': cloud['name'],
    'latitude': cloud['latitude'],
    'longitude': cloud['longitude'],
    'radiusM': cloud['radius_m'],
    'createdAtUtcMillis': cloud['created_at_utc_millis'],
    'updatedAtUtcMillis': cloud['updated_at_utc_millis'],
    'origin': cloud['origin'],
    'deletedAtUtcMillis': cloud['deleted_at_utc_millis'],
    'autoName': cloud['auto_name'],
    'autoNameUpdatedAtUtcMillis': cloud['auto_name_updated_at_utc_millis'],
    'autoNameSource': cloud['auto_name_source'],
    // Keep group HLCs for comparison but also fan to single
    'hlcMillis':
        (cloud['name_hlc_millis'] as num?)?.toInt() ??
        (cloud['updated_at_utc_millis'] as num?)?.toInt() ??
        0,
    'hlcCounter': (cloud['name_hlc_counter'] as num?)?.toInt() ?? 0,
    'hlcDeviceId':
        (cloud['name_hlc_device_id'] as String?) ??
        (cloud['origin'] as String? ?? ''),
    'hlc': {
      'millis': (cloud['name_hlc_millis'] as num?)?.toInt() ?? 0,
      'counter': (cloud['name_hlc_counter'] as num?)?.toInt() ?? 0,
      'deviceId': (cloud['name_hlc_device_id'] as String?) ?? '',
    },
  };

  Map<String, Object?> _cloudSessionCostToLocal(Map<String, Object?> cloud) => {
    'sessionId': cloud['session_id'],
    'costPerKwh': cloud['cost_per_kwh'],
    'paidAmount': cloud['paid_amount'],
    'costCurrency': cloud['cost_currency'],
    'updatedAtUtcMillis': cloud['updated_at_utc_millis'],
    'origin': cloud['origin'],
    'hlcMillis': (cloud['cost_hlc_millis'] as num?)?.toInt() ?? 0,
    'hlcCounter': (cloud['cost_hlc_counter'] as num?)?.toInt() ?? 0,
    'hlcDeviceId': (cloud['cost_hlc_device_id'] as String?) ?? '',
    'hlc': {
      'millis': (cloud['cost_hlc_millis'] as num?)?.toInt() ?? 0,
      'counter': (cloud['cost_hlc_counter'] as num?)?.toInt() ?? 0,
      'deviceId': (cloud['cost_hlc_device_id'] as String?) ?? '',
    },
  };

  Map<String, Object?> _cloudJourneyToLocal(Map<String, Object?> cloud) => {
    'id': cloud['id'],
    'name': cloud['name'],
    'startedAtUtcMillis': cloud['started_at_utc_millis'],
    'endedAtUtcMillis': cloud['ended_at_utc_millis'],
    'note': cloud['note'],
    'createdAtUtcMillis': cloud['created_at_utc_millis'],
    'updatedAtUtcMillis': cloud['updated_at_utc_millis'],
    'origin': cloud['origin'],
    'deletedAtUtcMillis': cloud['deleted_at_utc_millis'],
    'hlcMillis': (cloud['name_hlc_millis'] as num?)?.toInt() ?? 0,
    'hlcCounter': (cloud['name_hlc_counter'] as num?)?.toInt() ?? 0,
    'hlcDeviceId': (cloud['name_hlc_device_id'] as String?) ?? '',
    'hlc': {
      'millis': (cloud['name_hlc_millis'] as num?)?.toInt() ?? 0,
      'counter': (cloud['name_hlc_counter'] as num?)?.toInt() ?? 0,
      'deviceId': (cloud['name_hlc_device_id'] as String?) ?? '',
    },
  };

  Map<String, Object?> _cloudPreferenceToLocal(Map<String, Object?> cloud) => {
    'scope': cloud['scope'],
    'key': cloud['key'],
    'value': cloud['value'],
    'updatedAtUtcMillis': cloud['updated_at_utc_millis'],
    'origin': cloud['origin'],
    'deletedAtUtcMillis': cloud['deleted_at_utc_millis'],
    'hlcMillis': (cloud['hlc_millis'] as num?)?.toInt() ?? 0,
    'hlcCounter': (cloud['hlc_counter'] as num?)?.toInt() ?? 0,
    'hlcDeviceId': (cloud['hlc_device_id'] as String?) ?? '',
    'hlc': {
      'millis': (cloud['hlc_millis'] as num?)?.toInt() ?? 0,
      'counter': (cloud['hlc_counter'] as num?)?.toInt() ?? 0,
      'deviceId': (cloud['hlc_device_id'] as String?) ?? '',
    },
  };

  List<List<T>> _chunks<T>(List<T> items, int size) {
    final out = <List<T>>[];
    for (var i = 0; i < items.length; i += size) {
      out.add(
        items.sublist(i, i + size > items.length ? items.length : i + size),
      );
    }
    return out;
  }
}

/// Result of an annotation cloud sync run.
class AnnotationCloudSyncReport {
  const AnnotationCloudSyncReport({
    this.perStream = const {},
    this.errors = const {},
  });

  final Map<String, int> perStream;
  final Map<String, Object> errors;

  int get total => perStream.values.fold(0, (a, b) => a + b);

  bool get hasErrors => errors.isNotEmpty;

  @override
  String toString() => 'AnnotationCloudSyncReport($perStream, errors: $errors)';
}

/// No-op sink used in production until Supabase is wired.
class NoopCloudSink implements CloudSink {
  @override
  Future<void> upsert(
    String table,
    List<Map<String, Object?>> rows, {
    required List<String> conflictColumns,
    required bool merge,
  }) async {}

  @override
  Future<Set<String>> ownedVehicles(Set<String> ids) async => ids;

  @override
  Future<List<Map<String, Object?>>> fetch(String table) async => const [];
  @override
  Future<List<Map<String, Object?>>> fetchRange(
    String table, {
    required int offset,
    required int limit,
  }) async {
    final all = await fetch(table);
    if (offset >= all.length) return const [];
    final end = (offset + limit).clamp(0, all.length);
    return all.sublist(offset, end);
  }
}
