import 'package:capy_companion/sync/companion_archive.dart';
import 'package:capy_companion/sync/sqflite_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/memory_archive.dart';

/// Time authority T1: the interval's monotonic pair and time state survive
/// the companion's stored JSON, and rows written before the pair existed
/// read back as unknown with nulls.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<CompanionArchive> archiveWithTrip() async {
    final archive = await memoryArchive();
    await archive.upsertSession({
      'id': 'trip-1',
      'vehicleId': 'VIN1',
      'kind': 'TRIP',
      'status': 'CLOSED',
      'startedAtUtcMillis': 1750000000000,
      'startedAtElapsedNanos': 1,
      'noLongerReducible': 0,
      'createdAtUtcMillis': 1750000000000,
      'updatedAtUtcMillis': 1750000000000,
    });
    return archive;
  }

  test(
    'an interval keeps its monotonic pair and state through storage',
    () async {
      final archive = await archiveWithTrip();
      await archive.upsertInterval({
        'sessionId': 'trip-1',
        'startUtcMillis': 1750000000000,
        'widthMillis': 60000,
        'tractionWh': 100.0,
        'updatedAtUtcMillis': 1750000060000,
        'startElapsedNanos': 19960745017175,
        'startBootCount': 126,
        'timeState': 'trusted',
        'correctedFromUtcMillis': 1747801080000,
      });

      final series = await SqfliteStore(archive.database).series('trip-1');
      final minute = series.intervals.single;
      expect(minute.startElapsedNanos, 19960745017175);
      expect(minute.startBootCount, 126);
      expect(minute.timeState, 'trusted');
      expect(minute.correctedFromUtcMillis, 1747801080000);
    },
  );

  test('an interval from before the pair reads unknown with nulls', () async {
    final archive = await archiveWithTrip();
    await archive.upsertInterval({
      'sessionId': 'trip-1',
      'startUtcMillis': 1750000000000,
      'widthMillis': 60000,
      'tractionWh': 100.0,
      'updatedAtUtcMillis': 1750000060000,
    });

    final series = await SqfliteStore(archive.database).series('trip-1');
    final minute = series.intervals.single;
    expect(minute.startElapsedNanos, isNull);
    expect(minute.startBootCount, isNull);
    expect(minute.timeState, 'unknown');
    expect(minute.correctedFromUtcMillis, isNull);
  });
}
