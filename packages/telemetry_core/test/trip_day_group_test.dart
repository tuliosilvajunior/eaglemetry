import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  final homePlace = const InsightPlace(
    id: 'place-home',
    name: 'Casa',
    latitude: -23.5505,
    longitude: -46.6333,
    radiusM: 150.0,
  );

  final workPlace = const InsightPlace(
    id: 'place-work',
    name: 'Trabalho',
    latitude: -23.5615,
    longitude: -46.6559,
    radiusM: 150.0,
  );

  SessionRecord createTestSession({
    required String id,
    required int startedAtUtcMillis,
    required int endedAtUtcMillis,
    double distanceKm = 10.0,
    double tractionWh = 1800.0,
    double regenWh = 300.0,
    double auxWh = 100.0,
    double startLat = -23.5505,
    double startLon = -46.6333,
    double? endLat = -23.5615,
    double? endLon = -46.6559,
    double startSoc = 80.0,
    double endSoc = 75.0,
  }) {
    final startOdo = Measurement.measured(1000.0, unit: 'km');
    final endOdo = Measurement.measured(1000.0 + distanceKm, unit: 'km');
    final rollup = SessionRollup(
      distance: Measurement.measured(distanceKm, unit: 'km'),
      traction: Measurement.measured(tractionWh, unit: 'Wh'),
      regen: Measurement.measured(regenWh, unit: 'Wh'),
      auxiliary: Measurement.measured(auxWh, unit: 'Wh'),
      climate: const Measurement.unreported(unit: 'Wh'),
      delivered: const Measurement.unreported(unit: 'Wh'),
      integratedSeconds: Measurement.measured(
        (endedAtUtcMillis - startedAtUtcMillis) / 1000.0,
        unit: 's',
      ),
    );

    return SessionRecord(
      id: id,
      vehicleId: 'test-car',
      kind: SessionKind.trip,
      status: 'CLOSED',
      startedAtUtcMillis: startedAtUtcMillis,
      startedAtElapsedNanos: 0,
      endedAtUtcMillis: endedAtUtcMillis,
      endedAtElapsedNanos: (endedAtUtcMillis - startedAtUtcMillis) * 1000000,
      durationMillis: endedAtUtcMillis - startedAtUtcMillis,
      rollup: rollup,
      startOdometer: startOdo,
      endOdometer: endOdo,
      startSoc: Measurement.measured(startSoc, unit: '%'),
      endSoc: Measurement.measured(endSoc, unit: '%'),
      minSoc: Measurement.measured(endSoc, unit: '%'),
      maxSoc: Measurement.measured(startSoc, unit: '%'),
      startAmbientTemp: Measurement.measured(22.0, unit: '°C'),
      endAmbientTemp: Measurement.measured(23.0, unit: '°C'),
      meanAmbientTemp: Measurement.measured(22.5, unit: '°C'),
      startLatitude: startLat,
      startLongitude: startLon,
      createdAtUtcMillis: startedAtUtcMillis,
      updatedAtUtcMillis: endedAtUtcMillis,
    );
  }

  group('TripSessionEntry assembly', () {
    test('resolves start and end places from InsightPlace list', () {
      final session = createTestSession(
        id: 's1',
        startedAtUtcMillis: 1750000000000,
        endedAtUtcMillis: 1750001800000,
        distanceKm: 12.5,
        tractionWh: 2000.0,
        regenWh: 400.0,
        auxWh: 200.0,
      );

      final entry = assembleTripSessionEntry(
        session: session,
        places: [homePlace, workPlace],
        endLatitude: -23.5615,
        endLongitude: -46.6559,
        path: '-23.5505,-46.6333;-23.5550,-46.6400;-23.5615,-46.6559',
      );

      expect(entry.id, 's1');
      expect(entry.startPlace, 'Casa');
      expect(entry.endPlace, 'Trabalho');
      expect(entry.distanceKm, 12.5);
      expect(
        entry.netEnergyKwh,
        closeTo(1.8, 1e-4),
      ); // (2000 - 400 + 200) / 1000 = 1.8
      expect(entry.durationMillis, 1800000); // 30 min
      expect(
        entry.avgSpeedKmh,
        closeTo(25.0, 0.1),
      ); // 12.5 km / 0.5 h = 25 km/h
      expect(entry.routePoints, hasLength(3));
      expect(entry.routePoints.first.latitude, -23.5505);
      expect(entry.routePoints.last.latitude, -23.5615);
    });

    test('falls back to coordinates when place is not named', () {
      final session = createTestSession(
        id: 's2',
        startedAtUtcMillis: 1750000000000,
        endedAtUtcMillis: 1750001800000,
        startLat: -10.0,
        startLon: -20.0,
      );

      final entry = assembleTripSessionEntry(
        session: session,
        places: [homePlace, workPlace],
        endLatitude: -10.5,
        endLongitude: -20.5,
      );

      expect(entry.startPlace, isNull);
      expect(entry.endPlace, isNull);
      expect(entry.displayStartLocation, '-10.0000, -20.0000');
      expect(entry.displayEndLocation, '-10.5000, -20.5000');
    });
  });

  group('TripDayGroup assembly', () {
    test('groups trips by local calendar day and computes day totals', () {
      // Day 1: 2026-08-25 10:00 and 14:00 (local time)
      final t1 = DateTime(2026, 8, 25, 10, 0).millisecondsSinceEpoch;
      final t2 = DateTime(2026, 8, 25, 14, 0).millisecondsSinceEpoch;
      // Day 2: 2026-08-24 18:00 (local time)
      final t3 = DateTime(2026, 8, 24, 18, 0).millisecondsSinceEpoch;

      final s1 = createTestSession(
        id: 's1',
        startedAtUtcMillis: t1,
        endedAtUtcMillis: t1 + 1800000,
        distanceKm: 10.0,
        tractionWh: 2000.0,
        regenWh: 500.0,
        auxWh: 100.0, // net = 1.6 kWh
      );
      final s2 = createTestSession(
        id: 's2',
        startedAtUtcMillis: t2,
        endedAtUtcMillis: t2 + 1800000,
        distanceKm: 15.0,
        tractionWh: 3000.0,
        regenWh: 600.0,
        auxWh: 200.0, // net = 2.6 kWh
      );
      final s3 = createTestSession(
        id: 's3',
        startedAtUtcMillis: t3,
        endedAtUtcMillis: t3 + 1800000,
        distanceKm: 8.0,
        tractionWh: 1500.0,
        regenWh: 300.0,
        auxWh: 100.0, // net = 1.3 kWh
      );

      final entries = [
        assembleTripSessionEntry(session: s1, places: [homePlace]),
        assembleTripSessionEntry(session: s2, places: [homePlace]),
        assembleTripSessionEntry(session: s3, places: [homePlace]),
      ];

      final dayGroups = assembleTripDayGroups(entries);

      expect(dayGroups, hasLength(2));
      // First day: Aug 25 with 2 trips
      expect(dayGroups[0].date.year, 2026);
      expect(dayGroups[0].date.month, 8);
      expect(dayGroups[0].date.day, 25);
      expect(dayGroups[0].tripCount, 2);
      expect(dayGroups[0].totalDistanceKm, 25.0);
      expect(dayGroups[0].totalNetKwh, closeTo(4.2, 1e-4));
      expect(dayGroups[0].trips, hasLength(2));

      // Second day: Aug 24 with 1 trip
      expect(dayGroups[1].date.day, 24);
      expect(dayGroups[1].tripCount, 1);
      expect(dayGroups[1].totalDistanceKm, 8.0);
      expect(dayGroups[1].totalNetKwh, closeTo(1.3, 1e-4));
      expect(dayGroups[1].trips, hasLength(1));
    });
  });

  group('TripsFilter', () {
    test('filters by search query matching start or end place', () {
      final s1 = createTestSession(
        id: 's1',
        startedAtUtcMillis: 1750000000000,
        endedAtUtcMillis: 1750001800000,
      );
      final s2 = createTestSession(
        id: 's2',
        startedAtUtcMillis: 1750002000000,
        endedAtUtcMillis: 1750003800000,
        startLat: -23.5615,
        startLon: -46.6559,
      );

      final e1 = assembleTripSessionEntry(
        session: s1,
        places: [homePlace, workPlace],
        endLatitude: -23.5615,
        endLongitude: -46.6559,
      ); // Casa -> Trabalho
      final e2 = assembleTripSessionEntry(
        session: s2,
        places: [homePlace, workPlace],
        endLatitude: -23.5505,
        endLongitude: -46.6333,
      ); // Trabalho -> Casa

      const filterCasa = TripsFilter(query: 'casa');
      expect(filterCasa.matches(e1), isTrue);
      expect(filterCasa.matches(e2), isTrue);

      const filterTrabalho = TripsFilter(query: 'Trabalho');
      expect(filterTrabalho.matches(e1), isTrue);
      expect(filterTrabalho.matches(e2), isTrue);

      const filterShopping = TripsFilter(query: 'Shopping');
      expect(filterShopping.matches(e1), isFalse);
      expect(filterShopping.matches(e2), isFalse);
    });

    test('filters by time preset', () {
      final now = DateTime(2026, 8, 25, 12, 0);
      final within7d = now
          .subtract(const Duration(days: 3))
          .millisecondsSinceEpoch;
      final within30d = now
          .subtract(const Duration(days: 15))
          .millisecondsSinceEpoch;
      final older = now
          .subtract(const Duration(days: 45))
          .millisecondsSinceEpoch;

      final e1 = assembleTripSessionEntry(
        session: createTestSession(
          id: '1',
          startedAtUtcMillis: within7d,
          endedAtUtcMillis: within7d + 1000,
        ),
        places: const [],
      );
      final e2 = assembleTripSessionEntry(
        session: createTestSession(
          id: '2',
          startedAtUtcMillis: within30d,
          endedAtUtcMillis: within30d + 1000,
        ),
        places: const [],
      );
      final e3 = assembleTripSessionEntry(
        session: createTestSession(
          id: '3',
          startedAtUtcMillis: older,
          endedAtUtcMillis: older + 1000,
        ),
        places: const [],
      );

      const filterAll = TripsFilter(timePreset: TripsTimePreset.all);
      expect(filterAll.matches(e1, now: now), isTrue);
      expect(filterAll.matches(e2, now: now), isTrue);
      expect(filterAll.matches(e3, now: now), isTrue);

      const filter7d = TripsFilter(timePreset: TripsTimePreset.days7);
      expect(filter7d.matches(e1, now: now), isTrue);
      expect(filter7d.matches(e2, now: now), isFalse);
      expect(filter7d.matches(e3, now: now), isFalse);

      const filter30d = TripsFilter(timePreset: TripsTimePreset.days30);
      expect(filter30d.matches(e1, now: now), isTrue);
      expect(filter30d.matches(e2, now: now), isTrue);
      expect(filter30d.matches(e3, now: now), isFalse);
    });
  });
}
