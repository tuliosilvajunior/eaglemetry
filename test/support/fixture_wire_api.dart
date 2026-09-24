/// The car's Pigeon surface, answered from the shared store fixture.
///
/// `testdata/telemetry_store_cases.json` is the one set of sessions both
/// stores answer from, so a test that renders the car's store renders exactly
/// what the phone's store holds. Without this the Room side could only be
/// tested against a second fixture, and two fixtures cannot disagree.
library;

import 'package:telemetry_core/telemetry_core.dart';

class FixtureWireApi implements TelemetryWireApi {
  FixtureWireApi(this.cases);

  final List<dynamic> cases;

  @override
  Future<SessionListPageWire> storeListSessions(
    SessionFilterWire? filter,
    PageRequestWire? page,
  ) async {
    final limit = page?.limit ?? 50;
    final offset = page?.offset ?? 0;
    final filtered = cases.where((c) {
      final s = c['session'] as Map<String, dynamic>;
      if (filter?.kind != null &&
          (s['kind'] as String).toUpperCase() != filter!.kind!.toUpperCase()) {
        return false;
      }
      if (filter?.status != null && s['status'] != filter!.status) {
        return false;
      }
      if (filter?.fromUtcMillis != null &&
          (s['startedAtUtcMillis'] as num).toInt() < filter!.fromUtcMillis!) {
        return false;
      }
      if (filter?.toUtcMillis != null &&
          (s['startedAtUtcMillis'] as num).toInt() > filter!.toUtcMillis!) {
        return false;
      }
      return true;
    }).toList();

    filtered.sort((a, b) {
      final sa = (a['session']['startedAtUtcMillis'] as num).toInt();
      final sb = (b['session']['startedAtUtcMillis'] as num).toInt();
      return sb.compareTo(sa);
    });

    final paged = filtered.skip(offset).take(limit).toList();
    final sessionWires = [
      for (final c in paged)
        _toSessionRecordWire(c['session'] as Map<String, dynamic>),
    ];

    return SessionListPageWire(
      sessions: sessionWires,
      totalCount: filtered.length,
      limit: limit,
      offset: offset,
      hasMore: offset + paged.length < filtered.length,
    );
  }

  @override
  Future<SessionDetailWire?> storeGetSession(String id) async {
    final c = cases.firstWhere(
      (c) => c['session']['id'] == id,
      orElse: () => null,
    );
    if (c == null) return null;

    final sessionMap = c['session'] as Map<String, dynamic>;
    final eventList = (c['events'] as List<dynamic>?) ?? [];

    return SessionDetailWire(
      session: _toSessionRecordWire(sessionMap),
      events: [
        for (final ev in eventList)
          _toEventRecordWire(ev as Map<String, dynamic>),
      ],
    );
  }

  @override
  Future<TelemetrySeriesWire> storeGetSeries(
    String id,
    List<String>? keys,
    int? widthMillis,
  ) async {
    final c = cases.firstWhere(
      (c) => c['session']['id'] == id,
      orElse: () => null,
    );
    if (c == null) {
      return TelemetrySeriesWire(
        sessionId: id,
        intervals: const [],
        sampleSeries: const [],
      );
    }

    final intervalList = (c['intervals'] as List<dynamic>?) ?? [];
    final sampleList = (c['samples'] as List<dynamic>?) ?? [];

    final samplesByKey = <String, List<SamplePointWire>>{};
    for (final s in sampleList) {
      final map = s as Map<String, dynamic>;
      final k = map['key'] as String;
      if (keys == null || keys.isEmpty || keys.contains(k)) {
        samplesByKey.putIfAbsent(k, () => []).add(_toSamplePointWire(map));
      }
    }

    return TelemetrySeriesWire(
      sessionId: id,
      intervals: [
        for (final inv in intervalList)
          _toIntervalRecordWire(inv as Map<String, dynamic>),
      ],
      sampleSeries: [
        for (final entry in samplesByKey.entries)
          SampleSeriesWire(key: entry.key, points: entry.value),
      ],
    );
  }

  // --- Helpers -------------------------------------------------------------

