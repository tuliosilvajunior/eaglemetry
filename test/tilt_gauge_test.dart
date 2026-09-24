import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/telemetry_format.dart';
import 'package:capy_ui/capy_ui.dart';

Widget _host(Widget child, {Size size = const Size(420, 260)}) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(
      body: Center(
        child: SizedBox(width: size.width, height: size.height, child: child),
      ),
    ),
  );
}

/// Rotation of the group, in radians, read back off the rendered transform.
double _rotation(WidgetTester tester) {
  final transform = tester.widget<Transform>(find.byKey(tiltGroupKey).first);
  return math.atan2(
    transform.transform.getRow(1)[0],
    transform.transform.getRow(0)[0],
  );
}

void main() {
  group('tiltAngleLabel', () {
    test('rounds to whole degrees', () {
      expect(tiltAngleLabel(3.4), '3°');
      expect(tiltAngleLabel(-2.6), '-3°');
    });

    test('never shows a negative zero', () {
      expect(tiltAngleLabel(-0.2), '0°');
      expect(tiltAngleLabel(0), '0°');
    });

    test('an unknown or unusable angle is the placeholder', () {
      expect(tiltAngleLabel(null), '--');
      expect(tiltAngleLabel(double.nan), '--');
      expect(tiltAngleLabel(double.infinity), '--');
    });
  });

  group('TiltGauge', () {
    testWidgets('draws the silhouette tinted with the theme ink', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const TiltGauge(angleDeg: 4)));
      await tester.pump();

      final image = tester.widget<Image>(find.byType(Image));
      // The art is decoded at the size it is drawn, and never above the size
      // the file actually holds.
      final resized = image.image as ResizeImage;
      expect(
        (resized.imageProvider as AssetImage).assetName,
        CarSilhouette.side.asset,
      );
      expect(resized.width, isNotNull);
      expect(resized.width, lessThanOrEqualTo(CarSilhouette.side.sourceWidth));
      expect(image.colorBlendMode, BlendMode.srcIn);
      expect(image.color, AppThemeColors.light.ink);
    });

    testWidgets('carries the other axis by the silhouette alone', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const TiltGauge(
            angleDeg: 12,
            silhouette: CarSilhouette.front,
            animate: false,
          ),
        ),
      );
      await tester.pump();

      final image = tester.widget<Image>(find.byType(Image));
      final resized = image.image as ResizeImage;
      expect(
        (resized.imageProvider as AssetImage).assetName,
        CarSilhouette.front.asset,
      );
      // Positive roll is the vehicle's right side down, and a front view puts
      // that side at the left of the drawing, so it turns the same way as a
      // nose-up pitch on the side view.
      expect(_rotation(tester), closeTo(-12 * math.pi / 180, 1e-9));
    });

    testWidgets('draws every view of the vehicle at one scale', (tester) async {
      const box = Size(420, 260);
      await tester.pumpWidget(
        _host(const TiltGauge(angleDeg: 0, animate: false), size: box),
      );
      await tester.pump();
      final side = tester.getSize(find.byType(Image));

      await tester.pumpWidget(
        _host(
          const TiltGauge(
            angleDeg: 0,
            silhouette: CarSilhouette.front,
            animate: false,
          ),
          size: box,
        ),
      );
      await tester.pump();
      final front = tester.getSize(find.byType(Image));

      // Both keep their own aspect ratio, and neither leaves the box.
      expect(
        side.width / side.height,
        closeTo(CarSilhouette.side.aspectRatio, 0.01),
      );
      expect(
        front.width / front.height,
        closeTo(CarSilhouette.front.aspectRatio, 0.01),
      );
      expect(front.height, lessThanOrEqualTo(box.height));
      // Same vehicle, so same height in both views. Only the width differs,
      // and it differs by exactly the ratio of the two drawings.
      expect(front.height, closeTo(side.height, 0.5));
      expect(
        side.width / front.width,
        closeTo(
          CarSilhouette.side.aspectRatio / CarSilhouette.front.aspectRatio,
          0.02,
        ),
      );
    });

    testWidgets('keeps the whole drawing inside the box at any angle', (
      tester,
    ) async {
      const box = Size(420, 260);
      for (final silhouette in CarSilhouette.values) {
        for (final angle in const [-90.0, -45.0, -30.0, 30.0, 45.0, 90.0]) {
          await tester.pumpWidget(
            _host(
              TiltGauge(
                angleDeg: angle,
                silhouette: silhouette,
                animate: false,
              ),
              size: box,
            ),
          );
          await tester.pump();

          // The four corners come back already turned by the group's
          // transform, so this is the drawing where it actually lands.
          final image = find.byType(Image);
          final corners = [
            tester.getTopLeft(image),
            tester.getTopRight(image),
            tester.getBottomLeft(image),
            tester.getBottomRight(image),
          ];
          final gauge = tester.getRect(find.byType(TiltGauge));
          for (final corner in corners) {
            expect(
              corner.dy,
              greaterThanOrEqualTo(gauge.top - 0.5),
              reason: '$silhouette at $angle° leaves the top of the box',
            );
            expect(corner.dy, lessThanOrEqualTo(gauge.bottom + 0.5));
            expect(corner.dx, greaterThanOrEqualTo(gauge.left - 0.5));
            expect(corner.dx, lessThanOrEqualTo(gauge.right + 0.5));
          }
        }
      }
    });

    testWidgets('turns the drawing by the measured angle, in the direction '
        'the artwork asks for', (tester) async {
      await tester.pumpWidget(
        _host(const TiltGauge(angleDeg: 12, animate: false)),
      );
      await tester.pump();

      // The side view is mirrored to face right, so a nose-up angle must raise
      // the right of the drawing. On a y-down canvas that is counter-clockwise,
      // which is a negative rotation.
      expect(_rotation(tester), closeTo(-12 * math.pi / 180, 1e-9));
    });

    testWidgets('the mirror and the rotation sign move together', (
      tester,
    ) async {
      // The side file faces left and is flipped to put the nose at the right,
      // so raising the nose is counter-clockwise and the sign is negative.
      // Change one of the two alone and every reading inverts, which is the
      // defect seen on the car on 2026-08-11 — twice, because the first fix
      // changed both at once and cancelled itself.
      expect(CarSilhouette.side.mirrored, isTrue);
      expect(CarSilhouette.side.rotationSign, -1);
      expect(CarSilhouette.front.mirrored, isFalse);
      expect(CarSilhouette.front.rotationSign, -1);

      await tester.pumpWidget(
        _host(const TiltGauge(angleDeg: 0, animate: false)),
      );
      await tester.pump();
      expect(
        tester
            .widgetList<Transform>(
              find.ancestor(
                of: find.byType(Image),
                matching: find.byType(Transform),
              ),
            )
            .first
            .transform
            .getRow(0)[0],
        -1,
      );
    });

    testWidgets('a negative angle turns the other way', (tester) async {
      await tester.pumpWidget(
        _host(const TiltGauge(angleDeg: -12, animate: false)),
      );
      await tester.pump();

      expect(_rotation(tester), closeTo(12 * math.pi / 180, 1e-9));
    });

    testWidgets('the reading is drawn as measured, not exaggerated', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const TiltGauge(angleDeg: 1, animate: false)),
      );
      await tester.pump();

      expect(_rotation(tester), closeTo(-1 * math.pi / 180, 1e-9));
    });

    testWidgets('an unknown tilt draws level in the muted ink', (tester) async {
      await tester.pumpWidget(_host(const TiltGauge(angleDeg: null)));
      await tester.pump();

      expect(_rotation(tester), 0);
      expect(
        tester.widget<Image>(find.byType(Image)).color,
        AppThemeColors.light.inkSubtle,
      );
    });

    testWidgets('a new reading travels to its angle', (tester) async {
      await tester.pumpWidget(_host(const TiltGauge(angleDeg: 0)));
      await tester.pump();
      await tester.pumpWidget(_host(const TiltGauge(angleDeg: 20)));
      await tester.pump(const Duration(milliseconds: 40));

      final travelling = _rotation(tester);
      expect(travelling, lessThan(0));
      expect(travelling, greaterThan(-20 * math.pi / 180));

      await tester.pumpAndSettle();
      expect(_rotation(tester), closeTo(-20 * math.pi / 180, 1e-9));
    });

    testWidgets('fits the box it is given, at any shape', (tester) async {
      for (final size in const [
        Size(420, 260),
        Size(200, 140),
        Size(720, 200),
        Size(240, 600),
      ]) {
        await tester.pumpWidget(
          _host(const TiltGauge(angleDeg: 8, animate: false), size: size),
        );
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(TiltGauge)), size);
      }
    });

    testWidgets('takes its own height when the height is unbounded', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 400,
                child: Column(
                  children: const [TiltGauge(angleDeg: 2, animate: false)],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(TiltGauge)).height, greaterThan(0));
    });
  });

  group('TiltCard', () {
    testWidgets('shows the label and the formatted angle', (tester) async {
      await tester.pumpWidget(
        _host(
          TiltCard(
            label: 'Pitch',
            value: tiltAngleLabel(3.4),
            angleDeg: 3.4,
            animate: false,
          ),
          size: const Size(420, 320),
        ),
      );
      await tester.pump();

      expect(find.text('Pitch'), findsOneWidget);
      expect(find.text('3°'), findsOneWidget);
      expect(find.byType(TiltGauge), findsOneWidget);
    });

    testWidgets('shows the placeholder when there is no reading', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          TiltCard(
            label: 'Pitch',
            value: tiltAngleLabel(null),
            angleDeg: null,
            animate: false,
          ),
          size: const Size(420, 320),
        ),
      );
      await tester.pump();

      expect(find.text('--'), findsOneWidget);
    });
  });
}
