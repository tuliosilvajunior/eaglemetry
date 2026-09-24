import 'dart:convert';
import 'dart:io';

import 'package:capy_companion/sync/companion_archive.dart';
import 'package:capy_companion/sync/companion_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('migration 12->13 preserves annotation rows with sensible HLC', () async {
    final tmpPath =
        '${Directory.systemTemp.path}/hlc-mig-test-${DateTime.now().millisecondsSinceEpoch}.db';
    final fileDb = await databaseFactory.openDatabase(
      tmpPath,
      options: OpenDatabaseOptions(
        version: 12,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE places (
              id TEXT PRIMARY KEY,
              updatedAtUtcMillis INTEGER NOT NULL,
              origin TEXT NOT NULL DEFAULT 'car',
              row TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE preferences (
              scope TEXT NOT NULL,
              key TEXT NOT NULL,
              updatedAtUtcMillis INTEGER NOT NULL,
              origin TEXT NOT NULL DEFAULT 'car',
              row TEXT NOT NULL,
              PRIMARY KEY (scope, key)
            )
          ''');
          await db.execute('''
            CREATE TABLE session_costs (
              sessionId TEXT PRIMARY KEY,
              updatedAtUtcMillis INTEGER NOT NULL,
              origin TEXT NOT NULL DEFAULT 'car',
              row TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE preference_proposals (
              id TEXT PRIMARY KEY,
              updatedAtUtcMillis INTEGER NOT NULL,
              origin TEXT NOT NULL DEFAULT 'phone',
              row TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE journeys (
              id TEXT PRIMARY KEY,
              updatedAtUtcMillis INTEGER NOT NULL,
              origin TEXT NOT NULL DEFAULT 'phone',
              row TEXT NOT NULL
            )
          ''');
          await db.execute(
            'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
          await db.execute('''
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY,
              vehicleId TEXT NOT NULL DEFAULT 'unassigned',
              kind TEXT NOT NULL,
              status TEXT NOT NULL,
              startedAtUtcMillis INTEGER NOT NULL,
              closed INTEGER NOT NULL,
              dirty INTEGER NOT NULL DEFAULT 1,
              row TEXT NOT NULL
            )
          ''');
          await db.execute(
            'CREATE TABLE cursors (stream TEXT PRIMARY KEY, recordId TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE cycles (ordinal INTEGER PRIMARY KEY, dirty INTEGER NOT NULL DEFAULT 1, row TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE intervals (sessionId TEXT NOT NULL, startUtcMillis INTEGER NOT NULL, dirty INTEGER NOT NULL DEFAULT 1, row TEXT NOT NULL, PRIMARY KEY (sessionId, startUtcMillis))',
          );
          await db.execute(
            'CREATE TABLE events (id INTEGER, sessionId TEXT, type INTEGER NOT NULL, occurredAtUtcMillis INTEGER NOT NULL, occurredAtElapsedNanos INTEGER NOT NULL DEFAULT 0, signalKey INTEGER NOT NULL DEFAULT 0, value TEXT, previousValue TEXT, dirty INTEGER NOT NULL DEFAULT 1)',
          );
          await db.execute(
            'CREATE TABLE tracks (sessionId TEXT PRIMARY KEY, updatedAtUtcMillis INTEGER NOT NULL, pointCount INTEGER NOT NULL, dirty INTEGER NOT NULL DEFAULT 1, row TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE annotation_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, stream TEXT NOT NULL, row TEXT NOT NULL, createdAtUtcMillis INTEGER NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE nominatim_cache (cellKey TEXT PRIMARY KEY, latitude REAL NOT NULL, longitude REAL NOT NULL, displayName TEXT NOT NULL, fetchedAtUtcMillis INTEGER NOT NULL)',
          );
        },
        singleInstance: false,
      ),
    );
    await fileDb.insert('places', {
      'id': 'place-1',
      'updatedAtUtcMillis': 2000000,
      'origin': 'car',
      'row': jsonEncode({
        'id': 'place-1',
        'name': 'Home',
        'latitude': -23.5,
        'longitude': -46.6,
        'radiusM': 150.0,
        'createdAtUtcMillis': 1000000,
        'updatedAtUtcMillis': 2000000,
        'origin': 'car',
      }),
    });
    await fileDb.insert('preferences', {
      'scope': 'account',
      'key': 'theme_id',
      'updatedAtUtcMillis': 3000000,
      'origin': 'phone',
      'row': jsonEncode({
        'scope': 'account',
        'key': 'theme_id',
        'value': 'dark',
        'updatedAtUtcMillis': 3000000,
        'origin': 'phone',
      }),
    });
    await fileDb.insert('session_costs', {
      'sessionId': 'sess-1',
      'updatedAtUtcMillis': 4000000,
      'origin': 'car',
      'row': jsonEncode({
        'sessionId': 'sess-1',
        'costPerKwh': 0.75,
        'updatedAtUtcMillis': 4000000,
        'origin': 'car',
      }),
    });
    await fileDb.insert('preference_proposals', {
      'id': 'prop-1',
      'updatedAtUtcMillis': 5000000,
      'origin': 'phone',
      'row': jsonEncode({
        'id': 'prop-1',
        'key': 'pack_capacity_wh',
        'value': '39000',
        'status': 'PENDING',
        'proposedAtUtcMillis': 4900000,
        'updatedAtUtcMillis': 5000000,
        'origin': 'phone',
      }),
    });
    await fileDb.insert('journeys', {
      'id': 'journey-1',
      'updatedAtUtcMillis': 5500000,
      'origin': 'car',
      'row': jsonEncode({
        'id': 'journey-1',
        'name': 'Weekend',
        'startedAtUtcMillis': 5000000,
        'endedAtUtcMillis': 6000000,
        'createdAtUtcMillis': 5000000,
        'updatedAtUtcMillis': 5500000,
        'origin': 'car',
      }),
    });
    await fileDb.close();

    final companionDb = await CompanionDatabase.open(tmpPath);
    final db2 = companionDb.databaseForTest;

    final places = await db2.query('places', where: "id = 'place-1'");
    expect(places.length, 1);
    expect(places.first['updatedAtUtcMillis'], 2000000);
    expect(places.first['hlcMillis'], 2000000);
    expect(places.first['hlcCounter'], 0);
    expect(places.first['hlcDeviceId'], 'car');

    final prefs = await db2.query(
      'preferences',
      where: "scope='account' AND key='theme_id'",
    );
    expect(prefs.length, 1);
    expect(prefs.first['hlcMillis'], 3000000);
    expect(prefs.first['hlcDeviceId'], 'phone');

    final costs = await db2.query('session_costs', where: "sessionId='sess-1'");
    expect(costs.length, 1);
    expect(costs.first['hlcMillis'], 4000000);
    expect(costs.first['hlcDeviceId'], 'car');

    final props = await db2.query('preference_proposals', where: "id='prop-1'");
    expect(props.length, 1);
    expect(props.first['hlcMillis'], 5000000);
    expect(props.first['hlcDeviceId'], 'phone');

    final journeys = await db2.query('journeys', where: "id='journey-1'");
    expect(journeys.length, 1);
    expect(journeys.first['hlcMillis'], 5500000);
    expect(journeys.first['hlcDeviceId'], 'car');

    await companionDb.close();
    await databaseFactory.deleteDatabase(tmpPath);
  });

  test('local write populates HLC and counter advances', () async {
    final db = await CompanionDatabase.open(
      inMemoryDatabasePath,
      singleInstance: false,
    );
    final archive = CompanionArchive(db, deviceIdProvider: () => 'phone-1');

    await archive.upsertPlace({
      'id': 'p1',
      'name': 'Home',
      'latitude': -23.5,
      'longitude': -46.6,
      'radiusM': 150.0,
      'createdAtUtcMillis': 1000,
      'updatedAtUtcMillis': 5000000,
      'origin': 'phone',
    });
    var raw = await db.databaseForTest.query('places', where: "id='p1'");
    expect(raw.first['hlcMillis'], 5000000);
    expect(raw.first['hlcCounter'], 0);
    expect(raw.first['hlcDeviceId'], 'phone-1');

    await archive.upsertPlace({
      'id': 'p1',
      'name': 'Casa',
      'latitude': -23.5,
      'longitude': -46.6,
      'radiusM': 150.0,
      'createdAtUtcMillis': 1000,
      'updatedAtUtcMillis': 5000000,
      'origin': 'phone',
    });
    raw = await db.databaseForTest.query('places', where: "id='p1'");
    expect(raw.first['hlcMillis'], 5000000);
    expect(raw.first['hlcCounter'], 1);

    await db.close();
  });

  test('remote HLC merges rather than being overwritten', () async {
    final db = await CompanionDatabase.open(
      inMemoryDatabasePath,
      singleInstance: false,
    );
    final archive = CompanionArchive(db, deviceIdProvider: () => 'phone-1');

    await archive.upsertPlace({
      'id': 'p2',
      'name': 'Remote',
      'latitude': -23.5,
      'longitude': -46.6,
      'radiusM': 150.0,
      'createdAtUtcMillis': 9000000,
      'updatedAtUtcMillis': 9000000,
      'origin': 'car',
      'hlcMillis': 9000000,
      'hlcCounter': 5,
      'hlcDeviceId': 'car',
      'hlc': {'millis': 9000000, 'counter': 5, 'deviceId': 'car'},
    });
    var raw = await db.databaseForTest.query('places', where: "id='p2'");
    expect(raw.first['hlcMillis'], 9000000);
    expect(raw.first['hlcCounter'], 5);

    await archive.upsertPlace({
      'id': 'p3',
      'name': 'LocalAfterRemote',
      'latitude': -23.5,
      'longitude': -46.6,
      'radiusM': 150.0,
      'createdAtUtcMillis': 6000000,
      'updatedAtUtcMillis': 6000000,
      'origin': 'phone',
    });
    raw = await db.databaseForTest.query('places', where: "id='p3'");
    final localMillis = raw.first['hlcMillis'] as int;
    expect(localMillis >= 9000000, true);
    if (localMillis == 9000000) {
      expect((raw.first['hlcCounter'] as int) > 5, true);
    }

    await db.close();
  });

  test(
    'HLC now decides winner (6b) - slow-clock later HLC beats larger wall',
    () async {
      final db = await CompanionDatabase.open(
        inMemoryDatabasePath,
        singleInstance: false,
      );
      final archive = CompanionArchive(db);

      await archive.upsertPlace({
        'id': 'p-wall',
        'name': 'Home',
        'latitude': -23.5,
        'longitude': -46.6,
        'radiusM': 150.0,
        'createdAtUtcMillis': 1000,
        'updatedAtUtcMillis': 8000000,
        'origin': 'car',
        'hlcMillis': 8000000,
        'hlcCounter': 0,
        'hlcDeviceId': 'car',
      });
      await archive.upsertPlace({
        'id': 'p-wall',
        'name': 'Incoming',
        'latitude': -23.5,
        'longitude': -46.6,
        'radiusM': 150.0,
        'createdAtUtcMillis': 1000,
        'updatedAtUtcMillis': 7000000,
        'origin': 'phone',
        'hlcMillis': 9000000,
        'hlcCounter': 1,
        'hlcDeviceId': 'phone',
      });
      final all = await db.allPlaces();
      final kept = all.firstWhere((r) => r['id'] == 'p-wall');
      expect(kept['name'], 'Incoming');
      expect(kept['hlcMillis'], 9000000);
      expect(kept['hlcCounter'], 1);

      await db.close();
    },
  );
}
