import 'package:telemetry_core/telemetry_core.dart';

class MockTelemetryData {
  /// Pack capacity reported by the mock snapshot and used by the mock trip
  /// detail computation.
  static const batteryCapacityWh = 39100.0;

  int get _now => DateTime.now().millisecondsSinceEpoch;

  final List<Map<String, Object?>> _places = [];

  Map<String, Object?> platformStatus() => {
    'ok': true,
    'platform': 'web',
    'bridge': 'mock',
    'timestampMillis': _now,
  };

  Map<String, Object?> collectorStatus({bool running = true}) => {
    'running': running,
    'collectorStatus': running ? 'running' : 'stopped',
    'vehicleActivity': running ? 'MOVING' : 'STATIONARY',
    'tripState': running ? 'ACTIVE' : 'IDLE',
    'chargeState': 'DISCONNECTED',
    'callbackSignals': 7,
    'pollingSignals': 4,
    'lastUpdateMillis': _now,
    'signalCount': 12,
  };

  Map<String, Object?> roadcastStatus({bool running = true}) => {
    'running': running,
    'socketReachable': running,
    'signalCount': 815,
    'frameCount': 111,
    'hz': 60,
    'startedByApp': running,
    'error': running ? null : 'Roadcast is unavailable',
  };

  Map<String, Object?> roadcastUpdateStatus({
    bool checked = false,
    bool installed = false,
  }) => {
    'checked': checked,
    'channel': 'edge',
    'updateAvailable': checked && !installed,
    'compatible': true,
    'installedSha256': installed ? 'e6d6fb610bf4' : '28a5449a083d',
    'installedVersion': installed ? 'edge' : null,
    'installedCommit': installed ? '981dbacc437e' : null,
    'availableVersion': checked ? 'edge' : null,
    'availableCommit': checked ? '981dbacc437e' : null,
    'availableSha256': checked ? 'e6d6fb610bf4' : null,
    'error': null,
  };

  /// Mirrors the clamp in `HvacClimateController`: 15.5–33 °C on the half
  /// degree, fan 1–9. The mock applies the same bounds as the controller so the
  /// web build cannot offer a span the car never accepts.
  static const hvacMinTemperatureC = 15.5;
  static const hvacMaxTemperatureC = 33.0;
  static const hvacMinFanSpeed = 1;
  static const hvacMaxFanSpeed = 9;

  Map<String, Object?> hvacSetTemperature(double temperatureC) {
    final applied =
        ((temperatureC.clamp(hvacMinTemperatureC, hvacMaxTemperatureC) * 2)
            .round()) /
        2;
    return _hvacResult(
      action: 'setTemperature',
      requestedValue: temperatureC,
      appliedValue: applied,
      propertyIdHex: '0x15600503',
      areaId: 1,
      detail: 'mock set HVAC_TEMPERATURE_SET=$applied',
    );
  }

  Map<String, Object?> hvacSetFanSpeed(int fanSpeed) {
    final applied = fanSpeed.clamp(hvacMinFanSpeed, hvacMaxFanSpeed);
    return _hvacResult(
      action: 'setFanSpeed',
      requestedValue: fanSpeed,
      appliedValue: applied,
      propertyIdHex: '0x15400500',
      areaId: 5,
      detail: 'mock set HVAC_FAN_SPEED=$applied',
    );
  }

  Map<String, Object?> _hvacResult({
    required String action,
    required num requestedValue,
    required num appliedValue,
    required String propertyIdHex,
    required int areaId,
    required String detail,
  }) => {
    'ok': true,
    'action': action,
    'currentValue': null,
    'requestedValue': requestedValue,
    'appliedValue': appliedValue,
    'propertyIdHex': propertyIdHex,
    'areaId': areaId,
    'details': [detail],
    'timestampMillis': _now,
  };

  Map<String, Object?> telemetrySnapshot({bool isCharging = false}) {
    final now = _now;
    return {
      'timestampMillis': now,
      'batteryPercent': _reading(63.4),
      'speedKmh': _reading(42.0),
      'odometerKm': _reading(12842.7),
      'charging': {
        'ok': true,
        'isCharging': isCharging,
        'stateRaw': isCharging ? 606100482 : 606100481,
        'stateLabel': isCharging ? 'AC charging' : 'No charging',
        'plugRaw': isCharging ? 605225491 : 605225490,
        'plugLabel': isCharging ? 'AC' : 'None',
        'acPowerKw': isCharging ? 7.2 : null,
        'dcPowerKw': null,
        'currentA': isCharging ? 18.6 : null,
        'voltageV': 386.2,
        'estimatedTimeMinutes': isCharging ? 96.0 : null,
        'workTimeMinutes': isCharging ? 24.0 : null,
        'source': 'mock',
        'details': 'Web mock telemetry',
      },
      'gear': _reading(8),
    };
  }

