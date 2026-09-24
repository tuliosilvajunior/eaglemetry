import 'dart:async';

import 'package:capy_companion/l10n/app_localizations.dart';
import 'package:capy_companion/screens/insight_detail_screen.dart';
import 'package:capy_companion/screens/insights_screen.dart';
import 'package:capy_companion/sync/companion_archive.dart';
import 'package:capy_companion/sync/local_telemetry_source.dart';
import 'package:capy_companion/sync/sqflite_store.dart';
import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

import 'support/memory_archive.dart';

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('en'),
  theme: AppTheme.light(),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SizedBox(width: 400, height: 2000, child: child)),
);

class FakeHistoricalTelemetrySource implements HistoricalTelemetrySource {
  FakeHistoricalTelemetrySource({
    this.places = const [],
    this.trips = const [],
  });

  final List<InsightPlace> places;
  final List<InsightTrip> trips;
  final _changes = StreamController<SessionChange>.broadcast();

  @override
  Stream<SessionChange> sessionChanges() => _changes.stream;

  @override
  Future<InsightPlacesResult> insightPlaces() async =>
      InsightPlacesResult(places: places);

  @override
  Future<InsightTripsResult> insightTrips(String? subjectId) async =>
      InsightTripsResult(trips: trips, subjectId: subjectId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<CompanionArchive> _archive(WidgetTester tester) async {
  late CompanionArchive archive;
  await tester.runAsync(() async => archive = await memoryArchive());
  return archive;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pump();
}

InsightTrip _trip({
  required String id,
  required int? endedAtUtcMillis,
  double? distanceKm = 10.0,
  double? canPackWh = 1500.0,
  String? path,
  double? startLatitude = -23.5505,
  double? startLongitude = -46.6333,
  double? endLatitude = -23.5600,
  double? endLongitude = -46.6500,
  bool hasMinuteBuckets = true,
  bool? canAgreesWithSoc = true,
  int aggregationVersion = 2,
  double? meanAmbientTempC = 25.0,
}) => InsightTrip(
  id: id,
  endedAtUtcMillis: endedAtUtcMillis,
  distanceKm: distanceKm,
  canPackWh: canPackWh,
  path: path,
  startLatitude: startLatitude,
  startLongitude: startLongitude,
  endLatitude: endLatitude,
  endLongitude: endLongitude,
  hasMinuteBuckets: hasMinuteBuckets,
  canAgreesWithSoc: canAgreesWithSoc,
  aggregationVersion: aggregationVersion,
  meanAmbientTempC: meanAmbientTempC,
);

void main() {
  const fromPlace = InsightPlace(
    id: 'place-home',
    name: 'Home',
    latitude: -23.5505,
    longitude: -46.6333,
    radiusM: 150,
  );
  const toPlace = InsightPlace(
    id: 'place-work',
    name: 'Work',
    latitude: -23.5600,
    longitude: -46.6500,
    radiusM: 150,
  );
  final places = [fromPlace, toPlace];

  const now = 1750000000000;
  final nowDate = DateTime.fromMillisecondsSinceEpoch(now, isUtc: true);
  const day = 86400000;

  group('InsightDetailScreen - Supported and Cards', () {
    testWidgets(
      'displays Claim, Considered Trips, and Route Trend cards when supported',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final subject = _trip(
          id: 'trip-0',
          endedAtUtcMillis: now - day,
          distanceKm: 10.0,
          canPackWh: 1000.0, // 100 Wh/km
        );
        final ref1 = _trip(
          id: 'trip-1',
          endedAtUtcMillis: now - 2 * day,
          distanceKm: 10.0,
          canPackWh: 1500.0, // 150 Wh/km
        );
        final ref2 = _trip(
          id: 'trip-2',
          endedAtUtcMillis: now - 3 * day,
          distanceKm: 10.0,
          canPackWh: 1520.0, // 152 Wh/km
        );
        final ref3 = _trip(
          id: 'trip-3',
          endedAtUtcMillis: now - 4 * day,
          distanceKm: 10.0,
          canPackWh: 1510.0, // 151 Wh/km
        );
        final ref4 = _trip(
          id: 'trip-4',
          endedAtUtcMillis: now - 5 * day,
          distanceKm: 10.0,
          canPackWh: 1530.0, // 153 Wh/km
        );

        final allTrips = [subject, ref1, ref2, ref3, ref4];
        final route = NamedRoute(
          from: fromPlace,
          to: toPlace,
          trips: [subject, ref1, ref2, ref3, ref4],
        );

        final source = FakeHistoricalTelemetrySource(
          places: places,
          trips: allTrips,
        );

        await tester.pumpWidget(
          _host(
            InsightDetailScreen(route: route, source: source, now: nowDate),
          ),
        );
        await _settle(tester);

        // Header
        expect(find.text('Home → Work'), findsOneWidget);

        // Ranking card: primary content, most efficient first
        expect(find.text('Route ranking'), findsOneWidget);
        expect(find.text('Best run'), findsOneWidget);
        expect(find.text('1'), findsOneWidget);

        // Claim Card
        expect(find.text('The Claim'), findsOneWidget);
        expect(find.text('Supported'), findsOneWidget);
        expect(find.text('Baseline'), findsOneWidget);
        expect(find.text('Measured'), findsOneWidget);
        expect(find.text('Reference'), findsOneWidget);
        expect(find.text('4 trips considered'), findsWidgets);

        // Considered Trips Card
        expect(find.text('Considered Trips'), findsOneWidget);
        expect(find.text('150 Wh/km'), findsWidgets);
        expect(find.text('152 Wh/km'), findsWidgets);

        // Route Trend Card
        expect(find.text('Route Trend'), findsOneWidget);
        expect(find.text('100 Wh/km'), findsWidgets);
      },
    );

    testWidgets('displays status badge Within noise when not distinguishable', (
      tester,
    ) async {
      final subject = _trip(
        id: 'trip-0',
        endedAtUtcMillis: now - day,
        distanceKm: 10.0,
        canPackWh: 1500.0, // 150 Wh/km
      );
      final ref1 = _trip(
        id: 'trip-1',
        endedAtUtcMillis: now - 2 * day,
        distanceKm: 10.0,
        canPackWh: 1400.0, // 140 Wh/km
      );
      final ref2 = _trip(
        id: 'trip-2',
        endedAtUtcMillis: now - 3 * day,
        distanceKm: 10.0,
        canPackWh: 1600.0, // 160 Wh/km
      );
      final ref3 = _trip(
        id: 'trip-3',
        endedAtUtcMillis: now - 4 * day,
        distanceKm: 10.0,
        canPackWh: 1450.0, // 145 Wh/km
      );
      final ref4 = _trip(
        id: 'trip-4',
        endedAtUtcMillis: now - 5 * day,
        distanceKm: 10.0,
        canPackWh: 1550.0, // 155 Wh/km
      );

      final allTrips = [subject, ref1, ref2, ref3, ref4];
      final route = NamedRoute(from: fromPlace, to: toPlace, trips: allTrips);

      final source = FakeHistoricalTelemetrySource(
        places: places,
        trips: allTrips,
      );

      await tester.pumpWidget(
        _host(InsightDetailScreen(route: route, source: source, now: nowDate)),
      );
      await _settle(tester);

      expect(find.text('The Claim'), findsOneWidget);
      expect(find.text('Within noise'), findsOneWidget);
    });
  });

  group('InsightDetailScreen - Exclusions separated and not folded', () {
    testWidgets(
      'displays each exclusion reason separately and never as a folded total',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final subject = _trip(id: 'trip-0', endedAtUtcMillis: now - day);

        // 4 valid reference trips
        final validRefs = [
          for (var i = 1; i <= 4; i++)
            _trip(
              id: 'valid-$i',
              endedAtUtcMillis: now - (i + 1) * day,
              distanceKm: 10.0,
              canPackWh: 1500.0,
            ),
        ];

        // Excluded trips for various reasons:
        final oldTrip = _trip(
          id: 'old-1',
          endedAtUtcMillis: now - 40 * day, // outside 30-day window
          distanceKm: 10.0,
          canPackWh: 1500.0,
        );
        final versionTrip = _trip(
          id: 'version-1',
          endedAtUtcMillis: now - 3 * day,
          distanceKm: 10.0,
          canPackWh: 1500.0,
          aggregationVersion: 1, // versionMismatch
        );
        final shortTrip = _trip(
          id: 'short-1',
          endedAtUtcMillis: now - 4 * day,
          distanceKm: 0.2, // tooShort
          canPackWh: 20.0,
        );

        final allTrips = [
          subject,
          ...validRefs,
          oldTrip,
          versionTrip,
          shortTrip,
        ];
        final route = NamedRoute(
          from: fromPlace,
          to: toPlace,
          trips: [subject, ...validRefs],
        );

        final source = FakeHistoricalTelemetrySource(
          places: places,
          trips: allTrips,
        );

        await tester.pumpWidget(
          _host(
            InsightDetailScreen(route: route, source: source, now: nowDate),
          ),
        );
        await _settle(tester);

        // Considered trips sample
        expect(find.text('4 trips considered'), findsWidgets);

        // Exclusions shown individually
        expect(find.text('1 trip outside 30-day window'), findsOneWidget);
        expect(find.text('1 trip in older format'), findsOneWidget);
        expect(find.text('1 trip shorter than 0.5 km'), findsOneWidget);

        // Verify folded number does NOT exist
        expect(find.textContaining('3 excluded'), findsNothing);
      },
    );
  });

