import 'dart:convert';
import 'package:telemetry_core/telemetry_core.dart';

import 'mock_telemetry_data.dart';

/// In-memory implementation of [TelemetryStore] for testing and mock mode.
class MockTelemetryStore implements TelemetryStore {
  MockTelemetryStore({
    List<SessionRecord>? sessions,
    Map<String, List<TelemetryEventRecord>>? events,
    Map<String, List<IntervalRecord>>? intervals,
    Map<String, Map<String, List<SamplePoint>>>? samples,
    Map<String, TrackRow?>? tracks,
  }) : _sessions = sessions ?? [],
       _events = events ?? {},
       _intervals = intervals ?? {},
       _samples = samples ?? {},
       _tracks = tracks ?? {};

  final List<SessionRecord> _sessions;
  final Map<String, List<TelemetryEventRecord>> _events;
  final Map<String, List<IntervalRecord>> _intervals;
  final Map<String, Map<String, List<SamplePoint>>> _samples;
  final Map<String, TrackRow?> _tracks;

  /// Loads mock store data from a JSON string or asset.
  static MockTelemetryStore fromJson(String jsonStr) {
    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    final cases = (map['cases'] as List<dynamic>?) ?? [];
    final sessions = <SessionRecord>[];
    final events = <String, List<TelemetryEventRecord>>{};
    final intervals = <String, List<IntervalRecord>>{};
    final samples = <String, Map<String, List<SamplePoint>>>{};

    for (final c in cases) {
      final sessionMap = c['session'] as Map<String, dynamic>;
      final sessionId = sessionMap['id'] as String;

      final sessionRecord = _parseSession(sessionMap);
      sessions.add(sessionRecord);

      final eventList = (c['events'] as List<dynamic>?) ?? [];
      events[sessionId] = [
        for (final e in eventList) _parseEvent(e as Map<String, dynamic>),
      ];

      final intervalList = (c['intervals'] as List<dynamic>?) ?? [];
      intervals[sessionId] = [
        for (final inv in intervalList)
          _parseInterval(inv as Map<String, dynamic>),
      ];

      final sampleList = (c['samples'] as List<dynamic>?) ?? [];
      final sampleMap = <String, List<SamplePoint>>{};
      for (final s in sampleList) {
        final smap = s as Map<String, dynamic>;
        final key = (smap['key'] as String?) ?? 'UNKNOWN';
        sampleMap.putIfAbsent(key, () => []).add(_parseSample(smap));
      }
      samples[sessionId] = sampleMap;
    }

    return MockTelemetryStore(
      sessions: sessions,
      events: events,
      intervals: intervals,
      samples: samples,
    );
  }

  @override
  Future<SessionListPage> listSessions({
    SessionFilter? filter,
    PageRequest? page,
  }) async {
    final effectivePage = page ?? const PageRequest();
    final filtered = _sessions.where((s) {
      if (filter?.kind != null && s.kind != filter!.kind) return false;
      if (filter?.status != null && s.status != filter!.status) return false;
      if (filter?.fromUtcMillis != null &&
          s.startedAtUtcMillis < filter!.fromUtcMillis!) {
        return false;
      }
      if (filter?.toUtcMillis != null &&
          s.startedAtUtcMillis > filter!.toUtcMillis!) {
        return false;
      }
      return true;
    }).toList();

    filtered.sort(
      (a, b) => b.startedAtUtcMillis.compareTo(a.startedAtUtcMillis),
    );

    final paged = filtered
        .skip(effectivePage.offset)
        .take(effectivePage.limit)
        .toList();

    return SessionListPage(
      sessions: paged,
      totalCount: filtered.length,
      page: effectivePage,
      hasMore: effectivePage.offset + paged.length < filtered.length,
    );
  }

  @override
  Future<SessionDetail?> session(String id) async {
    final sessionRecord = _sessions.where((s) => s.id == id).firstOrNull;
    if (sessionRecord == null) return null;

    final sessionEvents = _events[id] ?? const [];
    final track = _tracks[id];
    return SessionDetail(
      session: sessionRecord,
      events: sessionEvents,
      track: track,
    );
  }

  @override
  Future<TelemetrySeries> series(
    String id, {
    Set<String>? keys,
    int? widthMillis,
  }) async {
    final sessionIntervals = _intervals[id] ?? const [];
    // Same monotonic placement as the real stores, so a mock cannot draw a
    // different chart than Room or SQLite would from the same rows.
    final positionOf = intervalPositionOf(sessionIntervals);

    final reducedIntervals = widthMillis != null && widthMillis > 60000
        ? reduceIntervalRecordsByIndex(
            sessionIntervals,
            widthMillis: widthMillis,
            positionOf: positionOf,
          )
        : (List<IntervalRecord>.from(sessionIntervals)
            ..sort((a, b) => positionOf(a).compareTo(positionOf(b))));

    final allSamples = _samples[id] ?? const {};
    final filteredSamples = <String, List<SamplePoint>>{};

    if (keys != null && keys.isNotEmpty) {
      for (final key in keys) {
        if (allSamples.containsKey(key)) {
          filteredSamples[key] = allSamples[key]!;
        }
      }
    } else {
      filteredSamples.addAll(allSamples);
    }

    return TelemetrySeries(
      sessionId: id,
      intervals: reducedIntervals,
      samples: filteredSamples,
    );
  }

