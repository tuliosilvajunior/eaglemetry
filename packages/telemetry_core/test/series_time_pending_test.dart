import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

IntervalRecord _minute(int minute, {String timeState = 'unknown'}) =>
    IntervalRecord(
      sessionId: 'trip-1',
      startUtcMillis: 1000000 + minute * 60000,
      widthMillis: 60000,
      traction: const Measurement.measured(40, unit: 'Wh'),
      regen: const Measurement.unreported(unit: 'Wh'),
      auxiliary: const Measurement.measured(5, unit: 'Wh'),
      climate: const Measurement.unreported(unit: 'Wh'),
      delivered: const Measurement.unreported(unit: 'Wh'),
      distance: const Measurement.measured(1, unit: 'km'),
      coveredSeconds: 60,
      climateCoveredSeconds: 0,
      speedCoveredSeconds: 0,
      deliveredCoveredSeconds: 0,
      timeState: timeState,
    );

void main() {
  group('seriesTimePending (time authority T6)', () {
    test('empty series is not pending', () {
      expect(seriesTimePending(const []), isFalse);
    });

    test('known and legacy series are not pending', () {
      expect(
        seriesTimePending([_minute(0, timeState: 'known'), _minute(1)]),
        isFalse,
      );
    });

    test('one pending minute marks the whole series', () {
      expect(
        seriesTimePending([
          _minute(0, timeState: 'known'),
          _minute(1, timeState: 'pending'),
          _minute(2, timeState: 'known'),
        ]),
        isTrue,
      );
    });

    test('uncorrectable alone does not mark pending', () {
      // Uncorrectable minutes keep their own marker (plan section 4); the
      // "not synced" chip is for rows the sweeper will still correct.
      expect(
        seriesTimePending([_minute(0, timeState: 'uncorrectable')]),
        isFalse,
      );
    });
  });
}