  SessionRecordWire _toSessionRecordWire(Map<String, dynamic> m) {
    return SessionRecordWire(
      id: m['id'] as String,
      vehicleId: m['vehicleId'] as String,
      kind: m['kind'] as String,
      status: m['status'] as String,
      startedAtUtcMillis: (m['startedAtUtcMillis'] as num).toInt(),
      startedAtElapsedNanos: (m['startedAtElapsedNanos'] as num).toInt(),
      startedAtBootCount: (m['startedAtBootCount'] as num?)?.toInt(),
      endedAtUtcMillis: (m['endedAtUtcMillis'] as num?)?.toInt(),
      endedAtElapsedNanos: (m['endedAtElapsedNanos'] as num?)?.toInt(),
      endedAtBootCount: (m['endedAtBootCount'] as num?)?.toInt(),
      durationMillis: (m['durationMillis'] as num?)?.toInt(),
      rollup: SessionRollupWire(
        distance: MeasurementWire(
          value: (m['rollupDistanceKm'] as num?)?.toDouble(),
          unit: 'km',
          validity: 'measured',
          note: '',
        ),
        traction: MeasurementWire(
          value: (m['rollupTractionWh'] as num?)?.toDouble(),
          unit: 'Wh',
          validity: 'measured',
          note: '',
        ),
        regen: MeasurementWire(
          value: (m['rollupRegenWh'] as num?)?.toDouble(),
          unit: 'Wh',
          validity: 'measured',
          note: '',
        ),
        auxiliary: MeasurementWire(
          value: (m['rollupAuxiliaryWh'] as num?)?.toDouble(),
          unit: 'Wh',
          validity: 'measured',
          note: '',
        ),
        climate: MeasurementWire(
          value: (m['rollupClimateWh'] as num?)?.toDouble(),
          unit: 'Wh',
          validity: 'measured',
          note: '',
        ),
        delivered: MeasurementWire(
          value: (m['rollupDeliveredWh'] as num?)?.toDouble(),
          unit: 'Wh',
          validity: 'measured',
          note: '',
        ),
        integratedSeconds: MeasurementWire(
          value: (m['rollupIntegratedSeconds'] as num?)?.toDouble(),
          unit: 's',
          validity: 'measured',
          note: '',
        ),
      ),
      startOdometer: MeasurementWire(
        value: (m['startOdometerKm'] as num?)?.toDouble(),
        unit: 'km',
        validity: 'measured',
        note: '',
      ),
      endOdometer: MeasurementWire(
        value: (m['endOdometerKm'] as num?)?.toDouble(),
        unit: 'km',
        validity: 'measured',
        note: '',
      ),
      startSoc: MeasurementWire(
        value: (m['startSocPercent'] as num?)?.toDouble(),
        unit: '%',
        validity: 'measured',
        note: '',
      ),
      endSoc: MeasurementWire(
        value: (m['endSocPercent'] as num?)?.toDouble(),
        unit: '%',
        validity: 'measured',
        note: '',
      ),
      minSoc: MeasurementWire(
        value: (m['minSocPercent'] as num?)?.toDouble(),
        unit: '%',
        validity: 'measured',
        note: '',
      ),
      maxSoc: MeasurementWire(
        value: (m['maxSocPercent'] as num?)?.toDouble(),
        unit: '%',
        validity: 'measured',
        note: '',
      ),
      socAgreesWithIntegral: m['socAgreesWithIntegral'] as String?,
      startAmbientTemp: MeasurementWire(
        value: (m['startAmbientTempC'] as num?)?.toDouble(),
        unit: '°C',
        validity: 'measured',
        note: '',
      ),
      endAmbientTemp: MeasurementWire(
        value: (m['endAmbientTempC'] as num?)?.toDouble(),
        unit: '°C',
        validity: 'measured',
        note: '',
      ),
      meanAmbientTemp: MeasurementWire(
        value: (m['meanAmbientTempC'] as num?)?.toDouble(),
        unit: '°C',
        validity: 'measured',
        note: '',
      ),
      plugType: (m['plugType'] as num?)?.toInt(),
      costPerKwh: (m['costPerKwh'] as num?)?.toDouble(),
      paidAmount: (m['paidAmount'] as num?)?.toDouble(),
      costCurrency: m['costCurrency'] as String?,
      chargeStartedAtUtcMillis: (m['chargeStartedAtUtcMillis'] as num?)
          ?.toInt(),
      chargeEndedAtUtcMillis: (m['chargeEndedAtUtcMillis'] as num?)?.toInt(),
      plugDisconnectedAtUtcMillis: (m['plugDisconnectedAtUtcMillis'] as num?)
          ?.toInt(),
      movementStartedAtUtcMillis: (m['movementStartedAtUtcMillis'] as num?)
          ?.toInt(),
      chargeEndReason: m['chargeEndReason'] as String?,
      endReason: m['endReason'] as String?,
      startLatitude: (m['startLatitude'] as num?)?.toDouble(),
      startLongitude: (m['startLongitude'] as num?)?.toDouble(),
      noLongerReducible: (m['noLongerReducible'] as bool?) ?? false,
      createdAtUtcMillis: (m['createdAtUtcMillis'] as num).toInt(),
      updatedAtUtcMillis: (m['updatedAtUtcMillis'] as num).toInt(),
    );
  }