  // --- Parser Helpers ------------------------------------------------------

  static SessionRecord _parseSession(Map<String, dynamic> map) {
    final rollup = SessionRollup(
      distance: _measurement(map['rollupDistanceKm'], unit: 'km'),
      traction: _measurement(map['rollupTractionWh'], unit: 'Wh'),
      regen: _measurement(map['rollupRegenWh'], unit: 'Wh'),
      auxiliary: _measurement(map['rollupAuxiliaryWh'], unit: 'Wh'),
      climate: _measurement(map['rollupClimateWh'], unit: 'Wh'),
      delivered: _measurement(map['rollupDeliveredWh'], unit: 'Wh'),
      integratedSeconds: _measurement(
        map['rollupIntegratedSeconds'],
        unit: 's',
      ),
    );

    return SessionRecord(
      id: map['id'] as String,
      vehicleId: map['vehicleId'] as String,
      kind: SessionKind.fromName(map['kind'] as String),
      status: map['status'] as String,
      startedAtUtcMillis: (map['startedAtUtcMillis'] as num).toInt(),
      startedAtElapsedNanos: (map['startedAtElapsedNanos'] as num).toInt(),
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
      noLongerReducible: (map['noLongerReducible'] as bool?) ?? false,
      createdAtUtcMillis: (map['createdAtUtcMillis'] as num).toInt(),
      updatedAtUtcMillis: (map['updatedAtUtcMillis'] as num).toInt(),
    );
  }

  static TelemetryEventRecord _parseEvent(Map<String, dynamic> map) {
    return TelemetryEventRecord(
      id: (map['id'] as num).toInt(),
      sessionId: map['sessionId'] as String?,
      type: map['type'] as String,
      occurredAtUtcMillis: (map['occurredAtUtcMillis'] as num).toInt(),
      occurredAtElapsedNanos: (map['occurredAtElapsedNanos'] as num).toInt(),
      signalKey: (map['signalId'] ?? map['signalKey']) as String?,
      value: map['value']?.toString(),
      previousValue: map['previousValue']?.toString(),
      quality: map['quality'] as String?,
      source: map['source'] as String?,
      details: (map['details'] as String?) ?? '',
    );
  }

  static IntervalRecord _parseInterval(Map<String, dynamic> map) {
    return IntervalRecord(
      sessionId: map['sessionId'] as String,
      startUtcMillis: (map['startUtcMillis'] as num).toInt(),
      widthMillis: (map['widthMillis'] as num?)?.toInt() ?? 60000,
      traction: _measurement(map['tractionWh'], unit: 'Wh'),
      regen: _measurement(map['regenWh'] ?? map['regeneratedWh'], unit: 'Wh'),
      auxiliary: _measurement(map['auxiliaryWh'], unit: 'Wh'),
      climate: _measurement(map['climateWh'], unit: 'Wh'),
      delivered: _measurement(map['deliveredWh'], unit: 'Wh'),
      distance: _measurement(
        map['distanceKm'] ?? map['speedDistanceKm'],
        unit: 'km',
      ),
      coveredSeconds: (map['coveredSeconds'] as num?)?.toDouble() ?? 0.0,
      climateCoveredSeconds:
          (map['climateCoveredSeconds'] as num?)?.toDouble() ?? 0.0,
      speedCoveredSeconds:
          (map['speedCoveredSeconds'] as num?)?.toDouble() ?? 0.0,
      deliveredCoveredSeconds:
          (map['deliveredCoveredSeconds'] as num?)?.toDouble() ?? 0.0,
      startSoc: _measurement(
        map['startSoc'] ?? map['startSocPercent'],
        unit: '%',
      ),
      endSoc: _measurement(map['endSoc'] ?? map['endSocPercent'], unit: '%'),
      startVoltage: _measurement(map['startVoltage'], unit: 'V'),
      endVoltage: _measurement(map['endVoltage'], unit: 'V'),
    );
  }

  static SamplePoint _parseSample(Map<String, dynamic> map) {
    return SamplePoint(
      tUtcMillis: (map['tUtcMillis'] as num).toInt(),
      tElapsedNanos: (map['tElapsedNanos'] as num).toInt(),
      bootCount: (map['bootCount'] as num?)?.toInt(),
      value: _measurement(map['value'], unit: ''),
      groupId: map['groupId'] as String?,
    );
  }
}

