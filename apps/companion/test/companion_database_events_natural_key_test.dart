import 'dart:io';

import 'package:capy_companion/sync/companion_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Issue 227: the companion's `events` table keys on the backend's natural
/// key — `(occurredAtUtcMillis, occurredAtElapsedNanos, type, signalKey)`,
/// the cloud's `telemetry_events` primary key minus `vehicle_id` — and no
/// longer on the car's autoincrement rowid.
///
/// The car's rowid restarts at 1 on reinstall; under the old
/// `id INTEGER PRIMARY KEY` every new event silently replaced the unrelated
/// stored event wearing the same number. These tests exercise the receiving
/// path directly: the event stream itself is gated off by issue 226 and
/// stays gated — the gate is not this issue's to change.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late String path;

  setUp(() async {
    path =
        '${Directory.systemTemp.path}/'
        'companion_natural_key_${DateTime.now().microsecondsSinceEpoch}.db';
  });

  tearDown(() async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  });

  Map<String, Object?> event({
    required int id,
    String? sessionId,
    required String type,
    required int occurredAtUtcMillis,
    required int occurredAtElapsedNanos,
    String? signalId,
    String? value,
  }) => {
    'id': id,
    'sessionId': sessionId,
    'type': type,
    'occurredAtUtcMillis': occurredAtUtcMillis,
    'occurredAtElapsedNanos': occurredAtElapsedNanos,
    'signalId': signalId,
    'value': value,
    'previousValue': null,
  };

  test('two events wearing the same car row number both survive', () async {
    final db = await CompanionDatabase.open(path, singleInstance: false);

    // One car's event 1, then — after a reinstall that restarted the car's
    // row numbering — a different event that also claims row 1.
    await db.upsertEvent(
      event(
        id: 1,
        sessionId: 'trip-1',
        type: 'TRIP_ARMED',
        occurredAtUtcMillis: 1000,
        occurredAtElapsedNanos: 100,
        value: 'armed',
      ),
    );
    await db.upsertEvent(
      event(
        id: 1,
        sessionId: 'charge-1',
        type: 'CHARGE_STARTED',
        occurredAtUtcMillis: 2000,
        occurredAtElapsedNanos: 200,
        value: 'charging',
      ),
    );

    final trip = await db.eventsForSession('trip-1');
    final charge = await db.eventsForSession('charge-1');
    expect(trip, hasLength(1));
    expect(trip.single['type'], 'TRIP_ARMED');
    expect(trip.single['value'], 'armed');
    expect(charge, hasLength(1));
    expect(charge.single['type'], 'CHARGE_STARTED');
    expect(charge.single['value'], 'charging');

    final raw = await databaseFactory.openDatabase(path);
    final count = await raw.rawQuery('SELECT COUNT(*) AS n FROM events');
    expect(count.single['n'], 2);
    await raw.close();
    await db.close();
  });

  test(
    're-delivering the same event updates in place, never duplicates',
    () async {
      final db = await CompanionDatabase.open(path, singleInstance: false);

      await db.upsertEvent(
        event(
          id: 7,
          sessionId: 'trip-1',
          type: 'SIGNAL_UPDATED',
          occurredAtUtcMillis: 1000,
          occurredAtElapsedNanos: 100,
          signalId: 'GEAR',
          value: 'D',
        ),
      );
      // The same natural key comes again — same millis, nanos, type and
      // signal — but the car's rowid moved, as it can across a reinstall.
      await db.upsertEvent(
        event(
          id: 99,
          sessionId: 'trip-1',
          type: 'SIGNAL_UPDATED',
          occurredAtUtcMillis: 1000,
          occurredAtElapsedNanos: 100,
          signalId: 'GEAR',
          value: 'R',
        ),
      );

      final events = await db.eventsForSession('trip-1');
      expect(events, hasLength(1));
      expect(events.single['value'], 'R');
      expect(events.single['id'], 99);

      // The replacement is dirty again and carries a rowid for the clear.
      final dirty = await db.dirtyEvents();
      expect(dirty, hasLength(1));
      expect(dirty.single['value'], 'R');
      expect(dirty.single[CompanionDatabase.rowIdKey], isA<int>());
      await db.close();
    },
  );

  test('the v11 to v12 migration carries every existing row across', () async {
    // The v11 shape: the car's rowid is the whole identity.
    final legacy = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 11,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE events (
              id INTEGER PRIMARY KEY,
              sessionId TEXT,
              type INTEGER NOT NULL,
              occurredAtUtcMillis INTEGER NOT NULL,
              occurredAtElapsedNanos INTEGER NOT NULL DEFAULT 0,
              signalKey INTEGER,
              value TEXT,
              previousValue TEXT,
              dirty INTEGER NOT NULL DEFAULT 1
            )
          ''');
          await db.execute(
            'CREATE INDEX events_session ON events (sessionId, occurredAtUtcMillis)',
          );
          await db.execute(
            'CREATE INDEX events_dirty ON events (dirty, id) WHERE dirty = 1',
          );
        },
      ),
    );
    // Type codes follow the stored registry: SIGNAL_UPDATED is 1,
    // TRIP_ARMED is 5, CHARGE_STARTED is 12; GEAR is signal code 1.
    Future<void> insertLegacy(
      int id, {
      String? sessionId,
      required int type,
      required int millis,
      required int nanos,
      int? signalKey,
      String? value,
      int dirty = 1,
    }) => legacy.insert('events', {
      'id': id,
      'sessionId': sessionId,
      'type': type,
      'occurredAtUtcMillis': millis,
      'occurredAtElapsedNanos': nanos,
      'signalKey': signalKey,
      'value': value,
      'dirty': dirty,
    });
    await insertLegacy(
      1,
      sessionId: 'trip-1',
      type: 5,
      millis: 1000,
      nanos: 100,
      value: 'armed',
      dirty: 0,
    );
    await insertLegacy(
      2,
      sessionId: 'trip-1',
      type: 1,
      millis: 1500,
      nanos: 150,
      signalKey: 1,
      value: 'D',
    );
    // Two legacy rows that share a natural key: the backend's own key says
    // they are the same event, so the migration folds them.
    await insertLegacy(
      3,
      sessionId: 'charge-1',
      type: 12,
      millis: 2000,
      nanos: 200,
      value: 'first',
    );
    await insertLegacy(
      4,
      sessionId: 'charge-1',
      type: 12,
      millis: 2000,
      nanos: 200,
      value: 'second',
    );
    await legacy.close();

    final db = await CompanionDatabase.open(path, singleInstance: false);

    // Every distinct event crossed, with its fields and marks intact.
    final trip = await db.eventsForSession('trip-1');
    expect(trip, hasLength(2));
    expect(trip[0]['type'], 'TRIP_ARMED');
    expect(trip[0]['value'], 'armed');
    expect(trip[0]['id'], 1);
    expect(trip[1]['signalId'], 'GEAR');
    expect(trip[1]['value'], 'D');
    final charge = await db.eventsForSession('charge-1');
    expect(charge, hasLength(1));
    expect(charge.single['value'], 'first');

    final raw = await databaseFactory.openDatabase(path);
    final dirtyRows = await raw.rawQuery(
      'SELECT COUNT(*) AS n FROM events WHERE dirty = 1',
    );
    // The still-unsynced legacy rows stay dirty; the migrated `dirty = 0`
    // row stays out of the upload.
    expect(dirtyRows.single['n'], 2);

    // The natural key is live after the migration. A reinstalled car's
    // event wearing row 1 lands beside the migrated history: trip-1's rows
    // are untouched by it.
    await db.upsertEvent(
      event(
        id: 1,
        sessionId: 'trip-2',
        type: 'TRIP_STARTED',
        occurredAtUtcMillis: 3000,
        occurredAtElapsedNanos: 300,
        value: 'new-car',
      ),
    );
    final untouched = await db.eventsForSession('trip-1');
    expect(untouched, hasLength(2));
    expect(
      untouched.firstWhere((e) => e['type'] == 'TRIP_ARMED')['value'],
      'armed',
    );
    final newCar = await db.eventsForSession('trip-2');
    expect(newCar, hasLength(1));
    expect(newCar.single['type'], 'TRIP_STARTED');

    // And a re-delivery of a migrated row replaces it in place, never
    // duplicating it.
    await db.upsertEvent(
      event(
        id: 50,
        sessionId: 'trip-1',
        type: 'TRIP_ARMED',
        occurredAtUtcMillis: 1000,
        occurredAtElapsedNanos: 100,
        value: 'armed again',
      ),
    );
    final after = await db.eventsForSession('trip-1');
    expect(after, hasLength(2));
    expect(
      after.firstWhere((e) => e['type'] == 'TRIP_ARMED')['value'],
      'armed again',
    );
    final total = await raw.rawQuery('SELECT COUNT(*) AS n FROM events');
    expect(total.single['n'], 4);
    await raw.close();
    await db.close();
  });

  test('a v11 events table without a primary key on id still migrates, '
      'folding duplicate natural keys', () async {
    // The shape `_normalizeEvents` leaves when a v10 database crosses v11
    // in the same upgrade: `id` is an ordinary column, not the key. The
    // `id INTEGER PRIMARY KEY` probe in `_rekeyEvents` missed this shape,
    // skipped the rebuild, and the unique index then crashed on the
    // duplicates below — the splash screen failure this test guards.
    final legacy = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 11,
        onCreate: (db, version) async {
          await db.execute('''
              CREATE TABLE events (
                id INTEGER,
                sessionId TEXT,
                type INTEGER NOT NULL,
                occurredAtUtcMillis INTEGER NOT NULL,
                occurredAtElapsedNanos INTEGER NOT NULL DEFAULT 0,
                signalKey INTEGER,
                value TEXT,
                previousValue TEXT,
                dirty INTEGER NOT NULL DEFAULT 1
              )
            ''');
        },
      ),
    );
    Future<void> insertLegacy(
      int id, {
      String? sessionId,
      required int type,
      required int millis,
      required int nanos,
      int? signalKey,
      String? value,
    }) => legacy.insert('events', {
      'id': id,
      'sessionId': sessionId,
      'type': type,
      'occurredAtUtcMillis': millis,
      'occurredAtElapsedNanos': nanos,
      'signalKey': signalKey,
      'value': value,
      'dirty': 1,
    });
    // Two rows sharing one natural key: the backend's own key says they
    // are the same event, so the migration folds them instead of letting
    // the unique index throw.
    await insertLegacy(
      1,
      sessionId: 'charge-1',
      type: 12,
      millis: 2000,
      nanos: 200,
      value: 'first',
    );
    await insertLegacy(
      2,
      sessionId: 'charge-1',
      type: 12,
      millis: 2000,
      nanos: 200,
      value: 'second',
    );
    // A keyless row: SQLite counts NULLs as distinct in a unique index,
    // so it survives the fold with its signalKey coerced to 0.
    await insertLegacy(
      3,
      sessionId: 'trip-1',
      type: 5,
      millis: 3000,
      nanos: 300,
      signalKey: null,
      value: 'armed',
    );
    await legacy.close();

    // Must open cleanly: this crashed with `UNIQUE constraint failed` on
    // the events_natural index before the fix.
    final db = await CompanionDatabase.open(path, singleInstance: false);

    // The duplicate pair folded to its first row, fields intact.
    final charge = await db.eventsForSession('charge-1');
    expect(charge, hasLength(1));
    expect(charge.single['id'], 1);
    expect(charge.single['value'], 'first');
    // The keyless row crossed with its NULL signalKey coerced to 0.
    final trip = await db.eventsForSession('trip-1');
    expect(trip, hasLength(1));
    expect(trip.single['id'], 3);
    expect(trip.single['type'], 'TRIP_ARMED');
    expect(trip.single['value'], 'armed');

    // The unique index is live and the fold left exactly two rows.
    final raw = await databaseFactory.openDatabase(path);
    final indexRows = await raw.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'events_natural'",
    );
    expect(indexRows, isNotEmpty);
    final total = await raw.rawQuery('SELECT COUNT(*) AS n FROM events');
    expect(total.single['n'], 2);
    await raw.close();
    await db.close();
  });
}
