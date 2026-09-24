import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  group('SyncProgressData', () {
    test(
      'computes cleanCount, ratio, percentage and isUpToDate when empty',
      () {
        const data = SyncProgressData(totalCount: 0, dirtyCount: 0);
        expect(data.cleanCount, 0);
        expect(data.ratio, 1.0);
        expect(data.percentage, 100);
        expect(data.isUpToDate, isTrue);
      },
    );

    test(
      'computes cleanCount, ratio, percentage and isUpToDate when partially synced',
      () {
        const data = SyncProgressData(totalCount: 100, dirtyCount: 25);
        expect(data.cleanCount, 75);
        expect(data.ratio, 0.75);
        expect(data.percentage, 75);
        expect(data.isUpToDate, isFalse);
      },
    );

    test('computes when 100% synced with data', () {
      const data = SyncProgressData(totalCount: 50, dirtyCount: 0);
      expect(data.cleanCount, 50);
      expect(data.ratio, 1.0);
      expect(data.percentage, 100);
      expect(data.isUpToDate, isTrue);
    });

    test('clamps cleanCount if dirtyCount exceeds totalCount gracefully', () {
      const data = SyncProgressData(totalCount: 10, dirtyCount: 15);
      expect(data.cleanCount, 0);
      expect(data.ratio, 0.0);
      expect(data.percentage, 0);
      expect(data.isUpToDate, isFalse);
    });

    test('serializes toMap and deserializes fromMap', () {
      const data = SyncProgressData(
        totalCount: 200,
        dirtyCount: 10,
        pendingCount: 5,
      );
      final map = data.toMap();
      final restored = SyncProgressData.fromMap(map);

      expect(restored.totalCount, 200);
      expect(restored.dirtyCount, 10);
      expect(restored.pendingCount, 5);
      expect(restored, equals(data));
      expect(restored.hashCode, equals(data.hashCode));
    });

    test(
      'deducts pendingCount from cleanCount and treats pending rows as not up to date',
      () {
        const data = SyncProgressData(
          totalCount: 100,
          dirtyCount: 0,
          pendingCount: 10,
        );
        expect(data.cleanCount, 90);
        expect(data.ratio, 0.90);
        expect(data.percentage, 90);
        expect(data.isUpToDate, isFalse);
      },
    );

    test('handles null or malformed map in fromMap', () {
      expect(SyncProgressData.fromMap(null), equals(SyncProgressData.zero));
      expect(
        SyncProgressData.fromMap({
          'totalCount': -5,
          'dirtyCount': -2,
          'pendingCount': -3,
        }),
        equals(SyncProgressData.zero),
      );
    });
  });
}
