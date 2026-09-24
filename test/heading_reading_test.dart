import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/telemetry_api.dart';
import 'package:telemetry_core/telemetry_core.dart';

/// The map path and the typed path meet in one set of gates. These tests pin
/// the gates, and pin that the two paths agree.
void main() {
  group('HeadingReading', () {
    test('reads a course the receiver reported', () {
      final reading = HeadingReading.fromMap(const {
        'timestampMillis': 1000,
        'availability': 'OK',
        'bearingDeg': 275.5,
        'bearingAccuracyDeg': 6.0,
        'speedMps': 14.2,
        'fixAgeMillis': 300,
      });
      expect(reading.availability, HeadingAvailability.ok);
      expect(reading.bearingDeg, 275.5);
      expect(reading.hasBearing, isTrue);
    });

    test('a stopped car keeps its speed and states why it has no course', () {
      final reading = HeadingReading.fromMap(const {
        'timestampMillis': 1000,
        'availability': 'NO_BEARING',
        'bearingDeg': null,
        'speedMps': 0.0,
        'fixAgeMillis': 900,
      });
      expect(reading.availability, HeadingAvailability.noBearing);
      expect(reading.hasBearing, isFalse);
      expect(reading.speedMps, 0.0);
    });

    test('refusals stay apart from one another', () {
      for (final entry in const {
        'GPS_DISABLED': HeadingAvailability.gpsDisabled,
        'PERMISSION_MISSING': HeadingAvailability.permissionMissing,
        'NO_FIX': HeadingAvailability.noFix,
        'FIX_STALE': HeadingAvailability.fixStale,
      }.entries) {
        final reading = HeadingReading.fromMap({
          'timestampMillis': 1,
          'availability': entry.key,
        });
        expect(reading.availability, entry.value);
        expect(reading.bearingDeg, isNull);
      }
    });

    test('a state this build does not know is never guessed', () {
      final reading = HeadingReading.fromMap(const {
        'timestampMillis': 1,
        'availability': 'MAGNETOMETER',
        'bearingDeg': 12.0,
      });
      expect(reading.availability, HeadingAvailability.unknown);
      // The state was not `ok`, so the number is refused rather than shown
      // under a reason the app cannot explain.
      expect(reading.bearingDeg, isNull);
    });

    test('an ok state with no usable course is demoted, not shown', () {
      for (final bearing in const [null, -1.0, 360.0, 400.0]) {
        final reading = HeadingReading.fromMap({
          'timestampMillis': 1,
          'availability': 'OK',
          'bearingDeg': bearing,
        });
        expect(reading.availability, HeadingAvailability.noBearing);
        expect(reading.bearingDeg, isNull);
      }
    });

    test('a negative accuracy, speed or fix age is refused', () {
      final reading = HeadingReading.fromMap(const {
        'timestampMillis': 1,
        'availability': 'OK',
        'bearingDeg': 10.0,
        'bearingAccuracyDeg': -2.0,
        'speedMps': -1.0,
        'fixAgeMillis': -5,
      });
      expect(reading.bearingDeg, 10.0);
      expect(reading.bearingAccuracyDeg, isNull);
      expect(reading.speedMps, isNull);
      expect(reading.fixAgeMillis, isNull);
    });

    test('the wire path and the map path agree', () {
      final fromWire = HeadingReading.fromWire(
        HeadingWire(
          timestampMillis: 1000,
          availability: 'OK',
          bearingDeg: 400.0,
          bearingAccuracyDeg: 4.0,
          speedMps: 9.0,
          fixAgeMillis: 200,
        ),
      );
      final fromMap = HeadingReading.fromMap(const {
        'timestampMillis': 1000,
        'availability': 'OK',
        'bearingDeg': 400.0,
        'bearingAccuracyDeg': 4.0,
        'speedMps': 9.0,
        'fixAgeMillis': 200,
      });
      expect(fromWire.availability, fromMap.availability);
      expect(fromWire.bearingDeg, fromMap.bearingDeg);
      expect(fromWire.speedMps, fromMap.speedMps);
    });
  });
}
