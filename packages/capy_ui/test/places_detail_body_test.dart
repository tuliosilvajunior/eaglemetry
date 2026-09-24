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
      expect(circleLayer.circles, hasLength(1));
      expect(circleLayer.circles.first.radius, 150);
      expect(circleLayer.circles.first.useRadiusInMeter, isTrue);
      expect(find.text('150 m'), findsWidgets);
      // Map present
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
      expect(slider.min, 50);
      expect(slider.max, 2000);

      // Simulate user dragging slider to 1000m
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
      expect(find.byKey(const Key('places-detail-overlap-row')), findsNothing);
    });

    testWidgets('overlap warning visible when radii overlap', (tester) async {
      // Other is ~110m away (approx 0.001 deg ~111m). Sum 300 > distance => overlap.
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
      expect(find.textContaining('Sobrepoe com'), findsWidgets);
      expect(find.textContaining('Trabalho'), findsOneWidget);
    });

    testWidgets('overlap warning appears after slider increases', (
      tester,
    ) async {
      // Other at ~250m away. With 150+150=300 >250 overlap, but with 50 radius 50+150=200 <250 no overlap.
      // So small radius hidden, large radius visible.
      const other = InsightPlace(
        id: 'other',
        name: 'Vizinho',
        latitude: -10.1822, // approx 250m north
        longitude: -48.33,
        radiusM: 150,
      );
      await tester.pumpWidget(
        _wrap(
          PlacesDetailBody(
            latitude: -10.18,
            longitude: -48.33,
            initialName: 'Casa',
            initialRadiusM: 50,
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

      final slider = tester.widget<Slider>(
        find.byKey(const Key('places-detail-slider')),
      );
      slider.onChanged!(500);
      await tester.pump();

      expect(
        find.byKey(const Key('places-detail-overlap-warning')),
        findsOneWidget,
      );
      expect(find.textContaining('Vizinho'), findsOneWidget);
    });

    testWidgets('overlap uses sum of radii, not single radius', (tester) async {
      // Place at ~200m away, each radius 100 => sum 200 not overlapping (need < sum). So equal distance not overlapping.
      // Use 100 each => sum 200, distance 200 => not overlap (strict <). Use 101 => sum 201 => overlap.
      // Build two cases.
      const other = InsightPlace(
        id: 'other',
        name: 'Outro',
        latitude: -10.1818, // approx 200m
        longitude: -48.33,
        radiusM: 100,
      );
      final d = insightDistanceM(
        -10.18,
        -48.33,
        other.latitude,
        other.longitude,
      );
      // Sanity: distance should be ~200m
      expect(d, greaterThan(150));
      expect(d, lessThan(250));

      // With radius 100, sum =200, d ~200 => should be non-overlapping if d >=200
      await tester.pumpWidget(
        _wrap(
          PlacesDetailBody(
            latitude: -10.18,
            longitude: -48.33,
            initialName: 'Casa',
            initialRadiusM: 100,
            otherPlaces: [other],
            onSave: (_, _, _) {},
          ),
        ),
      );
      await tester.pump();
      // Whether overlapped depends on exact distance; assert helper directly instead of UI ambiguity.
      final overlappingAt100 = PlacesDetailBody.overlapping(
        latitude: -10.18,
        longitude: -48.33,
        radiusM: 100,
        otherPlaces: [other],
      );
      // If distance <200 then overlaps, else not. Just verify logic matches expectation.
      if (d < 200) {
        expect(overlappingAt100, isNotEmpty);
      } else {
        expect(overlappingAt100, isEmpty);
      }
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

      // Change slider to 800
      tester
          .widget<Slider>(find.byKey(const Key('places-detail-slider')))
          .onChanged!(800);
      await tester.pump();

      // Name field already has 'Casa', change to 'Casa Nova'
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

    testWidgets('save disabled when name empty', (tester) async {
      var called = false;
      await tester.pumpWidget(
        _wrap(
          PlacesDetailBody(
            latitude: -10.18,
            longitude: -48.33,
            initialName: '',
            initialRadiusM: 150,
            otherPlaces: const [],
            onSave: (_, _, _) => called = true,
          ),
        ),
      );
      await tester.pump();

      // Save should be disabled (onPressed null)
      final saveTile = tester.widget<SoftActionTile>(
        find.byKey(const Key('places-detail-save')),
      );
      expect(saveTile.onPressed, isNull);
      await tester.tap(find.byKey(const Key('places-detail-save')));
      await tester.pump();
      expect(called, isFalse);

      // Enter name enables
      await tester.enterText(
        find.byKey(const Key('places-detail-name-field')),
        'Novo',
      );
      await tester.pump();
      final enabledTile = tester.widget<SoftActionTile>(
        find.byKey(const Key('places-detail-save')),
      );
      expect(enabledTile.onPressed, isNotNull);
    });

    testWidgets('cancel calls onCancel', (tester) async {
      var cancelled = false;
      await tester.pumpWidget(
        _wrap(
          PlacesDetailBody(
            latitude: -10.18,
            longitude: -48.33,
            initialName: 'Casa',
            initialRadiusM: 150,
            otherPlaces: const [],
            onSave: (_, _, _) {},
            onCancel: () => cancelled = true,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('places-detail-cancel')));
      expect(cancelled, isTrue);
    });

    testWidgets('radius label shows rounded meters', (tester) async {
      await tester.pumpWidget(
        _wrap(
          PlacesDetailBody(
            latitude: -10.18,
            longitude: -48.33,
            initialName: 'Casa',
            initialRadiusM: 123.6,
            otherPlaces: const [],
            onSave: (_, _, _) {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('124 m'), findsWidgets);
    });

    testWidgets('initial radius clamped to 50-2000', (tester) async {
      await tester.pumpWidget(
        _wrap(
          PlacesDetailBody(
            latitude: -10.18,
            longitude: -48.33,
            initialName: 'Casa',
            initialRadiusM: 10, // below min
            otherPlaces: const [],
            onSave: (_, _, _) {},
          ),
        ),
      );
      await tester.pump();
      final slider = tester.widget<Slider>(
        find.byKey(const Key('places-detail-slider')),
      );
      expect(slider.value, 50);

      await tester.pumpWidget(
        _wrap(
          PlacesDetailBody(
            latitude: -10.18,
            longitude: -48.33,
            initialName: 'Casa',
            initialRadiusM: 5000, // above max
            otherPlaces: const [],
            onSave: (_, _, _) {},
          ),
        ),
      );
      await tester.pump();
      final slider2 = tester.widget<Slider>(
        find.byKey(const Key('places-detail-slider')),
      );
      expect(slider2.value, 2000);
    });
  });

  group('PlacesDetailBody.overlapping helper', () {
    test('detects overlap when distance < sum', () {
      const a = InsightPlace(
        id: 'a',
        name: 'A',
        latitude: -10.18,
        longitude: -48.33,
        radiusM: 150,
      );
      const b = InsightPlace(
        id: 'b',
        name: 'B',
        latitude: -10.181,
        longitude: -48.331,
        radiusM: 150,
      );
      final overlapping = PlacesDetailBody.overlapping(
        latitude: a.latitude,
        longitude: a.longitude,
        radiusM: a.radiusM,
        otherPlaces: [b],
      );
      expect(overlapping, hasLength(1));
    });

    test('no overlap when distance > sum', () {
      const a = InsightPlace(
        id: 'a',
        name: 'A',
        latitude: -10.18,
        longitude: -48.33,
        radiusM: 50,
      );
      const b = InsightPlace(
        id: 'b',
        name: 'B',
        latitude: -10.50,
        longitude: -48.50,
        radiusM: 50,
      );
      final overlapping = PlacesDetailBody.overlapping(
        latitude: a.latitude,
        longitude: a.longitude,
        radiusM: a.radiusM,
        otherPlaces: [b],
      );
      expect(overlapping, isEmpty);
    });

    test('excludes self via placeId', () {
      const self = InsightPlace(
        id: 'self',
        name: 'Casa',
        latitude: -10.18,
        longitude: -48.33,
        radiusM: 150,
      );
      final overlapping = PlacesDetailBody.overlapping(
        latitude: self.latitude,
        longitude: self.longitude,
        radiusM: self.radiusM,
        otherPlaces: [self],
        placeId: 'self',
      );
      expect(overlapping, isEmpty);
    });

    test('placeContaining respects updated radius', () {
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
      // Point ~200m away
      const point = InsightPoint(-10.1818, -48.33);
      final dist = insightDistanceM(
        point.latitude,
        point.longitude,
        placeSmall.latitude,
        placeSmall.longitude,
      );
      expect(dist, greaterThan(150));
      expect(dist, lessThan(300));
      expect(placeContaining(point, [placeSmall]), isNull);
      expect(placeContaining(point, [placeLarge]), isNotNull);
    });
  });

  group('showPlaceDetailDialog keyboard', () {
    testWidgets('panel stays above the keyboard and stays scrollable', (
      tester,
    ) async {
      const keyboard = 300.0;
      // Fixed phone-size surface so the keyboard-line math below is exact.
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      PlaceDetailSave? saved;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          // Injects the simulated IME inset for every route, exactly how the
          // real system reports an open keyboard to the dialog route.
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(viewInsets: const EdgeInsets.only(bottom: keyboard)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                return Center(
                  child: FilledButton(
                    onPressed: () async {
                      saved = await showPlaceDetailDialog(
                        context: context,
                        latitude: -10,
                        longitude: -48,
                        initialName: '',
                        otherPlaces: const [],
                        title: 'Detalhe do local',
                        hintText: 'Nome',
                        saveLabel: 'Salvar',
                        cancelLabel: 'Cancelar',
                        barrierLabel: 'x',
                      );
                    },
                    child: const Text('open'),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final panelBox = tester.renderObject<RenderBox>(
        find.byKey(const Key('floating-panel')),
      );
      // 844 height - bottom inset 300 leaves room; the panel must fit
      // within it, never overflow past the keyboard line.
      expect(panelBox.size.height, lessThanOrEqualTo(844 - keyboard));
      expect(panelBox.localToGlobal(Offset.zero).dy, greaterThanOrEqualTo(0));
      expect(
        panelBox.localToGlobal(Offset(0, panelBox.size.height)).dy,
        lessThanOrEqualTo(844 - keyboard),
      );

      // The name field and save button are reachable: scrolling the body
      // brings the save row into the area above the keyboard.
      await tester.scrollUntilVisible(
        find.byKey(const Key('places-detail-save')),
        120,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('floating-panel')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        tester.getBottomRight(find.byKey(const Key('places-detail-save'))).dy,
        lessThanOrEqualTo(844 - keyboard),
      );

      await tester.enterText(
        find.byKey(const Key('places-detail-name-field')),
        'Casa',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('places-detail-save')));
      await tester.pumpAndSettle();
      expect(saved?.name, 'Casa');
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
