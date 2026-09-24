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
    double? startVoltage,
    double? endVoltage,
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
    startVoltage: startVoltage == null
        ? const Measurement.unreported(unit: 'V')
        : Measurement.measured(startVoltage, unit: 'V'),
    endVoltage: endVoltage == null
        ? const Measurement.unreported(unit: 'V')
        : Measurement.measured(endVoltage, unit: 'V'),
  );

  group('the charge pack voltage curve', () {
    test('reads the start and end of every bucket that carried a reading', () {
      final detail = ChargeDetailReading(
        session: chargeSession(),
        series: TelemetrySeries(
          sessionId: 'charge-1',
          intervals: [
            bucket(minute: 0, startVoltage: 380, endVoltage: 385),
            bucket(minute: 1, startVoltage: 385, endVoltage: 390),
            bucket(minute: 2, startVoltage: 390, endVoltage: 395),
          ],
          samples: const {},
        ),
      );

      final series = detail.voltageSeries;
      expect(series.map((p) => p.y), [380, 385, 385, 390, 390, 395]);
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
              bucket(minute: 0, startVoltage: 380, endVoltage: 385),
              bucket(minute: 1),
              bucket(minute: 2, startVoltage: 390, endVoltage: 395),
            ],
            samples: const {},
          ),
        );

        expect(detail.voltageSeries.map((p) => p.y), [380, 385, 390, 395]);
      },
    );
  });
}
