import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  Journey journey() => const Journey(
    id: 'j1',
    name: 'Férias na serra',
    startedAtUtcMillis: 1000,
    endedAtUtcMillis: 2000,
    updatedAtUtcMillis: 1500,
  );

  group('Journey.fromMap', () {
    test('parses a complete row', () {
      final journey = Journey.fromMap({
        'id': 'j1',
        'name': ' Férias ',
        'startedAtUtcMillis': 1000,
        'endedAtUtcMillis': 2000,
        'note': ' duas cidades ',
        'createdAtUtcMillis': 900,
        'updatedAtUtcMillis': 1500,
        'origin': 'car',
        'deletedAtUtcMillis': null,
      });
      expect(journey, isNotNull);
      expect(journey!.name, 'Férias');
      expect(journey.note, 'duas cidades');
      expect(journey.origin, 'car');
      expect(journey.deleted, isFalse);
    });

    test('refuses a row without an identity, a name or the clock', () {
      Map<String, Object?> base() => {
        'id': 'j1',
        'name': 'n',
        'startedAtUtcMillis': 1000,
        'endedAtUtcMillis': 2000,
        'updatedAtUtcMillis': 1500,
      };
      expect(Journey.fromMap(null), isNull);
      expect(
        Journey.fromMap(base()..remove('id')),
        isNull,
        reason: 'no identity',
      );
      expect(
        Journey.fromMap(base()..['name'] = '   '),
        isNull,
        reason: 'a blank name is no name',
      );
      expect(
        Journey.fromMap(base()..remove('updatedAtUtcMillis')),
        isNull,
        reason: 'no clock to merge with',
      );
    });

    test('refuses an inverted window', () {
      expect(
        Journey.fromMap({
          'id': 'j1',
          'name': 'n',
          'startedAtUtcMillis': 2000,
          'endedAtUtcMillis': 1000,
          'updatedAtUtcMillis': 1500,
        }),
        isNull,
      );
    });

    test('keeps a tombstone row', () {
      final journey = Journey.fromMap({
        'id': 'j1',
        'name': 'n',
        'startedAtUtcMillis': 1000,
        'endedAtUtcMillis': 2000,
        'updatedAtUtcMillis': 1500,
        'deletedAtUtcMillis': 1600,
      })!;
      expect(journey.deleted, isTrue);
      expect(journey.toMap()['deletedAtUtcMillis'], 1600);
    });

    test('roundtrips through its own map', () {
      final map = journey().copyWith(deletedAtUtcMillis: 1800).toMap();
      expect(
        Journey.fromMap(map),
        journey().copyWith(deletedAtUtcMillis: 1800),
      );
    });
  });

  group('journeyCoversSession', () {
    test('a session that started inside the window belongs', () {
      expect(journeyCoversSession(journey(), 1000), isTrue);
      expect(journeyCoversSession(journey(), 1500), isTrue);
      expect(journeyCoversSession(journey(), 2000), isTrue);
    });

    test('a session outside the window does not', () {
      expect(journeyCoversSession(journey(), 999), isFalse);
      expect(journeyCoversSession(journey(), 2001), isFalse);
    });

    test('a deleted journey covers nothing', () {
      final dead = journey().copyWith(deletedAtUtcMillis: 1600);
      expect(journeyCoversSession(dead, 1500), isFalse);
    });
  });

  group('foldJourneySessions', () {
    SessionRecord trip({
      required String id,
      required double distanceKm,
      double netWh = 1000,
    }) {
      return SessionRecord(
        id: id,
        vehicleId: 'v',
        kind: SessionKind.trip,
        status: 'CLOSED',
        startedAtUtcMillis: 1100,
        startedAtElapsedNanos: 0,
        rollup: SessionRollup(
          distance: Measurement.measured(distanceKm, unit: 'km'),
          traction: Measurement.measured(netWh + 100, unit: 'Wh'),
          regen: Measurement.measured(100, unit: 'Wh'),
          auxiliary: Measurement.measured(0, unit: 'Wh'),
          climate: Measurement.measured(0, unit: 'Wh'),
          delivered: Measurement.measured(0, unit: 'Wh'),
          integratedSeconds: Measurement.measured(600, unit: 's'),
        ),
        startOdometer: Measurement.measured(10.0, unit: 'km'),
        endOdometer: Measurement.measured(10.0 + distanceKm, unit: 'km'),
        startSoc: Measurement.unreported(unit: '%'),
        endSoc: Measurement.unreported(unit: '%'),
        minSoc: Measurement.unreported(unit: '%'),
        maxSoc: Measurement.unreported(unit: '%'),
        startAmbientTemp: Measurement.unreported(unit: '°C'),
        endAmbientTemp: Measurement.unreported(unit: '°C'),
        meanAmbientTemp: Measurement.unreported(unit: '°C'),
        createdAtUtcMillis: 1100,
        updatedAtUtcMillis: 1200,
      );
    }

    SessionRecord charge({
      required String id,
      required double kwh,
      double? rate,
      double? paid,
    }) {
      return SessionRecord(
        id: id,
        vehicleId: 'v',
        kind: SessionKind.charge,
        status: 'CLOSED',
        startedAtUtcMillis: 1200,
        startedAtElapsedNanos: 0,
        rollup: SessionRollup(
          distance: Measurement.unreported(unit: 'km'),
          traction: Measurement.measured(0, unit: 'Wh'),
          regen: Measurement.measured(0, unit: 'Wh'),
          auxiliary: Measurement.measured(0, unit: 'Wh'),
          climate: Measurement.measured(0, unit: 'Wh'),
          delivered: Measurement.measured(kwh * 1000, unit: 'Wh'),
          integratedSeconds: Measurement.measured(3600, unit: 's'),
        ),
        startOdometer: Measurement.unreported(unit: 'km'),
        endOdometer: Measurement.unreported(unit: 'km'),
        startSoc: Measurement.unreported(unit: '%'),
        endSoc: Measurement.unreported(unit: '%'),
        minSoc: Measurement.unreported(unit: '%'),
        maxSoc: Measurement.unreported(unit: '%'),
        startAmbientTemp: Measurement.unreported(unit: '°C'),
        endAmbientTemp: Measurement.unreported(unit: '°C'),
        meanAmbientTemp: Measurement.unreported(unit: '°C'),
        costPerKwh: rate,
        paidAmount: paid,
        createdAtUtcMillis: 1200,
        updatedAtUtcMillis: 1300,
      );
    }

    test('an empty journey folds to honest zeros', () {
      final reading = foldJourneySessions(const []);
      expect(reading.isEmpty, isTrue);
      expect(reading.distanceKm.displayValue, 0);
      expect(reading.netKwh.displayValue, 0);
      expect(reading.deliveredKwh.displayValue, 0);
      expect(reading.chargesCost, isNull);
    });

    test('sums what the car folded over every member', () {
      final reading = foldJourneySessions([
        trip(id: 't1', distanceKm: 120),
        trip(id: 't2', distanceKm: 80),
        charge(id: 'c1', kwh: 20, rate: 1.0),
      ]);
      expect(reading.tripCount, 2);
      expect(reading.chargeCount, 1);
      expect(reading.distanceKm.displayValue, 200);
      expect(reading.deliveredKwh.displayValue, 20);
      expect(reading.netKwh.isMeasured, isTrue);
      expect(reading.chargesCost, 20.0);
    });

    test('one member without a value prints nothing for that total', () {
      final reading = foldJourneySessions([
        trip(id: 't1', distanceKm: 120),
        SessionRecord(
          id: 't2',
          vehicleId: 'v',
          kind: SessionKind.trip,
          status: 'CLOSED',
          startedAtUtcMillis: 1150,
          startedAtElapsedNanos: 0,
          rollup: const SessionRollup(
            distance: Measurement.unreported(unit: 'km'),
            traction: Measurement.unreported(unit: 'Wh'),
            regen: Measurement.unreported(unit: 'Wh'),
            auxiliary: Measurement.unreported(unit: 'Wh'),
            climate: Measurement.unreported(unit: 'Wh'),
            delivered: Measurement.unreported(unit: 'Wh'),
            integratedSeconds: Measurement.unreported(unit: 's'),
          ),
          startOdometer: Measurement.unreported(unit: 'km'),
          endOdometer: Measurement.unreported(unit: 'km'),
          startSoc: Measurement.unreported(unit: '%'),
          endSoc: Measurement.unreported(unit: '%'),
          minSoc: Measurement.unreported(unit: '%'),
          maxSoc: Measurement.unreported(unit: '%'),
          startAmbientTemp: Measurement.unreported(unit: '°C'),
          endAmbientTemp: Measurement.unreported(unit: '°C'),
          meanAmbientTemp: Measurement.unreported(unit: '°C'),
          createdAtUtcMillis: 1150,
          updatedAtUtcMillis: 1160,
        ),
      ]);
      expect(reading.distanceKm.hasValue, isFalse);
      expect(reading.netKwh.hasValue, isFalse);
    });

    test('an unpriced charge refuses the money total', () {
      final reading = foldJourneySessions([
        charge(id: 'c1', kwh: 20, rate: 1.0),
        charge(id: 'c2', kwh: 5),
      ]);
      expect(reading.chargesCost, isNull);
    });
  });
}
