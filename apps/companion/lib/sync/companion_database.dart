import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:sqflite/sqflite.dart';
import 'package:telemetry_core/telemetry_core.dart';

/// The phone's own store of what it pulled from the car.
///
/// One rule decides the shape: the car's `toExportRow()` map is the wire
/// format, the backup format and now the stored row, so the whole map is kept
/// as JSON in a `row` column and only the fields the phone **queries by** are
/// promoted to real columns. Mirroring a hundred frame columns here would put
/// a second authority on the schema beside the car's Room database, and the
/// two would drift the day one column is renamed.
///
/// The events table is the one exception since issue 226: its payload is
/// decoded into typed columns ([_eventColumns]) because the raw JSON blob was
/// the table's whole cost and the phone queried it by nothing else.
///
/// A frame is keyed by `(sessionId, wallTimeUtcMillis)`, never by the car's
/// `id`: that column is a Room autoincrement with no meaning outside one
/// database.
class CompanionDatabase {
  CompanionDatabase(this._db);

  /// How a dirty read asks for the rowid.
  ///
  /// The alias is not decoration, and the asymmetry it fixes is easy to walk
  /// past. sqflite quotes a column whose name it knows to be a keyword, so
  /// the `row` column goes out as `"row"` and the result comes back under
  /// exactly that name on every platform. `rowid` is not on that list, so it
  /// goes out bare — and what sqlite names the result column of a bare column
  /// reference is a property of the sqlite that is running: the one behind
  /// `sqflite_common_ffi`, which the tests use, answers `rowid`; the one iOS
  /// carries answered something else, so the page came back with no `rowid`
  /// key at all and the clear that follows ran against a null. That is why
  /// every read here worked for a year and the one new column did not.
  ///
  /// An `AS` is the name. Nothing below it has to agree.
  static const _rowIdColumn = 'rowid AS $rowIdKey';

  /// Where a dirty page carries the row's own sqlite `rowid`.
  ///
  /// It leads with an underscore because it is not a field of the record: it
  /// names the row in **this** database and means nothing outside it. The
  /// uploader drops every key spelled this way before a row leaves the phone.
  static const rowIdKey = '_rowId';

