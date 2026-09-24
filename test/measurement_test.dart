import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  group('what a surface may print', () {
    test('a measurement prints its value with no badge', () {
      const reading = Measurement.measured(-2.1, unit: 'A');

      expect(reading.displayValue, -2.1);
      expect(reading.needsEstimateBadge, isFalse);
      expect(reading.isMeasured, isTrue);
    });

    test('an estimate prints its value and demands the badge', () {
      const reading = Measurement.estimated(
        -2.1,
        unit: 'A',
        note: 'assumed zero of 5000 counts',
      );

      expect(reading.displayValue, -2.1);
      expect(reading.needsEstimateBadge, isTrue);
      expect(reading.isMeasured, isFalse);
      expect(reading.note, isNotEmpty);
    });

    test('an invalid reading prints nothing', () {
      const reading = Measurement.invalid(unit: 'A');

      expect(reading.displayValue, isNull);
      expect(reading.hasValue, isFalse);
      expect(reading.needsEstimateBadge, isFalse);
    });

    test('an unreported reading prints nothing', () {
      const reading = Measurement.unreported(unit: 'A');

      expect(reading.displayValue, isNull);
      expect(reading.hasValue, isFalse);
    });
  });

  test('invalid and unreported print the same and mean different things', () {
    // The bus saying "do not trust this" is not the bus going quiet. Folding
    // them together loses the only evidence that separates a failed sensor from
    // a dropped connection.
    const invalid = Measurement.invalid(unit: 'A');
    const unreported = Measurement.unreported(unit: 'A');

    expect(invalid.displayValue, unreported.displayValue);
    expect(invalid, isNot(unreported));
    expect(invalid.validity, isNot(unreported.validity));
  });

  group('map keeps the doubt', () {
    test('a unit change on a measurement stays a measurement', () {
      const amps = Measurement.measured(-2100, unit: 'mA');
      final result = amps.map((value) => value / 1000, unit: 'A');

      expect(result.displayValue, -2.1);
      expect(result.unit, 'A');
      expect(result.validity, MeasurementValidity.measured);
    });

    test(
      'a unit change on an estimate stays an estimate and keeps the note',
      () {
        const amps = Measurement.estimated(
          -2100,
          unit: 'mA',
          note: 'assumed zero',
        );
        final result = amps.map((value) => value / 1000, unit: 'A');

        expect(result.needsEstimateBadge, isTrue);
        expect(result.note, 'assumed zero');
      },
    );

    test('mapping a reading with no value cannot invent one', () {
      const missing = Measurement.unreported(unit: 'A');
      final result = missing.map((value) => value * 2);

      expect(result.displayValue, isNull);
      expect(result.validity, MeasurementValidity.unreported);
    });
  });

  group('combine takes the weaker validity', () {
    Measurement power(Measurement volts, Measurement amps) =>
        Measurement.combine(
          volts,
          amps,
          unit: 'kW',
          compute: (v, a) => v * a / 1000,
        );

    test('two measurements make a measurement', () {
      final result = power(
        const Measurement.measured(400, unit: 'V'),
        const Measurement.measured(-2.1, unit: 'A'),
      );

      expect(result.displayValue, closeTo(-0.84, 1e-9));
      expect(result.validity, MeasurementValidity.measured);
      expect(result.unit, 'kW');
    });

    test('one estimate makes the result an estimate', () {
      final result = power(
        const Measurement.measured(400, unit: 'V'),
        const Measurement.estimated(-2.1, unit: 'A', note: 'assumed zero'),
      );

      expect(result.displayValue, closeTo(-0.84, 1e-9));
      expect(result.needsEstimateBadge, isTrue);
      expect(result.note, 'assumed zero');
    });

    test('one unusable operand makes the result unusable', () {
      final result = power(
        const Measurement.measured(400, unit: 'V'),
        const Measurement.invalid(unit: 'A'),
      );

      expect(result.displayValue, isNull);
      expect(result.validity, MeasurementValidity.invalid);
    });

    test('unreported outranks invalid, so the quieter source wins', () {
      final result = power(
        const Measurement.invalid(unit: 'V'),
        const Measurement.unreported(unit: 'A'),
      );

      expect(result.validity, MeasurementValidity.unreported);
    });

    test('a measured operand never lifts an estimate back to measured', () {
      final result = power(
        const Measurement.estimated(400, unit: 'V', note: 'assumed scale'),
        const Measurement.measured(-2.1, unit: 'A'),
      );

      expect(result.validity, MeasurementValidity.estimated);
    });
  });
}
