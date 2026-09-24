import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/dto/live_telemetry_snapshot.dart';

void main() {
  group('LiveTelemetrySnapshot', () {
    test('round-trip binary serialization and deserialization', () {
      final original = LiveTelemetrySnapshot(
        utcMillis: 1724443200000,
        socPercent: 65.4,
        speedKmh: 72.5,
        powerKw: -14.2,
        voltageV: 368.5,
        currentA: -38.5,
        latitude: -23.55052,
        longitude: -46.633308,
        altitudeM: 760.5,
        headingDeg: 184.2,
        isCharging: false,
        isDcfc: false,
        isParked: false,
        ambientTempC: 22.5,
        odometerKm: 14250.8,
      );

      final bytes = original.toBinaryPayload();
      final restored = LiveTelemetrySnapshot.fromBinaryPayload(bytes);

      expect(restored.utcMillis, original.utcMillis);
      expect(restored.socPercent, closeTo(original.socPercent!, 0.01));
      expect(restored.speedKmh, closeTo(original.speedKmh!, 0.01));
      expect(restored.powerKw, closeTo(original.powerKw!, 0.01));
      expect(restored.voltageV, closeTo(original.voltageV!, 0.01));
      expect(restored.currentA, closeTo(original.currentA!, 0.01));
      expect(restored.latitude, closeTo(original.latitude!, 0.00001));
      expect(restored.longitude, closeTo(original.longitude!, 0.00001));
      expect(restored.altitudeM, closeTo(original.altitudeM!, 0.1));
      expect(restored.headingDeg, closeTo(original.headingDeg!, 0.01));
      expect(restored.isCharging, isFalse);
      expect(restored.isDcfc, isFalse);
      expect(restored.isParked, isFalse);
      expect(restored.ambientTempC, closeTo(original.ambientTempC!, 0.01));
      expect(restored.odometerKm, closeTo(original.odometerKm!, 0.1));
    });

    test('round-trip binary serialization with minimal/null fields', () {
      final original = LiveTelemetrySnapshot(
        utcMillis: 1724443200000,
        isCharging: true,
        isDcfc: true,
        isParked: true,
      );

      final bytes = original.toBinaryPayload();
      final restored = LiveTelemetrySnapshot.fromBinaryPayload(bytes);

      expect(restored.utcMillis, original.utcMillis);
      expect(restored.socPercent, isNull);
      expect(restored.speedKmh, isNull);
      expect(restored.powerKw, isNull);
      expect(restored.voltageV, isNull);
      expect(restored.currentA, isNull);
      expect(restored.latitude, isNull);
      expect(restored.longitude, isNull);
      expect(restored.altitudeM, isNull);
      expect(restored.headingDeg, isNull);
      expect(restored.isCharging, isTrue);
      expect(restored.isDcfc, isTrue);
      expect(restored.isParked, isTrue);
      expect(restored.ambientTempC, isNull);
      expect(restored.odometerKm, isNull);
    });
  });
}