  /// Opens the store at [path]. Pass `:memory:` in a test.
  ///
  /// [singleInstance] is what sqflite does by default: a second open of the
  /// same path answers the first handle. A test that wants a fresh in-memory
  /// store per case has to turn it off, because every one of those cases opens
  /// the same `:memory:` path and would otherwise share one database.
  static Future<CompanionDatabase> open(
    String path, {
    bool singleInstance = true,
  }) async {
    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 13,
        onCreate: _create,
        onUpgrade: _upgrade,
        singleInstance: singleInstance,
      ),
    );
    return CompanionDatabase(db);
  }

  final Database _db;

  /// Exposed for tests.
  Database get databaseForTest => _db;

  Future<void> close() => _db.close();

  /// How much disk the archive occupies, without scanning any row.
  ///
  /// The number is the logical database size (used pages) plus the WAL/SHM
  /// sidecars where they exist. It uses `PRAGMA page_count` and
  /// `freelist_count` — O(1) header reads — plus `File.length` for the
  /// sidecars. With `auto_vacuum = FULL` (the setting on all four car
  /// snapshots) the file truncates on every commit, so logical size and
  /// `File.length` are the same after a wipe (15_102 pages / 47 MB before a
  /// DELETE, 618 pages / 2.5 MB after, freelist always 0). A total failure
  /// returns `bytes = -1` so the UI can show `--` instead of `0 B`.
  Future<StorageUsage> storageUsage() async {
    final path = _db.path;
    if (path == ':memory:' || path.isEmpty) {
      return const StorageUsage(
        bytes: 0,
        databaseBytes: 0,
        walBytes: 0,
        shmBytes: 0,
      );
    }
    try {
      final pageCountRow = await _db.rawQuery('PRAGMA page_count');
      final freelistRow = await _db.rawQuery('PRAGMA freelist_count');
      final pageSizeRow = await _db.rawQuery('PRAGMA page_size');
      final pageCount = (pageCountRow.first.values.first as num?)?.toInt() ?? 0;
      final freelist = (freelistRow.first.values.first as num?)?.toInt() ?? 0;
      final pageSize = (pageSizeRow.first.values.first as num?)?.toInt() ?? 0;
      final usedBytes = ((pageCount - freelist).clamp(0, pageCount) * pageSize);
      final walBytes = await _safeLength(File('$path-wal'));
      final shmBytes = await _safeLength(File('$path-shm'));
      return StorageUsage(
        bytes: usedBytes + walBytes + shmBytes,
        databaseBytes: usedBytes,
        walBytes: walBytes,
        shmBytes: shmBytes,
      );
    } catch (_) {
      // Total failure — let the UI show --, not 0 B.
      return const StorageUsage(
        bytes: -1,
        databaseBytes: -1,
        walBytes: 0,
        shmBytes: 0,
      );
    }
  }

  Future<int> _safeLength(File file) async {
    try {
      if (!await file.exists()) return 0;
      return await file.length();
    } catch (_) {
      return 0;
    }
  }

  /// Empties every table, in one transaction.
  Future<void> wipe() async {
    await _db.transaction((txn) async {
      for (final table in const [
        'sessions',
        'cycles',
        'intervals',
        'events',
        'tracks',
        'places',
        'preferences',
        'session_costs',
        'preference_proposals',
        'journeys',
        'annotation_outbox',
        'cursors',
        'nominatim_cache',
        'meta',
      ]) {
        await txn.delete(table);
      }
    });
  }

  static Future<void> _create(Database db, int version) async {
    final batch = db.batch();
    batch.execute('''
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
    batch.execute(
      'CREATE INDEX sessions_kind_start ON sessions (kind, startedAtUtcMillis DESC)',
    );
    batch.execute('''
      CREATE TABLE cycles (
        ordinal INTEGER PRIMARY KEY,
        dirty INTEGER NOT NULL DEFAULT 1,
        row TEXT NOT NULL
      )
    ''');
    batch.execute('''
      CREATE TABLE intervals (
        sessionId TEXT NOT NULL,
        startUtcMillis INTEGER NOT NULL,
        dirty INTEGER NOT NULL DEFAULT 1,
        row TEXT NOT NULL,
        PRIMARY KEY (sessionId, startUtcMillis)
      )
    ''');
    batch.execute(
      'CREATE INDEX intervals_session ON intervals (sessionId, startUtcMillis)',
    );
    batch.execute(_createEventsTable);
    batch.execute(
      'CREATE INDEX events_session ON events (sessionId, occurredAtUtcMillis)',
    );
    batch.execute(_createEventsNaturalIndex);
    batch.execute(_createTracksTable);
    batch.execute('CREATE INDEX tracks_dirty ON tracks (dirty, sessionId)');
    batch.execute(
      'CREATE TABLE cursors (stream TEXT PRIMARY KEY, recordId TEXT NOT NULL)',
    );
    // What still owes the cloud an upload.
    //
    // This is a mark per row, not a cursor, and the difference is the whole
    // reason it exists. A cursor can only be a position in an order, and the
    // orders available here are the natural keys — a session's uuid first
    // among them. A uuid does not grow with arrival, so a session recorded
    // today can sort **before** one uploaded last week and would sit forever
    // behind the cursor. The same key also cannot say that a row already
    // uploaded has changed, which every open session does when it closes.
    batch.execute('CREATE INDEX sessions_dirty ON sessions (dirty, id)');
    batch.execute('CREATE INDEX intervals_dirty ON intervals (dirty)');
    batch.execute(
      'CREATE INDEX events_dirty ON events (dirty, id) WHERE dirty = 1',
    );
    batch.execute('CREATE INDEX cycles_dirty ON cycles (dirty, ordinal)');
    batch.execute('''
      CREATE TABLE places (
        id TEXT PRIMARY KEY,
        updatedAtUtcMillis INTEGER NOT NULL,
        origin TEXT NOT NULL DEFAULT 'car',
        hlcMillis INTEGER NOT NULL DEFAULT 0,
        hlcCounter INTEGER NOT NULL DEFAULT 0,
        hlcDeviceId TEXT NOT NULL DEFAULT '',
        row TEXT NOT NULL
      )
    ''');
    batch.execute('''
      CREATE TABLE preferences (
        scope TEXT NOT NULL,
        key TEXT NOT NULL,
        updatedAtUtcMillis INTEGER NOT NULL,
        origin TEXT NOT NULL DEFAULT 'car',
        hlcMillis INTEGER NOT NULL DEFAULT 0,
        hlcCounter INTEGER NOT NULL DEFAULT 0,
        hlcDeviceId TEXT NOT NULL DEFAULT '',
        row TEXT NOT NULL,
        PRIMARY KEY (scope, key)
      )
    ''');
    batch.execute('''
      CREATE TABLE session_costs (
        sessionId TEXT PRIMARY KEY,
        updatedAtUtcMillis INTEGER NOT NULL,
        origin TEXT NOT NULL DEFAULT 'car',
        hlcMillis INTEGER NOT NULL DEFAULT 0,
        hlcCounter INTEGER NOT NULL DEFAULT 0,
        hlcDeviceId TEXT NOT NULL DEFAULT '',
        row TEXT NOT NULL
      )
    ''');
    batch.execute('''
      CREATE TABLE preference_proposals (
        id TEXT PRIMARY KEY,
        updatedAtUtcMillis INTEGER NOT NULL,
        origin TEXT NOT NULL DEFAULT 'phone',
        hlcMillis INTEGER NOT NULL DEFAULT 0,
        hlcCounter INTEGER NOT NULL DEFAULT 0,
        hlcDeviceId TEXT NOT NULL DEFAULT '',
        row TEXT NOT NULL
      )
    ''');
    batch.execute('''
      CREATE TABLE journeys (
        id TEXT PRIMARY KEY,
        updatedAtUtcMillis INTEGER NOT NULL,
        origin TEXT NOT NULL DEFAULT 'phone',
        hlcMillis INTEGER NOT NULL DEFAULT 0,
        hlcCounter INTEGER NOT NULL DEFAULT 0,
        hlcDeviceId TEXT NOT NULL DEFAULT '',
        row TEXT NOT NULL
      )
    ''');
    batch.execute('''
      CREATE TABLE annotation_outbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        stream TEXT NOT NULL,
        row TEXT NOT NULL,
        createdAtUtcMillis INTEGER NOT NULL
      )
    ''');
    batch.execute(
      'CREATE INDEX annotation_outbox_created ON annotation_outbox (createdAtUtcMillis)',
    );
    batch.execute(
      'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    batch.execute('''
      CREATE TABLE nominatim_cache (
        cellKey TEXT PRIMARY KEY,
        latitude REAL NOT NULL,
        longitude REAL NOT NULL,
        displayName TEXT NOT NULL,
        fetchedAtUtcMillis INTEGER NOT NULL
      )
    ''');
    await batch.commit(noResult: true);
  }

  static Future<void> _upgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      final batch = db.batch();
      batch.execute('DROP TABLE IF EXISTS trips');
      batch.execute('DROP TABLE IF EXISTS charges');
      batch.execute('DROP TABLE IF EXISTS energy_buckets');
      batch.execute('DROP TABLE IF EXISTS session_aggregates');
      batch.execute('''
        CREATE TABLE IF NOT EXISTS sessions (
          id TEXT PRIMARY KEY,
          vehicleId TEXT NOT NULL DEFAULT 'unassigned',
          kind TEXT NOT NULL,
          status TEXT NOT NULL,
          startedAtUtcMillis INTEGER NOT NULL,
          closed INTEGER NOT NULL,
          row TEXT NOT NULL
        )
      ''');
      batch.execute(
        'CREATE INDEX IF NOT EXISTS sessions_kind_start ON sessions (kind, startedAtUtcMillis DESC)',
      );
      batch.execute('''
        CREATE TABLE IF NOT EXISTS intervals (
          sessionId TEXT NOT NULL,
          startUtcMillis INTEGER NOT NULL,
          row TEXT NOT NULL,
          PRIMARY KEY (sessionId, startUtcMillis)
        )
      ''');
      batch.execute(
        'CREATE INDEX IF NOT EXISTS intervals_session ON intervals (sessionId, startUtcMillis)',
      );
      for (final table in const [
        'cycles',
        'intervals',
        'frames',
        'cursors',
        'frame_resume',
        'meta',
      ]) {
        batch.execute('DELETE FROM $table');
      }
      await batch.commit(noResult: true);
    }
    if (oldVersion < 3) {
      final batch = db.batch();
      batch.execute('''
        CREATE TABLE IF NOT EXISTS events (
          id INTEGER PRIMARY KEY,
          sessionId TEXT,
          occurredAtUtcMillis INTEGER NOT NULL,
          row TEXT NOT NULL
        )
      ''');
      batch.execute(
        'CREATE INDEX IF NOT EXISTS events_session ON events (sessionId, occurredAtUtcMillis)',
      );
      await batch.commit(noResult: true);
    }
    if (oldVersion < 4) {
      final batch = db.batch();
      batch.execute('''
        CREATE TABLE IF NOT EXISTS samples (
          sessionId TEXT NOT NULL,
          key TEXT NOT NULL,
          tUtcMillis INTEGER NOT NULL,
          tElapsedNanos INTEGER NOT NULL,
          id INTEGER NOT NULL,
          staged INTEGER NOT NULL,
          row TEXT NOT NULL,
          PRIMARY KEY (sessionId, key, tUtcMillis, staged)
        )
      ''');
      batch.execute(
        'CREATE INDEX IF NOT EXISTS samples_session ON samples (staged, sessionId, key, tUtcMillis)',
      );
      batch.execute(
        'CREATE TABLE IF NOT EXISTS sample_resume (sessionId TEXT PRIMARY KEY, after TEXT NOT NULL)',
      );
      batch.execute('DROP TABLE IF EXISTS frames');
      batch.execute('DROP TABLE IF EXISTS frame_resume');
      await batch.commit(noResult: true);
    }
    if (oldVersion < 5) {
      final batch = db.batch();
      batch.execute('''
        CREATE TABLE IF NOT EXISTS places (
          id TEXT PRIMARY KEY,
          updatedAtUtcMillis INTEGER NOT NULL,
          origin TEXT NOT NULL DEFAULT 'car',
          row TEXT NOT NULL
        )
      ''');
      batch.execute('''
        CREATE TABLE IF NOT EXISTS preferences (
          scope TEXT NOT NULL,
          key TEXT NOT NULL,
          updatedAtUtcMillis INTEGER NOT NULL,
          origin TEXT NOT NULL DEFAULT 'car',
          row TEXT NOT NULL,
          PRIMARY KEY (scope, key)
        )
      ''');
      batch.execute('''
        CREATE TABLE IF NOT EXISTS session_costs (
          sessionId TEXT PRIMARY KEY,
          updatedAtUtcMillis INTEGER NOT NULL,
          origin TEXT NOT NULL DEFAULT 'car',
          row TEXT NOT NULL
        )
      ''');
      batch.execute('''
        CREATE TABLE IF NOT EXISTS preference_proposals (
          id TEXT PRIMARY KEY,
          updatedAtUtcMillis INTEGER NOT NULL,
          origin TEXT NOT NULL DEFAULT 'phone',
          row TEXT NOT NULL
        )
      ''');
      batch.execute('''
        CREATE TABLE IF NOT EXISTS annotation_outbox (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          stream TEXT NOT NULL,
          row TEXT NOT NULL,
          createdAtUtcMillis INTEGER NOT NULL
        )
      ''');
      batch.execute(
        'CREATE INDEX IF NOT EXISTS annotation_outbox_created ON annotation_outbox (createdAtUtcMillis)',
      );
      await batch.commit(noResult: true);
    }
    if (oldVersion < 6) {
      // Everything already here owes the cloud an upload, because no upload
      // has ever run. The default says so.
      for (final table in const [
        'sessions',
        'intervals',
        'samples',
        'events',
        'cycles',
      ]) {
        await db.execute(
          'ALTER TABLE $table ADD COLUMN dirty INTEGER NOT NULL DEFAULT 1',
        );
      }
      await db.execute(
        'CREATE INDEX IF NOT EXISTS sessions_dirty ON sessions (dirty, id)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS intervals_dirty ON intervals (dirty)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS samples_dirty ON samples (dirty, staged)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS events_dirty ON events (dirty, id)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS cycles_dirty ON cycles (dirty, ordinal)',
      );
    }
    if (oldVersion < 7) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS journeys (
          id TEXT PRIMARY KEY,
          updatedAtUtcMillis INTEGER NOT NULL,
          origin TEXT NOT NULL DEFAULT 'phone',
          row TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 8) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS nominatim_cache (
          cellKey TEXT PRIMARY KEY,
          latitude REAL NOT NULL,
          longitude REAL NOT NULL,
          displayName TEXT NOT NULL,
          fetchedAtUtcMillis INTEGER NOT NULL
        )
      ''');
    }
    if (oldVersion < 9) {
      await db.execute(_createTracksTable);
      await db.execute(
        'CREATE INDEX IF NOT EXISTS tracks_dirty ON tracks (dirty, sessionId)',
      );
    }
    if (oldVersion < 10) {
      await db.execute('DROP TABLE IF EXISTS samples');
      await db.execute('DROP TABLE IF EXISTS sample_resume');
    }
    if (oldVersion < 11) {
      await _normalizeEvents(db);
    }
    if (oldVersion < 12) {
      await _rekeyEvents(db);
    }
    if (oldVersion < 13) {
      await _migrateAnnotationsToHlc(db);
    }
  }

  /// Issue 227 step 6a: annotation tables gain a hybrid logical clock.
  ///
  /// The migration is additive: three columns per table, backfilled to
  /// `hlcMillis = updatedAtUtcMillis`, `hlcDeviceId = origin`. Counter
  /// stays zero because no causal history exists yet.
  static Future<void> _migrateAnnotationsToHlc(Database db) async {
    for (final table in const [
      'places',
      'preferences',
      'session_costs',
      'preference_proposals',
      'journeys',
    ]) {
      final info = await db.rawQuery(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='$table'",
      );
      if (info.isEmpty) continue;
      final sql = info.first['sql'] as String? ?? '';
      if (!sql.contains('hlcMillis')) {
        await db.execute(
          'ALTER TABLE $table ADD COLUMN hlcMillis INTEGER NOT NULL DEFAULT 0',
        );
      }
      if (!sql.contains('hlcCounter')) {
        await db.execute(
          'ALTER TABLE $table ADD COLUMN hlcCounter INTEGER NOT NULL DEFAULT 0',
        );
      }
      if (!sql.contains('hlcDeviceId')) {
        await db.execute(
          "ALTER TABLE $table ADD COLUMN hlcDeviceId TEXT NOT NULL DEFAULT ''",
        );
      }
    }
    // Backfill existing rows: sensible stamp from wall time + origin.
    // Tables may not exist at the version the migration runs from (e.g. v10 events test).
    for (final entry in const [
      ('places', 'car'),
      ('preferences', 'car'),
      ('session_costs', 'car'),
      ('preference_proposals', 'phone'),
      ('journeys', 'phone'),
    ]) {
      final table = entry.$1;
      final defaultDevice = entry.$2;
      final exists = await db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='$table'",
      );
      if (exists.isEmpty) continue;
      try {
        await db.execute(
          "UPDATE $table SET hlcMillis = updatedAtUtcMillis, hlcDeviceId = COALESCE(NULLIF(origin, ''), '$defaultDevice') WHERE hlcMillis = 0",
        );
      } catch (_) {
        // Table exists but column may not exist if ALTER failed for some reason; ignore.
      }
    }
  }

  /// One route per session, as the car encoded it.
  ///
  /// [updatedAtUtcMillis] is the car's write stamp, carried across so the
  /// cursor the phone holds and the row it holds say the same thing. The
  /// arrays stay as the car sent them, inside `row`: this table stores the
  /// route, it does not decode it.
  static const _createTracksTable = '''
    CREATE TABLE IF NOT EXISTS tracks (
      sessionId TEXT PRIMARY KEY,
      updatedAtUtcMillis INTEGER NOT NULL,
      pointCount INTEGER NOT NULL,
      dirty INTEGER NOT NULL DEFAULT 1,
      row TEXT NOT NULL
    )
  ''';

  /// Issue 226: the companion's event table, normalized. Issue 227: keyed by
  /// the backend's natural key, not the car's rowid.
  ///
  /// The legacy shape stored the whole wire map as a ~350-byte JSON string in
  /// a `row` column and indexed the mark with a full index. This shape
  /// promotes the queried fields to typed columns and indexes the mark with
  /// a partial index that holds only unsynced rows.
  ///
  /// The identity is [_createEventsNaturalIndex]: the cloud's
  /// `telemetry_events` primary key minus `vehicle_id`, because this store
  /// holds one car. The car's `id` stays as an ordinary column — it is the
  /// sync cursor's record id and the wire shape carries it — but it is no
  /// longer the row's identity. A reinstalled car restarts its rowid at 1,
  /// and under the old `id INTEGER PRIMARY KEY` every new event silently
  /// replaced the unrelated old event that wore the same number. `signalKey`
  /// is `NOT NULL DEFAULT 0` (0 = no signal or unknown key) because SQLite
  /// counts NULLs as distinct in a unique index, which would let keyless
  /// events duplicate instead of replacing.
  static const _createEventsTable = '''
    CREATE TABLE IF NOT EXISTS events (
      id INTEGER,
      sessionId TEXT,
      type INTEGER NOT NULL,
      occurredAtUtcMillis INTEGER NOT NULL,
      occurredAtElapsedNanos INTEGER NOT NULL DEFAULT 0,
      signalKey INTEGER NOT NULL DEFAULT 0,
      value TEXT,
      previousValue TEXT,
      dirty INTEGER NOT NULL DEFAULT 1
    )
  ''';

  /// The event's identity, minus `vehicle_id`: this store is one car.
  ///
  /// Same key the cloud upserts on (`cloud_uploader.dart`, `telemetry_events`
  /// `conflictColumns`), so a row is the same event locally and remotely.
  static const _createEventsNaturalIndex = '''
    CREATE UNIQUE INDEX IF NOT EXISTS events_natural
    ON events (occurredAtUtcMillis, occurredAtElapsedNanos, type, signalKey)
  ''';

  // --- The upload to the cloud ---------------------------------------------
  //
  // Every read here is a page over a stable order.

  Future<List<Map<String, Object?>>> dirtySessions({int limit = 200}) async {
    final rows = await _db.query(
      'sessions',
      columns: [_rowIdColumn, 'row'],
      where: 'dirty = 1',
      orderBy: 'startedAtUtcMillis ASC, id ASC',
      limit: limit,
    );
    return [
      for (final row in rows) {..._decode(row['row']), rowIdKey: row[rowIdKey]},
    ];
  }

  Future<List<Map<String, Object?>>> dirtyIntervals({int limit = 500}) async {
    final rows = await _db.query(
      'intervals',
      columns: [_rowIdColumn, 'row'],
      where: 'dirty = 1',
      orderBy: 'sessionId ASC, startUtcMillis ASC',
      limit: limit,
    );
    return [
      for (final row in rows) {..._decode(row['row']), rowIdKey: row[rowIdKey]},
    ];
  }

  Future<List<Map<String, Object?>>> dirtyEvents({int limit = 500}) async {
    final rows = await _db.query(
      'events',
      columns: [
        _rowIdColumn,
        'id',
        'sessionId',
        'type',
        'occurredAtUtcMillis',
        'occurredAtElapsedNanos',
        'signalKey',
        'value',
        'previousValue',
      ],
      where: 'dirty = 1',
      orderBy: 'id ASC',
      limit: limit,
    );
    return [
      for (final row in rows) {..._eventWireRow(row), rowIdKey: row[rowIdKey]},
    ];
  }

  Future<List<Map<String, Object?>>> dirtyCycles({int limit = 200}) async {
    final rows = await _db.query(
      'cycles',
      columns: [_rowIdColumn, 'ordinal', 'row'],
      where: 'dirty = 1',
      orderBy: 'ordinal ASC',
      limit: limit,
    );
    return [
      for (final row in rows)
        {
          ..._decode(row['row']),
          'ordinal': row['ordinal'],
          rowIdKey: row[rowIdKey],
        },
    ];
  }

  Future<List<Map<String, Object?>>> dirtyTracks({int limit = 200}) async {
    final rows = await _db.query(
      'tracks',
      columns: [_rowIdColumn, 'sessionId', 'row'],
      where: 'dirty = 1',
      orderBy: 'sessionId ASC',
      limit: limit,
    );
    return [
      for (final row in rows)
        {
          ..._decode(row['row']),
          'sessionId': row['sessionId'],
          rowIdKey: row[rowIdKey],
        },
    ];
  }

  Future<int> countDirtyRows() async {
    final counts = await Future.wait([
      _countWhere('sessions', 'dirty = ?', const [1]),
      _countWhere('intervals', 'dirty = ?', const [1]),
      _countWhere('events', 'dirty = ?', const [1]),
      _countWhere('cycles', 'dirty = ?', const [1]),
      _countWhere('tracks', 'dirty = ?', const [1]),
    ]);
    return counts.fold<int>(0, (sum, count) => sum + count);
  }

  Future<int> countTotalRows() async {
    final counts = await Future.wait([
      _count('sessions'),
      _count('intervals'),
      _count('events'),
      _count('cycles'),
      _count('tracks'),
    ]);
    return counts.fold<int>(0, (sum, count) => sum + count);
  }

  Future<SyncProgressData> getSyncProgress() async {
    final total = await countTotalRows();
    final dirty = await countDirtyRows();
    return SyncProgressData(totalCount: total, dirtyCount: dirty);
  }

  /// Marks every persisted row as dirty so a full re-upload can run.
  Future<void> markAllDirty() async {
    final batch = _db.batch();
    batch.update('sessions', const {'dirty': 1});
    batch.update('intervals', const {'dirty': 1});
    batch.update('events', const {'dirty': 1});
    batch.update('cycles', const {'dirty': 1});
    batch.update('tracks', const {'dirty': 1});
    await batch.commit(noResult: true);
  }

  /// Clears the mark on the rows named, and on no others.
  ///
  /// Named, rather than "everything that was dirty when the page was read":
  /// a row can be written again while the page is in flight, and a blanket
  /// clear would drop that new version silently.
  ///
  /// The name is the row's own sqlite `rowid`, taken with the page. It says
  /// the same thing the natural key said and it says it in one statement per
  /// page instead of one per row, which is what a page of thousands needs.
  /// It also says it more exactly: every write here is an
  /// `INSERT OR REPLACE`, so a row rewritten while the page was in flight is
  /// a **new** row with a new rowid, and this clear passes it by. The one
  /// table whose primary key is the rowid itself — `cycles` on `ordinal` —
  /// keeps the identity it already had.
  Future<void> clearDirtySessions(Iterable<int> rowIds) =>
      _clear('sessions', rowIds);

  Future<void> clearDirtyIntervals(Iterable<int> rowIds) =>
      _clear('intervals', rowIds);

  Future<void> clearDirtyEvents(Iterable<int> rowIds) =>
      _clear('events', rowIds);

  Future<void> clearDirtyCycles(Iterable<int> rowIds) =>
      _clear('cycles', rowIds);

  Future<void> clearDirtyTracks(Iterable<int> rowIds) =>
      _clear('tracks', rowIds);

  /// How many names one statement carries.
  ///
  /// SQLite has a ceiling on the host parameters of one statement, and the
  /// old builds of it that a phone can still carry put that ceiling at 999.
  /// A page longer than this becomes as many statements as it needs, which is
  /// still a handful where the old code wrote one per row.
  static const _clearChunk = 900;

  Future<void> _clear(String table, Iterable<int> rowIds) async {
    final ids = rowIds.toList(growable: false);
    if (ids.isEmpty) return;
    final batch = _db.batch();
    for (var start = 0; start < ids.length; start += _clearChunk) {
      final end = start + _clearChunk;
      final chunk = ids.sublist(start, end > ids.length ? ids.length : end);
      final marks = List.filled(chunk.length, '?').join(',');
      batch.update(
        table,
        const {'dirty': 0},
        where: 'rowid IN ($marks)',
        whereArgs: chunk,
      );
    }
    await batch.commit(noResult: true);
  }

  /// The vehicle a session belongs to, for the rows that carry only a session.
  Future<Map<String, String>> vehicleIdsForSessions(
    Iterable<String> sessionIds,
  ) async {
    final ids = sessionIds.toSet().toList();
    if (ids.isEmpty) return const {};
    final marks = List.filled(ids.length, '?').join(',');
    final rows = await _db.query(
      'sessions',
      columns: ['id', 'vehicleId'],
      where: 'id IN ($marks)',
      whereArgs: ids,
    );
    return {
      for (final row in rows) row['id'] as String: row['vehicleId'] as String,
    };
  }

  /// The distinct vehicle ids this phone has ever synced from, minus the
  /// `unassigned` placeholder.
  ///
  /// A control write targets a vehicle the phone owns; the phone learns which
  /// cars those are from the sessions it holds. Used by the Lane C provider to
  /// name the one vehicle a phone controls, or to refuse when it could not.
  Future<Set<String>> knownVehicleIds() async {
    final all = await sessions(limit: 0);
    final ids = <String>{
      for (final row in all)
        if (row['vehicleId'] is String) row['vehicleId'] as String,
    }..removeWhere((id) => id.isEmpty || id == 'unassigned');
    return ids;
  }

  // --- Sessions ------------------------------------------------------------

  Future<void> upsertSession(Map<String, Object?> row) async {
    final id = row['id'] as String?;
    if (id == null || id.isEmpty) {
      throw ArgumentError('session row needs id');
    }
    final kind =
        (row['kind'] as String?) ??
        (row.containsKey('plugConnectedAtUtcMillis') ||
                row.containsKey('chargeStartedAtUtcMillis')
            ? 'CHARGE'
            : 'TRIP');
    final status = (row['status'] as String?) ?? 'ACTIVE';
    final vehicleId = (row['vehicleId'] as String?) ?? 'unassigned';
    final startedAt =
        (row['startedAtUtcMillis'] as num?)?.toInt() ??
        (row['plugConnectedAtUtcMillis'] as num?)?.toInt() ??
        (row['chargeStartedAtUtcMillis'] as num?)?.toInt() ??
        0;
    final closed = _isClosedSession(row);

    await _db.insert('sessions', {
      'id': id,
      'vehicleId': vehicleId,
      'kind': kind,
      'status': status,
      'startedAtUtcMillis': startedAt,
      'closed': closed ? 1 : 0,
      // A session that arrives again — closed, priced, rolled up — owes the
      // cloud the new version of itself.
      'dirty': 1,
      'row': jsonEncode(row),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Cloud-sourced session: already in the replica, so not dirty for upload.
  Future<void> upsertSessionFromCloud(Map<String, Object?> row) async {
    final id = row['id'] as String?;
    if (id == null || id.isEmpty) {
      throw ArgumentError('session row needs id');
    }
    final kind =
        (row['kind'] as String?) ??
        (row.containsKey('plugConnectedAtUtcMillis') ||
                row.containsKey('chargeStartedAtUtcMillis')
            ? 'CHARGE'
            : 'TRIP');
    final status = (row['status'] as String?) ?? 'ACTIVE';
    final vehicleId = (row['vehicleId'] as String?) ?? 'unassigned';
    final startedAt =
        (row['startedAtUtcMillis'] as num?)?.toInt() ??
        (row['plugConnectedAtUtcMillis'] as num?)?.toInt() ??
        (row['chargeStartedAtUtcMillis'] as num?)?.toInt() ??
        0;
    final closed = _isClosedSession(row);
    await _db.insert('sessions', {
      'id': id,
      'vehicleId': vehicleId,
      'kind': kind,
      'status': status,
      'startedAtUtcMillis': startedAt,
      'closed': closed ? 1 : 0,
      'dirty': 0,
      'row': jsonEncode(row),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> upsertTrip(Map<String, Object?> row) =>
      upsertSession(row.containsKey('kind') ? row : {'kind': 'TRIP', ...row});

  Future<void> upsertCharge(Map<String, Object?> row) =>
      upsertSession(row.containsKey('kind') ? row : {'kind': 'CHARGE', ...row});

  Future<void> upsertCycle(Map<String, Object?> row) async {
    final ordinal = (row['ordinal'] as num?)?.toInt();
    if (ordinal == null) {
      throw ArgumentError('cycle row needs ordinal');
    }
    await _db.insert('cycles', {
      'ordinal': ordinal,
      'dirty': 1,
      'row': jsonEncode(row),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Cloud-sourced cycle: already in the replica, so not dirty.
  Future<void> upsertCycleFromCloud(Map<String, Object?> row) async {
    final ordinal = (row['ordinal'] as num?)?.toInt();
    if (ordinal == null) {
      throw ArgumentError('cycle row needs ordinal');
    }
    await _db.insert('cycles', {
      'ordinal': ordinal,
      'dirty': 0,
      'row': jsonEncode(row),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Sessions, newest first. [limit] of zero or less means every one of them.
  Future<List<Map<String, Object?>>> sessions({
    String? kind,
    int limit = 0,
  }) async {
    final rows = await _db.query(
      'sessions',
      columns: ['row'],
      where: kind != null ? 'kind = ?' : null,
      whereArgs: kind != null ? [kind] : null,
      orderBy: 'startedAtUtcMillis DESC, id DESC',
      limit: limit > 0 ? limit : null,
    );
    return [for (final row in rows) _decode(row['row'])];
  }

  /// Paged and filtered sessions query for [SqfliteStore].
  Future<List<Map<String, Object?>>> querySessionsFiltered({
    String? where,
    List<Object?>? whereArgs,
    int limit = 50,
    int offset = 0,
  }) async {
    final rows = await _db.query(
      'sessions',
      columns: ['row'],
      where: where,
      whereArgs: whereArgs,
      orderBy: 'startedAtUtcMillis DESC, id DESC',
      limit: limit > 0 ? limit : null,
      offset: offset > 0 ? offset : null,
    );
    return [for (final row in rows) _decode(row['row'])];
  }

  Future<int> countSessionsFiltered({String? where, List<Object?>? whereArgs}) {
    if (where != null) {
      return _countWhere('sessions', where, whereArgs ?? const []);
    }
    return _count('sessions');
  }

  /// Trips, newest first.
  Future<List<Map<String, Object?>>> trips({int limit = 0}) =>
      sessions(kind: 'TRIP', limit: limit);

  /// Charges, newest first.
  Future<List<Map<String, Object?>>> charges({int limit = 0}) =>
      sessions(kind: 'CHARGE', limit: limit);

  Future<Map<String, Object?>?> session(String id) async {
    final rows = await _db.query(
      'sessions',
      columns: ['row'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _decode(rows.first['row']);
  }

  Future<Map<String, Object?>?> trip(String id) => session(id);

  Future<Map<String, Object?>?> charge(String id) => session(id);

  Future<List<Map<String, Object?>>> cycles({int limit = 0}) async {
    final rows = await _db.query(
      'cycles',
      columns: ['row'],
      orderBy: 'ordinal DESC',
      limit: limit > 0 ? limit : null,
    );
    return [for (final row in rows) _decode(row['row'])];
  }

  Future<int> countSessions({String? kind}) {
    if (kind != null) {
      return _countWhere('sessions', 'kind = ?', [kind]);
    }
    return _count('sessions');
  }

  Future<int> countTrips() => countSessions(kind: 'TRIP');

  Future<int> countCharges() => countSessions(kind: 'CHARGE');

  Future<int> countCycles() => _count('cycles');

  Future<int> countIntervals() => _count('intervals');

  Future<void> upsertInterval(Map<String, Object?> row) async {
    final sessionId = row['sessionId'] as String?;
    final startUtcMillis = (row['startUtcMillis'] as num?)?.toInt();
    if (sessionId == null || startUtcMillis == null) {
      throw ArgumentError('interval row needs sessionId and startUtcMillis');
    }
    await _db.insert('intervals', {
      'sessionId': sessionId,
      'startUtcMillis': startUtcMillis,
      'dirty': 1,
      'row': jsonEncode(row),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Cloud-sourced interval: already in the replica, so not dirty.
  ///
  /// Time-authority T6: a pull carrying `time_state = uncorrectable` never
  /// overwrites a locally known row — the corrected minute already landed
  /// and the uncorrectable band must not move it back.
  ///
  /// Time-authority T9: a pull carrying `corrected_from_utc_millis` is the
  /// car's corrected re-upload — the wrong minute under the OLD key was
  /// deleted from the cloud, so the local replica must not keep showing the
  /// old minute either. The old-key row is removed when the corrected row
  /// lands, so the phone ends with exactly the cloud state: no duplicate
  /// minute, no orphaned wrong row.
  Future<void> upsertIntervalFromCloud(Map<String, Object?> row) async {
    final sessionId = row['sessionId'] as String?;
    final startUtcMillis = (row['startUtcMillis'] as num?)?.toInt();
    if (sessionId == null || startUtcMillis == null) {
      throw ArgumentError('interval row needs sessionId and startUtcMillis');
    }
    if (_isUncorrectable(row)) {
      final existing = await _db.query(
        'intervals',
        columns: ['row'],
        where: 'sessionId = ? AND startUtcMillis = ?',
        whereArgs: [sessionId, startUtcMillis],
        limit: 1,
      );
      for (final found in existing) {
        final current = _decode(found['row']);
        final currentState = current['timeState'] ?? current['time_state'];
        if (currentState == 'known') return;
      }
      // T9: an uncorrectable pull naming a key the correction already
      // removed must not resurrect it. The corrected row is the truth; the
      // band's key is the OLD stamp the correction replaced.
      final resurrect = await _db.query(
        'intervals',
        columns: ['row'],
        where: 'sessionId = ?',
        whereArgs: [sessionId],
        limit: 100,
      );
      for (final found in resurrect) {
        final current = _decode(found['row']);
        if (_marker(current) == startUtcMillis) return;
      }
    }
    // T9 merge: the corrected row names the key it replaced. The local
    // replica can still hold that wrong key (a pull saw it before the car
    // deleted it); dropping both rows would lose the minute, keeping both
    // would duplicate it. The wrong-key row is replaced by the corrected
    // one — exactly what the cloud did.
    final correctedFrom = _marker(row);
    if (correctedFrom != null) {
      await _db.delete(
        'intervals',
        where: 'sessionId = ? AND startUtcMillis = ?',
        whereArgs: [sessionId, correctedFrom],
      );
    }
    await _db.insert('intervals', {
      'sessionId': sessionId,
      'startUtcMillis': startUtcMillis,
      'dirty': 0,
      'row': jsonEncode(row),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// The stamp this row was corrected from, in either spelling, or null when
  /// the row was never corrected (no cloud deletion happened for it).
  int? _marker(Map<String, Object?> row) {
    final raw =
        row['correctedFromUtcMillis'] ?? row['corrected_from_utc_millis'];
    return raw is num ? raw.toInt() : null;
  }

  /// True when the row carries the uncorrectable mark in either spelling:
  /// the cloud speaks snake_case, the replica camelCase.
  bool _isUncorrectable(Map<String, Object?> row) {
    final state = row['timeState'] ?? row['time_state'];
    return state == 'uncorrectable';
  }

  /// Writes one route. The primary key is the session, so the row that
  /// arrives at close replaces the raw one taken during the drive rather than
  /// adding a second route to the same trip.
  Future<void> upsertTrack(Map<String, Object?> row) async {
    final sessionId = row['sessionId'] as String?;
    final pointCount = (row['pointCount'] as num?)?.toInt();
    if (sessionId == null || sessionId.isEmpty || pointCount == null) {
      throw ArgumentError('track row needs sessionId and pointCount');
    }
    await _db.insert('tracks', {
      'sessionId': sessionId,
      'updatedAtUtcMillis': (row['updatedAtUtcMillis'] as num?)?.toInt() ?? 0,
      'pointCount': pointCount,
      'dirty': 1,
      'row': jsonEncode(row),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Cloud-sourced track: already in the replica, so not dirty.
  Future<void> upsertTrackFromCloud(Map<String, Object?> row) async {
    final sessionId = row['sessionId'] as String?;
    final pointCount = (row['pointCount'] as num?)?.toInt();
    if (sessionId == null || sessionId.isEmpty || pointCount == null) {
      throw ArgumentError('track row needs sessionId and pointCount');
    }
    await _db.insert('tracks', {
      'sessionId': sessionId,
      'updatedAtUtcMillis': (row['updatedAtUtcMillis'] as num?)?.toInt() ?? 0,
      'pointCount': pointCount,
      'dirty': 0,
      'row': jsonEncode(row),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// The route of one session, or null when this phone has not received it.
  Future<Map<String, Object?>?> trackFor(String sessionId) async {
    final rows = await _db.query(
      'tracks',
      columns: ['row'],
      where: 'sessionId = ?',
      whereArgs: [sessionId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _decode(rows.first['row']);
  }

  /// How many routes this phone holds. The archive counts what it has.
  Future<int> trackCount() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS c FROM tracks');
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  Future<List<Map<String, Object?>>> intervalsFor(String sessionId) async {
    final rows = await _db.query(
      'intervals',
      columns: ['row'],
      where: 'sessionId = ?',
      whereArgs: [sessionId],
      orderBy: 'startUtcMillis ASC',
    );
    return [for (final row in rows) _decode(row['row'])];
  }

  Future<Set<String>> sessionsWithIntervals(List<String> sessionIds) async {
    if (sessionIds.isEmpty) return const {};
    final placeholders = List.filled(sessionIds.length, '?').join(',');
    final rows = await _db.query(
      'intervals',
      columns: ['sessionId'],
      distinct: true,
      where: 'sessionId IN ($placeholders)',
      whereArgs: sessionIds,
    );
    return {
      for (final row in rows)
        if (row['sessionId'] is String) row['sessionId'] as String,
    };
  }

  // --- Events --------------------------------------------------------------
  //
  // Issue 226: events stopped being a raw JSON blob in a `row` column. The
  // wire map the car sends is decoded once into typed columns, and the wire
  // shape is rebuilt on the way out for the store and the cloud uploader, so
  // neither learns the table changed. Issue 227: the row's identity moved
  // from the car's rowid to the natural key (see [_createEventsNaturalIndex]).

  /// The event types, in `SignalModels.kt` declaration order. The stored
  /// code is the position plus one; 0 means an unknown type. The list is
  /// append-only: reordering or renumbering breaks every stored row.
  static const _eventTypeCodes = <String>[
    'SIGNAL_UPDATED',
    'SIGNAL_UNAVAILABLE',
    'SIGNAL_ERROR',
    'VEHICLE_ACTIVITY_CHANGED',
    'TRIP_ARMED',
    'TRIP_CANCELLED',
    'TRIP_STARTED',
    'TRIP_RECOVERED',
    'TRIP_PENDING_END',
    'TRIP_ENDED',
    'CHARGE_PLUG_CONNECTED',
    'CHARGE_STARTED',
    'CHARGE_RECOVERED',
    'CHARGE_PAUSED',
    'CHARGE_ENDED',
    'CHARGE_PLUG_DISCONNECTED',
    'CHARGE_LIMIT_ARMED',
    'CHARGE_LIMIT_REACHED',
    'CHARGE_STOP_REQUESTED',
    'CHARGE_STOP_FAILED',
  ];

  /// The signal keys that can carry a session stamp — the car's
  /// unknown key stores 0 — the column is `NOT NULL` because the natural key
  /// cannot hold a NULL (SQLite counts NULLs as distinct in a unique index).
  /// Append-only like [_eventTypeCodes].
  static const _eventSignalKeyCodes = <String>[
    'GEAR',
    'HEADLIGHTS_SWITCH',
    'ADAS_ACC_CRUISE_MODE',
    'EV_CHARGE_STATE',
    'EV_CHARGE_PLUG_TYPE',
    'PEPS_POWER_MODE',
    'DOOR_MOVE',
  ];

  static int _eventTypeCode(String? type) {
    final index = type == null ? -1 : _eventTypeCodes.indexOf(type);
    return index < 0 ? 0 : index + 1;
  }

  static String? _eventTypeName(int code) =>
      code <= 0 || code > _eventTypeCodes.length
      ? null
      : _eventTypeCodes[code - 1];

  static int? _eventSignalKeyCode(String? key) {
    if (key == null) return null;
    final index = _eventSignalKeyCodes.indexOf(key);
    return index < 0 ? null : index + 1;
  }

  static String? _eventSignalKeyName(int? code) =>
      code == null || code <= 0 || code > _eventSignalKeyCodes.length
      ? null
      : _eventSignalKeyCodes[code - 1];

  /// The wire map's typed columns, as the table stores them.
  static Map<String, Object?> _eventColumns(
    Map<String, Object?> item, {
    required int dirty,
  }) => {
    'id': (item['id'] as num?)?.toInt(),
    'sessionId': item['sessionId'] as String?,
    'type': _eventTypeCode(item['type'] as String?),
    'occurredAtUtcMillis': (item['occurredAtUtcMillis'] as num?)?.toInt() ?? 0,
    'occurredAtElapsedNanos':
        (item['occurredAtElapsedNanos'] as num?)?.toInt() ?? 0,
    'signalKey':
        _eventSignalKeyCode(
          (item['signalId'] ?? item['signalKey']) as String?,
        ) ??
        0,
    'value': item['value']?.toString(),
    'previousValue': item['previousValue']?.toString(),
    'dirty': dirty,
  };

  /// The wire shape rebuilt from stored columns.
  static Map<String, Object?> _eventWireRow(Map<String, Object?> row) => {
    'id': row['id'],
    'sessionId': row['sessionId'],
    'type': _eventTypeName(row['type'] as int? ?? 0) ?? '',
    'occurredAtUtcMillis': row['occurredAtUtcMillis'],
    'occurredAtElapsedNanos': row['occurredAtElapsedNanos'],
    'signalId': _eventSignalKeyName(row['signalKey'] as int?),
    'value': row['value'],
    'previousValue': row['previousValue'],
  };

  /// Receiving an event. The identity is the natural key, not the car's
  /// rowid: a re-delivered event replaces its own row in place, and an event
  /// from a reinstalled car that happens to wear an old row number can no
  /// longer overwrite an unrelated stored event. `REPLACE` on the unique
  /// natural index is exactly the cloud's `merge: false` upsert semantics.
  Future<void> upsertEvent(Map<String, Object?> item) async {
    await _db.insert(
      'events',
      _eventColumns(item, dirty: 1),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Cloud-sourced event: already in the replica, so not dirty.
  Future<void> upsertEventFromCloud(Map<String, Object?> item) async {
    await _db.insert(
      'events',
      _eventColumns(item, dirty: 0),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, Object?>>> eventsForSession(String sessionId) async {
    final rows = await _db.query(
      'events',
      where: 'sessionId = ?',
      whereArgs: [sessionId],
      orderBy: 'occurredAtUtcMillis ASC, rowid ASC',
    );
    return [for (final row in rows) _eventWireRow(row)];
  }

  /// Issue 226 migration: normalize the legacy JSON-blob table in place.
  ///
  /// The rows the companion never queried — the orphans, `sessionId IS
  /// NULL`, which were most of the table — die here. The survivors are
  /// decoded once, stored typed, and marked `dirty = 0`: they predate the
  /// uploader's mark and are not going up. The legacy indexes travel with
  /// the renamed table, so the new ones are built only after it drops.
  static Future<void> _normalizeEvents(Database db) async {
    final tableRows = await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'events'",
    );
    if (tableRows.isEmpty) return;
    final legacyShape = await db.rawQuery(
      "SELECT 1 FROM pragma_table_info('events') WHERE name = 'row'",
    );
    if (legacyShape.isEmpty) return;
    await db.execute('ALTER TABLE events RENAME TO events_legacy');
    await db.execute(_createEventsTable);
    final legacy = await db.query('events_legacy');
    final batch = db.batch();
    for (final row in legacy) {
      if (row['sessionId'] is! String) continue;
      final item = _decode(row['row'] as String);
      final columns = _eventColumns(item, dirty: 0);
      // The legacy row's own id is the authority; the JSON copy is echo.
      columns['id'] = row['id'];
      batch.insert('events', columns);
    }
    await batch.commit(noResult: true);
    await db.execute('DROP TABLE events_legacy');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS events_session '
      'ON events (sessionId, occurredAtUtcMillis)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS events_dirty '
      'ON events (dirty, id) WHERE dirty = 1',
    );
  }

  /// Issue 227 migration: move the event identity from the car's rowid to
  /// the natural key.
  ///
  /// The v11 shape keyed `events` on the car's autoincrement `id`. A
  /// reinstalled car restarts that sequence at 1, and the blind `REPLACE`
  /// then rewrote the phone's stored history one row number at a time. This
  /// migration rebuilds the table under the natural key the cloud already
  /// upserts on, carrying every row across with its `id` demoted to an
  /// ordinary column and its `dirty` mark untouched.
  ///
  /// A natural-key collision among existing rows means the backend's own
  /// definition says they are the same event; `OR IGNORE` keeps the first
  /// and the walk stays idempotent. The car's receive timestamps are
  /// nanosecond-resolution, so real rows cannot collide by accident.
  static Future<void> _rekeyEvents(Database db) async {
    final tableRows = await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'events'",
    );
    if (tableRows.isEmpty) return;
    final indexRows = await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'events_natural'",
    );
    if (indexRows.isNotEmpty) return;
    // The natural index is absent, so the table still keys on the car's
    // rowid. The `id INTEGER PRIMARY KEY` probe misses the shape
    // `_normalizeEvents` leaves when a v10 database crosses v11 in the same
    // upgrade — `id` is then an ordinary column — and skipping the rebuild
    // on that shape ran the unique index against a table that still held
    // same-event duplicates, crashing the upgrade. Keying the rebuild on
    // the index instead covers both shapes; the copy below folds whatever
    // duplicates the key declares.
    await db.execute('DROP TABLE IF EXISTS events_legacy');
    await db.execute('ALTER TABLE events RENAME TO events_legacy');
    await db.execute(_createEventsTable);
    // The natural index must exist before the copy: `OR IGNORE` folds the
    // same-event duplicates the key declares at insert time. Creating the
    // index after the copy would instead fail on them.
    await db.execute(_createEventsNaturalIndex);
    await db.execute('''
      INSERT OR IGNORE INTO events
        (id, sessionId, type, occurredAtUtcMillis, occurredAtElapsedNanos,
         signalKey, value, previousValue, dirty)
      SELECT id, sessionId, type, occurredAtUtcMillis, occurredAtElapsedNanos,
        COALESCE(signalKey, 0), value, previousValue, dirty
      FROM events_legacy
    ''');
    await db.execute('DROP TABLE events_legacy');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS events_session '
      'ON events (sessionId, occurredAtUtcMillis)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS events_dirty '
      'ON events (dirty, id) WHERE dirty = 1',
    );
  }

  // --- Annotations (places, preferences, session costs, proposals) ----------

  static Map<String, Object?> _hlcFromRow(
    Map<String, Object?> row,
    int fallbackMillis,
    String fallbackDeviceId,
  ) {
    final hlcMillis =
        (row['hlcMillis'] as num?)?.toInt() ??
        (row['hlc'] is Map ? (row['hlc'] as Map)['millis'] as num? : null)
            ?.toInt() ??
        fallbackMillis;
    final hlcCounter =
        (row['hlcCounter'] as num?)?.toInt() ??
        (row['hlc'] is Map ? (row['hlc'] as Map)['counter'] as num? : null)
            ?.toInt() ??
        0;
    final hlcDeviceId =
        (row['hlcDeviceId'] as String?) ??
        (row['hlc'] is Map
            ? (row['hlc'] as Map)['deviceId'] as String?
            : null) ??
        fallbackDeviceId;
    return {
      'hlcMillis': hlcMillis,
      'hlcCounter': hlcCounter,
      'hlcDeviceId': hlcDeviceId,
    };
  }

  Future<void> upsertPlace(
    String id,
    int updatedAtUtcMillis,
    String origin,
    Map<String, Object?> row,
  ) async {
    final hlc = _hlcFromRow(row, updatedAtUtcMillis, origin);
    await _db.insert('places', {
      'id': id,
      'updatedAtUtcMillis': updatedAtUtcMillis,
      'origin': origin,
      'hlcMillis': hlc['hlcMillis'],
      'hlcCounter': hlc['hlcCounter'],
      'hlcDeviceId': hlc['hlcDeviceId'],
      'row': jsonEncode(row),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, Object?>>> allPlaces() async {
    final rows = await _db.query('places', columns: ['row']);
    return [for (final row in rows) _decode(row['row'])];
  }

  Future<void> upsertPreference(
    String scope,
    String key,
    int updatedAtUtcMillis,
    String origin,
    Map<String, Object?> row,
  ) async {
    final hlc = _hlcFromRow(row, updatedAtUtcMillis, origin);
    await _db.insert('preferences', {
      'scope': scope,
      'key': key,
      'updatedAtUtcMillis': updatedAtUtcMillis,
      'origin': origin,
      'hlcMillis': hlc['hlcMillis'],
      'hlcCounter': hlc['hlcCounter'],
      'hlcDeviceId': hlc['hlcDeviceId'],
      'row': jsonEncode(row),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, Object?>>> allPreferences() async {
    final rows = await _db.query('preferences', columns: ['row']);
    return [for (final row in rows) _decode(row['row'])];
  }

  Future<void> upsertSessionCost(
    String sessionId,
    int updatedAtUtcMillis,
    String origin,
    Map<String, Object?> row,
  ) async {
    final hlc = _hlcFromRow(row, updatedAtUtcMillis, origin);
    await _db.insert('session_costs', {
      'sessionId': sessionId,
      'updatedAtUtcMillis': updatedAtUtcMillis,
      'origin': origin,
      'hlcMillis': hlc['hlcMillis'],
      'hlcCounter': hlc['hlcCounter'],
      'hlcDeviceId': hlc['hlcDeviceId'],
      'row': jsonEncode(row),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, Object?>>> allSessionCosts() async {
    final rows = await _db.query('session_costs', columns: ['row']);
    return [for (final row in rows) _decode(row['row'])];
  }

  Future<Map<String, Object?>?> sessionCost(String sessionId) async {
    final rows = await _db.query(
      'session_costs',
      columns: ['row'],
      where: 'sessionId = ?',
      whereArgs: [sessionId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _decode(rows.first['row']);
  }

  Future<void> upsertPreferenceProposal(
    String id,
    int updatedAtUtcMillis,
    String origin,
    Map<String, Object?> row,
  ) async {
    final hlc = _hlcFromRow(row, updatedAtUtcMillis, origin);
    await _db.insert('preference_proposals', {
      'id': id,
      'updatedAtUtcMillis': updatedAtUtcMillis,
      'origin': origin,
      'hlcMillis': hlc['hlcMillis'],
      'hlcCounter': hlc['hlcCounter'],
      'hlcDeviceId': hlc['hlcDeviceId'],
      'row': jsonEncode(row),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, Object?>>> allPreferenceProposals() async {
    final rows = await _db.query('preference_proposals', columns: ['row']);
    return [for (final row in rows) _decode(row['row'])];
  }

  Future<void> upsertJourney(
    String id,
    int updatedAtUtcMillis,
    String origin,
    Map<String, Object?> row,
  ) async {
    final hlc = _hlcFromRow(row, updatedAtUtcMillis, origin);
    await _db.insert('journeys', {
      'id': id,
      'updatedAtUtcMillis': updatedAtUtcMillis,
      'origin': origin,
      'hlcMillis': hlc['hlcMillis'],
      'hlcCounter': hlc['hlcCounter'],
      'hlcDeviceId': hlc['hlcDeviceId'],
      'row': jsonEncode(row),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, Object?>>> allJourneys() async {
    final rows = await _db.query('journeys', columns: ['row']);
    return [for (final row in rows) _decode(row['row'])];
  }

  // --- Nominatim cache -------------------------------------------------------

  Future<Map<String, Object?>?> nominatimCacheFor(String cellKey) async {
    final rows = await _db.query(
      'nominatim_cache',
      where: 'cellKey = ?',
      whereArgs: [cellKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first;
  }

  Future<void> upsertNominatimCache({
    required String cellKey,
    required double latitude,
    required double longitude,
    required String displayName,
    required int fetchedAtUtcMillis,
  }) async {
    await _db.insert('nominatim_cache', {
      'cellKey': cellKey,
      'latitude': latitude,
      'longitude': longitude,
      'displayName': displayName,
      'fetchedAtUtcMillis': fetchedAtUtcMillis,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteNominatimCache(String cellKey) async {
    await _db.delete(
      'nominatim_cache',
      where: 'cellKey = ?',
      whereArgs: [cellKey],
    );
  }

  Future<int> countNominatimCache() => _count('nominatim_cache');

  // --- Annotation outbox ------------------------------------------------------

  /// Local edits that have not reached the car yet, oldest first.
  Future<List<({int id, String stream, Map<String, Object?> row})>>
  pendingAnnotationPush() async {
    final rows = await _db.query(
      'annotation_outbox',
      orderBy: 'createdAtUtcMillis ASC, id ASC',
    );
    return [
      for (final row in rows)
        (
          id: row['id'] as int,
          stream: row['stream'] as String,
          row: _decode(row['row']),
        ),
    ];
  }

  Future<void> enqueueAnnotationPush(
    String stream,
    Map<String, Object?> row,
  ) async {
    await _db.insert('annotation_outbox', {
      'stream': stream,
      'row': jsonEncode(row),
      'createdAtUtcMillis': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> removeAnnotationPush(int id) async {
    await _db.delete('annotation_outbox', where: 'id = ?', whereArgs: [id]);
  }

  /// Clears the annotation outbox, optionally filtered by [stream].
  ///
  /// After a successful cloud Lane B push, the corresponding outbox rows are
  /// drained here.
  Future<void> clearAnnotationOutbox({String? stream}) async {
    if (stream == null) {
      await _db.delete('annotation_outbox');
    } else {
      await _db.delete(
        'annotation_outbox',
        where: 'stream = ?',
        whereArgs: [stream],
      );
    }
  }

  Future<int> _count(String table) async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS n FROM $table');
    return (rows.first['n'] as num?)?.toInt() ?? 0;
  }

  Future<int> _countWhere(
    String table,
    String where,
    List<Object?> whereArgs,
  ) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM $table WHERE $where',
      whereArgs,
    );
    return (rows.first['n'] as num?)?.toInt() ?? 0;
  }

  Future<({double? lat, double? lon})> firstGpsPoint(String sessionId) async {
    final points = await _trackPointsFor(sessionId);
    if (points.isEmpty) return (lat: null, lon: null);
    return (lat: points.first.latitude, lon: points.first.longitude);
  }

  Future<({double? lat, double? lon})> lastGpsPoint(String sessionId) async {
    final points = await _trackPointsFor(sessionId);
    if (points.isEmpty) return (lat: null, lon: null);
    return (lat: points.last.latitude, lon: points.last.longitude);
  }

  /// The decoded Track points of a session, or an empty list when this phone
  /// has not received a route for it.
  Future<List<TrackPoint>> _trackPointsFor(String sessionId) async {
    final row = await trackFor(sessionId);
    if (row != null) {
      try {
        return TrackCodec.decode(trackRowFromWire(row));
      } on Object {
        // A row this build cannot read is not a route it may guess at.
        return const [];
      }
    }
    return const [];
  }

  /// Builds a decimated GPS path string (`lat,lon;lat,lon`) from the Track.
  Future<String?> gpsPath(String sessionId, {int maxPoints = 25}) async {
    final points = await _trackPointsFor(sessionId);
    if (points.isEmpty) return null;
    final step = math.max(1, points.length ~/ maxPoints);
    final buffer = StringBuffer();
    for (var i = 0; i < points.length; i += step) {
      final point = points[i];
      if (buffer.isNotEmpty) buffer.write(';');
      buffer.write(
        '${point.latitude.toStringAsFixed(5)},${point.longitude.toStringAsFixed(5)}',
      );
    }
    if ((points.length - 1) % step != 0) {
      final point = points.last;
      if (buffer.isNotEmpty) buffer.write(';');
      buffer.write(
        '${point.latitude.toStringAsFixed(5)},${point.longitude.toStringAsFixed(5)}',
      );
    }
    return buffer.isEmpty ? null : buffer.toString();
  }

  // --- Cursors -------------------------------------------------------------

  Future<Map<SyncStreamType, String>> cursors() async {
    final rows = await _db.query('cursors');
    final out = <SyncStreamType, String>{};
    for (final row in rows) {
      final stream = SyncStreamType.values.where(
        (type) => type.name == row['stream'],
      );
      if (stream.isEmpty) continue;
      out[stream.first] = row['recordId'] as String;
    }
    return out;
  }

  Future<void> setCursor(SyncStreamType stream, String recordId) async {
    await _db.insert('cursors', {
      'stream': stream.name,
      'recordId': recordId,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> clearCursor(SyncStreamType stream) async {
    await _db.delete('cursors', where: 'stream = ?', whereArgs: [stream.name]);
  }

  // --- Closed sessions with no samples yet ---------------------------------

  Future<List<String>> closedSessionIdsInOrder() async {
    final rows = await _db.rawQuery('''
      SELECT id, startedAtUtcMillis FROM sessions WHERE closed = 1
      ORDER BY startedAtUtcMillis ASC, id ASC
    ''');
    return [for (final row in rows) row['id'] as String];
  }

  // --- Generic meta (used for one-time migrations like cloud re-upload) -----

  Future<String?> readMeta(String key) async {
    final rows = await _db.query(
      'meta',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> writeMeta(String key, String value) async {
    await _db.insert('meta', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteMeta(String key) async {
    await _db.delete('meta', where: 'key = ?', whereArgs: [key]);
  }

  /// Deletes all meta entries whose key starts with [prefix].
  Future<void> deleteMetaByPrefix(String prefix) async {
    await _db.delete('meta', where: 'key LIKE ?', whereArgs: ['$prefix%']);
  }

  // --- Revision ------------------------------------------------------------

  Future<int> revision() async {
    final rows = await _db.query(
      'meta',
      where: 'key = ?',
      whereArgs: ['revision'],
      limit: 1,
    );
    if (rows.isEmpty) return 0;
    return int.tryParse(rows.first['value'] as String) ?? 0;
  }

  Future<void> setRevision(int value) async {
    await _db.insert('meta', {
      'key': 'revision',
      'value': '$value',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Map<String, Object?> _decode(Object? raw) =>
      jsonDecode(raw as String) as Map<String, Object?>;

  static bool _isClosedSession(Map<String, Object?> row) {
    final ended =
        (row['endedAtUtcMillis'] as num?)?.toInt() ??
        (row['plugDisconnectedAtUtcMillis'] as num?)?.toInt() ??
        (row['chargeEndedAtUtcMillis'] as num?)?.toInt();
    final status = row['status'] as String?;
    return ended != null && status != 'FINALIZATION_PENDING';
  }
}
