import 'package:telemetry_core/telemetry_core.dart';
import 'companion_database.dart';

/// The reference implementation of [TelemetryStore], backed by the phone's SQLite archive.
///
/// Holds no privileged access: an interface [SqfliteStore] can serve is an interface
/// any replica (Room, Postgres) can serve (Section 4.4).
class SqfliteStore implements TelemetryStore {
  SqfliteStore(this.db);

  final CompanionDatabase db;

  @override
  Future<SessionListPage> listSessions({
    SessionFilter? filter,
    PageRequest? page,
  }) async {
    final effectivePage = page ?? const PageRequest();
    final whereClauses = <String>[];
    final whereArgs = <Object?>[];

    if (filter?.kind != null) {
      whereClauses.add('kind = ?');
      whereArgs.add(filter!.kind!.name.toUpperCase());
    }
    if (filter?.status != null) {
      whereClauses.add('status = ?');
      whereArgs.add(filter!.status!);
    }
    if (filter?.fromUtcMillis != null) {
      whereClauses.add('startedAtUtcMillis >= ?');
      whereArgs.add(filter!.fromUtcMillis!);
    }
    if (filter?.toUtcMillis != null) {
      whereClauses.add('startedAtUtcMillis <= ?');
      whereArgs.add(filter!.toUtcMillis!);
    }

    final whereSql = whereClauses.isNotEmpty
        ? whereClauses.join(' AND ')
        : null;

    final totalCount = await db.countSessionsFiltered(
      where: whereSql,
      whereArgs: whereArgs.isNotEmpty ? whereArgs : null,
    );

    final rawRows = await db.querySessionsFiltered(
      where: whereSql,
      whereArgs: whereArgs.isNotEmpty ? whereArgs : null,
      limit: effectivePage.limit,
      offset: effectivePage.offset,
    );

    final places = await _livePlaces();
    final sessions = [
      for (final r in rawRows)
        await _composeSession(_parseSessionRecord(r), places),
    ];
    final hasMore = effectivePage.offset + sessions.length < totalCount;

    return SessionListPage(
      sessions: sessions,
      totalCount: totalCount,
      page: effectivePage,
      hasMore: hasMore,
    );
  }

  @override
  Future<SessionDetail?> session(String id) async {
    final row = await db.session(id);
    if (row == null) return null;

    final places = await _livePlaces();
    final sessionRecord = await _composeSession(
      _parseSessionRecord(row),
      places,
    );
    final rawEvents = await db.eventsForSession(id);
    final events = [for (final e in rawEvents) _parseEventRecord(e)];
    final rawTrack = await db.trackFor(id);
    final track = rawTrack != null ? trackRowFromWire(rawTrack) : null;

    return SessionDetail(session: sessionRecord, events: events, track: track);
  }

  /// Applies the annotation side over a stored record: the freshest cost
  /// this phone holds (a local edit outvotes the car's composed row) and the
  /// place whose radius contains the session's start.
  Future<SessionRecord> _composeSession(
    SessionRecord record,
    List<InsightPlace> places,
  ) async {
    final cost = await db.sessionCost(record.id);
    var composed = record;
    if (cost != null) {
      composed = composed.copyWith(
        costPerKwh: (cost['costPerKwh'] as num?)?.toDouble(),
        paidAmount: (cost['paidAmount'] as num?)?.toDouble(),
        costCurrency: cost['costCurrency'] as String?,
      );
    }
    final place = placeNameAt(
      latitude: record.startLatitude,
      longitude: record.startLongitude,
      places: places,
    );
    if (place != null) composed = composed.copyWith(startPlace: place);
    return composed;
  }

  /// The live place rows this phone holds: the tombstones are gone, and a
  /// place the phone wrote itself is already among the rows.
  Future<List<InsightPlace>> _livePlaces() async {
    final rows = await db.allPlaces();
    return [
      for (final row in rows)
        if (row['deletedAtUtcMillis'] == null)
          InsightPlace(
            id: (row['id'] as String?) ?? '',
            name: (row['name'] as String?) ?? '',
            latitude: (row['latitude'] as num?)?.toDouble() ?? 0,
            longitude: (row['longitude'] as num?)?.toDouble() ?? 0,
            radiusM:
                (row['radiusM'] as num?)?.toDouble() ?? kInsightPlaceRadiusM,
            autoName: row['autoName'] as String?,
            autoNameUpdatedAtUtcMillis:
                (row['autoNameUpdatedAtUtcMillis'] as num?)?.toInt(),
            autoNameSource: row['autoNameSource'] as String?,
          ),
    ];
  }

  @override
  Future<TelemetrySeries> series(
    String id, {
    Set<String>? keys,
    int? widthMillis,
  }) async {
    final rawIntervals = await db.intervalsFor(id);
    final intervals = [for (final r in rawIntervals) _parseIntervalRecord(r)];
    // Same monotonic placement as the car's RoomStore, so the phone and the
    // head unit draw the same bars from the same rows.
    final positionOf = intervalPositionOf(intervals);
    final reducedIntervals = widthMillis != null && widthMillis > 60000
        ? reduceIntervalRecordsByIndex(
            intervals,
            widthMillis: widthMillis,
            positionOf: positionOf,
          )
        : (List<IntervalRecord>.from(intervals)
            ..sort((a, b) => positionOf(a).compareTo(positionOf(b))));

    return TelemetrySeries(
      sessionId: id,
      intervals: reducedIntervals,
      samples: const {},
    );
  }

