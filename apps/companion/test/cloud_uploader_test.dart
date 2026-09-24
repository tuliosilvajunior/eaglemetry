import 'package:capy_companion/sync/cloud_uploader.dart';
import 'package:capy_companion/sync/companion_archive.dart';
import 'package:capy_companion/runtime/companion_runtime.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/memory_archive.dart';

/// The sink a test uses. It records what it was asked to write and never
/// reaches a network.
class FakeCloudSink implements CloudSink {
  final List<
    ({
      String table,
      List<Map<String, Object?>> rows,
      List<String> conflictColumns,
      bool merge,
    })
  >
  writes = [];

  /// The table the next write must fail on, once.
  String? failOn;

  List<Map<String, Object?>> rowsFor(String table) => [
    for (final write in writes)
      if (write.table == table) ...write.rows,
  ];

  @override
  Future<void> upsert(
    String table,
    List<Map<String, Object?>> rows, {
    required List<String> conflictColumns,
    required bool merge,
  }) async {
    if (table == failOn) {
      failOn = null;
      throw StateError('refused $table');
    }
    writes.add((
      table: table,
      rows: rows,
      conflictColumns: conflictColumns,
      merge: merge,
    ));
  }

  /// Cars the cloud says belong to somebody else. A claim for one of these
  /// is accepted and then read back as absent, which is exactly what
  /// `ON CONFLICT DO NOTHING` does over a row another account owns.
  final Set<String> takenVehicles = {};

  /// How many times the run asked the cloud whose car this is.
  int ownershipReads = 0;

  @override
  Future<Set<String>> ownedVehicles(Set<String> ids) async {
    ownershipReads++;
    return ids.difference(takenVehicles);
  }

  final Map<String, List<Map<String, Object?>>> seededFetches = {};

  @override
  Future<List<Map<String, Object?>>> fetch(String table) async =>
      seededFetches[table] ?? const [];
  @override
  Future<List<Map<String, Object?>>> fetchRange(
    String table, {
    required int offset,
    required int limit,
  }) async {
    final all = await fetch(table);
    if (offset >= all.length) return const [];
    final end = (offset + limit).clamp(0, all.length);
    return all.sublist(offset, end);
  }
}

/// A sink that keeps the merge rule PostgREST keeps under
/// `Prefer: resolution=merge-duplicates`: on a conflict only the keys present
/// in the payload overwrite the stored row, so an omitted key leaves the
/// stored value alone while an explicit null wipes it. Keyed the way the
/// session upsert is keyed (`vehicle_id`, `id`).
class MergeStore implements CloudSink {
  final Map<String, Map<String, Object?>> sessions = {};

  @override
  Future<void> upsert(
    String table,
    List<Map<String, Object?>> rows, {
    required List<String> conflictColumns,
    required bool merge,
  }) async {
    for (final row in rows) {
      if (table == 'session') {
        final key = '${row['vehicle_id']}|${row['id']}';
        if (merge) {
          sessions[key] = {...?sessions[key], ...row};
        } else {
          sessions.putIfAbsent(key, () => Map.of(row));
        }
      }
    }
  }

  @override
  Future<Set<String>> ownedVehicles(Set<String> ids) async => ids;

  @override
  Future<List<Map<String, Object?>>> fetch(String table) async => const [];

  @override
  Future<List<Map<String, Object?>>> fetchRange(
    String table, {
    required int offset,
    required int limit,
  }) async => const [];
}

Future<Directory> _tempDir() async =>
    Directory.systemTemp.createTempSync('capy-upload-test');

Future<CompanionArchive> _archiveWithOneTrip() async {
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
  return archive;
}

/// A trip with exactly [intervals] intervals.
Future<CompanionArchive> _archiveWithIntervals(int intervals) async {
  final archive = await _archiveWithOneTrip();
  for (var i = 1; i <= intervals; i++) {
    await archive.upsertInterval({
      'sessionId': 'trip-1',
      'startUtcMillis': 1750000000000 + i * 60000,
      'widthMillis': 60000,
      'tractionWh': 100.0 + i,
      'updatedAtUtcMillis': 1750000060000 + i * 60000,
    });
  }
  return archive;
}

