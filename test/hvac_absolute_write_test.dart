import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/mock_telemetry_data.dart';
import 'package:capy_energy/core/telemetry_api.dart';

/// The absolute HVAC writes report what the controller applied, not what the
/// caller asked for. A request outside the range the car accepts must come back
/// as the clamped value, so a UI that echoes `appliedValue` cannot show a
/// setting the vehicle never took.
void main() {
  final mock = MockTelemetryData();

  group('setHvacTemperature', () {
    test('reports the request rounded to the half degree', () {
      final result = HvacCommandResult.fromMap(mock.hvacSetTemperature(21.3));

      expect(result.ok, isTrue);
      expect(result.action, 'setTemperature');
      expect(result.requestedValue, 21.3);
      expect(result.appliedValue, 21.5);
    });

    test('clamps below the minimum the controller accepts', () {
      final result = HvacCommandResult.fromMap(mock.hvacSetTemperature(4));

      expect(result.requestedValue, 4);
      expect(result.appliedValue, MockTelemetryData.hvacMinTemperatureC);
    });

    test('clamps above the maximum the controller accepts', () {
      final result = HvacCommandResult.fromMap(mock.hvacSetTemperature(99));

      expect(result.requestedValue, 99);
      expect(result.appliedValue, MockTelemetryData.hvacMaxTemperatureC);
    });
  });

  group('setHvacFanSpeed', () {
    test('passes a speed inside the range through unchanged', () {
      final result = HvacCommandResult.fromMap(mock.hvacSetFanSpeed(4));

      expect(result.ok, isTrue);
      expect(result.action, 'setFanSpeed');
      expect(result.appliedValue, 4);
    });

    test('clamps to the range the controller accepts', () {
      expect(
        HvacCommandResult.fromMap(mock.hvacSetFanSpeed(0)).appliedValue,
        MockTelemetryData.hvacMinFanSpeed,
      );
      expect(
        HvacCommandResult.fromMap(mock.hvacSetFanSpeed(42)).appliedValue,
        MockTelemetryData.hvacMaxFanSpeed,
      );
    });
  });

  test('the mock bounds match the ones the native controller enforces', () {
    // Mirrors HvacClimateController.MIN_TEMP_C/MAX_TEMP_C and
    // MIN_FAN_SPEED/MAX_FAN_SPEED. The mock must not offer a span the car
    // never accepts.
    expect(MockTelemetryData.hvacMinTemperatureC, 15.5);
    expect(MockTelemetryData.hvacMaxTemperatureC, 33.0);
    expect(MockTelemetryData.hvacMinFanSpeed, 1);
    expect(MockTelemetryData.hvacMaxFanSpeed, 9);
  });
}
