import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/capy_ui.dart';

/// The reference palette. The ramp is a theme value now, so a test that
/// checks the ordering has to say which theme it is checking.
const _ramp = AppThemeColors.light;

void main() {
  group('RouteSpeedScale', () {
    test('measures a leg by the mean of its two ends', () {
      const points = [
        RouteMapPoint(latitude: -10.18, longitude: -48.33, speedKmh: 10),
        RouteMapPoint(latitude: -10.19, longitude: -48.34, speedKmh: 30),
        RouteMapPoint(latitude: -10.20, longitude: -48.35, speedKmh: 90),
      ];

      final scale = RouteSpeedScale.fromPoints(points);

      // Legs of 20 and 60, not points of 10 and 90: the line draws legs.
      expect(scale.slowestKmh, 20);
      expect(scale.fastestKmh, 60);
      expect(scale.hasSpeed, isTrue);
    });

    test('a route the car recorded without speed has no scale', () {
      const points = [
        RouteMapPoint(latitude: -10.18, longitude: -48.33),
        RouteMapPoint(latitude: -10.19, longitude: -48.34),
      ];

      final scale = RouteSpeedScale.fromPoints(points);

      expect(scale.hasSpeed, isFalse);
      expect(scale.slowestKmh, isNull);
    });

    test('an unreported leg is drawn apart from a slow one', () {
      // Three points, so the route has two legs to put at the ends of the
      // ramp. Two points are one leg, and one leg is a drive at one speed.
      const points = [
        RouteMapPoint(latitude: -10.18, longitude: -48.33, speedKmh: 5),
        RouteMapPoint(latitude: -10.19, longitude: -48.34, speedKmh: 5),
        RouteMapPoint(latitude: -10.20, longitude: -48.35, speedKmh: 95),
      ];
      final scale = RouteSpeedScale.fromPoints(points);

      // "The car did not say" must not be painted as "the car was crawling".
      expect(
        scale.colorFor(null, _ramp),
        isNot(scale.colorFor(scale.slowestKmh, _ramp)),
      );
      expect(
        scale.colorFor(scale.slowestKmh, _ramp),
        RouteSpeedScale.rampOf(_ramp).first,
      );
      expect(
        scale.colorFor(scale.fastestKmh, _ramp),
        RouteSpeedScale.rampOf(_ramp).last,
      );
    });

    test('a drive at one speed takes the middle of the ramp', () {
      const points = [
        RouteMapPoint(latitude: -10.18, longitude: -48.33, speedKmh: 40),
        RouteMapPoint(latitude: -10.19, longitude: -48.34, speedKmh: 40),
      ];
      final scale = RouteSpeedScale.fromPoints(points);

      expect(scale.colorFor(40, _ramp), RouteSpeedScale.rampOf(_ramp)[2]);
    });
  });

  testWidgets('the route is cut into one polyline per colour, over a plate', (
    tester,
  ) async {
    await tester.pumpWidget(
      _card(const [
        RouteMapPoint(latitude: -10.18, longitude: -48.33, speedKmh: 5),
        RouteMapPoint(latitude: -10.19, longitude: -48.34, speedKmh: 5),
        RouteMapPoint(latitude: -10.20, longitude: -48.35, speedKmh: 95),
        RouteMapPoint(latitude: -10.21, longitude: -48.36, speedKmh: 95),
      ], width: 400),
    );
    await tester.pump();

    final layer = tester.widget<PolylineLayer>(find.byType(PolylineLayer));
    // The plate under the line, plus a run for each speed the drive held.
    expect(layer.polylines.length, greaterThan(2));
    expect(layer.polylines.first.strokeWidth, greaterThan(5));
    final colors = layer.polylines.skip(1).map((line) => line.color).toSet();
    expect(colors.length, greaterThan(1));
  });

  testWidgets('a card too narrow for the legend drops it, not the colours', (
    tester,
  ) async {
    const route = [
      RouteMapPoint(latitude: -10.18, longitude: -48.33, speedKmh: 10),
      RouteMapPoint(latitude: -10.19, longitude: -48.34, speedKmh: 80),
    ];

    await tester.pumpWidget(_card(route, width: 400));
    await tester.pump();
    expect(find.text('Slow 10 km/h'), findsOneWidget);
    expect(find.text('Fast 80 km/h'), findsOneWidget);

    await tester.pumpWidget(_card(route, width: 200));
    await tester.pump();
    expect(find.text('Slow 10 km/h'), findsNothing);
    expect(find.byType(PolylineLayer), findsOneWidget);
  });

  testWidgets('a drive is marked at its start and at its end', (tester) async {
    await tester.pumpWidget(
      _card(const [
        RouteMapPoint(latitude: -10.18, longitude: -48.33, speedKmh: 10),
        RouteMapPoint(latitude: -10.19, longitude: -48.34, speedKmh: 80),
      ], width: 400),
    );
    await tester.pump();

    final layer = tester.widget<MarkerLayer>(find.byType(MarkerLayer));
    expect(layer.markers.length, 2);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.byIcon(Icons.flag), findsOneWidget);
  });

  testWidgets('the tiles are taken down to a ground, not left as a picture', (
    tester,
  ) async {
    await tester.pumpWidget(
      _card(const [
        RouteMapPoint(latitude: -10.18, longitude: -48.33, speedKmh: 10),
        RouteMapPoint(latitude: -10.19, longitude: -48.34, speedKmh: 80),
      ], width: 400),
    );
    await tester.pump();

    // Four saturated ramp colours over a full-colour street map is two
    // pictures fighting; the filter is what makes the route the only thing
    // being read.
    expect(
      tester.widget<TileLayer>(find.byType(TileLayer)).tileBuilder,
      isNotNull,
    );
  });

  testWidgets('one recorded position is a place, not a route', (tester) async {
    await tester.pumpWidget(
      _card(const [
        RouteMapPoint(latitude: -10.18, longitude: -48.33),
      ], width: 400),
    );
    await tester.pump();

    expect(find.byType(PolylineLayer), findsNothing);
    expect(find.byIcon(Icons.place), findsOneWidget);
  });
}

Widget _card(
  List<RouteMapPoint> points, {
  required double width,
  bool legend = true,
}) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: RouteMapCard(
            points: points,
            speedLegend: legend
                ? const RouteSpeedLegend(
                    slowLabel: 'Slow 10 km/h',
                    fastLabel: 'Fast 80 km/h',
                  )
                : null,
          ),
        ),
      ),
    ),
  );
}