void main() {
  // `CompanionRuntime.start()` reaches the platform for the documents
  // directory, which needs a binding even when a test hands it an archive.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a name the car writes becomes the name Postgres holds', () {
    expect(snakeCase('startedAtUtcMillis'), 'started_at_utc_millis');
    expect(snakeCase('id'), 'id');
    expect(snakeCase('tUtcMillis'), 't_utc_millis');
  });

  test('the vehicle goes up before anything that names it', () async {
    final archive = await _archiveWithOneTrip();
    final sink = FakeCloudSink();
    await CloudUploader(
      database: archive.database,
      sink: sink,
      accountId: 'account-1',
    ).run();

    final order = [for (final write in sink.writes) write.table];
    expect(order.first, 'vehicle');
    expect(order.indexOf('session'), lessThan(order.indexOf('interval')));
  });

  test(
    'a row carries the account, the vehicle and the cloud spelling',
    () async {
      final archive = await _archiveWithOneTrip();
      final sink = FakeCloudSink();
      await CloudUploader(
        database: archive.database,
        sink: sink,
        accountId: 'account-1',
      ).run();

      final session = sink.rowsFor('session').single;
      expect(session['started_at_utc_millis'], 1750000000000);
      expect(session['account_id'], 'account-1');
      expect(session['vehicle_id'], 'VIN1');
      expect(session.containsKey('startedAtUtcMillis'), isFalse);

      final interval = sink.rowsFor('interval').single;
      expect(interval['vehicle_id'], 'VIN1');
      expect(interval['start_utc_millis'], 1750000000000);
    },
  );

  test('a session may be written again', () async {
    final archive = await _archiveWithOneTrip();
    final sink = FakeCloudSink();
    await CloudUploader(
      database: archive.database,
      sink: sink,
      accountId: 'account-1',
    ).run();

    bool mergeFor(String table) =>
        sink.writes.firstWhere((write) => write.table == table).merge;
    expect(mergeFor('session'), isTrue);
    expect(mergeFor('interval'), isTrue);
  });

  test(
    'a session recorded later still goes up when its uuid sorts first',
    () async {
      // The defect this pins: the first cursor was the session uuid, and a uuid
      // does not grow with arrival. A drive recorded today can sort before one
      // already uploaded, and it would then sit behind the cursor forever.
      final archive = await _archiveWithOneTrip();
      final sink = FakeCloudSink();
      final uploader = CloudUploader(
        database: archive.database,
        sink: sink,
        accountId: 'account-1',
      );
      await uploader.run();
      sink.writes.clear();

      await archive.upsertSession({
        'id': 'aaa-charge',
        'vehicleId': 'VIN1',
        'kind': 'CHARGE',
        'status': 'CLOSED',
        'startedAtUtcMillis': 1750000900000,
        'startedAtElapsedNanos': 1,
        'noLongerReducible': 0,
        'createdAtUtcMillis': 1750000900000,
        'updatedAtUtcMillis': 1750000900000,
      });

      final report = await uploader.run();
      expect(report.counts[CloudUploader.sessionStream], 1);
      expect(sink.rowsFor('session').single['id'], 'aaa-charge');
    },
  );

  test('a session that closes after its upload goes up again', () async {
    final archive = await memoryArchive();
    Map<String, Object?> trip(String status) => {
      'id': 'trip-1',
      'vehicleId': 'VIN1',
      'kind': 'TRIP',
      'status': status,
      'startedAtUtcMillis': 1750000000000,
      'startedAtElapsedNanos': 1,
      'noLongerReducible': 0,
      'createdAtUtcMillis': 1750000000000,
      'updatedAtUtcMillis': 1750000000000,
    };
    await archive.upsertSession(trip('ACTIVE'));

    final sink = FakeCloudSink();
    final uploader = CloudUploader(
      database: archive.database,
      sink: sink,
      accountId: 'account-1',
    );
    await uploader.run();
    expect(sink.rowsFor('session').single['status'], 'ACTIVE');

    sink.writes.clear();
    await archive.upsertSession(trip('CLOSED'));
    await uploader.run();
    // Without this the cloud would keep a drive that never ended: no end time,
    // no rollup, no end SOC.
    expect(sink.rowsFor('session').single['status'], 'CLOSED');
  });

  test(
    'a session with no vehicle yet waits, and takes its rows with it',
    () async {
      final archive = await memoryArchive();
      await archive.upsertSession({
        'id': 'trip-old',
        // What the phone's own schema defaults to for a session pulled before
        // the car minted its vehicle id.
        'vehicleId': 'unassigned',
        'kind': 'TRIP',
        'status': 'CLOSED',
        'startedAtUtcMillis': 1750000000000,
        'startedAtElapsedNanos': 1,
        'noLongerReducible': 0,
        'createdAtUtcMillis': 1750000000000,
        'updatedAtUtcMillis': 1750000000000,
      });
      await archive.upsertInterval({
        'sessionId': 'trip-old',
        'startUtcMillis': 1750000000000,
        'widthMillis': 60000,
        'updatedAtUtcMillis': 1750000060000,
      });

      final sink = FakeCloudSink();
      final report = await CloudUploader(
        database: archive.database,
        sink: sink,
        accountId: 'account-1',
      ).run();

      // The cloud enforces the vehicle with a foreign key. One such row would
      // fail the whole page, and the page would repeat forever.
      expect(report.movedNothing, isTrue);
      expect(sink.writes, isEmpty);
    },
  );

  test('a second run uploads nothing', () async {
    final archive = await _archiveWithOneTrip();
    final sink = FakeCloudSink();
    final uploader = CloudUploader(
      database: archive.database,
      sink: sink,
      accountId: 'account-1',
    );
    final first = await uploader.run();
    expect(first.movedNothing, isFalse);

    sink.writes.clear();
    final second = await uploader.run();
    expect(second.movedNothing, isTrue);
    expect(sink.writes, isEmpty);
  });

  test('a refused page is repeated, not skipped', () async {
    final archive = await _archiveWithOneTrip();
    final sink = FakeCloudSink()..failOn = 'session';
    final uploader = CloudUploader(
      database: archive.database,
      sink: sink,
      accountId: 'account-1',
    );

    await expectLater(uploader.run(), throwsStateError);
    expect(sink.rowsFor('session'), isEmpty);

    // The cursor did not move, so the next run carries the same page.
    final report = await uploader.run();
    expect(report.counts[CloudUploader.sessionStream], 1);
    expect(sink.rowsFor('session'), hasLength(1));
  });

  test('a cycle waits when the phone cannot say whose battery it is', () async {
    final archive = await _archiveWithOneTrip();
    await archive.upsertSession({
      'id': 'trip-2',
      'vehicleId': 'VIN2',
      'kind': 'TRIP',
      'status': 'CLOSED',
      'startedAtUtcMillis': 1750000100000,
      'startedAtElapsedNanos': 1,
      'noLongerReducible': 0,
      'createdAtUtcMillis': 1750000100000,
      'updatedAtUtcMillis': 1750000100000,
    });
    await archive.upsertCycle({'ordinal': 1, 'dischargePercent': 10.0});

    final sink = FakeCloudSink();
    await CloudUploader(
      database: archive.database,
      sink: sink,
      accountId: 'account-1',
    ).run();
    // Two vehicles and a cycle row that names neither. Uploading it under a
    // guess would merge two batteries into one history.
    expect(sink.rowsFor('battery_cycles'), isEmpty);
  });

  test('a cycle is keyed by its start time, not its ordinal', () async {
    final archive = await _archiveWithOneTrip();
    await archive.upsertCycle({
      'ordinal': 120,
      'startUtcMillis': 1750000000000,
      'dischargePercent': 10.0,
    });

    final sink = FakeCloudSink();
    await CloudUploader(
      database: archive.database,
      sink: sink,
      accountId: 'account-1',
    ).run();

    final cycleWrites = sink.writes
        .where((write) => write.table == 'battery_cycles')
        .toList();
    expect(cycleWrites, hasLength(1));
    // The cloud resolves the upsert against (vehicle_id, start_utc_millis):
    // an ordinal is a ledger position that a rebuild renumbers, a start time
    // is the cycle itself.
    expect(cycleWrites.single.conflictColumns, [
      'vehicle_id',
      'start_utc_millis',
    ]);
    expect(cycleWrites.single.rows.single['ordinal'], 120);
    expect(cycleWrites.single.rows.single['start_utc_millis'], 1750000000000);
  });

  test(
    'the same cycle uploaded twice keeps one key and replaces itself',
    () async {
      final archive = await _archiveWithOneTrip();
      await archive.upsertCycle({
        'ordinal': 120,
        'startUtcMillis': 1750000000000,
        'dischargePercent': 10.0,
      });
      final sink = FakeCloudSink();
      final uploader = CloudUploader(
        database: archive.database,
        sink: sink,
        accountId: 'account-1',
      );
      await uploader.run();

      // The open cycle is refolded and grows: same ordinal, same start, more
      // of the story. The local mirror replaces it by ordinal, the cloud must
      // replace it by start time.
      await archive.upsertCycle({
        'ordinal': 120,
        'startUtcMillis': 1750000000000,
        'dischargePercent': 12.5,
      });
      await uploader.run();

      final uploads = sink.rowsFor('battery_cycles');
      expect(uploads, hasLength(2));
      expect(uploads.last['vehicle_id'], uploads.first['vehicle_id']);
      expect(
        uploads.last['start_utc_millis'],
        uploads.first['start_utc_millis'],
      );
      expect(uploads.last['discharge_percent'], 12.5);
      // Both writes resolve against the same row in the cloud: nothing
      // duplicates and nothing else is touched.
      expect(
        sink.writes
            .where((write) => write.table == 'battery_cycles')
            .map((write) => write.conflictColumns),
        everyElement(['vehicle_id', 'start_utc_millis']),
      );
    },
  );

  test('a renumbered ledger does not overwrite a different cycle', () async {
    final archive = await _archiveWithOneTrip();
    await archive.upsertCycle({
      'ordinal': 120,
      'startUtcMillis': 1750000000000,
      'dischargePercent': 10.0,
    });
    final sink = FakeCloudSink();
    final uploader = CloudUploader(
      database: archive.database,
      sink: sink,
      accountId: 'account-1',
    );
    await uploader.run();

    // The car was rebuilt and its ledger shrank: the new cycle 120 is a
    // different drive on a different day. Under the ordinal key this upload
    // would replace the old cycle 120 and destroy its cost blend; under the
    // start-time key it lands beside it.
    await archive.upsertCycle({
      'ordinal': 120,
      'startUtcMillis': 1750900000000,
      'dischargePercent': 4.0,
    });
    await uploader.run();

    final uploads = sink.rowsFor('battery_cycles');
    expect(uploads, hasLength(2));
    expect(uploads.first['ordinal'], uploads.last['ordinal']);
    expect(uploads.first['start_utc_millis'], 1750000000000);
    expect(uploads.last['start_utc_millis'], 1750900000000);
    // The two rows carry different cloud keys, so the second upsert cannot
    // reach the first cycle's row.
    expect(
      uploads.first['start_utc_millis'],
      isNot(uploads.last['start_utc_millis']),
    );
  });

  test('a phone with no account uploads nothing and does not fail', () async {
    final archive = await _archiveWithOneTrip();
    final runtime = CompanionRuntime(archive: archive, documents: _tempDir);
    await runtime.start();
    // No project is compiled into a test build and nobody is signed in. That
    // is a working phone, not a failure: the archive is local either way.
    expect(await runtime.uploadToCloud(), isNull);
  });

  test('the runtime runs the uploader it was given', () async {
    final archive = await _archiveWithOneTrip();
    final sink = FakeCloudSink();
    final runtime = CompanionRuntime(archive: archive, documents: _tempDir)
      ..uploaderFactory = (database) =>
          CloudUploader(database: database, sink: sink, accountId: 'account-1');
    await runtime.start();
    final report = await runtime.uploadToCloud();
    expect(report?.movedNothing, isFalse);
    expect(sink.rowsFor('session'), hasLength(1));
  });

  test(
    'a car another account owns stops the run before a session is offered',
    () async {
      final archive = await _archiveWithOneTrip();
      final sink = FakeCloudSink()..takenVehicles.add('VIN1');
      final uploader = CloudUploader(
        database: archive.database,
        sink: sink,
        accountId: 'account-2',
      );

      await expectLater(
        uploader.run(),
        throwsA(
          isA<CloudVehicleTaken>().having(
            (e) => e.vehicleId,
            'vehicleId',
            'VIN1',
          ),
        ),
      );

      // The claim itself is still made: it is what makes the read-back mean
      // anything. What must not happen is a measurement offered under an owner
      // the cloud will refuse two tables later.
      expect(sink.rowsFor('vehicle'), hasLength(1));
      expect(sink.rowsFor('session'), isEmpty);
    },
  );

  test('a run claims the vehicle once, however many pages it takes', () async {
    final archive = await _archiveWithIntervals(20);
    final sink = FakeCloudSink();
    final uploader = CloudUploader(
      database: archive.database,
      sink: sink,
      accountId: 'account-1',
      pageSize: 2,
      bulkPageSize: 3,
    );
    // Bounded: one page per stream per run. Drain in batches over time.
    var runs = 0;
    while (await archive.database.countDirtyRows() > 0) {
      await uploader.run();
      runs++;
    }

    // All 21 intervals eventually arrived, but not in one burst.
    expect(sink.rowsFor('interval'), hasLength(21));
    expect(runs, greaterThan(1));
    // Each run claims the vehicle at most once.
    expect(sink.rowsFor('vehicle').length, runs);
    expect(sink.ownershipReads, runs);
  });

  test('the name this phone gives a row does not reach the cloud', () async {
    final archive = await _archiveWithIntervals(4);
    final sink = FakeCloudSink();
    await CloudUploader(
      database: archive.database,
      sink: sink,
      accountId: 'account-1',
      bulkPageSize: 2,
    ).run();

    // The sqlite rowid rides with the page so the mark can be cleared in one
    // statement. It names a row in this database and nothing else, and a wipe
    // restarts it, so it must not become a column in the cloud.
    for (final write in sink.writes) {
      for (final row in write.rows) {
        expect(row.keys.where((key) => key.startsWith('_')), isEmpty);
        expect(row.containsKey('_row_id'), isFalse);
      }
    }
  });

  test(
    'an unset column leaves the phone as an absent key, never a null',
    () async {
      final archive = await memoryArchive();
      // What the car actually sends while a session is open: every unset column
      // rides along as an explicit null.
      await archive.upsertSession({
        'id': 'trip-1',
        'vehicleId': 'VIN1',
        'kind': 'TRIP',
        'status': 'ACTIVE',
        'startedAtUtcMillis': 1750000000000,
        'startedAtElapsedNanos': 1,
        'endedAtUtcMillis': null,
        'endSocPercent': null,
        'noLongerReducible': 0,
        'createdAtUtcMillis': 1750000000000,
        'updatedAtUtcMillis': 1750000000000,
      });
      final sink = FakeCloudSink();
      await CloudUploader(
        database: archive.database,
        sink: sink,
        accountId: 'account-1',
      ).run();

      final session = sink.rowsFor('session').single;
      expect(session['status'], 'ACTIVE');
      expect(session.containsKey('ended_at_utc_millis'), isFalse);
      expect(session.containsKey('end_soc_percent'), isFalse);
    },
  );

  test(
    'a close re-upload without a set column leaves the stored value alone',
    () async {
      // Pins the merge contract PostgREST keeps: with
      // `Prefer: resolution=merge-duplicates` only the keys present in the
      // payload reach `ON CONFLICT ... DO UPDATE`, so an omitted key keeps
      // its value while an explicit null would wipe it. The fake below keeps
      // that rule, and the uploader must feed it payloads it cannot wipe with.
      final store = MergeStore();
      final archive = await memoryArchive();
      Map<String, Object?> trip(String status, {Object? endSoc}) => {
        'id': 'trip-1',
        'vehicleId': 'VIN1',
        'kind': 'TRIP',
        'status': status,
        'startedAtUtcMillis': 1750000000000,
        'startedAtElapsedNanos': 1,
        if (endSoc case final s) 'endSocPercent': s,
        'noLongerReducible': 0,
        'createdAtUtcMillis': 1750000000000,
        'updatedAtUtcMillis': 1750000000000,
      };
      // The open upload sets the end SOC; the close upload no longer carries it.
      await archive.upsertSession(trip('ACTIVE', endSoc: 42.0));
      final uploader = CloudUploader(
        database: archive.database,
        sink: store,
        accountId: 'account-1',
      );
      await uploader.run();
      await archive.upsertSession(trip('CLOSED'));
      await uploader.run();

      expect(store.sessions.values.single['status'], 'CLOSED');
      expect(store.sessions.values.single['end_soc_percent'], 42.0);
    },
  );
  test('every page clears its own mark, so a second run is empty', () async {
    final archive = await _archiveWithIntervals(20);
    final sink = FakeCloudSink();
    CloudUploader uploader() => CloudUploader(
      database: archive.database,
      sink: sink,
      accountId: 'account-1',
      pageSize: 2,
      bulkPageSize: 3,
    );

    // Drain the backlog in batches.
    while (await archive.database.countDirtyRows() > 0) {
      await uploader().run();
    }
    expect(await archive.database.countDirtyRows(), 0);

    final second = await uploader().run();
    expect(second.movedNothing, isTrue);
  });

  Map<String, Object?> trackRow({
    String sessionId = 'trip-1',
    int pointCount = 3,
  }) => {
    'sessionId': sessionId,
    'encodingVersion': 1,
    'pointCount': pointCount,
    't': '[0,5000,5000]',
    'path': 'a_track_path',
    'speed': '[400,500,600]',
    'alt': '[7600,50,50]',
    'updatedAtUtcMillis': 1750000060000,
  };

  test('a session uploads exactly one Track row', () async {
    final archive = await _archiveWithOneTrip();
    await archive.upsertTrack(trackRow());
    final sink = FakeCloudSink();
    final report = await CloudUploader(
      database: archive.database,
      sink: sink,
      accountId: 'account-1',
    ).run();

    expect(sink.rowsFor('track'), hasLength(1));
    expect(report.counts[CloudUploader.trackStream], 1);

    final track = sink.rowsFor('track').single;
    expect(track['session_id'], 'trip-1');
    expect(track['vehicle_id'], 'VIN1');
    expect(track['point_count'], 3);
    expect(track.containsKey('sessionId'), isFalse);
  });

  test('uploading the same session again replaces its Track row', () async {
    final archive = await _archiveWithOneTrip();
    await archive.upsertTrack(trackRow());
    final sink = FakeCloudSink();
    final uploader = CloudUploader(
      database: archive.database,
      sink: sink,
      accountId: 'account-1',
    );
    await uploader.run();

    bool mergeFor(String table) =>
        sink.writes.firstWhere((write) => write.table == table).merge;
    // A row already present is replaced, not left alone — the same rule a
    // session that closes needs, because the car keeps rewriting this row
    // as the drive continues.
    expect(mergeFor('track'), isTrue);
  });

  test(
    'a Track that grew while the session was open converges to the final version',
    () async {
      final archive = await _archiveWithOneTrip();
      // The raw row while the drive is still running.
      await archive.upsertTrack(trackRow(pointCount: 3));
      // The simplified, final row the car writes at close.
      await archive.upsertTrack(trackRow(pointCount: 7));

      final sink = FakeCloudSink();
      await CloudUploader(
        database: archive.database,
        sink: sink,
        accountId: 'account-1',
      ).run();

      // One row for the session, carrying the version the car settled on —
      // never the raw one it wrote first.
      expect(sink.rowsFor('track'), hasLength(1));
      expect(sink.rowsFor('track').single['point_count'], 7);
    },
  );

  test('the upload report counts rows and bytes per stream', () async {
    final archive = await _archiveWithOneTrip();
    await archive.upsertTrack(trackRow());
    final sink = FakeCloudSink();
    final report = await CloudUploader(
      database: archive.database,
      sink: sink,
      accountId: 'account-1',
    ).run();

    expect(report.counts[CloudUploader.trackStream], 1);
    expect(report.bytes[CloudUploader.trackStream], greaterThan(0));
    // Every stream that moved a row reports the bytes it moved, not only
    // the Track — a deployer diffs the whole report, before and after.
    expect(report.counts[CloudUploader.sessionStream], 1);
    expect(report.bytes[CloudUploader.sessionStream], greaterThan(0));
    expect(report.totalBytes, report.bytes.values.fold(0, (a, b) => a + b));
  });

  test('a refused Track page is repeated, not skipped', () async {
    final archive = await _archiveWithOneTrip();
    await archive.upsertTrack(trackRow());
    final sink = FakeCloudSink()..failOn = 'track';
    final uploader = CloudUploader(
      database: archive.database,
      sink: sink,
      accountId: 'account-1',
    );

    await expectLater(uploader.run(), throwsStateError);
    expect(sink.rowsFor('track'), isEmpty);

    // The cursor did not move, so the next run carries the same page, and
    // the repeat is a no-op rather than a second row.
    sink.writes.clear();
    final report = await uploader.run();
    expect(report.counts[CloudUploader.trackStream], 1);
    expect(sink.rowsFor('track'), hasLength(1));

    sink.writes.clear();
    final third = await uploader.run();
    expect(third.counts[CloudUploader.trackStream], isNull);
    expect(sink.rowsFor('track'), isEmpty);
  });

  test('the first drain is bounded to one page per stream per run', () async {
    // After the pending mark lands every historical row reads dirty. A single
    // run that drained the whole backlog would burst thousands of rows. The
    // bound is one page per stream per run — the backlog drains over time.
    final archive = await memoryArchive();
    for (var i = 0; i < 7; i++) {
      await archive.upsertSession({
        'id': 'trip-$i',
        'vehicleId': 'VIN1',
        'kind': 'TRIP',
        'status': 'CLOSED',
        'startedAtUtcMillis': 1750000000000 + i * 1000,
        'startedAtElapsedNanos': 1 + i,
        'noLongerReducible': 0,
        'createdAtUtcMillis': 1750000000000 + i * 1000,
        'updatedAtUtcMillis': 1750000000000 + i * 1000,
      });
    }
    final sink = FakeCloudSink();
    final uploader = CloudUploader(
      database: archive.database,
      sink: sink,
      accountId: 'account-1',
      pageSize: 3,
      bulkPageSize: 3,
    );

    final first = await uploader.run();
    expect(first.counts[CloudUploader.sessionStream], 3);
    expect(sink.rowsFor('session'), hasLength(3));
    // Four remain dirty — they were not sent in the first burst.
    expect(await archive.database.countDirtyRows(), 4);

    sink.writes.clear();
    final second = await uploader.run();
    expect(second.counts[CloudUploader.sessionStream], 3);
    expect(sink.rowsFor('session'), hasLength(3));
    expect(await archive.database.countDirtyRows(), 1);

    sink.writes.clear();
    final third = await uploader.run();
    expect(third.counts[CloudUploader.sessionStream], 1);
    expect(sink.rowsFor('session'), hasLength(1));
    expect(await archive.database.countDirtyRows(), 0);

    sink.writes.clear();
    final fourth = await uploader.run();
    expect(fourth.movedNothing, isTrue);
  });

  test('reports progress as streams are uploaded', () async {
    final archive = await _archiveWithOneTrip();
    final sink = FakeCloudSink();
    final uploader = CloudUploader(
      database: archive.database,
      sink: sink,
      accountId: 'account-1',
    );

    final progressReports = <CloudUploadProgress>[];
    await uploader.run(onProgress: progressReports.add);

    expect(progressReports, isNotEmpty);
    expect(progressReports.first.uploaded, 0);
    expect(progressReports.last.uploaded, progressReports.last.total);
    expect(progressReports.last.fraction, 1.0);
  });

  test(
    'skips measurement upload when car_direct_upload_active is true via predicate',
    () async {
      final archive = await _archiveWithOneTrip();
      final sink = FakeCloudSink();
      final uploader = CloudUploader(
        database: archive.database,
        sink: sink,
        accountId: 'account-1',
        isCarDirectUploadActive: () => true,
      );

      final report = await uploader.run();

      expect(report.movedNothing, isTrue);
      expect(sink.writes, isEmpty);
      expect(await archive.database.countDirtyRows(), greaterThan(0));
    },
  );

  test(
    'skips measurement upload when phone_cutover_readiness has car_direct_upload_active for active vehicle',
    () async {
      final archive = await _archiveWithOneTrip();
      final sink = FakeCloudSink();
      sink.seededFetches['phone_cutover_readiness'] = [
        {'vehicle_id': 'VIN1', 'car_direct_upload_active': true},
      ];
      final uploader = CloudUploader(
        database: archive.database,
        sink: sink,
        accountId: 'account-1',
        activeVehicleIdProvider: () => 'VIN1',
      );

      final report = await uploader.run();

      expect(report.movedNothing, isTrue);
      expect(sink.writes, isEmpty);
    },
  );

  test(
    'does not skip measurement upload when direct upload is active for another vehicle in account (F1 multi-vehicle)',
    () async {
      final archive = await _archiveWithOneTrip();
      final sink = FakeCloudSink();
      sink.seededFetches['phone_cutover_readiness'] = [
        {'vehicle_id': 'OTHER_VIN', 'car_direct_upload_active': true},
        {'vehicle_id': 'VIN1', 'car_direct_upload_active': false},
      ];
      final uploader = CloudUploader(
        database: archive.database,
        sink: sink,
        accountId: 'account-1',
        activeVehicleIdProvider: () => 'VIN1',
      );

      final report = await uploader.run();

      expect(report.counts[CloudUploader.sessionStream], 1);
      expect(sink.rowsFor('session'), hasLength(1));
    },
  );

  test(
    'does not skip upload when vehicle pairing is inactive even if stale cloud flag is true (F2 stale flag defense)',
    () async {
      final archive = await _archiveWithOneTrip();
      final sink = FakeCloudSink();
      sink.seededFetches['phone_cutover_readiness'] = [
        {'vehicle_id': 'VIN1', 'car_direct_upload_active': true},
      ];
      final uploader = CloudUploader(
        database: archive.database,
        sink: sink,
        accountId: 'account-1',
        activeVehicleIdProvider: () => null,
      );

      final report = await uploader.run();

      expect(report.counts[CloudUploader.sessionStream], 1);
      expect(sink.rowsFor('session'), hasLength(1));
    },
  );

  test(
    'runs measurement upload when car_direct_upload_active is false',
    () async {
      final archive = await _archiveWithOneTrip();
      final sink = FakeCloudSink();
      sink.seededFetches['phone_cutover_readiness'] = [
        {'vehicle_id': 'VIN1', 'car_direct_upload_active': false},
      ];
      final uploader = CloudUploader(
        database: archive.database,
        sink: sink,
        accountId: 'account-1',
        activeVehicleIdProvider: () => 'VIN1',
      );

      final report = await uploader.run();

      expect(report.counts[CloudUploader.sessionStream], 1);
      expect(sink.rowsFor('session'), hasLength(1));
    },
  );
}
