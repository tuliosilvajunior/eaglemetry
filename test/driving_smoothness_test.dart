import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/driving_smoothness.dart';

/// Feeds a tracker one steady sample train and returns the reading at the end.
///
/// [powerAt] is given the sample index so a test can shape the power however it
/// needs; speed is held, because every property under test here is about power
/// against distance rather than about speed itself.
DrivingSmoothness _drive({
  required double speedKmh,
  required double Function(int index) powerAt,
  Duration total = const Duration(seconds: 40),
  Duration step = const Duration(milliseconds: 200),
  SmoothnessTracker? tracker,
  int startMillis = 0,
}) {
  final t = tracker ?? SmoothnessTracker();
  final count = total.inMilliseconds ~/ step.inMilliseconds;
  var now = startMillis;
  for (var i = 0; i < count; i++) {
    t.observe(nowMillis: now, speedKmh: speedKmh, drivePowerKw: powerAt(i));
    now += step.inMilliseconds;
  }
  return t.readingAt(now - step.inMilliseconds);
}

void main() {
  group('the score', () {
    test('zero ramp is the top and twice the reference is the floor', () {
      expect(smoothnessScore(0, reference: 400), 1);
      expect(smoothnessScore(400, reference: 400), closeTo(0.5, 1e-9));
      expect(smoothnessScore(800, reference: 400), 0);
    });

    test('a reading past the floor clips instead of going negative', () {
      expect(smoothnessScore(5000, reference: 400), 0);
    });

    test('a reference of zero is refused rather than divided by', () {
      expect(smoothnessScore(100, reference: 0), 0);
    });
  });

  group('the reading', () {
    test('holding a steady power is the top of the track', () {
      final reading = _drive(speedKmh: 50, powerAt: (_) => 6.0);
      expect(reading.state, SmoothnessState.measured);
      expect(reading.standing, 1);
      expect(reading.rampKwPerKm, closeTo(0, 1e-9));
    });

    test('the reading is the same at every steady speed', () {
      // The defect that retired the previous reading was that holding a speed
      // — the same correct act at any speed — scored 1.00 at 30 km/h and 0.48
      // at 90. This is the assertion that keeps it retired.
      for (final speed in [30.0, 50.0, 70.0, 90.0]) {
        final reading = _drive(speedKmh: speed, powerAt: (_) => speed / 8);
        expect(
          reading.standing,
          1,
          reason: 'steady $speed km/h should read the same as any other',
        );
      }
    });

    test('changing power constantly drops the knob', () {
      final steady = _drive(speedKmh: 50, powerAt: (_) => 6.0);
      final churning = _drive(
        speedKmh: 50,
        powerAt: (i) => i.isEven ? 2.0 : 30.0,
      );
      expect(churning.standing!, lessThan(steady.standing!));
      expect(churning.standing, 0);
    });

    test('harsher driving always ranks below gentler driving', () {
      // The previous reading ranked these backwards, which is what made it
      // worth replacing. The order is the whole point of the instrument.
      double standingFor(double swing) => _drive(
        speedKmh: 50,
        // One power excursion every four seconds, of the given size.
        powerAt: (i) => (i % 20) < 3 ? 6.0 + swing : 6.0,
      ).standing!;

      final gentle = standingFor(5);
      final normal = standingFor(20);
      final harsh = standingFor(45);
      expect(gentle, greaterThan(normal));
      expect(normal, greaterThan(harsh));
    });
  });

  group('signal defences', () {
    test('quantisation dither does not register as driving', () {
      // VCU_DrvPwrAct resolves to 0.1 kW. Without the deadband a signal
      // dithering on its last bit would integrate into a large false ramp.
      final reading = _drive(
        speedKmh: 50,
        powerAt: (i) => i.isEven ? 6.0 : 6.1,
      );
      expect(reading.rampKwPerKm, closeTo(0, 1e-9));
      expect(reading.standing, 1);
    });

    test('samples faster than the grid are dropped, not counted twice', () {
      final t = SmoothnessTracker();
      expect(t.observe(nowMillis: 0, speedKmh: 50, drivePowerKw: 5), isTrue);
      // Inside the 200 ms grid.
      expect(t.observe(nowMillis: 50, speedKmh: 50, drivePowerKw: 40), isFalse);
      expect(
        t.observe(nowMillis: 199, speedKmh: 50, drivePowerKw: 40),
        isFalse,
      );
      expect(t.observe(nowMillis: 200, speedKmh: 50, drivePowerKw: 40), isTrue);
    });

    test('a gap in sampling does not fabricate a ramp', () {
      final t = SmoothnessTracker();
      t.observe(nowMillis: 0, speedKmh: 50, drivePowerKw: 5);
      t.observe(nowMillis: 200, speedKmh: 50, drivePowerKw: 5);
      // Ten seconds later the power has moved 35 kW. Nothing measured the
      // journey between, so it must not be charged as a ramp.
      final after = _drive(
        speedKmh: 50,
        powerAt: (_) => 40.0,
        tracker: t,
        startMillis: 10200,
      );
      expect(after.rampKwPerKm, closeTo(0, 1e-9));
    });

    test('a missing signal breaks the run rather than spanning it', () {
      final t = SmoothnessTracker();
      t.observe(nowMillis: 0, speedKmh: 50, drivePowerKw: 5);
      t.observe(nowMillis: 200, speedKmh: 50, drivePowerKw: null);
      final after = _drive(
        speedKmh: 50,
        powerAt: (_) => 40.0,
        tracker: t,
        startMillis: 400,
      );
      expect(after.rampKwPerKm, closeTo(0, 1e-9));
    });
  });

  group('states without a reading', () {
    test('a fresh tracker has nothing to show', () {
      expect(
        SmoothnessTracker().readingAt(0).state,
        SmoothnessState.unavailable,
      );
      expect(DrivingSmoothness.unavailable.hasKnob, isFalse);
      expect(DrivingSmoothness.unavailable.standing, isNull);
    });

    test('a stop holds the last reading instead of emptying the pill', () {
      final t = SmoothnessTracker();
      _drive(speedKmh: 50, powerAt: (_) => 6.0, tracker: t);
      final moving = t.readingAt(39800);
      expect(moving.state, SmoothnessState.measured);

      // Long enough stopped that the window carries no distance at all.
      final stopped = _drive(
        speedKmh: 0,
        powerAt: (_) => 1.0,
        total: const Duration(seconds: 40),
        tracker: t,
        startMillis: 40000,
      );
      expect(stopped.state, SmoothnessState.held);
      expect(stopped.standing, moving.standing);
      // No "now" to compare a standing against while the car is not moving.
      expect(stopped.instant, isNull);
    });

    test('a hold does not outlive the car being stopped', () {
      final t = SmoothnessTracker();
      _drive(speedKmh: 50, powerAt: (_) => 6.0, tracker: t);
      final withinHold = t.readingAt(
        39800 + kSmoothnessHold.inMilliseconds - 1000,
      );
      expect(withinHold.state, SmoothnessState.held);
      final pastHold = t.readingAt(
        39800 + kSmoothnessHold.inMilliseconds + 1000,
      );
      expect(pastHold.state, SmoothnessState.unavailable);
    });

    test('reset drops everything, including the hold', () {
      final t = SmoothnessTracker();
      _drive(speedKmh: 50, powerAt: (_) => 6.0, tracker: t);
      expect(t.readingAt(39800).state, SmoothnessState.measured);
      t.reset();
      expect(t.readingAt(39800).state, SmoothnessState.unavailable);
    });
  });

  group('the two marks', () {
    test('the instant reads a shorter window than the knob', () {
      final t = SmoothnessTracker();
      // Thirty seconds of churn, then five seconds of calm. The knob still
      // carries the churn; the tick has already left it behind.
      _drive(
        speedKmh: 50,
        powerAt: (i) => i.isEven ? 2.0 : 30.0,
        total: const Duration(seconds: 30),
        tracker: t,
      );
      final reading = _drive(
        speedKmh: 50,
        powerAt: (_) => 6.0,
        total: const Duration(seconds: 5),
        tracker: t,
        startMillis: 30000,
      );
      expect(reading.instant!, greaterThan(reading.standing!));
      expect(reading.improving, isTrue);
    });

    test('the colour follows the knob and never the tick', () {
      // A smooth stretch inside a harsh window must not turn the pill green:
      // the colour is the standing, so it cannot flicker with the pedal.
      final t = SmoothnessTracker();
      _drive(
        speedKmh: 50,
        powerAt: (i) => i.isEven ? 2.0 : 40.0,
        total: const Duration(seconds: 30),
        tracker: t,
      );
      // Six seconds, so the five-second window holds nothing but the calm.
      // At three it still carried the tail of the churn, which is the window
      // working rather than a smooth moment failing to register.
      final reading = _drive(
        speedKmh: 50,
        powerAt: (_) => 6.0,
        total: const Duration(seconds: 6),
        tracker: t,
        startMillis: 30000,
      );
      expect(reading.instant, 1);
      expect(reading.aboveNeutral, isFalse);
    });

    test('improving is null when either mark is missing', () {
      expect(DrivingSmoothness.unavailable.improving, isNull);
      expect(
        const DrivingSmoothness(
          state: SmoothnessState.held,
          standing: 0.5,
        ).improving,
        isNull,
      );
    });
  });

  test('the distance floor scales with the window', () {
    // A rate, not a fixed amount: the same judgement has to hold at five
    // seconds and at thirty.
    expect(
      smoothnessDistanceFloorKm(kSmoothnessWindow),
      closeTo(kSmoothnessMinSpeedKmh * 30 / 3600, 1e-9),
    );
    expect(
      smoothnessDistanceFloorKm(kSmoothnessInstantWindow),
      closeTo(kSmoothnessMinSpeedKmh * 5 / 3600, 1e-9),
    );
  });
}
