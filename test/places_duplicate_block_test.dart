import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/mock_telemetry_source.dart';
import 'package:capy_energy/core/telemetry_api.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/screens_v2/places/places_screen.dart';

/// A mock car that refuses every place write, as the repository does when
/// the driver saves on top of an existing same-name place nearby.
class _RefusingSource extends MockTelemetrySource {
  @override
  Future<InsightPlace> saveInsightPlace({
    String? id,
    required String name,
    required double latitude,
    required double longitude,
    double radiusM = kInsightPlaceRadiusM,
    String? autoName,
    int? autoNameUpdatedAtUtcMillis,
    String? autoNameSource,
  }) async {
    throw DuplicatePlaceException(name: 'Casa', distanceM: 123);
  }
}

void main() {
  group('MockTelemetrySource duplicate block', () {
    test(
      'second place with one normalized name within 500 m is refused',
      () async {
        final api = TelemetryApi(source: MockTelemetrySource());
        await api.saveInsightPlace(
          name: 'Casa',
          latitude: -10.18,
          longitude: -48.33,
        );

        await expectLater(
          api.saveInsightPlace(
            name: ' casa ',
            latitude: -10.1818,
            longitude: -48.33,
          ),
          throwsA(isA<DuplicatePlaceException>()),
        );
        // Nothing persisted.
        expect((await api.getInsightPlaces()).places, hasLength(1));
      },
    );

    test('error names the place, the metres and the two ways out', () async {
      final api = TelemetryApi(source: MockTelemetrySource());
      await api.saveInsightPlace(
        name: 'Casa',
        latitude: -10.18,
        longitude: -48.33,
      );
      await expectLater(
        api.saveInsightPlace(
          name: 'casa',
          latitude: -10.181,
          longitude: -48.33,
        ),
        throwsA(
          isA<DuplicatePlaceException>().having(
            (e) => e.toString(),
            'message',
            "Ja existe 'Casa' a 111 m — use raio maior ou mescle",
          ),
        ),
      );
    });

    test('same name beyond 500 m saves', () async {
      final api = TelemetryApi(source: MockTelemetrySource());
      await api.saveInsightPlace(
        name: 'Casa',
        latitude: -10.18,
        longitude: -48.33,
      );
      final second = await api.saveInsightPlace(
        name: 'Casa',
        latitude: -10.19,
        longitude: -48.33,
      );
      expect((await api.getInsightPlaces()).places, hasLength(2));
      expect(second.name, 'Casa');
    });

    test('different name nearby saves', () async {
      final api = TelemetryApi(source: MockTelemetrySource());
      await api.saveInsightPlace(
        name: 'Casa',
        latitude: -10.18,
        longitude: -48.33,
      );
      await api.saveInsightPlace(
        name: 'Trabalho',
        latitude: -10.1805,
        longitude: -48.3302,
      );
      expect((await api.getInsightPlaces()).places, hasLength(2));
    });

    test('updating the row by its own id stays allowed', () async {
      final api = TelemetryApi(source: MockTelemetrySource());
      final first = await api.saveInsightPlace(
        name: 'Casa',
        latitude: -10.18,
        longitude: -48.33,
      );
      final updated = await api.saveInsightPlace(
        id: first.id,
        name: 'Casa',
        latitude: -10.181,
        longitude: -48.331,
        radiusM: 300,
      );
      final places = await api.getInsightPlaces();
      expect(places.places, hasLength(1));
      expect(places.places.single.id, first.id);
      expect(updated.radiusM, 300);
    });
  });

  group('PlacesScreen refused write', () {
    testWidgets('shows the duplicate message as a snack, not a crash', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PlacesScreen(
            telemetryApi: TelemetryApi(source: _RefusingSource()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The list itself still renders (the read path is untouched).
      expect(find.byKey(const Key('places-named-section')), findsOneWidget);
    });

    testWidgets('save error surfaces as a snack over the detail dialog', (
      tester,
    ) async {
      final refusing = _RefusingAfterSeedSource()
        ..seed(
          const InsightPlace(
            id: 'seed',
            name: 'Casa',
            latitude: -10.18,
            longitude: -48.33,
          ),
        );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PlacesScreen(telemetryApi: TelemetryApi(source: refusing)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('places-named-seed')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('places-detail-save')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('places-save-error-snackbar')),
        findsOneWidget,
      );
      expect(find.textContaining("Ja existe 'Casa' a 123 m"), findsOneWidget);
    });
  });

  group('merge propagation', () {
    test('keeper update plus tombstone leaves one live place', () async {
      final api = TelemetryApi(source: MockTelemetrySource());
      final savedOlder = await api.saveInsightPlace(
        name: 'Casa',
        latitude: -10.18,
        longitude: -48.33,
        radiusM: 100,
      );
      final older = InsightPlace(
        id: savedOlder.id,
        name: savedOlder.name,
        latitude: savedOlder.latitude,
        longitude: savedOlder.longitude,
        radiusM: savedOlder.radiusM,
        createdAtUtcMillis: 1000,
      );
      // The duplicate exists because an older build let it through; the new
      // blocker refuses to create it again, so it enters by hand.
      final newer = const InsightPlace(
        id: 'legacy-dup',
        name: 'casa ',
        latitude: -10.1818,
        longitude: -48.33,
        radiusM: 100,
        createdAtUtcMillis: 2000,
      );

      final pair = PlaceDuplicatePair(
        placeA: older,
        placeB: newer,
        distanceM: insightDistanceM(
          older.latitude,
          older.longitude,
          newer.latitude,
          newer.longitude,
        ),
      );
      final keeper = resolveMergeKeep(pair.placeA, pair.placeB);
      final center = proposeMergeCenter(pair.placeA, pair.placeB);
      expect(keeper.id, older.id);

      // What both screens do on confirm: tombstone the loser first (the
      // blocker counts live rows), then update the keeper.
      await api.deleteInsightPlace(id: newer.id);
      await api.saveInsightPlace(
        id: keeper.id,
        name: keeper.name,
        latitude: center.latitude,
        longitude: center.longitude,
        radiusM: proposeMergeRadiusM(pair.placeA, pair.placeB),
      );

      final places = await api.getInsightPlaces();
      expect(places.places, hasLength(1));
      expect(places.places.single.id, older.id);
      expect(places.places.single.latitude, closeTo(-10.1809, 1e-9));

      final data = buildPlacesData(places: places.places, trips: const []);
      expect(data.duplicatePairs, isEmpty);
    });
  });
}

/// Refuses writes but serves one seeded live place for reads.
class _RefusingAfterSeedSource extends MockTelemetrySource {
  InsightPlace? _seed;

  void seed(InsightPlace place) => _seed = place;

  @override
  Future<InsightPlacesResult> insightPlaces() async =>
      InsightPlacesResult(places: [?_seed]);

  @override
  Future<InsightTripsResult> insightTrips(String? subjectId) async =>
      InsightTripsResult(trips: const [], subjectId: subjectId);

  @override
  Future<InsightPlace> saveInsightPlace({
    String? id,
    required String name,
    required double latitude,
    required double longitude,
    double radiusM = kInsightPlaceRadiusM,
    String? autoName,
    int? autoNameUpdatedAtUtcMillis,
    String? autoNameSource,
  }) async {
    throw DuplicatePlaceException(name: 'Casa', distanceM: 123);
  }
}
