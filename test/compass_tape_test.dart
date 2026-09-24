import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/compass_reading.dart';
import 'package:capy_ui/capy_ui.dart';

const _cardinals = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];

Widget _wrap(Widget child) => MaterialApp(
  theme: AppTheme.light(),
  home: Scaffold(
    body: Center(child: SizedBox(width: 280, child: child)),
  ),
);

void main() {
  group('compassIndexOf', () {
    test('names the eight points of the dial', () {
      expect(compassIndexOf(0), 0);
      expect(compassIndexOf(45), 1);
      expect(compassIndexOf(90), 2);
      expect(compassIndexOf(315), 7);
    });

    test('folds the degrees the tape walks past either end', () {
      // The tape draws half a span each side of the centre, so a course near
      // north asks for negative degrees and one near north-west asks past 360.
      expect(compassIndexOf(-45), 7);
      expect(compassIndexOf(-90), 6);
      expect(compassIndexOf(360), 0);
      expect(compassIndexOf(405), 1);
    });
  });

  group('compassBearingLabel', () {
    test('prints a whole degree', () {
      expect(compassBearingLabel(75.4), '75°');
      expect(compassBearingLabel(0), '0°');
    });

    test('north has one name', () {
      expect(compassBearingLabel(359.7), '0°');
    });

    test('an absent course is a placeholder, not a zero', () {
      expect(compassBearingLabel(null), '--');
      expect(compassBearingLabel(double.nan), '--');
    });
  });

  group('CompassNeedle', () {
    /// Turns the needle at [degPerSecond] for [seconds], then lets go and
    /// reports how far past the final course it swung.
    double overshootAfter(double degPerSecond, double seconds) {
      final needle = CompassNeedle()..snapTo(0);
      const frame = 1 / 60;
      final frames = (seconds / frame).round();
      for (var i = 0; i < frames; i++) {
        needle.target = compassNormalize(i * degPerSecond * frame);
        needle.step(frame);
      }
      final settled = needle.target;
      var worst = 0.0;
      for (var i = 0; i < 600; i++) {
        final moving = needle.step(frame);
        final past = compassDelta(settled, needle.angle);
        if (past > worst) worst = past;
        if (!moving) break;
      }
      return worst;
    }

    test('no turn rate makes the needle swing past the course', () {
      // The course arrives once a second, so every reading is a step. An
      // underdamped needle answered each one with a swing and the card was
      // never still. A degree is less than the width of the centre bar.
      expect(overshootAfter(10, 3), lessThan(1));
      expect(overshootAfter(60, 1.5), lessThan(1));
      expect(overshootAfter(300, 1.5), lessThan(1));
    });

    test('a step is finished before the next reading lands', () {
      // The chase has to be over inside the one second between courses,
      // otherwise the needle is always answering the reading before last.
      final needle = CompassNeedle()..snapTo(0);
      needle.target = 90;
      var frames = 0;
      while (needle.step(1 / 60) && frames < 600) {
        frames += 1;
      }
      expect(frames / 60, lessThan(1.0));
    });

    test('it comes to rest, so the ticker can stop', () {
      final needle = CompassNeedle()..snapTo(0);
      needle.target = 90;
      var moving = true;
      var frames = 0;
      while (moving && frames < 600) {
        moving = needle.step(1 / 60);
        frames += 1;
      }
      expect(moving, isFalse);
      // Under three seconds, which matters: the course is re-read every
      // second, and a needle still swinging from the last one would never
      // stand still.
      expect(frames, lessThan(180));
      expect(needle.angle, closeTo(90, 0.001));
      expect(needle.velocity, 0);
    });

    test('it turns the short way across north', () {
      final needle = CompassNeedle()..snapTo(350);
      needle.target = 10;
      // One frame is enough to see the direction: clockwise, not 340 degrees
      // back the other way.
      needle.step(1 / 60);
      expect(needle.velocity, greaterThan(0));
    });

    test('a dropped frame is integrated in bounded steps', () {
      // A whole second at once must not be one huge step: an underdamped
      // spring integrated that coarsely diverges instead of settling.
      final needle = CompassNeedle()..snapTo(0);
      needle.target = 90;
      needle.step(1);
      expect(needle.angle.isFinite, isTrue);
      expect(compassDelta(needle.angle, 90).abs(), lessThan(90));
    });

    test('snapTo places the needle with no motion', () {
      final needle = CompassNeedle()..snapTo(0);
      needle.target = 180;
      needle.step(1 / 60);
      needle.snapTo(42);
      expect(needle.angle, 42);
      expect(needle.velocity, 0);
      expect(needle.step(1 / 60), isFalse);
    });
  });

  group('CompassTape', () {
    testWidgets('draws without a course', (tester) async {
      await tester.pumpWidget(
        _wrap(const CompassTape(bearingDeg: null, cardinalLabels: _cardinals)),
      );
      expect(find.byType(CompassTape), findsOneWidget);
    });

    testWidgets('renders the final state under reduced motion', (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: _wrap(
            const CompassTape(bearingDeg: 90, cardinalLabels: _cardinals),
          ),
        ),
      );
      expect(find.byType(CompassTape), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a new course settles instead of hanging', (tester) async {
      await tester.pumpWidget(
        _wrap(const CompassTape(bearingDeg: 90, cardinalLabels: _cardinals)),
      );
      await tester.pumpWidget(
        _wrap(const CompassTape(bearingDeg: 180, cardinalLabels: _cardinals)),
      );
      // `pumpAndSettle` returns only once the ticker has stopped, so this is
      // the assertion that the simulation reaches rest under a real clock.
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('CompassCard', () {
    testWidgets('shows the title and the course', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const CompassCard(
            label: 'Compass',
            value: '75°',
            bearingDeg: 75,
            cardinalLabels: _cardinals,
          ),
        ),
      );
      expect(find.text('Compass'), findsOneWidget);
      expect(find.text('75°'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('a held course is captioned, a live one is not', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const CompassCard(
            label: 'Compass',
            value: '75°',
            bearingDeg: 75,
            cardinalLabels: _cardinals,
            state: CompassState.held,
            caption: 'Stopped. Last direction.',
          ),
        ),
      );
      expect(find.text('Stopped. Last direction.'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('an absent course shows the placeholder', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const CompassCard(
            label: 'Compass',
            value: '--',
            bearingDeg: null,
            cardinalLabels: _cardinals,
            state: CompassState.unavailable,
            caption: 'No GPS signal',
          ),
        ),
      );
      expect(find.text('--'), findsOneWidget);
      expect(find.text('No GPS signal'), findsOneWidget);
    });

    testWidgets('fits the readout strip without overflowing', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const CompassCard(
            label: 'Compass',
            value: '270°',
            bearingDeg: 270,
            cardinalLabels: _cardinals,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
