import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  group('StorageUsage', () {
    test('fromMap sums database + wal + shm when bytes absent', () {
      final usage = StorageUsage.fromMap({
        'databaseBytes': 1000,
        'walBytes': 200,
        'shmBytes': 32,
      });
      expect(usage.bytes, 1232);
      expect(usage.databaseBytes, 1000);
      expect(usage.walBytes, 200);
      expect(usage.shmBytes, 32);
    });

    test('fromMap prefers explicit bytes', () {
      final usage = StorageUsage.fromMap({
        'bytes': 5000,
        'databaseBytes': 1000,
        'walBytes': 200,
        'shmBytes': 32,
      });
      expect(usage.bytes, 5000);
    });

    test('toMap round-trips', () {
      const usage = StorageUsage(
        bytes: 1234,
        databaseBytes: 1000,
        walBytes: 200,
        shmBytes: 34,
      );
      final map = usage.toMap();
      expect(StorageUsage.fromMap(map), usage);
    });
  });

  group('formatStorageBytes', () {
    test('formats B, KB, MB, GB', () {
      expect(formatStorageBytes(0), '0 B');
      expect(formatStorageBytes(512), '512 B');
      expect(formatStorageBytes(1023), '1023 B');
      expect(formatStorageBytes(1024), '1.0 KB');
      expect(formatStorageBytes(1536), '1.5 KB');
      expect(formatStorageBytes(10 * 1024), '10 KB');
      expect(formatStorageBytes(1024 * 1024), '1.00 MB');
      expect(formatStorageBytes((5.2 * 1024 * 1024).toInt()), contains('MB'));
      expect(formatStorageBytes(1024 * 1024 * 1024), '1.00 GB');
    });

    test('negative shows placeholder', () {
      expect(formatStorageBytes(-1), '--');
    });

    test(
      'does not scan rows: model is pure and has no database dependency',
      () {
        // The model carries only file lengths; no query is needed to build it.
        // This test documents the seam: storage is file metadata, not COUNT(*).
        const usage = StorageUsage(
          bytes: 42,
          databaseBytes: 42,
          walBytes: 0,
          shmBytes: 0,
        );
        expect(formatStorageBytes(usage.bytes), '42 B');
      },
    );
  });
}
