import 'dart:convert';
import 'dart:io';

import 'package:capy_companion/sync/companion_database.dart';
import 'package:capy_companion/sync/sqflite_store.dart';
import 'package:capy_energy/core/room_store.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/screens_v2/history/session_mosaic.dart';
import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:telemetry_core/telemetry_core.dart';

import 'support/fixture_wire_api.dart';

/// One screen, two stores, one rendering.
///
/// This is the rule slice 5 exists for: a screen does not know which store
/// answers it. The car reads Room over Pigeon and the phone reads SQLite, and
/// both are asked the same three questions about the same session — so the
/// wall of readings either comes out identical or the two replicas disagree
/// about what the car recorded.
///
/// The fixture is `testdata/telemetry_store_cases.json`, which is also what
/// `room_store_test.dart` and `sqflite_store_test.dart` check values against.
/// Those two compare numbers; this one compares what a reader sees.
void main() {
  const sessionId = 'trip-001';

  late TripDetailReading fromPhone;
  late TripDetailReading fromCar;
  late SessionListPage phoneList;
  late SessionListPage carList;
  late CompanionDatabase phoneDatabase;

  Future<Map<String, dynamic>> loadFixture() async {
    var file = File('testdata/telemetry_store_cases.json');
    if (!file.existsSync()) {
      file = File('../../testdata/telemetry_store_cases.json');
    }
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  /// The phone's store, on an in-memory database seeded from the fixture.
  Future<TelemetryStore> phoneStore(Map<String, dynamic> fixture) async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final db = phoneDatabase = await CompanionDatabase.open(
      inMemoryDatabasePath,
      singleInstance: false,
    );
    for (final entry in fixture['cases'] as List<dynamic>) {
      final session = entry['session'] as Map<String, dynamic>;
      await db.upsertSession(session);
      for (final interval in (entry['intervals'] as List<dynamic>? ?? [])) {
        await db.upsertInterval(interval as Map<String, dynamic>);
      }
      for (final event in (entry['events'] as List<dynamic>? ?? [])) {
        await db.upsertEvent(event as Map<String, dynamic>);
      }
    }
    return SqfliteStore(db);
  }

  /// The car's store, over the same fixture answered as the Pigeon surface.
  TelemetryStore carStore(Map<String, dynamic> fixture) =>
      RoomStore(wire: FixtureWireApi(fixture['cases'] as List<dynamic>));

  Future<TripDetailReading> read(TelemetryStore store) async {
    final stored = await store.session(sessionId);
    final series = await store.series(sessionId);
    return TripDetailReading(
      session: stored!.session,
      series: series,
      events: stored.events,
    );
  }

  /// Every line of text the wall prints, in reading order.
  List<String> textsOf(WidgetTester tester) => [
    for (final text in tester.widgetList<Text>(find.byType(Text))) ?text.data,
  ];

  Future<List<String>> render(
    WidgetTester tester,
    TripDetailReading reading,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 1800,
              height: 260,
              child: SessionMosaic.trip(reading: reading),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return textsOf(tester);
  }

  // The stores are read here, not inside a widget test: SQLite answers off
  // the test isolate, and inside `testWidgets` the clock is fake, so a read
  // awaited there waits for a tick that never comes.
  setUpAll(() async {
    final fixture = await loadFixture();
    final phone = await phoneStore(fixture);
    final car = carStore(fixture);
    fromPhone = await read(phone);
    fromCar = await read(car);
    phoneList = await phone.listSessions(
      filter: const SessionFilter(kind: SessionKind.trip),
    );
    carList = await car.listSessions(
      filter: const SessionFilter(kind: SessionKind.trip),
    );
  });

  // The database is closed, or the test isolate stays alive holding it open.
  tearDownAll(() => phoneDatabase.close());

  testWidgets('the same drive draws the same wall from either store', (
    tester,
  ) async {
    final phoneTexts = await render(tester, fromPhone);
    final carTexts = await render(tester, fromCar);

    // Not merely equal in length: the same readings, in the same order, with
    // the same figures. A store that answered a different distance or lost a
    // temperature would land here.
    expect(carTexts, phoneTexts);
    // And the wall really is drawn — an empty list would compare equal too.
    expect(phoneTexts, isNotEmpty);
    expect(phoneTexts, contains('2.5'));
  });

  testWidgets('both stores answer the same list for the same filter', (
    tester,
  ) async {
    expect(
      carList.sessions.map((s) => s.id),
      phoneList.sessions.map((s) => s.id),
    );
    expect(carList.totalCount, phoneList.totalCount);
    for (var i = 0; i < carList.sessions.length; i++) {
      final carSession = carList.sessions[i];
      final phoneSession = phoneList.sessions[i];
      expect(
        sessionReadingDistance(carSession),
        sessionReadingDistance(phoneSession),
      );
      expect(
        sessionReadingDurationMillis(carSession),
        sessionReadingDurationMillis(phoneSession),
      );
      expect(carSession.rollup, phoneSession.rollup);
    }
  });

  test(
    'both stores answer identical series for a pending session with monotonic pairs (parity)',
    () async {
      const pendingId = 'pending-parity-session';
      const minuteNanos = 60000000000;
      final rows = [
        (elapsed: 2 * minuteNanos, traction: 300.0, stamp: 1000000),
        (elapsed: 0, traction: 100.0, stamp: 2000000),
        (elapsed: minuteNanos, traction: 200.0, stamp: 3000000),
      ];
      for (final row in rows) {
        await phoneDatabase.upsertInterval({
          'sessionId': pendingId,
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

      IntervalRecordWire wireFor(
        ({int elapsed, double traction, int stamp}) row,
      ) => IntervalRecordWire(
        sessionId: pendingId,
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

      final car = RoomStore(
        wire: _PendingWireParity([for (final row in rows) wireFor(row)]),
      );
      final phone = SqfliteStore(phoneDatabase);

      for (final width in [null, 120000, 180000]) {
        final carSeries = await car.series(pendingId, widthMillis: width);
        final phoneSeries = await phone.series(pendingId, widthMillis: width);

        expect(carSeries.intervals.length, phoneSeries.intervals.length);
        for (var i = 0; i < carSeries.intervals.length; i++) {
          final c = carSeries.intervals[i];
          final p = phoneSeries.intervals[i];
          expect(c.startUtcMillis, p.startUtcMillis);
          expect(c.traction.value, p.traction.value);
          expect(c.widthMillis, p.widthMillis);
        }
      }
    },
  );
}

class _PendingWireParity extends FixtureWireApi {
  _PendingWireParity(this.pendingIntervals) : super(const []);

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
