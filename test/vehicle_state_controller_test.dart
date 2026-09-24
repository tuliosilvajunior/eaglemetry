import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/telemetry_api.dart';
import 'package:capy_energy/core/vehicle_state_controller.dart';

void main() {
  test('shared vehicle state distinguishes active and unknown charging', () {
    final controller = VehicleStateController();

    controller.applySnapshotForTest(_snapshot(ok: true, isCharging: true));
    expect(controller.chargingActivity, VehicleChargingActivity.charging);
    expect(controller.isActivelyCharging, isTrue);

    controller.applySnapshotForTest(_snapshot(ok: false, isCharging: null));
    expect(controller.chargingActivity, VehicleChargingActivity.unknown);
    expect(controller.isActivelyCharging, isFalse);
  });
}

TelemetrySnapshot _snapshot({required bool ok, required bool? isCharging}) {
  Map<String, Object?> reading(double? value) => {
    'ok': value != null,
    'value': value,
    'source': 'test',
    'details': '',
  };
  return TelemetrySnapshot.fromMap({
    'timestampMillis': 1,
    'batteryPercent': reading(50),
    'speedKmh': reading(null),
    'odometerKm': reading(null),
    'charging': {
      'ok': ok,
      'isCharging': isCharging,
      'source': 'test',
      'details': '',
    },
    'gear': reading(null),
  });
}