  Map<String, Object?> liveFrame() {
    final now = _now;
    final seconds = now / 1000.0;
    final speed = 38 + (seconds % 12);
    final power = -8 + ((seconds % 6) - 3);
    // Deriva lenta de SOC e posição: sem movimento nenhum, a tela live no mock web
    // fica indistinguível de uma tela travada, que é justamente o que ela precisa
    // deixar de parecer.
    final soc = 63.4 - ((seconds % 600) / 600);
    final step = (seconds % 900) / 900;
    return {
      'timestampMillis': now,
      'updatedSignalId': 'VEHICLE_SPEED',
      'signals': [
        _signal('HV_BATTERY_SOC', soc, '%', now, '0x1160030f'),
        _signal('HV_BATTERY_VOLTAGE', 386.2, 'V', now, '0x21607365'),
        _signal('HV_BATTERY_CURRENT', -21.4, 'A', now, '0x21607364'),
        _signal(
          'EV_BATTERY_INSTANTANEOUS_POWER',
          power,
          'kW',
          now,
          '0x1160030c',
        ),
        _signal(
          'ED_DRIVING_ENERGY_FLOW',
          86.7 + ((seconds % 4) / 100),
          'raw',
          now,
          '0x2160a6e9',
        ),
        _signal(
          'TRIP_ED_DRIVING_ENERGY_FLOW',
          86.7 + ((seconds % 4) / 100),
          'raw',
          now,
          '0x24804100',
        ),
        _signal(
          'TRIP_ED_DRIVING_ENERGY_FLOW_VENDOR',
          86.7 + ((seconds % 4) / 100),
          'raw',
          now,
          '0x216074e9',
        ),
        _signal('HYBRID_POWER_FLOW', 6, '', now, '0x21407173'),
        _signal('VEHICLE_SPEED', speed, 'km/h', now, '0x11600207'),
        _signal('ODOMETER', 12842.7, 'km', now, '0x11600204'),
        _signal(
          'AMBIENT_AIR_TEMPERATURE',
          22.5 + ((seconds % 8) / 4),
          '°C',
          now,
          '0x2140a377',
        ),
        _signal('GEAR', 8, '', now, '0x11400400'),
        _signal('EV_CHARGE_STATE', 0, '', now, '0x24204000'),
        _signal('EV_CHARGE_PLUG_TYPE', 0, '', now, '0x24150400'),
      ],
      'status': collectorStatus(),
      'trip': {
        'tripState': 'ACTIVE',
        'activeTripId': 'mock-trip-002',
        'tripWritesThisRun': 2,
      },
      'charge': {
        'chargeState': 'DISCONNECTED',
        'activeChargeId': null,
        'chargeWritesThisRun': 2,
      },
      // Mesmas chaves de `LocationSignalProvider.statusMap()` no Kotlin: quando o
      // mock inventa nome próprio, a tela que lê o mapa funciona no carro e mostra
      // "sem GPS" no mock — ou o contrário, que é pior de achar.
      'location': {
        'gpsEnabled': true,
        'permissionGranted': true,
        'running': true,
        'gpsProviderEnabled': true,
        'networkProviderEnabled': true,
        'lastError': null,
        'lastFixAgeMillis': 800,
        'locationProvider': 'mock',
        // Synthetic coordinates for UI work: not a real position.
        'latitude': -23.5617 + step * 0.01,
        'longitude': -46.6559 + step * 0.008,
        'altitudeM': 762.0 + (seconds % 60),
        'gpsAccuracyM': 5.5,
      },
      'sessions': {'tripRows': 2, 'chargeRows': 2},
      'frames': {
        'framesWrittenThisRun': 180,
        'lastFrameSessionId': 'mock-trip-002',
      },
      'recentEvents': _events().take(5).toList(growable: false),
    };
  }

  Stream<Map<String, Object?>> liveTelemetryStream() {
    return Stream.periodic(
      const Duration(seconds: 1),
      (_) => liveFrame(),
    ).asBroadcastStream();
  }

  Map<String, Object?> events({required int limit}) => {
    'events': _events().take(limit).toList(growable: false),
    'eventFile': 'mock://telemetry_events.jsonl',
    'database': 'mock',
    'databaseInsertedThisRun': 12,
  };

  Map<String, Object?> tripSessions({required int limit}) {
    final rows = _tripRows();
    return {
      'sessions': rows.take(limit).toList(growable: false),
      'totalCount': rows.length,
      'limit': limit,
      'tripWritesThisRun': rows.length,
    };
  }

  Map<String, Object?>? tripSession(String id) =>
      _tripRows().where((row) => row['id'] == id).firstOrNull;

  Map<String, Object?>? chargeSession(String id) =>
      _chargeRows().where((row) => row['id'] == id).firstOrNull;

  /// Closed trips for the Insights comparison, including [subjectId].
  ///
  /// Four reference drives sit at 100 Wh/km. The closed mock trip is 250
  /// Wh/km, which is past the IQR of that set, so the sentence on History is
  /// a real claim rather than "not enough data".
  Map<String, Object?> insightTrips({String? subjectId}) {
    const day = 86400000;
    Map<String, Object?> trip({
      required String id,
      required int endedAtUtcMillis,
      required double distanceKm,
      required double canPackWh,
    }) => {
      'id': id,
      'endedAtUtcMillis': endedAtUtcMillis,
      'rollupDistanceKm': distanceKm,
      'rollupTractionWh': canPackWh,
      'rollupRegenWh': 0.0,
      'rollupAuxiliaryWh': 0.0,
      'hasMinuteBuckets': true,
      'socAgreesWithIntegral': 'agrees',
    };

    final closed = _tripRows().firstWhere(
      (row) => row['id'] == 'mock-trip-001',
    );
    final closedEnd = closed['endedAtUtcMillis'] as int;
    final startOdo = (closed['startOdometerKm'] as num).toDouble();
    final endOdo = (closed['endOdometerKm'] as num).toDouble();
    final rows = <Map<String, Object?>>[
      {
        ...trip(
          id: 'mock-trip-001',
          endedAtUtcMillis: closedEnd,
          distanceKm: endOdo - startOdo,
          canPackWh: (endOdo - startOdo) * 250,
        ),
        'startLatitude': -10.18,
        'startLongitude': -48.33,
        'endLatitude': -10.19,
        'endLongitude': -48.34,
        'path': '-10.18,-48.33;-10.19,-48.34',
      },
      for (var i = 1; i <= 4; i++)
        trip(
          id: 'mock-insight-ref-$i',
          endedAtUtcMillis: _now - i * day,
          distanceKm: 10,
          canPackWh: 1000,
        ),
    ];
    if (subjectId != null && rows.every((row) => row['id'] != subjectId)) {
      rows.add(
        trip(
          id: subjectId,
          endedAtUtcMillis: closedEnd,
          distanceKm: 12.5,
          canPackWh: 3125,
        ),
      );
    }
    return {'trips': rows, 'subjectId': subjectId};
  }

  Map<String, Object?> insightPlaces() => {
    'places': List<Map<String, Object?>>.unmodifiable(_places),
  };

