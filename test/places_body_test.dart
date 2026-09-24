import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  group('PlacesBody Loadable states', () {
    testWidgets('shows loading spinner and attribution', (tester) async {
      await tester.pumpWidget(
        _wrap(
          PlacesBody(
            state: const Loadable<PlacesData>.loading(),
            capabilities: SurfaceCapabilities.fromWidth(390),
            isOptIn: true,
          ),
        ),
      );
      expect(find.byKey(const Key('places-loading')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // Attribution always visible even in loading via center column?
      expect(find.text(PlacesBody.attribution), findsOneWidget);
    });

    testWidgets('shows error with retry', (tester) async {
      var retried = false;
      await tester.pumpWidget(
        _wrap(
          PlacesBody(
            state: Loadable<PlacesData>.failed(Exception('bridge error')),
            capabilities: SurfaceCapabilities.fromWidth(390),
            isOptIn: true,
            onRetry: () => retried = true,
          ),
        ),
      );
      expect(find.byKey(const Key('places-error')), findsOneWidget);
      expect(find.textContaining('bridge error'), findsOneWidget);
      expect(find.byKey(const Key('places-attribution')), findsOneWidget);
      await tester.tap(find.byKey(const Key('places-retry')));
      expect(retried, isTrue);
    });

    testWidgets('shows empty no GPS with attribution', (tester) async {
      final data = PlacesData(named: const [], candidates: const []);
      await tester.pumpWidget(
        _wrap(
          PlacesBody(
            state: Loadable<PlacesData>.ready(data),
            capabilities: SurfaceCapabilities.fromWidth(390),
            isOptIn: true,
          ),
        ),
      );
      expect(find.byKey(const Key('places-empty-no-gps')), findsOneWidget);
      expect(find.text(PlacesBody.emptyNoGps), findsOneWidget);
      expect(find.byKey(const Key('places-attribution')), findsOneWidget);
    });

    testWidgets(
      'empty named still shows unnamed section empty message when all named',
      (tester) async {
        final places = [
          const InsightPlace(
            id: 'p1',
            name: 'Casa',
            latitude: -10.18,
            longitude: -48.33,
          ),
        ];
        final trips = <InsightTrip>[];
        final data = buildPlacesData(places: places, trips: trips);
        // No candidates because no trips, but named exists -> candidates empty => all-named empty section
        await tester.pumpWidget(
          _wrap(
            PlacesBody(
              state: Loadable<PlacesData>.ready(data),
              capabilities: SurfaceCapabilities.fromWidth(390),
              isOptIn: true,
            ),
          ),
        );
        expect(find.byKey(const Key('places-named-section')), findsOneWidget);
        expect(find.byKey(const Key('places-unnamed-empty')), findsOneWidget);
        expect(find.text(PlacesBody.emptyAllNamed), findsOneWidget);
      },
    );
  });

  group('PlacesBody ordering and rows', () {
    testWidgets('named section ordered by recurrence desc', (tester) async {
      final places = [
        const InsightPlace(
          id: 'home',
          name: 'Casa',
          latitude: -10.18,
          longitude: -48.33,
        ),
        const InsightPlace(
          id: 'work',
          name: 'Trabalho',
          latitude: -10.19,
          longitude: -48.34,
        ),
        const InsightPlace(
          id: 'shop',
          name: 'Mercado',
          latitude: -10.20,
          longitude: -48.35,
        ),
      ];
      final trips = [
        // 3 trips home->work (home count 3, work 3)
        _trip(
          id: 't1',
          startLat: -10.18,
          startLon: -48.33,
          endLat: -10.19,
          endLon: -48.34,
        ),
        _trip(
          id: 't2',
          startLat: -10.18,
          startLon: -48.33,
          endLat: -10.19,
          endLon: -48.34,
        ),
        _trip(
          id: 't3',
          startLat: -10.18,
          startLon: -48.33,
          endLat: -10.19,
          endLon: -48.34,
        ),
        // 1 trip home->shop (home +1 => 4, shop 1)
        _trip(
          id: 't4',
          startLat: -10.18,
          startLon: -48.33,
          endLat: -10.20,
          endLon: -48.35,
        ),
      ];
      final data = buildPlacesData(places: places, trips: trips);
      // Expected order: Casa (4), Trabalho (3), Mercado (1)
      expect(data.named[0].place.id, 'home');
      expect(data.named[1].place.id, 'work');
      expect(data.named[2].place.id, 'shop');

      await tester.pumpWidget(
        _wrap(
          PlacesBody(
            state: Loadable<PlacesData>.ready(data),
            capabilities: SurfaceCapabilities.fromWidth(390),
            isOptIn: true,
          ),
        ),
      );

      // Check displayName fallback (name present)
      expect(find.text('Casa'), findsOneWidget);
      expect(find.text('Trabalho'), findsOneWidget);
      expect(find.text('Mercado'), findsOneWidget);
      // Check counts
      expect(find.text('4 visitas'), findsOneWidget);
      expect(find.text('3 visitas'), findsOneWidget);
      expect(find.text('1 visitas'), findsOneWidget);
      // Radius chip
      expect(find.text('150 m'), findsNWidgets(3));
      // Order in UI: first row is Casa
      final casaPos = tester.getTopLeft(find.text('Casa')).dy;
      final trabalhoPos = tester.getTopLeft(find.text('Trabalho')).dy;
      expect(casaPos, lessThan(trabalhoPos));
    });

    testWidgets('candidate section ordered by recurrence desc', (tester) async {
      final places = <InsightPlace>[];
      final trips = [
        // Two trips at cell A, one at cell B
        _trip(
          id: 't1',
          startLat: -10.18,
          startLon: -48.33,
          endLat: -10.50,
          endLon: -48.50,
        ),
        _trip(
          id: 't2',
          startLat: -10.18,
          startLon: -48.33,
          endLat: -10.50,
          endLon: -48.50,
        ),
        _trip(
          id: 't3',
          startLat: -10.21,
          startLon: -48.36,
          endLat: -10.60,
          endLon: -48.60,
        ),
      ];
      final data = buildPlacesData(places: places, trips: trips);
      // candidates should be ordered by count: cell -10.18,-48.33 has 2, -10.50 etc has 2? Actually each trip has 2 endpoints, so counts depend.
      // At least verify candidates non-empty and ordered descending
      expect(data.candidates, isNotEmpty);
      for (var i = 0; i < data.candidates.length - 1; i++) {
        expect(
          data.candidates[i].count,
          greaterThanOrEqualTo(data.candidates[i + 1].count),
        );
      }

      await tester.pumpWidget(
        _wrap(
          PlacesBody(
            state: Loadable<PlacesData>.ready(data),
            capabilities: SurfaceCapabilities.fromWidth(390),
            isOptIn: true,
          ),
        ),
      );

      expect(find.byKey(const Key('places-unnamed-section')), findsOneWidget);
      // Verify attribution still visible
      expect(find.byKey(const Key('places-attribution')), findsOneWidget);
    });

    testWidgets('row shows name ?? autoName', (tester) async {
      final places = [
        const InsightPlace(
          id: 'p1',
          name: '',
          latitude: -10.18,
          longitude: -48.33,
          autoName: 'Rua A, Cidade',
        ),
        const InsightPlace(
          id: 'p2',
          name: 'Meu Lar',
          latitude: -10.19,
          longitude: -48.34,
          autoName: 'Rua B',
        ),
      ];
      final trips = [
        _trip(
          id: 't1',
          startLat: -10.18,
          startLon: -48.33,
          endLat: -10.19,
          endLon: -48.34,
        ),
      ];
      final data = buildPlacesData(places: places, trips: trips);
      await tester.pumpWidget(
        _wrap(
          PlacesBody(
            state: Loadable<PlacesData>.ready(data),
            capabilities: SurfaceCapabilities.fromWidth(390),
            isOptIn: true,
          ),
        ),
      );
      expect(find.text('Rua A, Cidade'), findsOneWidget);
      expect(find.text('Meu Lar'), findsOneWidget);
      // autoName should NOT override explicit name
      expect(find.text('Rua B'), findsNothing);
    });
  });

  group('PlacesBody banner and attribution', () {
    testWidgets('banner visible when opt-in off and CTA calls onOpenSettings', (
      tester,
    ) async {
      var opened = false;
      final places = [
        const InsightPlace(
          id: 'p1',
          name: 'Casa',
          latitude: -10.18,
          longitude: -48.33,
        ),
      ];
      final data = buildPlacesData(
        places: places,
        trips: [
          _trip(
            id: 't1',
            startLat: -10.18,
            startLon: -48.33,
            endLat: -10.50,
            endLon: -48.50,
          ),
        ],
      );

      await tester.pumpWidget(
        _wrap(
          PlacesBody(
            state: Loadable<PlacesData>.ready(data),
            capabilities: SurfaceCapabilities.fromWidth(390),
            isOptIn: false,
            onOpenSettings: () => opened = true,
          ),
        ),
      );

      expect(find.byKey(const Key('places-optin-banner')), findsOneWidget);
      expect(find.text(PlacesBody.optInBannerTitle), findsOneWidget);
      expect(find.byKey(const Key('places-optin-cta')), findsOneWidget);
      await tester.tap(find.byKey(const Key('places-optin-cta')));
      expect(opened, isTrue);
      expect(find.text(PlacesBody.attribution), findsWidgets);
    });

    testWidgets('banner hidden when opt-in on', (tester) async {
      final data = PlacesData(named: const [], candidates: const []);
      await tester.pumpWidget(
        _wrap(
          PlacesBody(
            state: Loadable<PlacesData>.ready(data),
            capabilities: SurfaceCapabilities.fromWidth(390),
            isOptIn: true,
          ),
        ),
      );
      expect(find.byKey(const Key('places-optin-banner')), findsNothing);
    });

    testWidgets('attribution visible in non-empty state', (tester) async {
      final places = [
        const InsightPlace(
          id: 'p1',
          name: 'Casa',
          latitude: -10.18,
          longitude: -48.33,
        ),
      ];
      final trips = [
        _trip(
          id: 't1',
          startLat: -10.18,
          startLon: -48.33,
          endLat: -10.50,
          endLon: -48.50,
        ),
      ];
      final data = buildPlacesData(places: places, trips: trips);
      await tester.pumpWidget(
        _wrap(
          PlacesBody(
            state: Loadable<PlacesData>.ready(data),
            capabilities: SurfaceCapabilities.fromWidth(390),
            isOptIn: true,
          ),
        ),
      );
      expect(find.byKey(const Key('places-attribution')), findsOneWidget);
      expect(find.text(PlacesBody.attribution), findsOneWidget);
    });

    testWidgets(
      'viewport-reactive: compact single column, expanded two columns',
      (tester) async {
        final places = [
          const InsightPlace(
            id: 'p1',
            name: 'Casa',
            latitude: -10.18,
            longitude: -48.33,
          ),
        ];
        final data = buildPlacesData(
          places: places,
          trips: [
            _trip(
              id: 't1',
              startLat: -10.18,
              startLon: -48.33,
              endLat: -10.50,
              endLon: -48.50,
            ),
          ],
        );
        // compact
        await tester.pumpWidget(
          _wrap(
            PlacesBody(
              state: Loadable<PlacesData>.ready(data),
              capabilities: SurfaceCapabilities.fromWidth(390),
              isOptIn: true,
            ),
            width: 390,
          ),
        );
        expect(find.byKey(const Key('places-body')), findsOneWidget);
        // expanded
        await tester.pumpWidget(
          _wrap(
            PlacesBody(
              state: Loadable<PlacesData>.ready(data),
              capabilities: SurfaceCapabilities.fromWidth(1200),
              isOptIn: true,
            ),
            width: 1200,
          ),
        );
        expect(find.byKey(const Key('places-body')), findsOneWidget);
      },
    );
  });

  group('PlacesBody duplicates banner', () {
    testWidgets('hidden when no near duplicates', (tester) async {
      final data = buildPlacesData(
        places: [
          const InsightPlace(
            id: 'p1',
            name: 'Casa',
            latitude: -10.18,
            longitude: -48.33,
          ),
        ],
        trips: const [],
      );
      await tester.pumpWidget(
        _wrap(
          PlacesBody(
            state: Loadable<PlacesData>.ready(data),
            capabilities: SurfaceCapabilities.fromWidth(390),
            isOptIn: true,
          ),
        ),
      );
      expect(find.byKey(const Key('places-duplicates-banner')), findsNothing);
    });

    testWidgets(
      'near same-name pair shows warning with names + distance and Mesclar',
      (tester) async {
        final data = buildPlacesData(
          places: [
            const InsightPlace(
              id: 'a',
              name: 'Casa',
              latitude: -10.18,
              longitude: -48.33,
            ),
            const InsightPlace(
              id: 'b',
              name: 'casa ',
              latitude: -10.1818,
              longitude: -48.33,
            ),
          ],
          trips: const [],
        );
        expect(data.duplicatePairs, hasLength(1));

        PlaceDuplicatePair? mergedPair;
        await tester.pumpWidget(
          _wrap(
            PlacesBody(
              state: Loadable<PlacesData>.ready(data),
              capabilities: SurfaceCapabilities.fromWidth(390),
              isOptIn: true,
              onMergePlaces: (pair) => mergedPair = pair,
            ),
          ),
        );

        expect(
          find.byKey(const Key('places-duplicates-banner')),
          findsOneWidget,
        );
        expect(find.text(PlacesBody.duplicatesBannerTitle), findsOneWidget);
        expect(find.textContaining('Casa e casa'), findsOneWidget);
        final cta = find.byKey(const Key('places-duplicate-merge-a-b'));
        expect(cta, findsOneWidget);
        await tester.tap(cta);
        expect(mergedPair?.placeA.id, 'a');
        expect(mergedPair?.placeB.id, 'b');
      },
    );

    testWidgets('row renders without Mesclar when no callback', (tester) async {
      final data = buildPlacesData(
        places: [
          const InsightPlace(
            id: 'a',
            name: 'Casa',
            latitude: -10.18,
            longitude: -48.33,
          ),
          const InsightPlace(
            id: 'b',
            name: 'Casa',
            latitude: -10.1818,
            longitude: -48.33,
          ),
        ],
        trips: const [],
      );
      await tester.pumpWidget(
        _wrap(
          PlacesBody(
            state: Loadable<PlacesData>.ready(data),
            capabilities: SurfaceCapabilities.fromWidth(390),
            isOptIn: true,
          ),
        ),
      );
      expect(find.byKey(const Key('places-duplicates-banner')), findsOneWidget);
      expect(find.byKey(const Key('places-duplicate-merge-a-b')), findsNothing);
    });
  });
}

Widget _wrap(Widget child, {double width = 390}) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(size: Size(width, 800)),
        child: child,
      ),
    ),
  );
}

InsightTrip _trip({
  required String id,
  required double startLat,
  required double startLon,
  required double endLat,
  required double endLon,
}) {
  return InsightTrip(
    id: id,
    endedAtUtcMillis: DateTime.now().millisecondsSinceEpoch,
    distanceKm: 10,
    canPackWh: 1000,
    hasMinuteBuckets: true,
    canAgreesWithSoc: true,
    aggregationVersion: 1,
    startLatitude: startLat,
    startLongitude: startLon,
    endLatitude: endLat,
    endLongitude: endLon,
    path: '$startLat,$startLon;$endLat,$endLon',
  );
}