  /// Updates the cost of a charge and queues it for synchronization.
  Future<void> updateChargeCost({
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
    await db.upsertSessionCost(sessionId, now, kAnnotationOriginPhone, row);
    await db.enqueueAnnotationPush(SyncStreamType.sessionCosts.name, row);
  }

  // --- Parser Helpers ------------------------------------------------------

  static SessionRecord _parseSessionRecord(Map<String, Object?> map) {
    final rollup = SessionRollup(
      distance: _measurement(map['rollupDistanceKm'], unit: 'km'),
      traction: _measurement(map['rollupTractionWh'], unit: 'Wh'),
      regen: _measurement(map['rollupRegenWh'], unit: 'Wh'),
      auxiliary: _measurement(map['rollupAuxiliaryWh'], unit: 'Wh'),
      climate: _measurement(
        map['rollupClimateWh'] ?? map['climateWh'],
        unit: 'Wh',
      ),
      delivered: _measurement(
        map['rollupDeliveredWh'] ??
            map['deliveredWh'] ??
            (map['estimatedEnergyKwh'] != null
                ? (map['estimatedEnergyKwh'] as num).toDouble() * 1000.0
                : null),
        unit: 'Wh',
      ),
      integratedSeconds: _measurement(
        map['rollupIntegratedSeconds'] ??
            map['integratedSeconds'] ??
            map['coveredSeconds'],
        unit: 's',
      ),
    );

    final kindName = (map['kind'] as String?) ?? 'TRIP';
    final kind = SessionKind.fromName(kindName);

    return SessionRecord(
      id: (map['id'] as String?) ?? '',
      vehicleId: (map['vehicleId'] as String?) ?? 'unassigned',
      kind: kind,
      status: (map['status'] as String?) ?? 'UNKNOWN',
      startedAtUtcMillis: (map['startedAtUtcMillis'] as num?)?.toInt() ?? 0,
      startedAtElapsedNanos:
          (map['startedAtElapsedNanos'] as num?)?.toInt() ?? 0,
      startedAtBootCount: (map['startedAtBootCount'] as num?)?.toInt(),
      endedAtUtcMillis: (map['endedAtUtcMillis'] as num?)?.toInt(),
      endedAtElapsedNanos: (map['endedAtElapsedNanos'] as num?)?.toInt(),
      endedAtBootCount: (map['endedAtBootCount'] as num?)?.toInt(),
      durationMillis: (map['durationMillis'] as num?)?.toInt(),
      rollup: rollup,
      startOdometer: _measurement(map['startOdometerKm'], unit: 'km'),
      endOdometer: _measurement(map['endOdometerKm'], unit: 'km'),
      startSoc: _measurement(map['startSocPercent'], unit: '%'),
      endSoc: _measurement(map['endSocPercent'], unit: '%'),
      minSoc: _measurement(map['minSocPercent'], unit: '%'),
      maxSoc: _measurement(map['maxSocPercent'], unit: '%'),
      socAgreesWithIntegral: map['socAgreesWithIntegral'] as String?,
      startAmbientTemp: _measurement(map['startAmbientTempC'], unit: '°C'),
      endAmbientTemp: _measurement(map['endAmbientTempC'], unit: '°C'),
      meanAmbientTemp: _measurement(map['meanAmbientTempC'], unit: '°C'),
      plugType: (map['plugType'] as num?)?.toInt(),
      costPerKwh: (map['costPerKwh'] as num?)?.toDouble(),
      paidAmount: (map['paidAmount'] as num?)?.toDouble(),
      costCurrency: map['costCurrency'] as String?,
      chargeStartedAtUtcMillis: (map['chargeStartedAtUtcMillis'] as num?)
          ?.toInt(),
      chargeEndedAtUtcMillis: (map['chargeEndedAtUtcMillis'] as num?)?.toInt(),
      plugDisconnectedAtUtcMillis: (map['plugDisconnectedAtUtcMillis'] as num?)
          ?.toInt(),
      movementStartedAtUtcMillis: (map['movementStartedAtUtcMillis'] as num?)
          ?.toInt(),
      chargeEndReason: map['chargeEndReason'] as String?,
      endReason: map['endReason'] as String?,
      startLatitude: (map['startLatitude'] as num?)?.toDouble(),
      startLongitude: (map['startLongitude'] as num?)?.toDouble(),
      startAltitudeM: (map['startAltitudeM'] as num?)?.toDouble(),
      startGpsAccuracyM: (map['startGpsAccuracyM'] as num?)?.toDouble(),
      startGear: (map['startGear'] as num?)?.toInt(),
      startPlace: map['startPlace'] as String?,
      startPowerKw: (map['startPowerKw'] as num?)?.toDouble(),
      movementStartedAtElapsedNanos:
          (map['movementStartedAtElapsedNanos'] as num?)?.toInt(),
      chargeStartedAtElapsedNanos: (map['chargeStartedAtElapsedNanos'] as num?)
          ?.toInt(),
      chargeEndedAtElapsedNanos: (map['chargeEndedAtElapsedNanos'] as num?)
          ?.toInt(),
      movementStartedAtBootCount: (map['movementStartedAtBootCount'] as num?)
          ?.toInt(),
      chargeStartedAtBootCount: (map['chargeStartedAtBootCount'] as num?)
          ?.toInt(),
      chargeEndedAtBootCount: (map['chargeEndedAtBootCount'] as num?)?.toInt(),
      plugDisconnectedAtElapsedNanos:
          (map['plugDisconnectedAtElapsedNanos'] as num?)?.toInt(),
      plugDisconnectedAtBootCount: (map['plugDisconnectedAtBootCount'] as num?)
          ?.toInt(),
      noLongerReducible: (map['noLongerReducible'] as bool?) ?? false,
      createdAtUtcMillis: (map['createdAtUtcMillis'] as num?)?.toInt() ?? 0,
      updatedAtUtcMillis: (map['updatedAtUtcMillis'] as num?)?.toInt() ?? 0,
      climbM: (map['climbM'] as num?)?.toDouble(),
      descentM: (map['descentM'] as num?)?.toDouble(),
      fixCount: (map['fixCount'] as num?)?.toInt(),
    );
  }

  static TelemetryEventRecord _parseEventRecord(Map<String, Object?> map) {
    return TelemetryEventRecord(
      id: (map['id'] as num?)?.toInt() ?? 0,
      sessionId: map['sessionId'] as String?,
      type: (map['type'] as String?) ?? '',
      occurredAtUtcMillis: (map['occurredAtUtcMillis'] as num?)?.toInt() ?? 0,
      occurredAtElapsedNanos:
          (map['occurredAtElapsedNanos'] as num?)?.toInt() ?? 0,
      signalKey: (map['signalId'] ?? map['signalKey']) as String?,
      value: map['value']?.toString(),
      previousValue: map['previousValue']?.toString(),
      quality: map['quality'] as String?,
      source: map['source'] as String?,
      details: (map['details'] as String?) ?? '',
    );
  }

  static IntervalRecord _parseIntervalRecord(Map<String, Object?> map) {
    return IntervalRecord(
      sessionId: (map['sessionId'] as String?) ?? '',
      startUtcMillis: (map['startUtcMillis'] as num?)?.toInt() ?? 0,
      widthMillis: (map['widthMillis'] as num?)?.toInt() ?? 60000,
      traction: _measurement(map['tractionWh'], unit: 'Wh'),
      regen: _measurement(map['regenWh'] ?? map['regeneratedWh'], unit: 'Wh'),
      auxiliary: _measurement(map['auxiliaryWh'], unit: 'Wh'),
      climate: _measurement(map['climateWh'], unit: 'Wh'),
      delivered: _measurement(map['deliveredWh'], unit: 'Wh'),
      distance: _measurement(
        map['distanceKm'] ??
            map['speedDistanceKm'] ??
            map['odometerDistanceKm'],
        unit: 'km',
      ),
      coveredSeconds:
          (map['coveredSeconds'] as num?)?.toDouble() ??
          (map['integratedSeconds'] as num?)?.toDouble() ??
          0.0,
      climateCoveredSeconds:
          (map['climateCoveredSeconds'] as num?)?.toDouble() ??
          (map['climateIntegratedSeconds'] as num?)?.toDouble() ??
          0.0,
      speedCoveredSeconds:
          (map['speedCoveredSeconds'] as num?)?.toDouble() ??
          (map['speedIntegratedSeconds'] as num?)?.toDouble() ??
          0.0,
      deliveredCoveredSeconds:
          (map['deliveredCoveredSeconds'] as num?)?.toDouble() ??
          (map['coveredSeconds'] as num?)?.toDouble() ??
          (map['integratedSeconds'] as num?)?.toDouble() ??
          0.0,
      startSoc: _measurement(
        map['startSoc'] ?? map['startSocPercent'],
        unit: '%',
      ),
      endSoc: _measurement(map['endSoc'] ?? map['endSocPercent'], unit: '%'),
      startVoltage: _measurement(map['startVoltage'], unit: 'V'),
      endVoltage: _measurement(map['endVoltage'], unit: 'V'),
      startElapsedNanos: (map['startElapsedNanos'] as num?)?.toInt(),
      startBootCount: (map['startBootCount'] as num?)?.toInt(),
      timeState: (map['timeState'] as String?) ?? 'unknown',
      correctedFromUtcMillis: (map['correctedFromUtcMillis'] as num?)?.toInt(),
    );
  }

  static Measurement _measurement(Object? val, {required String unit}) {
    if (val == null) {
      return Measurement.unreported(unit: unit);
    }
    final numVal = (val as num).toDouble();
    return Measurement.measured(numVal, unit: unit);
  }
}
