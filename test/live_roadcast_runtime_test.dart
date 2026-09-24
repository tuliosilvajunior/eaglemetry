import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/live_roadcast_runtime.dart';

void main() {
  group('RollingSignalBuffer', () {
    test('keeps only the configured time window', () {
      final buffer = RollingSignalBuffer(
        window: const Duration(seconds: 30),
        sampleRateHz: 60,
      );

      for (var index = 0; index <= 2400; index++) {
        buffer.add(index * 1000 ~/ 60, index.toDouble());
      }

      final spots = buffer.spots(maxPoints: 5000);
      expect(buffer.length, lessThanOrEqualTo(buffer.capacity));
      expect(spots.last.x, lessThanOrEqualTo(30.001));
      expect(buffer.latest, 2400);
    });

    test('decimates chart and sparkline output without losing endpoints', () {
      final buffer = RollingSignalBuffer();
      for (var index = 0; index < 300; index++) {
        buffer.add(index * 100, index.toDouble());
      }

      final spots = buffer.spots(maxPoints: 240);
      final values = buffer.values(maxPoints: 120);

      expect(spots, hasLength(240));
      expect(values, hasLength(120));
      expect(spots.first.y, 0);
      expect(spots.last.y, 299);
      expect(values.first, 0);
      expect(values.last, 299);
    });

    test('ignores missing and non-finite values', () {
      final buffer = RollingSignalBuffer();

      buffer
        ..add(1, null)
        ..add(2, double.nan)
        ..add(3, double.infinity)
        ..add(4, 12.5);

      expect(buffer.length, 1);
      expect(buffer.latest, 12.5);
    });
  });
}
