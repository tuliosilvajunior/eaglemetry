import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';
import 'package:capy_companion/abrp/abrp_payload.dart';

void main() {
  group('AbrpPayload', () {
    test('fromSnapshot matches ABRP Telemetry API field format', () {
      final snapshot = LiveTelemetrySnapshot(
        utcMillis: 1724443200000,
        socPercent: 80.0,
        speedKmh: 60.0,
        powerKw: 15.0,
        voltageV: 370.0,
        currentA: 40.5,
        latitude: -23.55,
        longitude: -46.63,
        altitudeM: 750.0,
        headingDeg: 90.0,
        isCharging: true,
        isDcfc: false,
        isParked: true,
        ambientTempC: 25.0,
        odometerKm: 10000.0,
      );

      final map = AbrpPayload.fromSnapshot(snapshot);

      expect(map['utc'], 1724443200.0);
      expect(map['soc'], 80.0);
      expect(map['speed'], 60.0);
      expect(map['power'], 15.0);
      expect(map['voltage'], 370.0);
      expect(map['current'], 40.5);
      expect(map['lat'], -23.55);
      expect(map['lon'], -46.63);
      expect(map['elevation'], 750.0);
      expect(map['heading'], 90.0);
      expect(map['is_charging'], 1);
      expect(map['is_dcfc'], 0);
      expect(map['is_parked'], 1);
      expect(map['ext_temp'], 25.0);
      expect(map['odometer'], 10000.0);
    });

    test('fromSnapshot clamps a car clock that runs ahead of the phone', () {
      // Iternio answers 400 and drops the sample when utc is in the future.
      // The head unit clock jumps after a reboot.
      final snapshot = LiveTelemetrySnapshot(
        utcMillis: 1724443200000 + 3600000,
        socPercent: 50.0,
        isCharging: false,
        isDcfc: false,
        isParked: false,
      );

      final map = AbrpPayload.fromSnapshot(snapshot, nowMillis: 1724443200000);

      expect(map['utc'], 1724443200.0);
      expect(map['soc'], 50.0);
    });

    test('fromSnapshot keeps a car clock that lags the phone', () {
      final snapshot = LiveTelemetrySnapshot(
        utcMillis: 1724443200000,
        isCharging: false,
        isDcfc: false,
        isParked: false,
      );

      final map = AbrpPayload.fromSnapshot(snapshot, nowMillis: 1724443260000);

      expect(map['utc'], 1724443200.0);
    });

    test('fromSnapshot omits null fields and encodes flags as 0/1', () {
      final snapshot = LiveTelemetrySnapshot(
        utcMillis: 1724443200000,
        isCharging: false,
        isDcfc: true,
        isParked: false,
      );

      final map = AbrpPayload.fromSnapshot(snapshot);

      expect(map['utc'], 1724443200.0);
      expect(map['is_charging'], 0);
      expect(map['is_dcfc'], 1);
      expect(map['is_parked'], 0);
      expect(map.containsKey('soc'), isFalse);
      expect(map.containsKey('speed'), isFalse);
      expect(map.containsKey('power'), isFalse);
      expect(map.containsKey('voltage'), isFalse);
      expect(map.containsKey('current'), isFalse);
      expect(map.containsKey('lat'), isFalse);
      expect(map.containsKey('lon'), isFalse);
      expect(map.containsKey('elevation'), isFalse);
      expect(map.containsKey('heading'), isFalse);
      expect(map.containsKey('ext_temp'), isFalse);
      expect(map.containsKey('odometer'), isFalse);
    });
  });
}
