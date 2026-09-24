import 'dart:convert';
import 'dart:io';

import 'package:capy_energy/core/room_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

import 'support/fixture_wire_api.dart';

void main() {
  group('RoomStore with shared fixture', () {
    late RoomStore store;
    late Map<String, dynamic> fixture;

    setUp(() async {
      var fixtureFile = File('testdata/telemetry_store_cases.json');
      if (!fixtureFile.existsSync()) {
        fixtureFile = File('../testdata/telemetry_store_cases.json');
      }
      final content = await fixtureFile.readAsString();
      fixture = jsonDecode(content) as Map<String, dynamic>;

      final cases = fixture['cases'] as List<dynamic>;
      final mockWire = FixtureWireApi(cases);
      store = RoomStore(wire: mockWire);
    });

    test('Question 1: listSessions matches fixture parity', () async {
      final page = await store.listSessions();

      expect(page.totalCount, 2);
      expect(page.sessions.length, 2);
      expect(page.hasMore, isFalse);

      expect(page.sessions[0].id, 'charge-001');
      expect(page.sessions[0].kind, SessionKind.charge);
      expect(page.sessions[0].rollup.delivered.value, 14000.0);

      expect(page.sessions[1].id, 'trip-001');
      expect(page.sessions[1].kind, SessionKind.trip);
      expect(page.sessions[1].rollup.distance.value, 2.5);
      expect(page.sessions[1].rollup.netPackEnergy.value, 440.0);
    });

    test('Question 2: session matches fixture parity and events', () async {
      final detail = await store.session('trip-001');
      expect(detail, isNotNull);
      expect(detail!.session.id, 'trip-001');
      expect(detail.session.startSoc.value, 85.0);
      expect(detail.events.length, 2);
      expect(detail.events[0].type, 'TRIP_ARMED');
    });

    test('Question 3: series matches fixture intervals and samples', () async {
      final series = await store.series('trip-001', widthMillis: 120000);
      expect(series.sessionId, 'trip-001');
      expect(series.intervals.length, 2);
      expect(series.intervals[0].widthMillis, 120000);
      expect(series.intervals[0].traction.value, 380.0);
      expect(series.intervals[0].distance.value, closeTo(1.7, 1e-6));

      expect(series.samples.containsKey('VEHICLE_SPEED'), isTrue);
      expect(series.samples['VEHICLE_SPEED']!.length, 3);
    });
  });

  group('RoomStore pending time (time authority T7)', () {
    test('a pending session positions by the monotonic pair', () async {
      // The same rows as the companion's pending test, answered as the
      // Pigeon surface answers them: the car must draw the same two bars.
      const minuteNanos = 60000000000;
      final rows = [
        (elapsed: 2 * minuteNanos, traction: 300.0, stamp: 1000000),
        (elapsed: 0, traction: 100.0, stamp: 2000000),
        (elapsed: minuteNanos, traction: 200.0, stamp: 3000000),
      ];
      IntervalRecordWire wireFor(
        ({int elapsed, double traction, int stamp}) row,
      ) => IntervalRecordWire(
        sessionId: 'pending-session',
        startUtcMillis: row.stamp,
        widthMillis: 60000,
        traction: MeasurementWire(
          value: row.traction,
          unit: 'Wh',
          validity: 'measured',
          note: '',
        ),
        regen: MeasurementWire(unit: 'Wh', validity: 'unreported', note: ''),
        auxiliary: MeasurementWire(
          unit: 'Wh',
          validity: 'unreported',
          note: '',
        ),
        climate: MeasurementWire(unit: 'Wh', validity: 'unreported', note: ''),
        delivered: MeasurementWire(
          unit: 'Wh',
          validity: 'unreported',
          note: '',
        ),
        distance: MeasurementWire(unit: 'km', validity: 'unreported', note: ''),
        coveredSeconds: 60,
        climateCoveredSeconds: 0,
        speedCoveredSeconds: 0,
        deliveredCoveredSeconds: 0,
        startElapsedNanos: row.elapsed,
        startBootCount: 7,
        timeState: 'pending',
      );
      final store = RoomStore(
        wire: _PendingWire([for (final row in rows) wireFor(row)]),
      );

      final series = await store.series('pending-session', widthMillis: 120000);

      expect(series.intervals, hasLength(2));
      expect(series.intervals[0].traction.value, 300.0);
      expect(series.intervals[1].traction.value, 300.0);

      final series1Min = await store.series('pending-session');
      expect(series1Min.intervals, hasLength(3));
      // 1-minute series must return in driving order (elapsed 0, 1m, 2m),
      // not stamp order (which had the 2m row first).
      expect(series1Min.intervals[0].traction.value, 100.0);
      expect(series1Min.intervals[1].traction.value, 200.0);
      expect(series1Min.intervals[2].traction.value, 300.0);
    });
  });
}

/// Answers one pending series; every other question is out of scope.
class _PendingWire extends FixtureWireApi {
  _PendingWire(this.pendingIntervals) : super(const []);

  final List<IntervalRecordWire> pendingIntervals;

  @override
  Future<TelemetrySeriesWire> storeGetSeries(
    String id,
    List<String>? keys,
    int? widthMillis,
  ) async => TelemetrySeriesWire(
    sessionId: id,
    intervals: pendingIntervals,
    sampleSeries: const [],
  );
}
