import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/charge_climate_warning.dart';
import 'package:telemetry_core/telemetry_core.dart';

/// One charge minute carrying climate and nothing else, which is all a charge
/// integrates.
EnergyBucket _minute({required double climateKw, double seconds = 60}) {
  return EnergyBucket(
    start: DateTime.utc(2026, 8, 11),
    width: const Duration(minutes: 1),
    tractionWh: 0,
    regeneratedWh: 0,
    auxiliaryWh: 0,
    integratedSeconds: 0,
    speedDistanceKm: 0,
    odometerDistanceKm: 0,
    speedIntegratedSeconds: 0,
    climateWh: climateKw * seconds / 3.6,
    climateIntegratedSeconds: seconds,
  );
}

void main() {
  group('readChargeClimateKw', () {
    test('weights by covered seconds, not by bucket', () {
      // The minute in progress is short by construction. Averaging the two
      // rates would give it the same weight as the whole minute and report
      // 3.0 kW for a car that drew 4 kW for 60 s and 2 kW for 20 s.
      final kw = readChargeClimateKw([
        _minute(climateKw: 4),
        _minute(climateKw: 2, seconds: 20),
      ]);
      expect(kw, closeTo((4 * 60 + 2 * 20) / 80, 0.0001));
    });

    test('an uncovered series is unknown, not zero', () {
      expect(readChargeClimateKw([_minute(climateKw: 3, seconds: 0)]), isNull);
      expect(readChargeClimateKw(const []), isNull);
    });
  });

  group('readChargeClimateWarning', () {
    ChargeClimateWarning read({
      required double climateKw,
      required double? chargingPowerKw,
      ChargeClimateWarning previous = ChargeClimateWarning.none,
    }) {
      return readChargeClimateWarning(
        buckets: [_minute(climateKw: climateKw)],
        chargingPowerKw: chargingPowerKw,
        previous: previous,
      );
    }

    test('stays silent below the warning share', () {
      expect(read(climateKw: 2, chargingPowerKw: 7), ChargeClimateWarning.none);
    });

    test('warns above half the charging rate', () {
      expect(read(climateKw: 4, chargingPowerKw: 7), ChargeClimateWarning.high);
    });

    test('a draw at or above the rate is the severe case', () {
      // Not exact equality: the rate makes a kW -> Wh -> kW round trip, so a
      // draw set to the charging rate lands a few parts in 10^15 either side
      // of it. The boundary is unobservable, and a test that pinned it would
      // be pinning the rounding rather than the rule.
      expect(
        read(climateKw: 7.1, chargingPowerKw: 7),
        ChargeClimateWarning.outweighs,
      );
      expect(
        read(climateKw: 9, chargingPowerKw: 7),
        ChargeClimateWarning.outweighs,
      );
    });

    test('a charger delivering nothing is severe, not a division by zero', () {
      expect(
        read(climateKw: 1, chargingPowerKw: 0),
        ChargeClimateWarning.outweighs,
      );
    });

    test('holds through the hysteresis gap in both directions', () {
      // 0.45 of the rate: above the clear threshold, below the warn one. It
      // neither raises the banner nor lowers one already up.
      expect(
        read(climateKw: 3.15, chargingPowerKw: 7),
        ChargeClimateWarning.none,
      );
      expect(
        read(
          climateKw: 3.15,
          chargingPowerKw: 7,
          previous: ChargeClimateWarning.high,
        ),
        ChargeClimateWarning.high,
      );
      // Below the clear threshold it goes away even when it was up.
      expect(
        read(
          climateKw: 2.1,
          chargingPowerKw: 7,
          previous: ChargeClimateWarning.high,
        ),
        ChargeClimateWarning.none,
      );
    });

    test('an unread charging rate says nothing', () {
      expect(
        read(climateKw: 4, chargingPowerKw: null),
        ChargeClimateWarning.none,
      );
    });

    test('an unread climate draw says nothing', () {
      // The car publishing no climate power is the normal case until the
      // Roadcast daemon carries a verified scale for `VCU_ThermalPwrAct`.
      expect(
        readChargeClimateWarning(
          buckets: const [],
          chargingPowerKw: 7,
          previous: ChargeClimateWarning.none,
        ),
        ChargeClimateWarning.none,
      );
    });
  });
}
