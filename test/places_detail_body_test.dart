import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  group('PlacesDetailBody', () {
    testWidgets('shows initial circle radius from initialRadiusM', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          PlacesDetailBody(
            latitude: -10.18,
            longitude: -48.33,
            initialName: 'Casa',
            initialRadiusM: 150,
            otherPlaces: const [],
            onSave: (_, _, _) {},
          ),
        ),
      );
      await tester.pump();
      final circleLayer = tester.widget<CircleLayer>(
        find.byKey(const Key('places-detail-circle-layer')),
      );
      expect(circleLayer.circles.first.radius, 150);
      expect(circleLayer.circles.first.useRadiusInMeter, isTrue);
      expect(find.text('150 m'), findsWidgets);
      expect(find.byKey(const Key('places-detail-map')), findsOneWidget);
    });

    testWidgets('slider updates circle live', (tester) async {
      await tester.pumpWidget(
        _wrap(
          PlacesDetailBody(
            latitude: -10.18,
            longitude: -48.33,
            initialName: 'Casa',
            initialRadiusM: 150,
            otherPlaces: const [],
            onSave: (_, _, _) {},
          ),
        ),
      );
      await tester.pump();
      final slider = tester.widget<Slider>(
        find.byKey(const Key('places-detail-slider')),
      );
      expect(slider.value, 150);
      slider.onChanged!(1000);
      await tester.pump();
      final updatedLayer = tester.widget<CircleLayer>(
        find.byKey(const Key('places-detail-circle-layer')),
      );
      expect(updatedLayer.circles.first.radius, 1000);
      expect(find.text('1000 m'), findsWidgets);
    });

    testWidgets('overlap warning hidden when no overlap', (tester) async {
      const other = InsightPlace(
        id: 'other',
        name: 'Trabalho',
        latitude: -10.50,
        longitude: -48.50,
        radiusM: 150,
      );
      await tester.pumpWidget(
        _wrap(
          PlacesDetailBody(
            latitude: -10.18,
            longitude: -48.33,
            initialName: 'Casa',
            initialRadiusM: 150,
            otherPlaces: [other],
            onSave: (_, _, _) {},
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('places-detail-overlap-warning')),
        findsNothing,
      );
    });

    testWidgets('overlap warning visible when radii overlap', (tester) async {
      const other = InsightPlace(
        id: 'other',
        name: 'Trabalho',
        latitude: -10.181,
        longitude: -48.331,
        radiusM: 150,
      );
      await tester.pumpWidget(
        _wrap(
          PlacesDetailBody(
            latitude: -10.18,
            longitude: -48.33,
            initialName: 'Casa',
            initialRadiusM: 150,
            otherPlaces: [other],
            onSave: (_, _, _) {},
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('places-detail-overlap-warning')),
        findsOneWidget,
      );
      expect(find.textContaining('Trabalho'), findsOneWidget);
    });

    testWidgets('save calls onSave with name and current radius', (
      tester,
    ) async {
      String? savedName;
      double? savedRadius;
      await tester.pumpWidget(
        _wrap(
          PlacesDetailBody(
            latitude: -10.18,
            longitude: -48.33,
            initialName: 'Casa',
            initialRadiusM: 150,
            otherPlaces: const [],
            onSave: (name, radius, _) {
              savedName = name;
              savedRadius = radius;
            },
          ),
        ),
      );
      await tester.pump();
      tester
          .widget<Slider>(find.byKey(const Key('places-detail-slider')))
          .onChanged!(800);
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('places-detail-name-field')),
        'Casa Nova',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('places-detail-save')));
      await tester.pump();
      expect(savedName, 'Casa Nova');
      expect(savedRadius, 800);
    });

    testWidgets('placeContaining respects updated radius', (tester) async {
      const placeSmall = InsightPlace(
        id: 'p',
        name: 'Casa',
        latitude: -10.18,
        longitude: -48.33,
        radiusM: 50,
      );
      const placeLarge = InsightPlace(
        id: 'p',
        name: 'Casa',
        latitude: -10.18,
        longitude: -48.33,
        radiusM: 500,
      );
      const point = InsightPoint(-10.1818, -48.33);
      expect(placeContaining(point, [placeSmall]), isNull);
      expect(placeContaining(point, [placeLarge]), isNotNull);
    });
  });

  group('PlacesBody tap opens detail', () {
    testWidgets('tapping named row calls onSelectNamed', (tester) async {
      var tapped = false;
      NamedPlaceEntry? tappedEntry;
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
        _wrap2(
          PlacesBody(
            state: Loadable<PlacesData>.ready(data),
            capabilities: SurfaceCapabilities.fromWidth(390),
            isOptIn: true,
            onSelectNamed: (e) {
              tapped = true;
              tappedEntry = e;
            },
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('places-named-p1')));
      await tester.pump();
      expect(tapped, isTrue);
      expect(tappedEntry?.place.id, 'p1');
    });

    testWidgets('tapping candidate row calls onSelectCandidate', (
      tester,
    ) async {
      var tapped = false;
      CandidatePlace? tappedCandidate;
      final data = buildPlacesData(
        places: [],
        trips: [
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
        ],
      );
      expect(data.candidates, isNotEmpty);
      final first = data.candidates.first;
      await tester.pumpWidget(
        _wrap2(
          PlacesBody(
            state: Loadable<PlacesData>.ready(data),
            capabilities: SurfaceCapabilities.fromWidth(390),
            isOptIn: true,
            onSelectCandidate: (c) {
              tapped = true;
              tappedCandidate = c;
            },
          ),
        ),
      );
      await tester.tap(find.byKey(Key('places-candidate-${first.id}')));
      await tester.pump();
      expect(tapped, isTrue);
      expect(tappedCandidate?.id, first.id);
    });
  });
}

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(
      body: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  );
}

Widget _wrap2(Widget child, {double width = 390}) {
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