  TelemetryEventRecordWire _toEventRecordWire(Map<String, dynamic> m) {
    return TelemetryEventRecordWire(
      id: (m['id'] as num).toInt(),
      sessionId: m['sessionId'] as String?,
      type: m['type'] as String,
      occurredAtUtcMillis: (m['occurredAtUtcMillis'] as num).toInt(),
      occurredAtElapsedNanos: (m['occurredAtElapsedNanos'] as num).toInt(),
      signalKey: m['signalId'] as String?,
      value: m['value'] as String?,
      previousValue: m['previousValue'] as String?,
      quality: m['quality'] as String?,
      source: m['source'] as String?,
      details: m['details'] as String,
    );
  }

  IntervalRecordWire _toIntervalRecordWire(Map<String, dynamic> m) {
    return IntervalRecordWire(
      sessionId: m['sessionId'] as String,
      startUtcMillis: (m['startUtcMillis'] as num).toInt(),
      widthMillis: (m['widthMillis'] as num?)?.toInt() ?? 60000,
      traction: MeasurementWire(
        value: (m['tractionWh'] as num?)?.toDouble(),
        unit: 'Wh',
        validity: 'measured',
        note: '',
      ),
      regen: MeasurementWire(
        value: (m['regenWh'] as num?)?.toDouble(),
        unit: 'Wh',
        validity: 'measured',
        note: '',
      ),
      auxiliary: MeasurementWire(
        value: (m['auxiliaryWh'] as num?)?.toDouble(),
        unit: 'Wh',
        validity: 'measured',
        note: '',
      ),
      climate: MeasurementWire(
        value: (m['climateWh'] as num?)?.toDouble(),
        unit: 'Wh',
        validity: 'measured',
        note: '',
      ),
      delivered: MeasurementWire(
        value: (m['deliveredWh'] as num?)?.toDouble(),
        unit: 'Wh',
        validity: 'measured',
        note: '',
      ),
      distance: MeasurementWire(
        value: (m['distanceKm'] as num?)?.toDouble(),
        unit: 'km',
        validity: 'measured',
        note: '',
      ),
      coveredSeconds: (m['coveredSeconds'] as num).toDouble(),
      climateCoveredSeconds: (m['climateCoveredSeconds'] as num).toDouble(),
      speedCoveredSeconds: (m['speedCoveredSeconds'] as num).toDouble(),
      deliveredCoveredSeconds: (m['deliveredCoveredSeconds'] as num).toDouble(),
      startElapsedNanos: (m['startElapsedNanos'] as num?)?.toInt(),
      startBootCount: (m['startBootCount'] as num?)?.toInt(),
      timeState: m['timeState'] as String?,
    );
  }

  SamplePointWire _toSamplePointWire(Map<String, dynamic> m) {
    return SamplePointWire(
      tUtcMillis: (m['tUtcMillis'] as num).toInt(),
      tElapsedNanos: (m['tElapsedNanos'] as num).toInt(),
      bootCount: (m['bootCount'] as num?)?.toInt(),
      value: MeasurementWire(
        value: (m['value'] as num?)?.toDouble(),
        unit: '',
        validity: m['validity'] as String,
        note: '',
      ),
      groupId: m['groupId'] as String?,
    );
  }

  @override
  Future<InsightPlacesWire> getInsightPlaces() async =>
      InsightPlacesWire(places: const []);

  @override
  Future<List<PreferenceRowWire>> getPreferenceRows() async => const [];

  @override
  Future<PreferenceRowWire?> savePreferenceRow(
    String scope,
    String key,
    String? value,
  ) async => null;

  @override
  Future<List<PreferenceProposalWire>> getPreferenceProposals() async =>
      const [];

  @override
  Future<PreferenceProposalWire?> proposePreference(
    String key,
    String? value,
  ) async => null;

  @override
  Future<PreferenceProposalWire?> decidePreferenceProposal(
    String id,
    bool accept,
  ) async => null;

  // Unused mock methods
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
