import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';
import 'package:capy_energy/core/mock_telemetry_data.dart';

void main() {
  group('LiveEnergyBucketsResult width', () {
    test('carries the native cut down to every bucket', () {
      final result = LiveEnergyBucketsResult.fromMap({
        'sessionId': 'trip-1',
        'startedAtUtcMillis': 1785505140000,
        'bucketMillis': 10000,
        'buckets': [
          {'startUtcMillis': 1785505140000, 'tractionWh': 40.0},
        ],
      });

      expect(result.width, const Duration(seconds: 10));
      expect(result.buckets.single.width, const Duration(seconds: 10));
    });

    test('stays on the minute when the native side names no width', () {
      // The energy chart's own poll predates the field, so a payload without it
      // has to keep meaning minutes rather than becoming an unknown width.
      final result = LiveEnergyBucketsResult.fromMap({
        'sessionId': 'trip-1',
        'buckets': [
          {'startUtcMillis': 1785505140000, 'tractionWh': 40.0},
        ],
      });

      expect(result.width, EnergyBucket.oneMinute);
      expect(result.buckets.single.width, EnergyBucket.oneMinute);
    });
  });

  group('mock efficiency window', () {
    final result = LiveEnergyBucketsResult.fromMap(
      MockTelemetryData().liveEfficiencyBuckets(),
    );

    test('is ninety ten-second buckets', () {
      expect(result.width, const Duration(seconds: 10));
      expect(result.buckets, hasLength(90));
      expect(
        result.buckets.last.start.difference(result.buckets.first.start),
        const Duration(seconds: 890),
      );
    });

    test('reads as a plausible drive', () {
      final series = readEfficiency(result.buckets);

      expect(series.points, hasLength(90));
      expect(series.averageKmPerKwh, greaterThan(2));
      expect(series.averageKmPerKwh, lessThan(12));
      expect(series.head?.state, isNot(EfficiencyState.unreported));
    });

    /// Read at the bucket, not through the trailing window.
    ///
    /// The window is what makes a ratio exist, so it reduces the states that
    /// name its absence to near nothing — on this fixture it leaves only
    /// `consuming` and `gap`. That is the fix working, not the fixture going
    /// thin. The painter still has to draw all five, so the guarantee this
    /// test is here for is about the mock data, and it is checked at the width
    /// the mock data is written in.
    test('exercises every state the card has to draw', () {
      final states = readEfficiency(
        result.buckets,
        window: Duration.zero,
      ).points.map((point) => point.state).toSet();

      expect(states, containsAll(EfficiencyState.values));
    });

    /// The window must not move the headline figure. It changes what each
    /// point answers over, never what the fifteen minutes cost in total.
    test('the trailing window leaves the average untouched', () {
      final windowed = readEfficiency(result.buckets);
      final perBucket = readEfficiency(result.buckets, window: Duration.zero);

      expect(
        windowed.averageKmPerKwh,
        closeTo(perBucket.averageKmPerKwh!, 0.0001),
      );
      expect(windowed.distanceKm, closeTo(perBucket.distanceKm, 0.0001));
      expect(windowed.netWh, closeTo(perBucket.netWh, 0.0001));
    });
  });
}
