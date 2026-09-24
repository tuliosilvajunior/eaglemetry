import 'dart:convert';
import 'dart:io';

import 'package:capy_companion/sync/companion_database.dart';
import 'package:capy_companion/sync/sqflite_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:telemetry_core/telemetry_core.dart';

Future<CompanionDatabase> _memoryDatabase() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  return CompanionDatabase.open(inMemoryDatabasePath, singleInstance: false);
}

void main() {
  group('SqfliteStore with shared fixture', () {
    late CompanionDatabase db;
    late SqfliteStore store;
    late Map<String, dynamic> fixture;

    setUp(() async {
      db = await _memoryDatabase();
      store = SqfliteStore(db);

      var fixtureFile = File('testdata/telemetry_store_cases.json');
      if (!fixtureFile.existsSync()) {
        fixtureFile = File('../../testdata/telemetry_store_cases.json');
      }
      final content = await fixtureFile.readAsString();
      fixture = jsonDecode(content) as Map<String, dynamic>;

      // Populate SQLite with fixture data
      final cases = fixture['cases'] as List<dynamic>;
      for (final c in cases) {
        final sessionMap = c['session'] as Map<String, dynamic>;
        await db.upsertSession(sessionMap);

        final intervals = c['intervals'] as List<dynamic>? ?? [];
        for (final inv in intervals) {
          await db.upsertInterval(inv as Map<String, dynamic>);
        }

        final events = c['events'] as List<dynamic>? ?? [];
        for (final ev in events) {
          await db.upsertEvent(ev as Map<String, dynamic>);
        }
      }
    });

    tearDown(() async {
      await db.close();
    });

    test(
      'Question 1: listSessions lists sessions with pagination and rollup Measurements',
      () async {
        final page = await store.listSessions(
          page: const PageRequest(limit: 10),
        );

        expect(page.totalCount, 2);
        expect(page.sessions.length, 2);
        expect(page.hasMore, isFalse);

        // Newest first by startedAtUtcMillis
        expect(page.sessions[0].id, 'charge-001');
        expect(page.sessions[0].kind, SessionKind.charge);
        expect(page.sessions[0].rollup.delivered.value, 14000.0);
        expect(page.sessions[0].rollup.delivered.unit, 'Wh');
        expect(page.sessions[0].rollup.delivered.isMeasured, isTrue);

        expect(page.sessions[1].id, 'trip-001');
        expect(page.sessions[1].kind, SessionKind.trip);
        expect(page.sessions[1].rollup.distance.value, 2.5);
        expect(page.sessions[1].rollup.distance.unit, 'km');
        expect(page.sessions[1].rollup.traction.value, 500.0);
        expect(page.sessions[1].rollup.regen.value, 100.0);
        expect(
          page.sessions[1].rollup.netPackEnergy.value,
          440.0,
        ); // 500 - 100 + 40
      },
    );

    test(
      'Question 1: listSessions applies SessionFilter by kind and time window',
      () async {
        final tripsOnly = await store.listSessions(
          filter: const SessionFilter(kind: SessionKind.trip),
        );
        expect(tripsOnly.totalCount, 1);
        expect(tripsOnly.sessions.first.id, 'trip-001');

        final chargesOnly = await store.listSessions(
          filter: const SessionFilter(kind: SessionKind.charge),
        );
        expect(chargesOnly.totalCount, 1);
        expect(chargesOnly.sessions.first.id, 'charge-001');

        final inWindow = await store.listSessions(
          filter: const SessionFilter(
            fromUtcMillis: 1700000000000,
            toUtcMillis: 1700000050000,
          ),
        );
        expect(inWindow.totalCount, 1);
        expect(inWindow.sessions.first.id, 'trip-001');
      },
    );

    test(
      'Question 2: session retrieves complete SessionDetail and chronological events',
      () async {
        final detail = await store.session('trip-001');
        expect(detail, isNotNull);
        expect(detail!.session.id, 'trip-001');
        expect(detail.session.startSoc.value, 85.0);
        expect(detail.session.endSoc.value, 84.0);
        expect(detail.session.startOdometer.value, 12500.0);
        expect(detail.session.endOdometer.value, 12502.5);
        expect(detail.session.startLatitude, 37.7749);

        expect(detail.events.length, 2);
        expect(detail.events[0].type, 'TRIP_ARMED');
        expect(detail.events[0].value, 'DRIVE');
        expect(detail.events[1].type, 'TRIP_ENDED');
        expect(detail.events[1].value, 'PARK');
      },
    );

    test('Question 2: session returns null for non-existent session', () async {
      final detail = await store.session('non-existent');
      expect(detail, isNull);
    });

    test('Question 3: series retrieves 1-minute intervals', () async {
      final series = await store.series('trip-001');

      expect(series.sessionId, 'trip-001');
      expect(series.intervals.length, 3);
      expect(series.intervals[0].startUtcMillis, 1700000000000);
      expect(series.intervals[0].traction.value, 200.0);
      expect(series.intervals[0].distance.value, 0.9);
      expect(series.intervals[1].traction.value, 180.0);
      expect(series.intervals[2].traction.value, 120.0);
      expect(series.samples, isEmpty);
    });

    test('Question 3: series reduces intervals with widthMillis', () async {
      // 2-minute bucket width
      final series = await store.series('trip-001', widthMillis: 120000);

      expect(series.intervals.length, 2);
      // Position comes from the ordinal on the one-minute grid, never from a
      // stamp subtraction: bucket 0 opens at minute 0, bucket 1 at minute 2.
      expect(series.intervals[0].startUtcMillis, 0);
      expect(series.intervals[0].widthMillis, 120000);
      expect(series.intervals[0].traction.value, 380.0);
      expect(series.intervals[0].regen.value, 70.0); // 30 + 40
      expect(
        series.intervals[0].distance.value,
        closeTo(1.7, 1e-6),
      ); // 0.9 + 0.8
      expect(series.intervals[0].coveredSeconds, 120.0);

      // Bucket 1 (minutes 2-3): interval 2 alone.
      expect(series.intervals[1].startUtcMillis, 120000);
      expect(series.intervals[1].traction.value, 120.0);
      expect(series.samples, isEmpty);
    });

    test(
      'Question 3: a bogus stamp does not widen the reduced session on the phone',
      () async {
        // Nine stored minutes, one of them stamped by a boot-default clock
        // years from the session. The store must reduce by ordinal, so the
        // phone draws nine minutes — the same bars as the car.
        const sessionStart = 1780000000000;
        for (var i = 0; i < 9; i++) {
          await db.upsertInterval({
            'sessionId': 'bogus-stamp-session',
            'startUtcMillis': i == 8
                ? 1753168080000 // 2025-05-23 22:08:00 UTC boot default
                : sessionStart + i * 60000,
            'tractionWh': 100.0,
            'regenWh': 0.0,
            'auxiliaryWh': 0.0,
            'climateWh': 0.0,
            'deliveredWh': 0.0,
            'distanceKm': 0.0,
            'coveredSeconds': 60.0,
            'climateCoveredSeconds': 0.0,
            'speedCoveredSeconds': 60.0,
            'deliveredCoveredSeconds': 0.0,
          });
        }
        final series = await store.series(
          'bogus-stamp-session',
          widthMillis: 120000,
        );

        // 5 two-minute buckets, never a 22000-hour span.
        expect(series.intervals, hasLength(5));
        final covered = series.intervals.fold<double>(
          0,
          (sum, inv) => sum + inv.coveredSeconds,
        );
        expect(covered, closeTo(9 * 60, 1e-9));
        final traction = series.intervals.fold<double>(
          0,
          (sum, inv) => sum + (inv.traction.displayValue ?? 0),
        );
        expect(traction, closeTo(900, 1e-9));
      },
    );

    test(
      'Question 3: a pending session positions by the monotonic pair',
      () async {
        // The wall clock never synced this boot: the middle minute carries
        // the earliest stamp. The phone must draw the elapsed order anyway —
        // the same bars the car draws — and the stale stamps take no part.
        const minuteNanos = 60000000000;
        final rows = [
          (elapsed: 2 * minuteNanos, traction: 300.0, stamp: 1000000),
          (elapsed: 0, traction: 100.0, stamp: 2000000),
          (elapsed: minuteNanos, traction: 200.0, stamp: 3000000),
        ];
        for (final row in rows) {
          await db.upsertInterval({
            'sessionId': 'pending-session',
            'startUtcMillis': row.stamp,
            'tractionWh': row.traction,
            'regenWh': 0.0,
            'auxiliaryWh': 0.0,
            'climateWh': 0.0,
            'deliveredWh': 0.0,
            'distanceKm': 0.0,
            'coveredSeconds': 60.0,
            'climateCoveredSeconds': 0.0,
            'speedCoveredSeconds': 0.0,
            'deliveredCoveredSeconds': 0.0,
            'startElapsedNanos': row.elapsed,
            'startBootCount': 7,
            'timeState': 'pending',
          });
        }
        final series = await store.series(
          'pending-session',
          widthMillis: 120000,
        );

        // Elapsed minutes 0 and 1 share bucket 0: 100 + 200 Wh.
        // The stamp order would bucket 300 + 100 instead.
        expect(series.intervals, hasLength(2));
        expect(series.intervals[0].traction.value, 300.0);
        expect(series.intervals[1].traction.value, 300.0);

        final series1Min = await store.series('pending-session');
        expect(series1Min.intervals, hasLength(3));
        expect(series1Min.intervals[0].traction.value, 100.0);
        expect(series1Min.intervals[1].traction.value, 200.0);
        expect(series1Min.intervals[2].traction.value, 300.0);

        final series3Min = await store.series(
          'pending-session',
          widthMillis: 180000,
        );
        expect(series3Min.intervals, hasLength(1));
        expect(series3Min.intervals[0].startUtcMillis, 0);
        expect(series3Min.intervals[0].traction.value, 600.0);
      },
    );
  });
}
