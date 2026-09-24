import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/live_vehicle_speed.dart';

void main() {
  test('parses the normalized CarPropertyManager speed payload', () {
    final reading = LiveVehicleSpeedReading.fromMap({
      'speedKmh': 72.0,
      'quality': 'MEASURED',
      'source': 'VHAL_CALLBACK',
      'receivedAtUtcMillis': 10000,
      'receivedAtElapsedNanos': 5000000000,
      'sourceTimestampNanos': 4900000000,
    });

    expect(reading.speedKmh, 72);
    expect(reading.isUsableAt(11000), isTrue);
    expect(reading.motionTimestampNanos, 4900000000);
  });

  test('rejects stale, failed, non-VHAL and implausible readings', () {
    LiveVehicleSpeedReading reading({
      Object? speed = 72.0,
      String quality = 'MEASURED',
      String source = 'VHAL_POLLING',
      int received = 10000,
    }) => LiveVehicleSpeedReading.fromMap({
      'speedKmh': speed,
      'quality': quality,
      'source': source,
      'receivedAtUtcMillis': received,
      'receivedAtElapsedNanos': 5000000000,
    });

    expect(reading().isUsableAt(13001), isFalse);
    expect(reading(quality: 'ERROR').isUsableAt(11000), isFalse);
    expect(reading(source: 'CAN_BRIDGE').isUsableAt(11000), isFalse);
    expect(reading(speed: 260.0).isUsableAt(11000), isFalse);
  });
}
