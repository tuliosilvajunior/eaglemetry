import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  SessionRecord chargeSession({String id = 'charge-1'}) => SessionRecord(
    id: id,
    vehicleId: 'v1',
    kind: SessionKind.charge,
    status: 'CLOSED',
    startedAtUtcMillis: 1000000,
    startedAtElapsedNanos: 0,
    durationMillis: 180000,
    rollup: const SessionRollup(
      distance: Measurement.unreported(unit: 'km'),
      traction: Measurement.unreported(unit: 'Wh'),
      regen: Measurement.unreported(unit: 'Wh'),
      auxiliary: Measurement.unreported(unit: 'Wh'),
      climate: Measurement.unreported(unit: 'Wh'),
      delivered: Measurement.measured(3000, unit: 'Wh'),
      integratedSeconds: Measurement.measured(180, unit: 's'),
    ),
    startOdometer: const Measurement.unreported(unit: 'km'),
    endOdometer: const Measurement.unreported(unit: 'km'),
    startSoc: const Measurement.measured(50, unit: '%'),
    endSoc: const Measurement.measured(80, unit: '%'),
    minSoc: const Measurement.measured(50, unit: '%'),
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
    sessionId: 'charge-1',
    startUtcMillis: 1000000 + minute * 60000,
    widthMillis: 60000,
    traction: const Measurement.unreported(unit: 'Wh'),
    regen: const Measurement.unreported(unit: 'Wh'),
    auxiliary: const Measurement.unreported(unit: 'Wh'),
    climate: const Measurement.unreported(unit: 'Wh'),
    delivered: const Measurement.measured(1000, unit: 'Wh'),
    distance: const Measurement.unreported(unit: 'km'),
    coveredSeconds: 60,
    climateCoveredSeconds: 0,
    speedCoveredSeconds: 0,
    deliveredCoveredSeconds: 60,
    startSoc: startSoc == null
        ? const Measurement.unreported(unit: '%')
        : Measurement.measured(startSoc, unit: '%'),
    endSoc: endSoc == null
        ? const Measurement.unreported(unit: '%')
        : Measurement.measured(endSoc, unit: '%'),
  );

  group('the charge SOC curve', () {
    test('reads the start and end of every bucket that carried a reading', () {
      final detail = ChargeDetailReading(
        session: chargeSession(),
        series: TelemetrySeries(
          sessionId: 'charge-1',
          intervals: [
            bucket(minute: 0, startSoc: 50, endSoc: 55),
            bucket(minute: 1, startSoc: 55, endSoc: 60),
            bucket(minute: 2, startSoc: 60, endSoc: 65),
          ],
          samples: const {},
        ),
      );

      final series = detail.socSeries;
      expect(series.map((p) => p.y), [50, 55, 55, 60, 60, 65]);
      expect(series.first.x, 0);
      expect(series.last.x, 180);
    });

    test(
      'skips a bucket the bus went quiet through, rather than a default',
      () {
        final detail = ChargeDetailReading(
          session: chargeSession(),
          series: TelemetrySeries(
            sessionId: 'charge-1',
            intervals: [
              bucket(minute: 0, startSoc: 50, endSoc: 55),
              // No reading landed in this bucket at all.
              bucket(minute: 1),
              bucket(minute: 2, startSoc: 60, endSoc: 65),
            ],
            samples: const {},
          ),
        );

        expect(detail.socSeries.map((p) => p.y), [50, 55, 60, 65]);
      },
    );

    test('the charge power curve is unchanged by the SOC source', () {
      final detail = ChargeDetailReading(
        session: chargeSession(),
        series: TelemetrySeries(
          sessionId: 'charge-1',
          intervals: [bucket(minute: 0, startSoc: 50, endSoc: 55)],
          samples: const {},
        ),
      );

      expect(detail.powerSeries.single.y, closeTo(60.0, 0.001));
    });
  });
}
