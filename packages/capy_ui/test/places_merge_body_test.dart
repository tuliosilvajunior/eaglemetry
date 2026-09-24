import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  final placeA = const InsightPlace(
    id: 'a',
    name: 'Casa',
    latitude: -10.18,
    longitude: -48.33,
    radiusM: 150,
    createdAtUtcMillis: 100,
  );
  final placeB = const InsightPlace(
    id: 'b',
    name: 'casa ',
    latitude: -10.1818,
    longitude: -48.33,
    radiusM: 100,
    createdAtUtcMillis: 200,
  );

  group('PlacesMergeBody', () {
    testWidgets('renders both names, distance and three circles', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(PlacesMergeBody(pair: _pair(placeA, placeB))),
      );
      await tester.pump();

      expect(find.byKey(const Key('places-merge-title')), findsOneWidget);
      expect(find.textContaining('Casa'), findsWidgets);
      expect(find.textContaining('200 m'), findsOneWidget);

      final layer = tester.widget<CircleLayer>(
        find.byKey(const Key('places-merge-circle-layer')),
      );
      expect(layer.circles, hasLength(3));
      // Source circles keep their own geometry.
      expect(layer.circles[0].radius, 150);
      expect(layer.circles[0].point.latitude, -10.18);
      expect(layer.circles[1].radius, 100);
      expect(layer.circles[1].point.latitude, -10.1818);
      // Proposed circle starts at the proposal and sits at the mean center.
      final expected = proposeMergeRadiusM(placeA, placeB);
      expect(layer.circles[2].point.latitude, closeTo(-10.1809, 1e-9));
      expect(layer.circles[2].radius, expected);
      expect(find.text('${expected.round()} m'), findsWidgets);
      expect(layer.circles.every((c) => c.useRadiusInMeter), isTrue);
    });

    testWidgets('slider moves the proposed circle live', (tester) async {
      await tester.pumpWidget(
        _wrap(PlacesMergeBody(pair: _pair(placeA, placeB))),
      );
      await tester.pump();

      final slider = tester.widget<Slider>(
        find.byKey(const Key('places-merge-slider')),
      );
      expect(slider.min, 50);
      expect(slider.max, 2000);

      slider.onChanged!(800);
      await tester.pump();

      final layer = tester.widget<CircleLayer>(
        find.byKey(const Key('places-merge-circle-layer')),
      );
      expect(layer.circles[2].radius, 800);
      expect(find.text('800 m'), findsWidgets);
    });

    testWidgets(
      'confirm returns the older id as keeper and the proposed geometry',
      (tester) async {
        PlaceMergeSave? save;
        await tester.pumpWidget(
          _wrap(
            PlacesMergeBody(
              pair: _pair(placeA, placeB),
              onSave: (s) => save = s,
            ),
          ),
        );
        await tester.pump();

        tester
            .widget<Slider>(find.byKey(const Key('places-merge-slider')))
            .onChanged!(600);
        await tester.pump();
        await tester.tap(find.byKey(const Key('places-merge-confirm')));
        await tester.pump();

        expect(save, isNotNull);
        expect(save!.keepId, 'a');
        expect(save!.deleteId, 'b');
        expect(save!.latitude, closeTo(-10.1809, 1e-9));
        expect(save!.longitude, closeTo(-48.33, 1e-9));
        expect(save!.radiusM, 600);
      },
    );

    testWidgets('cancel calls onCancel', (tester) async {
      var cancelled = false;
      await tester.pumpWidget(
        _wrap(
          PlacesMergeBody(
            pair: _pair(placeA, placeB),
            onCancel: () => cancelled = true,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('places-merge-cancel')));
      expect(cancelled, isTrue);
    });
  });

  group('showPlacesMergeDialog', () {
    testWidgets('confirm pops with PlaceMergeSave, cancel pops null', (
      tester,
    ) async {
      PlaceMergeSave? result;
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => Center(
              child: SoftActionTile(
                label: 'open',
                onPressed: () async {
                  result = await showPlacesMergeDialog(
                    context: context,
                    pair: _pair(placeA, placeB),
                    title: 'Mesclar locais',
                    saveLabel: 'Confirmar mescla',
                    cancelLabel: 'Cancelar',
                    barrierLabel: 'merge',
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('places-merge-body')), findsOneWidget);

      await tester.tap(find.byKey(const Key('places-merge-confirm')));
      await tester.pumpAndSettle();
      expect(result?.keepId, 'a');
      expect(result?.deleteId, 'b');
    });
  });
}

PlaceDuplicatePair _pair(InsightPlace a, InsightPlace b) => PlaceDuplicatePair(
  placeA: a,
  placeB: b,
  distanceM: insightDistanceM(a.latitude, a.longitude, b.latitude, b.longitude),
);

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(
      body: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  );
}
