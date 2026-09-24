import 'package:flutter_test/flutter_test.dart';

import 'support/memory_archive.dart';

Map<String, Object?> _interval(String state) => {
  'sessionId': 'trip-1',
  'startUtcMillis': 60000,
  'widthMillis': 60000,
  'traction': 40.0,
  'timeState': state,
};

void main() {
  group('time authority T6: the pull never moves a known row back', () {
    test('an uncorrectable pull over a known row is ignored', () async {
      final archive = await memoryArchive();
      await archive.upsertIntervalFromCloud(_interval('known'));

      await archive.upsertIntervalFromCloud(_interval('uncorrectable'));

      final stored = await archive.database.intervalsFor('trip-1');
      expect(stored, hasLength(1));
      expect(stored.single['timeState'], 'known');
      expect(stored.single['traction'], 40.0);
    });

    test('a known pull over an uncorrectable row replaces it', () async {
      final archive = await memoryArchive();
      await archive.upsertIntervalFromCloud(_interval('uncorrectable'));

      await archive.upsertIntervalFromCloud({
        ..._interval('known'),
        'traction': 41.0,
      });

      final stored = await archive.database.intervalsFor('trip-1');
      expect(stored, hasLength(1));
      expect(stored.single['timeState'], 'known');
      expect(stored.single['traction'], 41.0);
    });

    test('an uncorrectable pull with no local row is stored', () async {
      // Silence would lose data: a band the phone never held is still
      // history worth keeping, marked as what it is.
      final archive = await memoryArchive();

      await archive.upsertIntervalFromCloud(_interval('uncorrectable'));

      final stored = await archive.database.intervalsFor('trip-1');
      expect(stored, hasLength(1));
      expect(stored.single['timeState'], 'uncorrectable');
    });

    test(
      'an uncorrectable pull over a snake_case time_state known row is ignored',
      () async {
        final archive = await memoryArchive();
        await archive.upsertIntervalFromCloud({
          'sessionId': 'trip-1',
          'startUtcMillis': 60000,
          'widthMillis': 60000,
          'traction': 40.0,
          'time_state': 'known',
        });

        await archive.upsertIntervalFromCloud(_interval('uncorrectable'));

        final stored = await archive.database.intervalsFor('trip-1');
        expect(stored, hasLength(1));
        final row = stored.single;
        final state = row['timeState'] ?? row['time_state'];
        expect(state, 'known');
        expect(row['traction'], 40.0);
      },
    );

    test(
      'nothing deletes an uncorrectable row across repeated pulls or persists',
      () async {
        // Captain's rule: never lose data in silence. Once stored, an
        // uncorrectable row is preserved; no pull or refresh pass ever drops it.
        final archive = await memoryArchive();
        await archive.upsertIntervalFromCloud(_interval('uncorrectable'));

        // Multiple sync cycles with other sessions
        await archive.upsertIntervalFromCloud({
          'sessionId': 'trip-2',
          'startUtcMillis': 120000,
          'widthMillis': 60000,
          'traction': 50.0,
          'timeState': 'known',
        });
        await archive.persist();

        final stored1 = await archive.database.intervalsFor('trip-1');
        expect(stored1, hasLength(1));
        expect(stored1.single['timeState'], 'uncorrectable');

        final stored2 = await archive.database.intervalsFor('trip-2');
        expect(stored2, hasLength(1));
        expect(stored2.single['timeState'], 'known');
      },
    );
  });

  group(
    'time authority T9: a corrected re-upload replaces the wrong minute',
    () {
      test(
        'the old wrong key is removed when the corrected row lands',
        () async {
          final archive = await memoryArchive();
          // The phone already pulled the wrong minute (the car wrote it before
          // the boot's anchor arrived).
          await archive.upsertIntervalFromCloud({
            'sessionId': 'trip-1',
            'startUtcMillis': 60000,
            'widthMillis': 60000,
            'traction': 40.0,
          });

          // The car rewrote that minute and deleted the old key from the cloud.
          await archive.upsertIntervalFromCloud({
            'sessionId': 'trip-1',
            'startUtcMillis': 120000,
            'widthMillis': 60000,
            'traction': 41.0,
            'correctedFromUtcMillis': 60000,
          });

          final stored = await archive.database.intervalsFor('trip-1');
          expect(
            stored,
            hasLength(1),
            reason: 'no duplicate minute, no orphan',
          );
          expect(stored.single['startUtcMillis'], 120000);
          expect(stored.single['traction'], 41.0);
        },
      );

      test(
        'a pull with the marker in snake_case merges the same way',
        () async {
          final archive = await memoryArchive();
          await archive.upsertIntervalFromCloud({
            'sessionId': 'trip-1',
            'startUtcMillis': 60000,
            'widthMillis': 60000,
            'traction': 10.0,
          });

          await archive.upsertIntervalFromCloud({
            'sessionId': 'trip-1',
            'startUtcMillis': 180000,
            'widthMillis': 60000,
            'traction': 11.0,
            'corrected_from_utc_millis': 60000,
          });

          final stored = await archive.database.intervalsFor('trip-1');
          expect(stored, hasLength(1));
          expect(stored.single['startUtcMillis'], 180000);
        },
      );

      test('an uncorrectable pull cannot resurrect the wrong key', () async {
        final archive = await memoryArchive();
        // The corrected row landed first, deleting the wrong key locally.
        await archive.upsertIntervalFromCloud({
          'sessionId': 'trip-1',
          'startUtcMillis': 120000,
          'widthMillis': 60000,
          'traction': 41.0,
          'correctedFromUtcMillis': 60000,
        });

        // A late band from an unplaceable boot names the OLD key: it must not
        // re-create the row the correction already removed.
        await archive.upsertIntervalFromCloud({
          'sessionId': 'trip-1',
          'startUtcMillis': 60000,
          'widthMillis': 60000,
          'traction': 40.0,
          'timeState': 'uncorrectable',
        });

        final stored = await archive.database.intervalsFor('trip-1');
        expect(stored, hasLength(1));
        expect(stored.single['startUtcMillis'], 120000);
        expect(stored.single['traction'], 41.0);
      });
    },
  );
}
