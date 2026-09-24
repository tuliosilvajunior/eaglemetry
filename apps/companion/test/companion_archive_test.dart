import 'package:capy_companion/sync/companion_archive.dart';
import 'package:capy_companion/sync/companion_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:telemetry_core/telemetry_core.dart';

import 'support/memory_archive.dart';

void main() {
  test('upsert overwrites a session and bumps revision', () async {
    final archive = await memoryArchive();
    final rev0 = archive.revision;
    await archive.upsertTrip({
      'id': 'trip-1',
      'status': 'OPEN',
      'startedAtUtcMillis': 1,
    });
    expect(archive.revision, greaterThan(rev0));

    final rev1 = archive.revision;
    await archive.upsertTrip({
      'id': 'trip-1',
      'status': 'CLOSED',
      'startedAtUtcMillis': 1,
    });
    expect(archive.revision, greaterThan(rev1));
    expect(await archive.database.trips(), hasLength(1));
    expect((await archive.database.trip('trip-1'))?['status'], 'CLOSED');
  });

  test('the store survives a reload', () async {
    final archive = await memoryArchive();
    await archive.upsertCharge({
      'id': 'chg-1',
      'status': 'CLOSED',
      'plugConnectedAtUtcMillis': 1,
    });
    await archive.confirm(SyncStreamType.sessions, 'chg-1');
    await archive.persist();

    // The same database, read by a second archive: what a restart sees.
    await archive.load();
    expect((await archive.database.charge('chg-1'))?['id'], 'chg-1');
    expect(archive.confirmedId(SyncStreamType.sessions), 'chg-1');
  });

  test('a wipe deletes the cursors with the rows', () async {
    final archive = await memoryArchive();
    await archive.upsertTrip({
      'id': 'trip-1',
      'status': 'CLOSED',
      'startedAtUtcMillis': 1,
      'endedAtUtcMillis': 2,
    });
    await archive.upsertCharge({
      'id': 'charge-1',
      'status': 'CLOSED',
      'plugConnectedAtUtcMillis': 1,
      'chargeEndedAtUtcMillis': 2,
    });
    await archive.confirm(SyncStreamType.sessions, 'trip-1');
    final before = archive.revision;

    await archive.wipe();

    expect(await archive.database.countTrips(), 0);
    expect(await archive.database.countCharges(), 0);

    // The cursor goes with the rows.
    expect(archive.confirmedId(SyncStreamType.sessions), isNull);

    // The revision moves, so a list watching it redraws.
    expect(archive.revision, greaterThan(before));
  });

  test('a wipe survives a reload, cursors included', () async {
    final archive = await memoryArchive();
    await archive.upsertTrip({
      'id': 'trip-1',
      'status': 'CLOSED',
      'startedAtUtcMillis': 1,
      'endedAtUtcMillis': 2,
    });
    await archive.confirm(SyncStreamType.sessions, 'trip-1');
    await archive.wipe();

    await archive.load();
    expect(archive.confirmedId(SyncStreamType.sessions), isNull);
    expect(await archive.database.countTrips(), 0);
  });

  group('Annotation Last-Writer-Wins channel merge', () {
    test(
      'upsertPlace resolves conflicts with LWW and origin tie-break',
      () async {
        final archive = await memoryArchive();
        await archive.upsertPlace({
          'id': 'p1',
          'name': 'Home',
          'latitude': 10.0,
          'longitude': 20.0,
          'updatedAtUtcMillis': 100,
          'origin': kAnnotationOriginPhone,
          'hlcMillis': 100,
          'hlcCounter': 0,
          'hlcDeviceId': kAnnotationOriginPhone,
        });

        // Older update is rejected
        await archive.upsertPlace({
          'id': 'p1',
          'name': 'Old Home',
          'latitude': 10.0,
          'longitude': 20.0,
          'updatedAtUtcMillis': 50,
          'origin': kAnnotationOriginCar,
          'hlcMillis': 50,
          'hlcCounter': 0,
          'hlcDeviceId': kAnnotationOriginCar,
        });
        expect((await archive.database.allPlaces()).single['name'], 'Home');

        // Newer update is accepted
        await archive.upsertPlace({
          'id': 'p1',
          'name': 'New Home',
          'latitude': 10.0,
          'longitude': 20.0,
          'updatedAtUtcMillis': 200,
          'origin': kAnnotationOriginPhone,
          'hlcMillis': 200,
          'hlcCounter': 0,
          'hlcDeviceId': kAnnotationOriginPhone,
        });
        expect((await archive.database.allPlaces()).single['name'], 'New Home');
      },
    );

    test('upsertPreference resolves conflicts with LWW', () async {
      final archive = await memoryArchive();
      await archive.upsertPreference({
        'scope': 'account',
        'key': 'theme_id',
        'value': 'dark',
        'updatedAtUtcMillis': 100,
        'origin': kAnnotationOriginPhone,
        'hlcMillis': 100,
        'hlcCounter': 0,
        'hlcDeviceId': kAnnotationOriginPhone,
      });

      // Newer preference replaces older
      await archive.upsertPreference({
        'scope': 'account',
        'key': 'theme_id',
        'value': 'midnight',
        'updatedAtUtcMillis': 150,
        'origin': kAnnotationOriginCar,
        'hlcMillis': 150,
        'hlcCounter': 0,
        'hlcDeviceId': kAnnotationOriginCar,
      });
      expect(
        (await archive.database.allPreferences()).single['value'],
        'midnight',
      );
    });

    test('upsertSessionCost resolves conflicts with LWW', () async {
      final archive = await memoryArchive();
      await archive.upsertSessionCost({
        'sessionId': 's1',
        'costPerKwh': 0.5,
        'paidAmount': 10.0,
        'costCurrency': 'USD',
        'updatedAtUtcMillis': 100,
        'origin': kAnnotationOriginPhone,
        'hlcMillis': 100,
        'hlcCounter': 0,
        'hlcDeviceId': kAnnotationOriginPhone,
      });

      await archive.upsertSessionCost({
        'sessionId': 's1',
        'costPerKwh': 0.6,
        'paidAmount': 12.0,
        'costCurrency': 'USD',
        'updatedAtUtcMillis': 200,
        'origin': kAnnotationOriginCar,
        'hlcMillis': 200,
        'hlcCounter': 0,
        'hlcDeviceId': kAnnotationOriginCar,
      });
      final cost = await archive.database.sessionCost('s1');
      expect(cost?['costPerKwh'], 0.6);
    });

    test('upsertJourney resolves conflicts with LWW', () async {
      final archive = await memoryArchive();
      await archive.upsertJourney({
        'id': 'j1',
        'name': 'Trip A',
        'startedAtUtcMillis': 10,
        'endedAtUtcMillis': 20,
        'updatedAtUtcMillis': 100,
        'origin': kAnnotationOriginPhone,
        'hlcMillis': 100,
        'hlcCounter': 0,
        'hlcDeviceId': kAnnotationOriginPhone,
      });

      // Older update rejected
      final acceptedOld = await archive.upsertJourney({
        'id': 'j1',
        'name': 'Older Trip A',
        'startedAtUtcMillis': 10,
        'endedAtUtcMillis': 20,
        'updatedAtUtcMillis': 50,
        'origin': kAnnotationOriginCar,
        'hlcMillis': 50,
        'hlcCounter': 0,
        'hlcDeviceId': kAnnotationOriginCar,
      });
      expect(acceptedOld, isFalse);
      expect((await archive.database.allJourneys()).single['name'], 'Trip A');

      // Newer update accepted
      final acceptedNew = await archive.upsertJourney({
        'id': 'j1',
        'name': 'Newer Trip A',
        'startedAtUtcMillis': 10,
        'endedAtUtcMillis': 20,
        'updatedAtUtcMillis': 200,
        'origin': kAnnotationOriginCar,
        'hlcMillis': 200,
        'hlcCounter': 0,
        'hlcDeviceId': kAnnotationOriginCar,
      });
      expect(acceptedNew, isTrue);
      expect(
        (await archive.database.allJourneys()).single['name'],
        'Newer Trip A',
      );
    });
  });

  test(
    'upgrade from v1 drops legacy tables, creates sessions, and wipes old state',
    () async {
      sqfliteFfiInit();
      final factory = databaseFactoryFfi;
      final path = inMemoryDatabasePath;
      final rawDb = await factory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async {
            await db.execute(
              'CREATE TABLE trips (id TEXT PRIMARY KEY, startedAtUtcMillis INTEGER, closed INTEGER, row TEXT)',
            );
            await db.execute(
              'CREATE TABLE charges (id TEXT PRIMARY KEY, startedAtUtcMillis INTEGER, closed INTEGER, row TEXT)',
            );
            await db.execute(
              'CREATE TABLE cycles (ordinal INTEGER PRIMARY KEY, row TEXT)',
            );
            await db.execute(
              'CREATE TABLE intervals (sessionId TEXT, startUtcMillis INTEGER, row TEXT, PRIMARY KEY (sessionId, startUtcMillis))',
            );
            await db.execute(
              'CREATE TABLE frames (sessionId TEXT, wallTimeUtcMillis INTEGER, staged INTEGER, row TEXT, PRIMARY KEY (sessionId, wallTimeUtcMillis, staged))',
            );
            await db.execute(
              'CREATE TABLE cursors (stream TEXT PRIMARY KEY, recordId TEXT)',
            );
            await db.execute(
              'CREATE TABLE frame_resume (sessionId TEXT PRIMARY KEY, after TEXT)',
            );
            await db.execute(
              'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)',
            );

            await db.insert('trips', {
              'id': 'old-trip',
              'startedAtUtcMillis': 100,
              'closed': 1,
              'row': '{}',
            });
            await db.insert('cycles', {'ordinal': 1, 'row': '{}'});
            await db.insert('frames', {
              'sessionId': 'old-trip',
              'wallTimeUtcMillis': 100,
              'staged': 0,
              'row': '{}',
            });
            await db.insert('cursors', {
              'stream': 'tripSessions',
              'recordId': 'old-trip',
            });
          },
        ),
      );
      await rawDb.close();

      final companionDb = await CompanionDatabase.open(
        path,
        singleInstance: false,
      );
      final archive = CompanionArchive(companionDb);
      await archive.load();

      expect(await archive.database.countTrips(), 0);
      expect(await archive.database.countCycles(), 0);
      expect(archive.confirmedId(SyncStreamType.sessions), isNull);

      await archive.upsertSession({
        'id': 'new-session',
        'kind': 'TRIP',
        'startedAtUtcMillis': 500,
        'status': 'CLOSED',
      });
      expect(await archive.database.countTrips(), 1);
      await companionDb.close();
    },
  );
}