  group('InsightDetailScreen - All 9 forms of InsightAbsence', () {
    testWidgets('InsightAbsence.subjectNeverRecorded', (tester) async {
      final subject = _trip(
        id: 'trip-0',
        endedAtUtcMillis: now - day,
        canPackWh: null, // neverRecorded
      );
      final route = NamedRoute(from: fromPlace, to: toPlace, trips: [subject]);
      final source = FakeHistoricalTelemetrySource(
        places: places,
        trips: [subject],
      );

      await tester.pumpWidget(
        _host(InsightDetailScreen(route: route, source: source, now: nowDate)),
      );
      await _settle(tester);

      expect(find.text('Insufficient data'), findsOneWidget);
      expect(
        find.text('This route has no measured pack energy to compare.'),
        findsOneWidget,
      );
    });

    testWidgets('InsightAbsence.subjectNoMinuteBuckets', (tester) async {
      final subject = _trip(
        id: 'trip-0',
        endedAtUtcMillis: now - day,
        hasMinuteBuckets: false, // noMinuteBuckets
      );
      final route = NamedRoute(from: fromPlace, to: toPlace, trips: [subject]);
      final source = FakeHistoricalTelemetrySource(
        places: places,
        trips: [subject],
      );

      await tester.pumpWidget(
        _host(InsightDetailScreen(route: route, source: source, now: nowDate)),
      );
      await _settle(tester);

      expect(find.text('Insufficient data'), findsOneWidget);
      expect(
        find.text('This route has no measured pack energy to compare.'),
        findsOneWidget,
      );
    });

    testWidgets('InsightAbsence.subjectSignContradiction', (tester) async {
      final subject = _trip(
        id: 'trip-0',
        endedAtUtcMillis: now - day,
        canAgreesWithSoc: false, // signContradiction
      );
      final route = NamedRoute(from: fromPlace, to: toPlace, trips: [subject]);
      final source = FakeHistoricalTelemetrySource(
        places: places,
        trips: [subject],
      );

      await tester.pumpWidget(
        _host(InsightDetailScreen(route: route, source: source, now: nowDate)),
      );
      await _settle(tester);

      expect(find.text('Insufficient data'), findsOneWidget);
      expect(
        find.text('This route has no measured pack energy to compare.'),
        findsOneWidget,
      );
    });

    testWidgets('InsightAbsence.subjectUnconfirmedSign', (tester) async {
      final subject = _trip(
        id: 'trip-0',
        endedAtUtcMillis: now - day,
        canAgreesWithSoc: null, // unconfirmedSign
      );
      final route = NamedRoute(from: fromPlace, to: toPlace, trips: [subject]);
      final source = FakeHistoricalTelemetrySource(
        places: places,
        trips: [subject],
      );

      await tester.pumpWidget(
        _host(InsightDetailScreen(route: route, source: source, now: nowDate)),
      );
      await _settle(tester);

      expect(find.text('Insufficient data'), findsOneWidget);
      expect(
        find.text('This route has no measured pack energy to compare.'),
        findsOneWidget,
      );
    });

    testWidgets('InsightAbsence.subjectTooShort', (tester) async {
      final subject = _trip(
        id: 'trip-0',
        endedAtUtcMillis: now - day,
        distanceKm: 0.2, // tooShort
      );
      final route = NamedRoute(from: fromPlace, to: toPlace, trips: [subject]);
      final source = FakeHistoricalTelemetrySource(
        places: places,
        trips: [subject],
      );

      await tester.pumpWidget(
        _host(InsightDetailScreen(route: route, source: source, now: nowDate)),
      );
      await _settle(tester);

      expect(find.text('Insufficient data'), findsOneWidget);
      expect(
        find.text('This route has no measured pack energy to compare.'),
        findsOneWidget,
      );
    });

    testWidgets('InsightAbsence.subjectNotClosed', (tester) async {
      final subject = _trip(
        id: 'trip-0',
        endedAtUtcMillis: null, // notClosed
      );
      final route = NamedRoute(from: fromPlace, to: toPlace, trips: [subject]);
      final source = FakeHistoricalTelemetrySource(
        places: places,
        trips: [subject],
      );

      await tester.pumpWidget(
        _host(InsightDetailScreen(route: route, source: source, now: nowDate)),
      );
      await _settle(tester);

      expect(find.text('Insufficient data'), findsOneWidget);
      expect(
        find.text('This route has no measured pack energy to compare.'),
        findsOneWidget,
      );
    });

    testWidgets('InsightAbsence.insufficientSupport', (tester) async {
      final subject = _trip(id: 'trip-0', endedAtUtcMillis: now - day);
      final ref1 = _trip(id: 'trip-1', endedAtUtcMillis: now - 2 * day);
      // Only 1 reference trip => insufficient support (needs 4)

      final route = NamedRoute(
        from: fromPlace,
        to: toPlace,
        trips: [subject, ref1],
      );
      final source = FakeHistoricalTelemetrySource(
        places: places,
        trips: [subject, ref1],
      );

      await tester.pumpWidget(
        _host(InsightDetailScreen(route: route, source: source, now: nowDate)),
      );
      await _settle(tester);

      expect(find.text('Insufficient data'), findsOneWidget);
      expect(
        find.text(
          'Not enough measured trips in the last 30 days yet (1 usable).',
        ),
        findsOneWidget,
      );
    });

    testWidgets('InsightAbsence.notOnRoute', (tester) async {
      final subject = _trip(
        id: 'trip-0',
        endedAtUtcMillis: now - day,
        startLatitude: null, // not on route
        endLatitude: null,
      );
      final route = NamedRoute(from: fromPlace, to: toPlace, trips: [subject]);
      final source = FakeHistoricalTelemetrySource(
        places: places,
        trips: [subject],
      );

      await tester.pumpWidget(
        _host(InsightDetailScreen(route: route, source: source, now: nowDate)),
      );
      await _settle(tester);

      expect(find.text('Insufficient data'), findsOneWidget);
    });

    testWidgets('InsightAbsence.noOtherVariant', (tester) async {
      const viaA = '-23.5505,-46.6333;-23.5550,-46.6400;-23.5600,-46.6500';
      final subject = _trip(
        id: 'trip-0',
        endedAtUtcMillis: now - day,
        path: viaA,
      );
      final ref1 = _trip(
        id: 'trip-1',
        endedAtUtcMillis: now - 2 * day,
        path: viaA, // same path, no other variant
      );
      final route = NamedRoute(
        from: fromPlace,
        to: toPlace,
        trips: [subject, ref1],
      );
      final source = FakeHistoricalTelemetrySource(
        places: places,
        trips: [subject, ref1],
      );

      await tester.pumpWidget(
        _host(InsightDetailScreen(route: route, source: source, now: nowDate)),
      );
      await _settle(tester);

      expect(find.text('Insufficient data'), findsOneWidget);
    });
  });

