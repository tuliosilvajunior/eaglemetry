import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  SessionRecord tripSession({String id = 'trip-1'}) => SessionRecord(
    id: id,
    vehicleId: 'v1',
    kind: SessionKind.trip,
    status: 'CLOSED',
    startedAtUtcMillis: 1000000,
    startedAtElapsedNanos: 0,
    durationMillis: 180000,
    rollup: const SessionRollup(
      distance: Measurement.measured(5, unit: 'km'),
      traction: Measurement.measured(800, unit: 'Wh'),
      regen: Measurement.measured(100, unit: 'Wh'),
      auxiliary: Measurement.measured(50, unit: 'Wh'),
      climate: Measurement.measured(30, unit: 'Wh'),
      delivered: Measurement.unreported(unit: 'Wh'),
      integratedSeconds: Measurement.measured(180, unit: 's'),
    ),
    startOdometer: const Measurement.measured(10000, unit: 'km'),
    endOdometer: const Measurement.measured(10005, unit: 'km'),
    startSoc: const Measurement.measured(80, unit: '%'),
    endSoc: const Measurement.measured(70, unit: '%'),
    minSoc: const Measurement.measured(70, unit: '%'),
    maxSoc: const Measurement.measured(80, unit: '%'),
    startAmbientTemp: const Measurement.unreported(unit: '°C'),
    endAmbientTemp: const Measurement.unreported(unit: '°C'),
    meanAmbientTemp: const Measurement.unreported(unit: '°C'),
    createdAtUtcMillis: 1000000,
    updatedAtUtcMillis: 1000000,
  );

  IntervalRecord bucket({
    required int minute,
    double? startSoc,
    double? endSoc,
  }) => IntervalRecord(
    sessionId: 'trip-1',
    startUtcMillis: 1000000 + minute * 60000,
    widthMillis: 60000,
    traction: const Measurement.measured(200, unit: 'Wh'),
    regen: const Measurement.unreported(unit: 'Wh'),
    auxiliary: const Measurement.unreported(unit: 'Wh'),
    climate: const Measurement.unreported(unit: 'Wh'),
    delivered: const Measurement.unreported(unit: 'Wh'),
    distance: const Measurement.measured(1.5, unit: 'km'),
    coveredSeconds: 60,
    climateCoveredSeconds: 0,
    speedCoveredSeconds: 60,
    deliveredCoveredSeconds: 0,
    startSoc: startSoc == null
        ? const Measurement.unreported(unit: '%')
        : Measurement.measured(startSoc, unit: '%'),
    endSoc: endSoc == null
        ? const Measurement.unreported(unit: '%')
        : Measurement.measured(endSoc, unit: '%'),
  );

  group('the trip SOC curve', () {
    test('reads the start and end of every bucket that carried a reading', () {
      final detail = TripDetailReading(
        session: tripSession(),
        series: TelemetrySeries(
          sessionId: 'trip-1',
          intervals: [
            bucket(minute: 0, startSoc: 80, endSoc: 77),
            bucket(minute: 1, startSoc: 77, endSoc: 74),
            bucket(minute: 2, startSoc: 74, endSoc: 70),
          ],
          samples: const {},
        ),
      );

      final series = detail.socSeries;
      expect(series.map((p) => p.y), [80, 77, 77, 74, 74, 70]);
      expect(series.first.x, 0);
      expect(series.last.x, 180);
    });

    test(
      'skips a bucket the bus went quiet through, rather than a default',
      () {
        final detail = TripDetailReading(
          session: tripSession(),
          series: TelemetrySeries(
            sessionId: 'trip-1',
            intervals: [
              bucket(minute: 0, startSoc: 80, endSoc: 77),
              // No reading landed in this bucket at all.
              bucket(minute: 1),
              bucket(minute: 2, startSoc: 74, endSoc: 70),
            ],
            samples: const {},
          ),
        );

        expect(detail.socSeries.map((p) => p.y), [80, 77, 74, 70]);
      },
    );
  });
}