Measurement _measurement(Object? val, {required String unit}) {
  if (val == null) {
    return Measurement.unreported(unit: unit);
  }
  return Measurement.measured((val as num).toDouble(), unit: unit);
}

/// The mock car's sessions, as the store answers them.
///
/// The mock has always held its rows in [MockTelemetryData]. This states them
/// once more in the store's shape rather than keeping a second set of mock
/// drives: one mock car, one set of sessions, three questions.
MockTelemetryStore buildMockTelemetryStore(MockTelemetryData mock) {
  final sessions = <SessionRecord>[];
  final intervals = <String, List<IntervalRecord>>{};
  final samples = <String, Map<String, List<SamplePoint>>>{};
  final tracks = <String, TrackRow?>{};

  void add(Map<String, Object?> row, SessionKind kind) {
    final record = _mockRecord(row, kind);
    sessions.add(record);
    intervals[record.id] = _mockIntervals(mock, record);
    tracks[record.id] = _mockTrack(mock, record);
  }

  for (final row in _rowsOf(mock.tripSessions(limit: 100))) {
    add(row, SessionKind.trip);
  }
  for (final row in _rowsOf(mock.chargeSessions(limit: 100))) {
    add(row, SessionKind.charge);
  }

  return MockTelemetryStore(
    sessions: sessions,
    intervals: intervals,
    samples: samples,
    tracks: tracks,
  );
}

List<Map<String, Object?>> _rowsOf(Map<String, Object?> answer) => [
  for (final row in (answer['sessions'] as List<Object?>? ?? const []))
    if (row is Map) row.cast<String, Object?>(),
];

SessionRecord _mockRecord(Map<String, Object?> row, SessionKind kind) {
  double? number(String key) => (row[key] as num?)?.toDouble();
  int? whole(String key) => (row[key] as num?)?.toInt();

  final startedAtUtcMillis =
      whole('startedAtUtcMillis') ?? whole('plugConnectedAtUtcMillis') ?? 0;
  final startedAtElapsedNanos =
      whole('startedAtElapsedNanos') ??
      whole('plugConnectedAtElapsedNanos') ??
      0;
  final endedAtUtcMillis =
      whole('endedAtUtcMillis') ??
      whole('plugDisconnectedAtUtcMillis') ??
      whole('chargeEndedAtUtcMillis');
  final endedAtElapsedNanos =
      whole('endedAtElapsedNanos') ??
      whole('plugDisconnectedAtElapsedNanos') ??
      whole('chargeEndedAtElapsedNanos');

  Measurement measurement(String key, String unit) {
    final value = number(key);
    return value == null
        ? Measurement.unreported(unit: unit)
        : Measurement.measured(value, unit: unit);
  }

  return SessionRecord(
    id: (row['id'] as String?) ?? '',
    vehicleId: 'mock',
    kind: kind,
    status: (row['status'] as String?) ?? 'UNKNOWN',
    startedAtUtcMillis: startedAtUtcMillis,
    startedAtElapsedNanos: startedAtElapsedNanos,
    endedAtUtcMillis: endedAtUtcMillis,
    endedAtElapsedNanos: endedAtElapsedNanos,
    durationMillis: endedAtUtcMillis == null
        ? null
        : endedAtUtcMillis - startedAtUtcMillis,
    rollup: SessionRollup(
      distance: Measurement.combine(
        measurement('startOdometerKm', 'km'),
        measurement('endOdometerKm', 'km'),
        unit: 'km',
        compute: (a, b) => b - a,
      ),
      traction: const Measurement.unreported(unit: 'Wh'),
      regen: const Measurement.unreported(unit: 'Wh'),
      auxiliary: const Measurement.unreported(unit: 'Wh'),
      climate: const Measurement.unreported(unit: 'Wh'),
      delivered: kind == SessionKind.charge
          ? measurement(
              'estimatedEnergyKwh',
              'kWh',
            ).map((kwh) => kwh * 1000, unit: 'Wh')
          : const Measurement.unreported(unit: 'Wh'),
      integratedSeconds: const Measurement.unreported(unit: 's'),
    ),
    startOdometer: measurement('startOdometerKm', 'km'),
    endOdometer: measurement('endOdometerKm', 'km'),
    startSoc: measurement('startSoc', '%'),
    endSoc: measurement('endSoc', '%'),
    minSoc: measurement('endSoc', '%'),
    maxSoc: measurement('startSoc', '%'),
    startAmbientTemp: measurement('startAmbientTempC', '°C'),
    endAmbientTemp: measurement('endAmbientTempC', '°C'),
    meanAmbientTemp: measurement('startAmbientTempC', '°C'),
    plugType: whole('plugType'),
    costPerKwh: number('costPerKwh'),
    paidAmount: number('paidAmount'),
    costCurrency: row['costCurrency'] as String?,
    chargeStartedAtUtcMillis: whole('chargeStartedAtUtcMillis'),
    chargeStartedAtElapsedNanos: whole('chargeStartedAtElapsedNanos'),
    chargeEndedAtUtcMillis: whole('chargeEndedAtUtcMillis'),
    chargeEndedAtElapsedNanos: whole('chargeEndedAtElapsedNanos'),
    plugDisconnectedAtUtcMillis: whole('plugDisconnectedAtUtcMillis'),
    plugDisconnectedAtElapsedNanos: whole('plugDisconnectedAtElapsedNanos'),
    movementStartedAtUtcMillis: whole('movementStartedAtUtcMillis'),
    movementStartedAtElapsedNanos: whole('movementStartedAtElapsedNanos'),
    chargeEndReason: row['chargeEndReason'] as String?,
    endReason: row['endReason'] as String?,
    startLatitude: number('startLatitude'),
    startLongitude: number('startLongitude'),
    startAltitudeM: number('startAltitudeM'),
    startGpsAccuracyM: number('startGpsAccuracyM'),
    startGear: whole('startGear'),
    startPowerKw: number('startPowerKw'),
    createdAtUtcMillis: whole('createdAtUtcMillis') ?? startedAtUtcMillis,
    updatedAtUtcMillis:
        whole('updatedAtUtcMillis') ?? endedAtUtcMillis ?? startedAtUtcMillis,
  );
}