  group('InsightDetailScreen - Navigation from InsightsScreen', () {
    testWidgets('tapping a comparable route navigates to InsightDetailScreen', (
      tester,
    ) async {
      final archive = await _archive(tester);

      await tester.runAsync(() async {
        await archive.upsertPlace({
          'id': 'place-home',
          'name': 'Casa',
          'latitude': -23.5505,
          'longitude': -46.6333,
          'radiusM': 150.0,
          'createdAtUtcMillis': now,
          'updatedAtUtcMillis': now,
          'origin': 'phone',
        });

        await archive.upsertPlace({
          'id': 'place-work',
          'name': 'Trabalho',
          'latitude': -23.5600,
          'longitude': -46.6500,
          'radiusM': 150.0,
          'createdAtUtcMillis': now,
          'updatedAtUtcMillis': now,
          'origin': 'phone',
        });

        // Four measured trips: the route becomes comparable and opens.
        for (var i = 1; i <= 4; i++) {
          final start = now + i * day;
          await archive.upsertTrip({
            'id': 'trip-$i',
            'status': 'CLOSED',
            'startedAtUtcMillis': start,
            'endedAtUtcMillis': start + 1800000,
            'startedAtElapsedNanos': 1000000000,
            'endedAtElapsedNanos': 1801000000000,
            'startLatitude': -23.5505,
            'startLongitude': -46.6333,
            'endLatitude': -23.5600,
            'endLongitude': -46.6500,
            'rollupDistanceKm': 15.0,
            'rollupTractionWh': 2100.0 + i * 10.0,
            'socAgreesWithIntegral': 'agrees',
          });
          await archive.upsertInterval({
            'sessionId': 'trip-$i',
            'startUtcMillis': start,
            'tractionWh': 2100.0 + i * 10.0,
            'integratedSeconds': 60.0,
          });
        }
      });

      final store = SqfliteStore(archive.database);
      final source = LocalTelemetrySource(archive);

      await tester.pumpWidget(
        _host(InsightsScreen(store: store, source: source)),
      );
      await _settle(tester);

      expect(find.text('Casa ↔ Trabalho'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsNothing);

      // Tap on the route card
      await tester.tap(find.text('Casa ↔ Trabalho'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _settle(tester);

      // Should navigate to InsightDetailScreen
      expect(find.byType(InsightDetailScreen), findsOneWidget);
      expect(find.text('Route ranking'), findsOneWidget);
      expect(find.text('Best run'), findsOneWidget);
      expect(find.text('The Claim'), findsOneWidget);
    });

    testWidgets(
      'a route below the measurement gate stays muted and does not open',
      (tester) async {
        final archive = await _archive(tester);

        await tester.runAsync(() async {
          await archive.upsertPlace({
            'id': 'place-home',
            'name': 'Casa',
            'latitude': -23.5505,
            'longitude': -46.6333,
            'radiusM': 150.0,
            'createdAtUtcMillis': now,
            'updatedAtUtcMillis': now,
            'origin': 'phone',
          });

          await archive.upsertPlace({
            'id': 'place-work',
            'name': 'Trabalho',
            'latitude': -23.5600,
            'longitude': -46.6500,
            'radiusM': 150.0,
            'createdAtUtcMillis': now,
            'updatedAtUtcMillis': now,
            'origin': 'phone',
          });

          // One measured trip and one without any measurement: two total,
          // one comparable, three missing.
          for (var i = 1; i <= 2; i++) {
            final start = now + i * day;
            await archive.upsertTrip({
              'id': 'trip-$i',
              'status': 'CLOSED',
              'startedAtUtcMillis': start,
              'endedAtUtcMillis': start + 1800000,
              'startedAtElapsedNanos': 1000000000,
              'endedAtElapsedNanos': 1801000000000,
              'startLatitude': -23.5505,
              'startLongitude': -46.6333,
              'endLatitude': -23.5600,
              'endLongitude': -46.6500,
              if (i == 1) ...{
                'rollupDistanceKm': 15.0,
                'rollupTractionWh': 2250.0,
                'socAgreesWithIntegral': 'agrees',
              },
            });
          }
          await archive.upsertInterval({
            'sessionId': 'trip-1',
            'startUtcMillis': now + day,
            'tractionWh': 2250.0,
            'integratedSeconds': 60.0,
          });
        });

        final store = SqfliteStore(archive.database);
        final source = LocalTelemetrySource(archive);

        await tester.pumpWidget(
          _host(InsightsScreen(store: store, source: source)),
        );
        await _settle(tester);

        expect(find.text('Casa ↔ Trabalho'), findsOneWidget);
        expect(find.byIcon(Icons.lock_outline), findsOneWidget);
        expect(
          find.text('3 more measured trips needed before comparisons start'),
          findsOneWidget,
        );

        await tester.tap(find.text('Casa ↔ Trabalho'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.byType(InsightDetailScreen), findsNothing);
      },
    );
  });
}
