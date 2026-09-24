import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/telemetry_api.dart';

HeadingReading _ok(double bearing, double speedMps, int atMillis) =>
    HeadingReading.fromMap({
      'timestampMillis': atMillis,
      'availability': 'OK',
      'bearingDeg': bearing,
      'speedMps': speedMps,
      'fixAgeMillis': 200,
    });

HeadingReading _stopped(int atMillis, {double speedMps = 0.0}) =>
    HeadingReading.fromMap({
      'timestampMillis': atMillis,
      'availability': 'NO_BEARING',
      'bearingDeg': null,
      'speedMps': speedMps,
      'fixAgeMillis': 300,
    });

HeadingReading _refused(String availability, int atMillis) =>
    HeadingReading.fromMap({
      'timestampMillis': atMillis,
      'availability': availability,
    });

void main() {
  group('compassDelta', () {
    test('takes the short way round the dial', () {
      expect(compassDelta(350, 10), 20);
      expect(compassDelta(10, 350), -20);
      expect(compassDelta(0, 90), 90);
    });

    test('reports a half turn with one sign', () {
      expect(compassDelta(0, 180), 180);
      expect(compassDelta(180, 0), 180);
    });

    test('a blend across north does not cross the whole dial', () {
      // The plain mean of 350 and 10 is 180, which points backwards.
      expect(compassBlend(350, 10, 0.5), 0);
      expect(compassBlend(10, 350, 0.5), 0);
    });
  });

  group('CompassTracker', () {
    test('says nothing before a reading arrives', () {
      expect(CompassTracker().reading.state, CompassState.unavailable);
      expect(CompassTracker().reading.hasBearing, isFalse);
    });

    test('a creeping car does not start the needle', () {
      final tracker = CompassTracker();
      // 2 km/h: the receiver reports a course, but it is derived from a
      // displacement close to the position error.
      final reading = tracker.update(_ok(90, 2 / 3.6, 1000));
      expect(reading.state, CompassState.unavailable);
      expect(reading.reason, HeadingAvailability.ok);
    });

    test('the two floors keep the needle steady in traffic', () {
      final tracker = CompassTracker();
      expect(tracker.update(_ok(90, 5 / 3.6, 1000)).state, CompassState.live);
      // Now below the show floor but above the keep floor. A single floor would
      // drop the needle here and raise it again a second later.
      expect(tracker.update(_ok(90, 2 / 3.6, 2000)).state, CompassState.live);
      // Below both floors, so the course is no longer taken.
      expect(tracker.update(_ok(90, 1 / 3.6, 3000)).state, CompassState.held);
    });

    test('a stopped car holds the course it arrived on', () {
      final tracker = CompassTracker();
      tracker.update(_ok(90, 10, 1000));
      final held = tracker.update(_stopped(4000));
      expect(held.state, CompassState.held);
      expect(held.bearingDeg, closeTo(90, 1e-9));
      expect(held.reason, HeadingAvailability.noBearing);
      expect(held.heldForMillis, 0);
      expect(tracker.update(_stopped(9000)).heldForMillis, 5000);
    });

    test('a long wait does not expire the hold', () {
      final tracker = CompassTracker();
      tracker.update(_ok(90, 10, 0));
      // An hour at a standstill. The car still faces the way it arrived.
      final held = tracker.update(_stopped(3600000));
      expect(held.state, CompassState.held);
      expect(held.bearingDeg, closeTo(90, 1e-9));
    });

    test('creeping far enough to turn discards the hold', () {
      final tracker = CompassTracker();
      tracker.update(_ok(90, 10, 0));
      // 1 m/s under the floors would be a course, but the car is manoeuvring:
      // six seconds is six metres, which is more than enough to turn.
      expect(
        tracker.update(_stopped(3000, speedMps: 1)).state,
        isNot(CompassState.unavailable),
      );
      expect(
        tracker.update(_stopped(6000, speedMps: 1)).state,
        CompassState.unavailable,
      );
    });

    test('a fresh course after a discarded hold starts the needle again', () {
      final tracker = CompassTracker();
      tracker.update(_ok(90, 10, 0));
      tracker.update(_stopped(10000, speedMps: 1));
      expect(tracker.reading.state, CompassState.unavailable);
      final live = tracker.update(_ok(270, 10, 11000));
      expect(live.state, CompassState.live);
      // No blend against the discarded heading: it was thrown away, so the new
      // course is taken whole rather than dragged back towards a stale one.
      expect(live.bearingDeg, closeTo(270, 1e-9));
    });

    test('a lost fix is not a stopped car, so nothing is held', () {
      for (final reason in const [
        'NO_FIX',
        'FIX_STALE',
        'GPS_DISABLED',
        'PERMISSION_MISSING',
        'MAGNETOMETER',
      ]) {
        final tracker = CompassTracker();
        tracker.update(_ok(90, 10, 1000));
        final reading = tracker.update(_refused(reason, 2000));
        expect(
          reading.state,
          CompassState.unavailable,
          reason: '$reason must not hold a heading',
        );
        expect(reading.hasBearing, isFalse);
      }
    });

    test('the reported reason names the state the source is in', () {
      final tracker = CompassTracker();
      tracker.update(_ok(90, 10, 1000));
      expect(
        tracker.update(_refused('GPS_DISABLED', 2000)).reason,
        HeadingAvailability.gpsDisabled,
      );
    });

    test('a course is smoothed towards, not jumped to', () {
      final tracker = CompassTracker(smoothing: 0.25);
      tracker.update(_ok(0, 10, 0));
      // A quarter of the way from 0 to 100.
      expect(tracker.update(_ok(100, 10, 1000)).bearingDeg, closeTo(25, 1e-9));
    });

    test('smoothing across north keeps the needle near north', () {
      final tracker = CompassTracker(smoothing: 0.5);
      tracker.update(_ok(350, 10, 0));
      expect(tracker.update(_ok(10, 10, 1000)).bearingDeg, closeTo(0, 1e-9));
    });

    test('reset forgets the held course', () {
      final tracker = CompassTracker();
      tracker.update(_ok(90, 10, 1000));
      tracker.update(_stopped(2000));
      tracker.reset();
      expect(tracker.reading.state, CompassState.unavailable);
      expect(tracker.update(_stopped(3000)).hasBearing, isFalse);
    });
  });
}