List<IntervalRecord> _mockIntervals(
  MockTelemetryData mock,
  SessionRecord record,
) {
  final answer = mock.tripEnergyBuckets(sessionId: record.id);
  final rows = (answer['buckets'] as List<Object?>? ?? const []);
  return [
    for (final row in rows)
      if (row is Map) _mockInterval(row.cast<String, Object?>(), record),
  ];
}

IntervalRecord _mockInterval(Map<String, Object?> row, SessionRecord record) {
  double value(String key) => (row[key] as num?)?.toDouble() ?? 0;
  final delivered = record.kind == SessionKind.charge
      ? value('tractionWh')
      : 0.0;
  return IntervalRecord(
    sessionId: record.id,
    startUtcMillis: (row['startUtcMillis'] as num?)?.toInt() ?? 0,
    widthMillis: 60000,
    traction: Measurement.measured(value('tractionWh'), unit: 'Wh'),
    regen: Measurement.measured(value('regeneratedWh'), unit: 'Wh'),
    auxiliary: Measurement.measured(value('auxiliaryWh'), unit: 'Wh'),
    climate: const Measurement.unreported(unit: 'Wh'),
    delivered: Measurement.measured(delivered, unit: 'Wh'),
    distance: Measurement.measured(value('speedDistanceKm'), unit: 'km'),
    coveredSeconds: value('integratedSeconds'),
    climateCoveredSeconds: 0,
    speedCoveredSeconds: value('speedIntegratedSeconds'),
    deliveredCoveredSeconds: record.kind == SessionKind.charge
        ? value('integratedSeconds')
        : 0,
    startSoc: _measurement(
      row['startSoc'] ?? row['startSocPercent'],
      unit: '%',
    ),
    endSoc: _measurement(row['endSoc'] ?? row['endSocPercent'], unit: '%'),
  );
}

/// The mock drive's route as a Track row, so the detail screen draws the map,
/// the terrain and the climb from the Track exactly as it does for a recorded
/// session (issue 184).
TrackRow? _mockTrack(MockTelemetryData mock, SessionRecord record) {
  final answer = mock.sessionFrames(sessionId: record.id, limit: 20000);
  final frames = (answer['frames'] as List<Object?>? ?? const []);
  final points = <TrackPoint>[];
  for (final frame in frames) {
    if (frame is! Map) continue;
    final row = frame.cast<String, Object?>();
    final latitude = (row['latitude'] as num?)?.toDouble();
    final longitude = (row['longitude'] as num?)?.toDouble();
    if (latitude == null || longitude == null) continue;
    points.add(
      TrackPoint(
        latitude: latitude,
        longitude: longitude,
        tSeconds: ((row['elapsedRealtimeNanos'] as num?)?.toInt() ?? 0) / 1e9,
        speedKmh: (row['speedKmh'] as num?)?.toDouble() ?? 0,
        altitudeM: (row['altitudeM'] as num?)?.toDouble() ?? 0,
      ),
    );
  }
  if (points.isEmpty) return null;
  return TrackCodec.encode(points);
}