  Map<String, Object?> saveInsightPlace({
    String? id,
    required String name,
    required double latitude,
    required double longitude,
    required double radiusM,
    String? autoName,
    int? autoNameUpdatedAtUtcMillis,
    String? autoNameSource,
  }) {
    final existing = id == null
        ? -1
        : _places.indexWhere((place) => place['id'] == id);
    final existingRow = existing >= 0 ? _places[existing] : null;
    // Same near-duplicate rule the car repository and the phone source
    // apply, so the mock refuses with the same words.
    final blocker = findBlockingDuplicate(
      id: existing >= 0 ? id : null,
      name: name,
      latitude: latitude,
      longitude: longitude,
      existing: [
        for (final place in _places)
          InsightPlace(
            id: (place['id'] as String?) ?? '',
            name: (place['name'] as String?) ?? '',
            latitude: ((place['latitude'] as num?)?.toDouble()) ?? 0,
            longitude: ((place['longitude'] as num?)?.toDouble()) ?? 0,
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
    final row = <String, Object?>{
      'id': existing >= 0 ? id : 'mock-place-${_places.length + 1}',
      'name': name,
      'latitude': latitude,
      'longitude': longitude,
      'radiusM': radiusM,
      'createdAtUtcMillis': existingRow?['createdAtUtcMillis'] as int? ?? _now,
      'autoName': autoName ?? existingRow?['autoName'],
      'autoNameUpdatedAtUtcMillis':
          autoNameUpdatedAtUtcMillis ??
          existingRow?['autoNameUpdatedAtUtcMillis'],
      'autoNameSource': autoNameSource ?? existingRow?['autoNameSource'],
    };
    if (existing >= 0) {
      _places[existing] = row;
    } else {
      _places.add(row);
    }
    return row;
  }

  Map<String, Object?> deleteInsightPlace(String id) {
    _places.removeWhere((place) => place['id'] == id);
    return const {'ok': true};
  }

  // --- Preferences ----------------------------------------------------------

  final List<Map<String, Object?>> _preferences = [];
  final List<Map<String, Object?>> _proposals = [];

  Map<String, Object?> preferenceRows() => {
    'rows': List<Map<String, Object?>>.unmodifiable(
      _preferences.where((row) => row['deletedAtUtcMillis'] == null),
    ),
  };

  Map<String, Object?> savePreferenceRow({
    required String scope,
    required String key,
    required String? value,
  }) {
    final accepted = kSyncedPreferenceKeys[key] == scope;
    if (!accepted) return const {'ok': false};
    final row = <String, Object?>{
      'scope': scope,
      'key': key,
      'value': value,
      'updatedAtUtcMillis': _now,
      'origin': kAnnotationOriginCar,
      'deletedAtUtcMillis': null,
    };
    final index = _preferences.indexWhere(
      (existing) => existing['scope'] == scope && existing['key'] == key,
    );
    if (index >= 0) {
      _preferences[index] = row;
    } else {
      _preferences.add(row);
    }
    return row;
  }

  Map<String, Object?> preferenceProposals() => {
    'proposals': List<Map<String, Object?>>.unmodifiable(
      _proposals.where((row) => row['status'] == 'PENDING'),
    ),
  };

  Map<String, Object?>? proposePreference({
    required String key,
    required String? value,
  }) {
    if (!kControlPreferenceKeys.contains(key)) return null;
    final row = <String, Object?>{
      'id': 'mock-proposal-${_proposals.length + 1}',
      'key': key,
      'value': value,
      'status': 'PENDING',
      'proposedAtUtcMillis': _now,
      'decidedAtUtcMillis': null,
      'updatedAtUtcMillis': _now,
      'origin': kAnnotationOriginPhone,
    };
    _proposals.add(row);
    return row;
  }

  Map<String, Object?>? decidePreferenceProposal({
    required String id,
    required bool accept,
  }) {
    final index = _proposals.indexWhere((row) => row['id'] == id);
    if (index < 0) return null;
    final row = _proposals[index];
    _proposals[index] = {
      ...row,
      'status': accept ? 'ACCEPTED' : 'REFUSED',
      'decidedAtUtcMillis': _now,
      'updatedAtUtcMillis': _now,
      'origin': kAnnotationOriginCar,
    };
    return _proposals[index];
  }

  /// Battery cycles, newest first.
  ///
  /// The rows are chosen to cover the states the list must draw differently,
  /// because each of them suppresses a readout: the oldest cycle is partial and
  /// frozen, one cycle has no trustworthy capacity, one was fed by two
  /// currencies, one is only part priced, and the newest is open. A mock of six
  /// ordinary cycles would leave every one of those paths unexercised on the
  /// web build.
  Map<String, Object?> batteryCycles({required int limit}) {
    const day = 86400000;
    final rows = <Map<String, Object?>>[
      // Open: the bar is partly filled and the numbers are partial.
      _cycle(
        ordinal: 6,
        startUtcMillis: _now - 3 * day,
        endUtcMillis: _now,
        dischargePercent: 41.5,
        distanceKm: 173.4,
        tripEnergyKwh: 16.4,
        cost: 12.30,
        pricedEnergyKwh: 16.4,
        isOpen: true,
      ),
      // Part priced: a charge the driver never entered a price for.
      _cycle(
        ordinal: 5,
        startUtcMillis: _now - 11 * day,
        endUtcMillis: _now - 3 * day,
        dischargePercent: 100,
        distanceKm: 402.7,
        tripEnergyKwh: 39.1,
        parkedEnergyKwh: 0.8,
        parkedSocPercent: 2.1,
        cost: 21.90,
        pricedEnergyKwh: 27.4,
        unpricedEnergyKwh: 12.5,
      ),
      // Two currencies: the cycle has no cost at all.
      _cycle(
        ordinal: 4,
        startUtcMillis: _now - 19 * day,
        endUtcMillis: _now - 11 * day,
        dischargePercent: 100,
        distanceKm: 388.2,
        tripEnergyKwh: 39.4,
        parkedEnergyKwh: 0.6,
        parkedSocPercent: 1.5,
        pricedEnergyKwh: 39.4,
        mixedCurrency: true,
      ),
      _cycle(
        ordinal: 3,
        startUtcMillis: _now - 28 * day,
        endUtcMillis: _now - 19 * day,
        dischargePercent: 100,
        distanceKm: 415.9,
        tripEnergyKwh: 39.6,
        parkedEnergyKwh: 1.1,
        parkedSocPercent: 2.8,
        cost: 30.10,
        pricedEnergyKwh: 39.6,
      ),
      // No trustworthy capacity: the bar and the distance stay, the energy,
      // the efficiency and the cost per kWh go.
      _cycle(
        ordinal: 2,
        startUtcMillis: _now - 37 * day,
        endUtcMillis: _now - 28 * day,
        dischargePercent: 100,
        distanceKm: 371.5,
        tripEnergyKwh: 21.2,
        energyIncomplete: true,
        pricedEnergyKwh: 21.2,
        cost: 16.40,
      ),
      // Partial and frozen: collection began mid-battery, and retention has
      // since deleted the sessions, so this cost is final.
      _cycle(
        ordinal: 1,
        startUtcMillis: _now - 44 * day,
        endUtcMillis: _now - 37 * day,
        dischargePercent: 62.4,
        distanceKm: 244.0,
        tripEnergyKwh: 24.7,
        cost: 18.05,
        pricedEnergyKwh: 24.7,
        isPartial: true,
        frozenAtUtcMillis: _now - 2 * day,
      ),
    ];
    return {
      'cycles': rows.take(limit).toList(growable: false),
      'totalCount': rows.length,
      'limit': limit,
    };
  }

  /// What one cycle is made of.
  ///
  /// Like [batteryCycles], the rows cover the states a reader must draw
  /// differently rather than a plausible drive week: a trip the fold split
  /// across the boundary, a whole charge, a parked session that has no list row
  /// at all, and a trip retention has deleted. Cycle 1 is the frozen one, and a
  /// frozen cycle has no membership to answer with.
  Map<String, Object?> batteryCycleSessions({required int ordinal}) {
    const hour = 3600000;
    if (ordinal <= 1) return {'ordinal': ordinal, 'sessions': const []};

    final trip = _tripRows().last;
    final charge = _chargeRows().first;
    final tripStart = _asMillis(trip['startedAtUtcMillis']);
    final chargeStart = _asMillis(charge['plugConnectedAtUtcMillis']);
    final sessions =
        <Map<String, Object?>>[
            // Deleted: the id and the window survive, the session does not.
            {
              'kind': 'TRIP',
              'sessionId': 'mock-trip-deleted',
              'share': 1.0,
              'startUtcMillis': tripStart - 48 * hour,
              'endUtcMillis': tripStart - 47 * hour,
              'deleted': true,
            },
            {
              'kind': 'PARKED',
              'sessionId': 'mock-parked-001',
              'share': 1.0,
              'startUtcMillis': tripStart - 12 * hour,
              'endUtcMillis': tripStart - 2 * hour,
              'deleted': false,
            },
            {
              'kind': 'CHARGE',
              'sessionId': charge['id'],
              'share': 1.0,
              'startUtcMillis': chargeStart,
              'endUtcMillis': chargeStart + 2 * hour,
              'deleted': false,
              'charge': charge,
            },
            // Split: the cycle closed inside this drive, so it took part of it.
            {
              'kind': 'TRIP',
              'sessionId': trip['id'],
              'share': 0.45,
              'startUtcMillis': tripStart,
              'endUtcMillis': tripStart + hour,
              'deleted': false,
              'trip': trip,
            },
          ]
          // Oldest first, like the native read, so a hand-written row here cannot
          // put the list out of order.
          ..sort(
            (a, b) => _asMillis(
              a['startUtcMillis'],
            ).compareTo(_asMillis(b['startUtcMillis'])),
          );
    return {'ordinal': ordinal, 'sessions': sessions};
  }

  int _asMillis(Object? value) => value is int ? value : _now;

  Map<String, Object?> _cycle({
    required int ordinal,
    required int startUtcMillis,
    required int endUtcMillis,
    required double dischargePercent,
    required double distanceKm,
    required double tripEnergyKwh,
    required double pricedEnergyKwh,
    double parkedEnergyKwh = 0,
    double parkedSocPercent = 0,
    double unpricedEnergyKwh = 0,
    double? cost,
    String costCurrency = 'BRL',
    bool isOpen = false,
    bool isPartial = false,
    bool energyIncomplete = false,
    bool mixedCurrency = false,
    int? frozenAtUtcMillis,
  }) => {
    'ordinal': ordinal,
    'startUtcMillis': startUtcMillis,
    'endUtcMillis': endUtcMillis,
    'dischargePercent': dischargePercent,
    'distanceKm': distanceKm,
    'tripEnergyKwh': tripEnergyKwh,
    'parkedEnergyKwh': parkedEnergyKwh,
    'parkedSocPercent': parkedSocPercent,
    'pricedEnergyKwh': pricedEnergyKwh,
    'unpricedEnergyKwh': unpricedEnergyKwh,
    'isOpen': isOpen,
    'isPartial': isPartial,
    'energyIncomplete': energyIncomplete,
    'mixedCurrency': mixedCurrency,
    'updatedAtUtcMillis': endUtcMillis,
    'cost': mixedCurrency ? null : cost,
    'costCurrency': mixedCurrency ? null : costCurrency,
    'frozenAtUtcMillis': frozenAtUtcMillis,
  };

  /// Per-minute energy series for the energy-monitor chart.
  ///
  /// Deliberately awkward: it runs long enough to outgrow the one-minute
  /// bucket, drops two minutes in the middle so gap handling is exercised, and
  /// ends on a partial minute the way a live trip always does.
  Map<String, Object?> tripEnergyBuckets({required String sessionId}) {
    const minutes = 75;
    final firstStart =
        (_now ~/ 60000 - minutes) * 60000; // aligned, like the native side
    final buckets = <Map<String, Object?>>[];
    for (var i = 0; i < minutes; i++) {
      // A stretch the car reported nothing for.
      if (i == 40 || i == 41) continue;

      final open = i == minutes - 1;
      final seconds = open ? 22.0 : 60.0;
      final coasting = i % 11 == 0;
      final tractionKw = coasting ? 4.0 : 18.0 + (i % 13);
      final regenKw = coasting ? 9.0 : (i % 5 == 0 ? 3.0 : 0.0);
      final speedKmh = coasting ? 18.0 : 42.0 + (i % 9);
      final distanceKm = speedKmh * seconds / 3600;

      buckets.add({
        'startUtcMillis': firstStart + i * 60000,
        'tractionWh': tractionKw * 1000 * seconds / 3600,
        'regeneratedWh': regenKw * 1000 * seconds / 3600,
        'auxiliaryWh': 1.4 * 1000 * seconds / 3600,
        'integratedSeconds': seconds,
        'speedDistanceKm': distanceKm,
        'odometerDistanceKm': distanceKm,
        'speedIntegratedSeconds': seconds,
      });
    }
    return {
      'sessionId': sessionId,
      'bucketMillis': 60000,
      'lastChargeCostPerKwh': 0.92,
      'lastChargeCostCurrency': 'BRL',
      'buckets': buckets,
    };
  }

  /// Per-minute energy over a clock window, spanning more than one mock trip.
  ///
  /// The eight-hour window deliberately contains a parked stretch between two
  /// drives, so gap handling is exercised by the option most likely to hit it.
  Map<String, Object?> energyBucketsInWindow({required int minutes}) {
    final end = _now;
    final start = (end ~/ 60000 - minutes) * 60000;
    final buckets = <Map<String, Object?>>[];

    for (var offset = 0; offset < minutes; offset++) {
      final startMillis = start + offset * 60000;
      final minutesAgo = minutes - offset;

      // Parked between two drives: a stretch the car reported nothing for.
      if (minutesAgo > 90 && minutesAgo < 260) continue;
      // A short stop close to now, so the narrow windows carry one too. The
      // two tracks must never claim the same minute — the car cannot be
      // driving and standing still at once — so every minute skipped here is
      // a minute `parkedEnergyBucketsInWindow` fills, and no other.
      if (minutesAgo >= 4 && minutesAgo <= 12) continue;
      // And an older window reaches back before the car was collecting at all.
      if (minutesAgo > 400) continue;

      final open = offset == minutes - 1;
      final seconds = open ? 34.0 : 60.0;
      final coasting = offset % 9 == 0;
      final tractionKw = coasting ? 3.5 : 16.0 + (offset % 11);
      final regenKw = coasting ? 8.0 : (offset % 6 == 0 ? 2.5 : 0.0);
      final speedKmh = coasting ? 16.0 : 38.0 + (offset % 13);
      final distanceKm = speedKmh * seconds / 3600;

      buckets.add({
        'startUtcMillis': startMillis,
        'tractionWh': tractionKw * 1000 * seconds / 3600,
        'regeneratedWh': regenKw * 1000 * seconds / 3600,
        'auxiliaryWh': 1.4 * 1000 * seconds / 3600,
        'integratedSeconds': seconds,
        'speedDistanceKm': distanceKm,
        'odometerDistanceKm': distanceKm,
        'speedIntegratedSeconds': seconds,
      });
    }

    return {
      'startUtcMillis': start,
      'endUtcMillis': end,
      'bucketMillis': 60000,
      'lastChargeCostPerKwh': 0.92,
      'lastChargeCostCurrency': 'BRL',
      'buckets': buckets,
    };
  }

  /// Per-minute energy over the same clock window, for parked sessions.
  ///
  /// It fills exactly the stretch [energyBucketsInWindow] leaves empty, because
  /// that is what the car does: the minutes the drive track has no bars for are
  /// the minutes the car was standing still. The two tracks are complementary
  /// readings of one window, not two versions of the same one.
  ///
  /// Three regimes, so the card is exercised rather than decorated. The plan's
  /// bench floors set the rates: about 118 W with everything off, about 850 W
  /// with climate running.
  Map<String, Object?> parkedEnergyBucketsInWindow({required int minutes}) {
    final end = _now;
    final start = (end ~/ 60000 - minutes) * 60000;
    final buckets = <Map<String, Object?>>[];

    for (var offset = 0; offset < minutes; offset++) {
      final minutesAgo = minutes - offset;
      // Exactly the minutes the drive track leaves out, and no others. The
      // long stop between the two drives, plus the short one near now so the
      // 15-minute and 1-hour windows have a parked reading as well.
      final longStop = minutesAgo > 90 && minutesAgo < 260;
      final shortStop = minutesAgo >= 4 && minutesAgo <= 12;
      if (!longStop && !shortStop) continue;

      const seconds = 60.0;
      // Climate runs for the first stretch after the driver leaves, then the
      // car settles to its standby draw. The short stop is climate throughout:
      // a driver who parked and stayed in the car with the air on.
      final climateRunning = minutesAgo > 200 || shortStop;
      // One stretch the daemon covered only part of. The split is refused for
      // these, and the bar has to come out undivided rather than charging the
      // uncovered seconds to the system share.
      final partiallyCovered = minutesAgo > 150 && minutesAgo <= 170;

      final packW = climateRunning ? 850.0 : 118.0;
      final climateW = climateRunning ? 700.0 : 0.0;
      final climateSeconds = switch (true) {
        _ when partiallyCovered => 21.0,
        _ when climateRunning => seconds,
        // Standby minutes are covered and measured zero, which is a different
        // fact from a minute nobody measured.
        _ => seconds,
      };

      buckets.add({
        'startUtcMillis': start + offset * 60000,
        // A parked car has no traction and returns nothing.
        'tractionWh': 0.0,
        'regeneratedWh': 0.0,
        'auxiliaryWh': packW * seconds / 3600,
        'integratedSeconds': seconds,
        'speedDistanceKm': 0.0,
        'odometerDistanceKm': 0.0,
        'speedIntegratedSeconds': 0.0,
        'climateWh': climateW * seconds / 3600,
        'climateIntegratedSeconds': climateSeconds,
      });
    }

    return {
      'startUtcMillis': start,
      'endUtcMillis': end,
      'bucketMillis': 60000,
      'lastChargeCostPerKwh': 0.92,
      'lastChargeCostCurrency': 'BRL',
      'buckets': buckets,
    };
  }

  /// The tail of the mock trip, as the in-memory monitor would report it.
  ///
  /// Derived from [tripEnergyBuckets] so the two agree the way the native
  /// accumulator and its live monitor do — a mock where the live bar disagreed
  /// with the stored series would hide exactly the bug worth catching.
  Map<String, Object?> liveEnergyBuckets() {
    final stored = tripEnergyBuckets(sessionId: 'mock-trip-002');
    final buckets = (stored['buckets']! as List).cast<Map<String, Object?>>();
    final tail = buckets.skip(buckets.length - 3).toList(growable: false);
    return {
      'sessionId': 'mock-trip-002',
      'startedAtUtcMillis': tail.first['startUtcMillis'],
      'buckets': tail,
    };
  }

  /// The open charge's climate minutes.
  ///
  /// Climate is the only term a charge integrates, so every other field stays
  /// zero — and a reader must not take those zeros as measurements. The draw
  /// is set high enough to trip the climate-share warning, because that banner
  /// is the surface this feeds and a mock that never trips it cannot show it.
  Map<String, Object?> liveChargeEnergyBuckets() {
    const widthMillis = 60000;
    const climateKw = 2.4;
    final start = (_now ~/ widthMillis) * widthMillis - 2 * widthMillis;
    final buckets = List.generate(3, (index) {
      // The minute in progress is short by construction; the two behind it are
      // whole. The reader divides energy by covered seconds, so a partial
      // minute gives the same rate rather than a smaller one.
      final seconds = index == 2 ? 20.0 : 60.0;
      return <String, Object?>{
        'startUtcMillis': start + index * widthMillis,
        'tractionWh': 0.0,
        'regeneratedWh': 0.0,
        'auxiliaryWh': 0.0,
        'integratedSeconds': 0.0,
        'speedDistanceKm': 0.0,
        'odometerDistanceKm': 0.0,
        'speedIntegratedSeconds': 0.0,
        'climateWh': climateKw * seconds / 3.6,
        'climateIntegratedSeconds': seconds,
      };
    }, growable: false);
    return {
      'sessionId': 'mock-charge-001',
      'startedAtUtcMillis': start,
      'buckets': buckets,
    };
  }

  /// Empty by default: `continuousModeEnabled` is off in [settings].
  Map<String, Object?> liveContinuousEnergyBuckets() {
    return const {};
  }

  /// Ninety ten-second buckets: the efficiency card's fifteen-minute window.
  ///
  /// The drive is written to exercise every state the card has to draw, not to
  /// look tidy: a braking stretch that ends in a net gain, a stop with the
  /// climate system still running, a coast, and an interval the car reported
  /// nothing for.
  Map<String, Object?> liveEfficiencyBuckets() {
    const widthMillis = 10000;
    final start = (_now ~/ widthMillis) * widthMillis - 89 * widthMillis;
    final buckets = List.generate(90, (index) {
      final braking = index >= 34 && index < 40;
      final stopped = index >= 55 && index < 62;
      final coasting = index >= 70 && index < 73;
      // Stopped with nothing running: a red light. Distinct from `stopped`,
      // which keeps the climate load and reads as `idle`. Without it the mock
      // never produces `EfficiencyState.still`.
      final waiting = index >= 64 && index < 67;
      final silent = index >= 47 && index < 49;

      if (silent) {
        return <String, Object?>{
          'startUtcMillis': start + index * widthMillis,
          'tractionWh': 0.0,
          'regeneratedWh': 0.0,
          'auxiliaryWh': 0.0,
          'integratedSeconds': 0.0,
          'speedDistanceKm': 0.0,
          'odometerDistanceKm': 0.0,
          'speedIntegratedSeconds': 0.0,
        };
      }

      final speedKmh = stopped || waiting
          ? 0.0
          : (34 + (index * 7) % 46).toDouble();
      final tractionWh = switch (true) {
        _ when stopped || waiting => 0.0,
        _ when coasting => 0.2,
        _ when braking => 0.0,
        _ => 28 + (index * 13) % 44,
      }.toDouble();
      return <String, Object?>{
        'startUtcMillis': start + index * widthMillis,
        'tractionWh': tractionWh,
        // Coasting is a crossing, not a common state: with the auxiliary load
        // counted, a plain lift-off still draws and still has a real ratio.
        // Only a lift that regenerates just enough to cancel the auxiliaries
        // brings net energy near zero, which is the case worth a guard.
        'regeneratedWh': switch (true) {
          _ when braking => 18.0 + index % 5,
          _ when coasting => 3.55,
          _ => 0.0,
        },
        'auxiliaryWh': switch (true) {
          _ when waiting => 0.0,
          _ when stopped => 6.0,
          _ => 3.5,
        },
        'integratedSeconds': 10.0,
        'speedDistanceKm': speedKmh * 10 / 3600,
        'odometerDistanceKm': 0.0,
        'speedIntegratedSeconds': 10.0,
      };
    }, growable: false);
    return {
      'sessionId': 'mock-trip-002',
      'startedAtUtcMillis': start,
      'bucketMillis': widthMillis,
      'buckets': buckets,
    };
  }

  Map<String, Object?> chargeSessions({required int limit}) {
    final rows = _chargeRows();
    return {
      'sessions': rows.take(limit).toList(growable: false),
      'totalCount': rows.length,
      'limit': limit,
      'chargeWritesThisRun': rows.length,
    };
  }

  Map<String, Object?> sessionFrames({
    required String sessionId,
    required int limit,
  }) {
    final now = _now;
    final frames = List.generate(90, (index) {
      final timestamp = now - (90 - index) * 1000;
      final isCharge = sessionId.startsWith('mock-charge');
      final speed = isCharge ? 0.0 : (18 + (index % 35)).toDouble();
      final power = isCharge ? 6.8 + (index % 8) / 10 : -5.0 - (index % 18) / 2;
      return {
        'id': '$sessionId-frame-$index',
        'sessionId': sessionId,
        'sessionType': isCharge ? 'CHARGE' : 'TRIP',
        'timestampUtcMillis': timestamp,
        'elapsedRealtimeNanos': timestamp * 1000000,
        'socPercent': isCharge ? 47.0 + index * 0.12 : 66.0 - index * 0.03,
        'voltageV': 386.0 + (index % 6) / 10,
        'currentA': power / 0.386,
        'powerKw': power,
        'speedKmh': speed,
        'odometerKm': 12821.0 + index * 0.01,
        'gear': speed > 0 ? 8 : 4,
        'chargeState': isCharge ? 1 : 0,
        'chargePlugType': isCharge ? 2 : 0,
        'ambientTempC': 21.5 + (index % 10) / 5,
        'latitude': -23.5617 + index * 0.00005,
        'longitude': -46.6559 + index * 0.00004,
        'altitudeM': 760.0 + (index % 12),
        'gpsAccuracyM': 5.0,
        'locationProvider': 'mock',
        'locationElapsedRealtimeNanos': timestamp * 1000000,
        'sampleCount': 9,
        'freshnessMask': 255,
        'qualityMask': 0,
      };
    });
    return {
      'sessionId': sessionId,
      'totalCount': frames.length,
      'limit': limit,
      'frames': frames.take(limit).toList(growable: false),
    };
  }

  /// Mirrors the `RANGE_REMAINING` read on the car (266 km at 72% SOC on a
  /// live read; property `0x11400308`), on top
  /// of the same SOC and closed-trip efficiency the other mock surfaces report,
  /// so the vehicle range and the app estimate stay consistent with each other.
  Map<String, Object?> rangeEstimate({bool collecting = true}) {
    final now = _now;
    final capacityKwh = batteryCapacityWh / 1000;
    const efficiencyKmPerKwh = 7.18;
    final fullRangeKm = capacityKwh * efficiencyKmPerKwh;
    const socPercent = 63.4;
    final ownRangeKm = socPercent / 100 * fullRangeKm;
    if (!collecting) {
      return {
        'timestampMillis': now,
        'carRangeKm': null,
        'carRangeQuality': 'UNAVAILABLE',
        'carRangeReason': 'COLLECTION_STOPPED',
        'carRangePropertyId': 289407752,
        'carRangeSignalSource': null,
        'carRangeReceivedAtUtcMillis': null,
        'carRangeSourceTimestampNanos': null,
        'socPercent': null,
        'capacityKwh': capacityKwh,
        'capacitySource': 'SETTINGS',
        'efficiencyKmPerKwh': efficiencyKmPerKwh,
        'efficiencySource': 'CLOSED_TRIPS_7D',
        'efficiencyWindowDays': 7,
        'efficiencyTripCount': 2,
        'efficiencyDistanceKm': 24.7,
        'efficiencyNetEnergyKwh': 3.44,
        'efficiencyUpdatedAtUtcMillis': now,
        'fullRangeKm': null,
        'ownRangeKm': null,
        'ownRangeQuality': 'UNAVAILABLE',
        'ownRangeReason': 'COLLECTION_STOPPED',
      };
    }
    return {
      'timestampMillis': now,
      'carRangeKm': 266.0,
      'carRangeQuality': 'AVAILABLE',
      'carRangeReason': null,
      'carRangePropertyId': 289407752,
      'carRangeSignalSource': 'VHAL_CALLBACK',
      'carRangeReceivedAtUtcMillis': now,
      'carRangeSourceTimestampNanos': now * 1000000,
      'socPercent': socPercent,
      'capacityKwh': capacityKwh,
      'capacitySource': 'SETTINGS',
      'efficiencyKmPerKwh': efficiencyKmPerKwh,
      'efficiencySource': 'CLOSED_TRIPS_7D',
      'efficiencyWindowDays': 7,
      'efficiencyTripCount': 2,
      'efficiencyDistanceKm': 24.7,
      'efficiencyNetEnergyKwh': 3.44,
      'efficiencyUpdatedAtUtcMillis': now,
      'fullRangeKm': fullRangeKm,
      'ownRangeKm': ownRangeKm,
      'ownRangeQuality': 'AVAILABLE',
      'ownRangeReason': null,
    };
  }

  /// A mock course over ground.
  ///
  /// It turns slowly and continuously, one full circle every two minutes, so
  /// the web build can exercise the wrap through north that a compass has to
  /// draw. Pass `moving` false for the state a stopped car reports: a fresh fix
  /// with no course at all.
  Map<String, Object?> heading({bool moving = true}) {
    final now = _now;
    if (!moving) {
      return {
        'timestampMillis': now,
        'availability': 'NO_BEARING',
        'bearingDeg': null,
        'bearingAccuracyDeg': null,
        'speedMps': 0.0,
        'fixAgeMillis': 900,
      };
    }
    return {
      'timestampMillis': now,
      'availability': 'OK',
      'bearingDeg': (now % 120000) / 120000 * 360.0,
      'bearingAccuracyDeg': 8.5,
      'speedMps': 12.4,
      'fixAgeMillis': 420,
    };
  }

  Map<String, Object?> clearTelemetryDatabase() => {
    'ok': true,
    'telemetryEventsDeleted': 0,
    'tripSessionsDeleted': 0,
    'chargeSessionsDeleted': 0,
    'telemetryFramesDeleted': 0,
    'sessionAggregatesDeleted': 0,
    'timestampMillis': _now,
  };

  Map<String, Object?> retention() => {
    'ok': true,
    'skipped': false,
    'reason': 'mock',
    'retentionDays': 30,
    'cutoffUtcMillis': _now - 30 * 24 * 60 * 60 * 1000,
    'aggregatesUpserted': 4,
    'telemetryFramesDeleted': 0,
    'telemetryEventsDeleted': 0,
    'lastRunUtcMillis': _now,
    'timestampMillis': _now,
  };

  Map<String, Object?> settings({
    bool autoStartOnBoot = true,
    bool gpsEnabled = true,
    bool keepBluetoothOnEnabled = false,
    bool debugEventFileEnabled = false,
    bool temperatureModeHelperEnabled = false,
    bool replaceOemChargingEnabled = false,
    bool externalChargeControlEnabled = false,
    int chargeTargetSoc = 80,
    bool continuousModeEnabled = false,
    double? defaultChargeCostPerKwh = 0.9,
    double packCapacityWh = 39600,
    String chargeCostCurrency = 'BRL',
  }) => {
    'autoStartOnBoot': autoStartOnBoot,
    'gpsEnabled': gpsEnabled,
    'keepBluetoothOnEnabled': keepBluetoothOnEnabled,
    'debugEventFileEnabled': debugEventFileEnabled,
    'temperatureModeHelperEnabled': temperatureModeHelperEnabled,
    'replaceOemChargingEnabled': replaceOemChargingEnabled,
    'externalChargeControlEnabled': externalChargeControlEnabled,
    'chargeTargetSoc': chargeTargetSoc,
    'continuousModeEnabled': continuousModeEnabled,
    'defaultChargeCostPerKwh': defaultChargeCostPerKwh,
    'packCapacityWh': packCapacityWh,
    'chargeCostCurrency': chargeCostCurrency,
  };

  Map<String, Object?> chargeControlAppStatus({
    bool installed = false,
    bool updateAvailable = false,
    bool installScheduled = false,
  }) => {
    'installed': installed,
    'installedVersionName': installed ? '1.0.0' : null,
    'installedVersionCode': installed ? 1 : null,
    'availableVersionName': '1.0.0',
    'availableVersionCode': 1,
    'updateAvailable': updateAvailable,
    'installScheduled': installScheduled,
    'error': null,
  };

  Map<String, Object?> appUpdateStatus({
    bool checked = false,
    bool updateAvailable = true,
    bool installScheduled = false,
  }) => {
    'checked': checked,
    'updateAvailable': checked && updateAvailable,
    'compatible': true,
    'installedVersionName': '0.4.3',
    'installedVersionCode': 45,
    'availableVersionName': checked ? '0.4.6' : null,
    'availableVersionCode': checked ? 59 : null,
    'requiresReflash': false,
    'installScheduled': installScheduled,
    'changelog': checked
        ? [
            {
              'versionName': '0.4.6',
              'versionCode': 59,
              'notes': {
                'en': ['Improves app update details.'],
                'pt': ['Melhora os detalhes da atualização do app.'],
                'ru': ['Улучшены сведения об обновлении приложения.'],
              },
            },
          ]
        : const [],
    'error': null,
  };

  Map<String, Object?> _reading(Object? value) => {
    'ok': value != null,
    'value': value,
    'source': 'mock',
    'details': 'Web mock telemetry',
  };

  Map<String, Object?> _signal(
    String signalId,
    Object? value,
    String unit,
    int now,
    String propertyIdHex,
  ) => {
    'signalId': signalId,
    'value': value,
    'unit': unit,
    // Mesmo enum do `SignalQuality` nativo: a tela live recusa UNAVAILABLE/ERROR, e
    // um rótulo que não existe no Kotlin faria o mock passar por um caminho que o
    // carro nunca toma.
    'quality': 'MEASURED',
    'source': 'mock',
    'propertyId': 0,
    'propertyIdHex': propertyIdHex,
    'areaId': 0,
    'timestampMillis': now,
    'sourceTimestampNanos': null,
    'timestamp': _timestamp(now),
    'details': 'Web mock telemetry',
  };

  List<Map<String, Object?>> _events() {
    final now = _now;
    return [
      _event(
        'evt-004',
        'TRIP_STARTED',
        now - 2 * 60 * 60 * 1000,
        'mock-trip-002',
      ),
      _event(
        'evt-003',
        'CHARGE_ENDED',
        now - 4 * 60 * 60 * 1000,
        'mock-charge-002',
      ),
      _event(
        'evt-002',
        'CHARGE_STARTED',
        now - 6 * 60 * 60 * 1000,
        'mock-charge-002',
      ),
      _event(
        'evt-001',
        'TRIP_ENDED',
        now - 27 * 60 * 60 * 1000,
        'mock-trip-001',
      ),
    ];
  }

  Map<String, Object?> _event(
    String id,
    String type,
    int timestamp,
    String details,
  ) => {
    'id': id,
    'type': type,
    'timestamp': _timestamp(timestamp),
    'signalId': null,
    'value': null,
    'previousValue': null,
    'quality': 'FRESH',
    'source': 'mock',
    'details': details,
  };

  List<Map<String, Object?>> _tripRows() {
    final now = _now;
    return [
      {
        'id': 'mock-trip-002',
        'status': 'ACTIVE',
        'startedAtUtcMillis': now - 2 * 60 * 60 * 1000,
        'startedAtElapsedNanos': 1000000000,
        'movementStartedAtUtcMillis': now - 2 * 60 * 60 * 1000 + 30000,
        'movementStartedAtElapsedNanos': 1030000000,
        'endedAtUtcMillis': null,
        'endedAtElapsedNanos': null,
        'startSoc': 66.3,
        'endSoc': null,
        'startOdometerKm': 12821.4,
        'endOdometerKm': null,
        'startGear': 8,
        'endReason': null,
        'createdAtUtcMillis': now - 2 * 60 * 60 * 1000,
        'updatedAtUtcMillis': now,
      },
      {
        'id': 'mock-trip-001',
        'status': 'ENDED',
        'startedAtUtcMillis': now - 27 * 60 * 60 * 1000,
        'startedAtElapsedNanos': 1000000000,
        'movementStartedAtUtcMillis': now - 27 * 60 * 60 * 1000 + 20000,
        'movementStartedAtElapsedNanos': 1020000000,
        'endedAtUtcMillis': now - 26 * 60 * 60 * 1000,
        'endedAtElapsedNanos': 4600000000,
        'startSoc': 71.2,
        'endSoc': 68.6,
        'startOdometerKm': 12796.7,
        'endOdometerKm': 12821.4,
        'startGear': 8,
        'endReason': 'GEAR_P_STABLE',
        'createdAtUtcMillis': now - 27 * 60 * 60 * 1000,
        'updatedAtUtcMillis': now - 26 * 60 * 60 * 1000,
      },
    ];
  }

  List<Map<String, Object?>> _chargeRows() {
    final now = _now;
    return [
      {
        'id': 'mock-charge-002',
        'status': 'COMPLETE',
        'plugConnectedAtUtcMillis': now - 6 * 60 * 60 * 1000,
        'plugConnectedAtElapsedNanos': 1000000000,
        'chargeStartedAtUtcMillis': now - 6 * 60 * 60 * 1000 + 60000,
        'chargeStartedAtElapsedNanos': 1060000000,
        'chargeEndedAtUtcMillis': now - 4 * 60 * 60 * 1000,
        'chargeEndedAtElapsedNanos': 8200000000,
        'plugDisconnectedAtUtcMillis': now - 4 * 60 * 60 * 1000 + 120000,
        'plugDisconnectedAtElapsedNanos': 8320000000,
        'startSoc': 46.8,
        'endSoc': 63.4,
        'startOdometerKm': 12821.4,
        'endOdometerKm': 12821.4,
        'plugType': 2,
        'startPowerKw': 6.8,
        'estimatedEnergyKwh': 10.2,
        'costPerKwh': 0.9,
        'paidAmount': null,
        'costCurrency': 'BRL',
        'startAmbientTempC': 24.5,
        'endAmbientTempC': 19.0,
        'endReason': 'PLUG_DISCONNECTED',
        'createdAtUtcMillis': now - 6 * 60 * 60 * 1000,
        'updatedAtUtcMillis': now - 4 * 60 * 60 * 1000 + 120000,
      },
      {
        'id': 'mock-charge-001',
        'status': 'COMPLETE',
        'plugConnectedAtUtcMillis': now - 2 * 24 * 60 * 60 * 1000,
        'plugConnectedAtElapsedNanos': 1000000000,
        'chargeStartedAtUtcMillis': now - 2 * 24 * 60 * 60 * 1000 + 45000,
        'chargeStartedAtElapsedNanos': 1045000000,
        'chargeEndedAtUtcMillis':
            now - 2 * 24 * 60 * 60 * 1000 + 70 * 60 * 1000,
        'chargeEndedAtElapsedNanos': 5200000000,
        'plugDisconnectedAtUtcMillis':
            now - 2 * 24 * 60 * 60 * 1000 + 72 * 60 * 1000,
        'plugDisconnectedAtElapsedNanos': 5320000000,
        'startSoc': 38.4,
        'endSoc': 52.0,
        'startOdometerKm': 12796.7,
        'endOdometerKm': 12796.7,
        'plugType': 2,
        'startPowerKw': 7.1,
        'estimatedEnergyKwh': 6.4,
        'costPerKwh': 0.9,
        'paidAmount': 8.5,
        'costCurrency': 'BRL',
        'startAmbientTempC': 18.0,
        'endAmbientTempC': 21.5,
        'endReason': 'PLUG_DISCONNECTED',
        'createdAtUtcMillis': now - 2 * 24 * 60 * 60 * 1000,
        'updatedAtUtcMillis': now - 2 * 24 * 60 * 60 * 1000 + 72 * 60 * 1000,
      },
    ];
  }

  Map<String, Object?> _timestamp(int millis) => {
    'receivedAtUtcMillis': millis,
    'receivedAtElapsedNanos': millis * 1000000,
    'sourceTimestampNanos': null,
    'accuracy': 'RECEIVED_EVENT',
    'uncertaintyMillis': 0,
  };
}
