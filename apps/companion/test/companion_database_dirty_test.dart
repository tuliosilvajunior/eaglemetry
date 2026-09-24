import 'package:capy_companion/sync/companion_database.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/memory_archive.dart';

/// Every dirty read hands the uploader the row's own sqlite name, and hands it
/// under one key.
///
/// It is asked for with an `AS` for a reason. A bare `rowid` in a select list
/// is a plain column reference, and what sqlite names the result column of one
/// is not fixed between builds: a page read on iOS came back with no `rowid`
/// key at all, and the clear that follows ran against a null. These tests hold
/// the alias in place.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every dirty stream carries a row id that is a whole number', () async {
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
    await archive.upsertInterval({
      'sessionId': 'trip-1',
      'startUtcMillis': 1750000000000,
      'widthMillis': 60000,
      'tractionWh': 100.0,
      'updatedAtUtcMillis': 1750000060000,
    });
    await archive.upsertEvent({
      'id': 1,
      'sessionId': 'trip-1',
      'occurredAtUtcMillis': 1750000000000,
      'occurredAtElapsedNanos': 2,
      'type': 'TRIP_ARMED',
    });
    await archive.upsertTrack({
      'sessionId': 'trip-1',
      'encodingVersion': 1,
      'pointCount': 1,
      'path': 'abc',
      't': '[0]',
      'speed': '[0]',
      'alt': '[0]',
      'updatedAtUtcMillis': 1750000060000,
    });

    final db = archive.database;
    final pages = {
      'sessions': await db.dirtySessions(),
      'intervals': await db.dirtyIntervals(),
      'tracks': await db.dirtyTracks(),
      'events': await db.dirtyEvents(),
    };

    for (final entry in pages.entries) {
      expect(entry.value, isNotEmpty, reason: '${entry.key} has nothing dirty');
      for (final row in entry.value) {
        expect(
          row[CompanionDatabase.rowIdKey],
          isA<int>(),
          reason: '${entry.key} came back with no row id',
        );
      }
    }
  });

  test('a mark is cleared by the row id the page came with', () async {
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

    final page = await archive.database.dirtySessions();
    await archive.database.clearDirtySessions([
      for (final row in page) row[CompanionDatabase.rowIdKey] as int,
    ]);

    expect(await archive.database.dirtySessions(), isEmpty);
  });

  test(
    'countTotalRows and getSyncProgress reflect clean and dirty records',
    () async {
      final archive = await memoryArchive();
      final db = archive.database;

      var progress = await db.getSyncProgress();
      expect(progress.totalCount, 0);
      expect(progress.dirtyCount, 0);
      expect(progress.cleanCount, 0);
      expect(progress.isUpToDate, true);

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

      expect(await db.countTotalRows(), 1);
      expect(await db.countDirtyRows(), 1);
      progress = await db.getSyncProgress();
      expect(progress.totalCount, 1);
      expect(progress.dirtyCount, 1);
      expect(progress.cleanCount, 0);
      expect(progress.isUpToDate, false);

      final page = await db.dirtySessions();
      await db.clearDirtySessions([
        for (final row in page) row[CompanionDatabase.rowIdKey] as int,
      ]);

      expect(await db.countTotalRows(), 1);
      expect(await db.countDirtyRows(), 0);
      progress = await db.getSyncProgress();
      expect(progress.totalCount, 1);
      expect(progress.dirtyCount, 0);
      expect(progress.cleanCount, 1);
      expect(progress.isUpToDate, true);
    },
  );
}
