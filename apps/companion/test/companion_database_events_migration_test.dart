import 'dart:convert';
import 'dart:io';

import 'package:capy_companion/sync/companion_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Issue 226: the v10 → v11 migration normalizes the legacy event table.
///
/// The legacy shape held every event the car ever sent as a JSON string in a
/// `row` column. The migration must keep what the session narrative reads,
/// retire the orphans the companion never queried, and mark the survivors
/// `dirty = 0` so the cloud uploader never offers them again.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late String path;

  Future<void> insertLegacyEvent(
    Database db, {
    required int id,
    String? sessionId,
    required String type,
    String? signalId,
    String? value,
  }) async {
    await db.insert('events', {
      'id': id,
      'sessionId': sessionId,
      'occurredAtUtcMillis': 1000 + id,
      'dirty': 1,
      'row': jsonEncode({
        'id': id,
        'sessionId': sessionId,
        'type': type,
        'occurredAtUtcMillis': 1000 + id,
        'occurredAtElapsedNanos': id,
        'signalId': signalId,
        'value': value,
        'previousValue': null,
        'quality': 'MEASURED',
        'source': 'CAN_BRIDGE',
        'details': '',
      }),
    });
  }

  setUp(() async {
    path =
        '${Directory.systemTemp.path}/'
        'companion_migration_${DateTime.now().microsecondsSinceEpoch}.db';
    final legacy = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 10,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE events (
              id INTEGER PRIMARY KEY,
              sessionId TEXT,
              occurredAtUtcMillis INTEGER NOT NULL,
              dirty INTEGER NOT NULL DEFAULT 1,
              row TEXT NOT NULL
            )
          ''');
          await db.execute(
            'CREATE INDEX events_session ON events (sessionId, occurredAtUtcMillis)',
          );
          await db.execute('CREATE INDEX events_dirty ON events (dirty, id)');
        },
      ),
    );
    // The narrative rows the migration keeps.
    await insertLegacyEvent(
      legacy,
      id: 1,
      sessionId: 'trip-1',
      type: 'SIGNAL_UPDATED',
      signalId: 'GEAR',
      value: 'R',
    );
    await insertLegacyEvent(
      legacy,
      id: 4,
      sessionId: 'trip-1',
      type: 'TRIP_STARTED',
    );
    // A narrative signal the code registry does not know: kept, keyless.
    await insertLegacyEvent(
      legacy,
      id: 3,
      sessionId: 'trip-1',
      type: 'SIGNAL_UPDATED',
      signalId: 'MYSTERY_KEY',
      value: '7',
    );
    await insertLegacyEvent(
      legacy,
      id: 5,
      sessionId: 'trip-1',
      type: 'SOMETHING_ELSE',
    );
    // An unknown type survives unnamed: the migration never drops a
    // narrative record it cannot name.
    // The orphan the companion never queried: dropped.
    await insertLegacyEvent(
      legacy,
      id: 2,
      type: 'SIGNAL_UPDATED',
      signalId: 'ODOMETER',
      value: '12450.3',
    );
    await legacy.close();
  });

  tearDown(() async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  });

  test('the migration keeps narrative rows as typed wire rows', () async {
    final db = await CompanionDatabase.open(path, singleInstance: false);
    final events = await db.eventsForSession('trip-1');

    expect(events, hasLength(4));
    expect(events[0]['type'], 'SIGNAL_UPDATED');
    expect(events[0]['signalId'], 'GEAR');
    expect(events[0]['value'], 'R');
    expect(events[0]['occurredAtUtcMillis'], 1001);
    // A narrative key outside the registry survives with its key forgotten.
    expect(events[1]['signalId'], isNull);
    expect(events[1]['value'], '7');
    // The lifecycle row carries no signal at all.
    expect(events[2]['type'], 'TRIP_STARTED');
    expect(events[2]['signalId'], isNull);
    // An unknown legacy type survives with no name rather than losing the
    // row: the migration never drops a narrative record it cannot name.
    expect(events[3]['type'], '');

    await db.close();
  });

  test('the migration drops orphans but keeps unnameable rows', () async {
    final db = await CompanionDatabase.open(path, singleInstance: false);
    expect(await db.eventsForSession('trip-1'), hasLength(4));
    await db.close();

    // The odometer orphan is gone; every survivor names a session.
    final raw = await databaseFactory.openDatabase(path);
    final count = await raw.rawQuery('SELECT COUNT(*) AS n FROM events');
    expect(count.first['n'], 4);
    final orphans = await raw.rawQuery(
      'SELECT COUNT(*) AS n FROM events WHERE sessionId IS NULL',
    );
    expect(orphans.first['n'], 0);
    await raw.close();
  });

  test('survivors come back dirty = 0 and stay out of the upload', () async {
    final db = await CompanionDatabase.open(path, singleInstance: false);

    expect(await db.dirtyEvents(), isEmpty);

    await db.close();
  });

  test('the dirty index becomes partial and new rows still flow', () async {
    final db = await CompanionDatabase.open(path, singleInstance: false);

    // The receiving path stays live for the day the stream is re-enabled.
    await db.upsertEvent({
      'id': 9,
      'sessionId': 'trip-2',
      'type': 'SIGNAL_UPDATED',
      'occurredAtUtcMillis': 5000,
      'occurredAtElapsedNanos': 9,
      'signalId': 'GEAR',
      'value': 'D',
    });
    final dirty = await db.dirtyEvents();
    expect(dirty, hasLength(1));
    expect(dirty.single['type'], 'SIGNAL_UPDATED');
    expect(dirty.single['signalId'], 'GEAR');
    expect(dirty.single[CompanionDatabase.rowIdKey], isA<int>());
    await db.close();

    final raw = await databaseFactory.openDatabase(path);
    final indexes = await raw.rawQuery(
      "SELECT sql FROM sqlite_master WHERE type = 'index' "
      "AND name = 'events_dirty'",
    );
    expect(
      (indexes.single['sql'] as String).contains('WHERE dirty = 1'),
      isTrue,
    );
    await raw.close();
  });
}
