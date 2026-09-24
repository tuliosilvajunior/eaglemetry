import 'dart:async';
import 'dart:convert';

import 'companion_database.dart';

/// Where an uploaded row goes.
///
/// The uploader knows the shape of a row and the order of the streams. It does
/// not know the provider. That keeps the rule the account layer already
/// follows: **one file knows it is Supabase**, and a provider error never
/// reaches a screen as server text.
abstract class CloudSink {
  /// Writes [rows] into [table].
  ///
  /// [conflictColumns] names the key that makes a replay a no-op. When
  /// [merge] is false a row already present is left exactly as it is; when it
  /// is true the row is replaced, which is what a session that closed after
  /// its first upload needs.
  Future<void> upsert(
    String table,
    List<Map<String, Object?>> rows, {
    required List<String> conflictColumns,
    required bool merge,
  });

  /// Which of [ids] this account owns.
  ///
  /// The read is scoped by the cloud's own rules, so an id that belongs to
  /// somebody else comes back absent rather than as a row with another owner.
  /// It is asked after the claim, never before: two phones claiming at once
  /// would both read "free" and one of them would be wrong.
  Future<Set<String>> ownedVehicles(Set<String> ids);

  /// Reads annotation rows from [table] that this account may see.
  ///
  /// Used by the annotation pull path. RLS scopes the result, so no explicit
  /// filter is needed here — the fake sink simply returns what it was seeded
  /// with. A no-op sink returns an empty list.
  Future<List<Map<String, Object?>>> fetch(String table) async => const [];

  /// Paginated read of [table] for telemetry pull.
  ///
  /// Default falls back to [fetch] + slice so fakes need not implement it.
  /// Production uses PostgREST `Range` header to avoid loading 50k rows in
  /// one response.
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

/// The rows and the bytes one stream moved.
///
/// The two travel together everywhere a report is read, so they are one
/// value here rather than two maps a caller has to index in step.
class StreamUploadStats {
  const StreamUploadStats({required this.rows, required this.bytes});

  final int rows;
  final int bytes;

  StreamUploadStats operator +(StreamUploadStats other) =>
      StreamUploadStats(rows: rows + other.rows, bytes: bytes + other.bytes);

  @override
  String toString() => '$rows rows, $bytes bytes';
}

/// What one upload run moved.
///
/// A deployer runs this before and after a format change and diffs the two
/// reports, so a claimed saving is measured rather than asserted. See issue
/// 185 and the parent 173.
class CloudUploadReport {
  const CloudUploadReport(this.perStream);

  const CloudUploadReport.empty() : perStream = const {};

  final Map<String, StreamUploadStats> perStream;

  /// Rows per stream, for a caller that only asks about counts.
  Map<String, int> get counts => {
    for (final entry in perStream.entries) entry.key: entry.value.rows,
  };

  /// Bytes per stream, for a caller that only asks about size.
  Map<String, int> get bytes => {
    for (final entry in perStream.entries) entry.key: entry.value.bytes,
  };

  int get total => perStream.values.fold(0, (sum, stats) => sum + stats.rows);

  int get totalBytes =>
      perStream.values.fold(0, (sum, stats) => sum + stats.bytes);

  bool get movedNothing => total == 0;

  @override
  String toString() => 'CloudUploadReport($perStream)';
}

/// Progress of a cloud upload in flight.
class CloudUploadProgress {
  const CloudUploadProgress({
    required this.uploaded,
    required this.total,
    this.currentStream,
  });

  final int uploaded;
  final int total;
  final String? currentStream;

  double get fraction => total <= 0 ? 1.0 : (uploaded / total).clamp(0.0, 1.0);

  @override
  String toString() =>
      'CloudUploadProgress($uploaded/$total, stream: $currentStream)';
}

/// Pushes what this phone holds into the cloud replica.
///
/// Three rules decide everything here:
///
/// * **what owes an upload is a mark per row, not a cursor.** A cursor can
///   only be a position in an order, and the orders here are the natural keys
///   — a session's uuid first among them. A uuid does not grow with arrival,
///   so a session recorded today can sort before one uploaded last week and
///   would sit behind the cursor forever. The mark also answers the second
///   question a cursor cannot: a row already uploaded has **changed**, which
///   every open session does when it closes. It is the phone's own mark, and
///   it is not the car's ack cursor: the car is acked for what reached the
///   phone, and this records what reached Postgres;
/// * **idempotency is on the vehicle and the session's uuid**, never on an
///   integer id. A wipe restarts the car's row ids at 1, so the same vehicle's
///   older cloud rows would collide with them. The device-local ids are
///   dropped on the way out for exactly that reason;
/// * **the order is not free.** A measurement row names a vehicle, and the
///   cloud enforces it, so the vehicle goes first and the sessions before
///   anything that hangs off them. A run that stops halfway leaves a shorter
///   history, never a broken one.
class CloudUploader {
  CloudUploader({
    required CompanionDatabase database,
    required this.sink,
    required this.accountId,
    this.pageSize = 500,
    this.bulkPageSize = 5000,
    this.isCarDirectUploadActive,
    this.activeVehicleIdsProvider,
    String? Function()? activeVehicleIdProvider,
  }) : _db = database,
       _activeVehicleIdProvider = activeVehicleIdProvider;

  final CompanionDatabase _db;
  final String? Function()? _activeVehicleIdProvider;

  /// Optional provider for the vehicle ID(s) actively paired with this phone.
  /// Used to scope `car_direct_upload_active` checks per vehicle rather than account-wide.
  final Iterable<String> Function()? activeVehicleIdsProvider;

  /// Where a row goes. A test gives it a fake and never reaches a network.
  final CloudSink sink;

  /// The account every uploaded row is stamped with.
  ///
  /// It is denormalised onto every measurement row on purpose: ownership is a
  /// Row Level Security policy, and a policy that had to join to find the
  /// owner would be a join per row checked.
  final String accountId;

  /// How many rows of a stream one page carries.
  ///
  /// It is the page of the streams that count one row per thing that
  /// happened: a session, a battery cycle. There are few of them and they are
  /// wide, so the page stays small.
  final int pageSize;

  /// The page of the streams that count one row per measurement.
  ///
  /// A sample is narrow and there are hundreds of thousands of them, so the
  /// cost of moving them is the number of requests, not their size. A page of
  /// 500 made an archive of 200,000 samples into 400 round trips; this makes
  /// it 40. The loss is that a request refused repeats a bigger page, which
  /// is safe because every write is keyed, only slower.
  final int bulkPageSize;

  /// Optional signal predicate for checking if the car is directly uploading.
  /// When not provided, falls back to querying `phone_cutover_readiness` via [sink].
  final FutureOr<bool> Function()? isCarDirectUploadActive;

  /// The vehicles this run already claimed and read back as ours.
  ///
  /// The claim is an upsert and the read back is a select, and both answer
  /// the same for the same car every time they are asked. Asking once per
  /// page instead of once per run was two requests per page per stream — more
  /// requests than the measurements themselves used. The answer cannot change
  /// under a run: a car another account owns stops the run at the first ask.
  final Set<String> _claimedVehicles = {};

  /// The streams that have no page left.
  ///
  /// A stream whose page came back short has nothing more to give: no row
  /// arrives while a run is in flight. Without this every pass re-read every
  /// stream to learn again that most of them are empty.
  final Set<String> _exhaustedStreams = {};

  static const sessionStream = 'session';
  static const intervalStream = 'interval';
  static const trackStream = 'track';
  static const eventStream = 'event';
  static const cycleStream = 'cycle';

  Future<bool> _isDirectUploadActive() async {
    if (isCarDirectUploadActive != null) {
      return await isCarDirectUploadActive!();
    }
    final idsProvider = activeVehicleIdsProvider;
    final idProvider = _activeVehicleIdProvider;
    final myVehicleIds = <String>{
      if (idsProvider != null) ...idsProvider(),
      if (idProvider != null) ...[idProvider()].whereType<String>(),
    }..removeWhere((id) => id.isEmpty);

    if (myVehicleIds.isEmpty) {
      return false;
    }
    try {
      final rows = await sink.fetch('phone_cutover_readiness');
      return rows
          .where((r) => myVehicleIds.contains(r['vehicle_id']))
          .any((r) => r['car_direct_upload_active'] == true);
    } catch (_) {
      return false;
    }
  }

  /// Uploads every page that is ready, and stops when nothing is left.
  ///
  /// A page is committed to the cursor only after the sink accepted it, so a
  /// failure repeats the page rather than skipping it. The repeat is safe
  /// because every write is keyed.
  /// Uploads at most one page per stream.
  ///
  /// After the pending mark landed (`MIGRATION_42_43` / `oldVersion < 6`),
  /// every historical row reads dirty. A single `run()` that drained the
  /// whole backlog would burst thousands of rows in one go. Bounding to one
  /// pass lets the backlog drain in batches over time, using the existing
  /// page limit (`pageSize` / `bulkPageSize`) without a scheduler or rate
  /// limiter — the caller simply invokes `run()` again later.
  Future<CloudUploadReport> run({
    void Function(CloudUploadProgress progress)? onProgress,
  }) async {
    if (await _isDirectUploadActive()) {
      return const CloudUploadReport.empty();
    }
    _claimedVehicles.clear();
    _exhaustedStreams.clear();
    final totalToUpload = await _db.countDirtyRows();
    var uploadedSoFar = 0;
    if (onProgress != null && totalToUpload > 0) {
      onProgress(CloudUploadProgress(uploaded: 0, total: totalToUpload));
    }
    final pass = await _pass(
      onBatchUploaded: (stream, count) {
        uploadedSoFar += count;
        if (onProgress != null) {
          final effectiveTotal = uploadedSoFar > totalToUpload
              ? uploadedSoFar
              : totalToUpload;
          onProgress(
            CloudUploadProgress(
              uploaded: uploadedSoFar,
              total: effectiveTotal,
              currentStream: stream,
            ),
          );
        }
      },
    );
    return CloudUploadReport(pass.perStream);
  }

  /// One page of each stream, in the order the foreign keys demand.
  Future<CloudUploadReport> _pass({
    void Function(String stream, int count)? onBatchUploaded,
  }) async {
    final perStream = <String, StreamUploadStats>{};

    void record(String stream, StreamUploadStats? stats) {
      if (stats == null) return;
      perStream[stream] = stats;
      onBatchUploaded?.call(stream, stats.rows);
    }

    final all = await _page(sessionStream, pageSize, _db.dirtySessions);
    // A session the phone pulled before the car minted its vehicle id carries
    // the placeholder. It cannot be scoped to a vehicle, the cloud enforces
    // that with a foreign key, and one such row would fail the whole page —
    // forever, since the mark is only cleared on success. It waits instead.
    final sessions = [
      for (final row in all)
        if (_scopedVehicleId(row['vehicleId']) != null) row,
    ];
    if (sessions.isNotEmpty) {
      await _uploadVehiclesFor(sessions);
      final sinkRows = [
        for (final row in sessions) _row(row, drop: const {'rowId'}),
      ];
      await sink.upsert(
        'session',
        sinkRows,
        conflictColumns: const ['vehicle_id', 'id'],
        // A session is uploaded while it is open and again when it closes, so
        // the second write replaces the first. It is the same row, not a
        // second measurement — and the mark is what makes the second write
        // happen at all.
        merge: true,
      );
      await _db.clearDirtySessions([for (final row in sessions) _rowId(row)]);
      record(
        sessionStream,
        StreamUploadStats(rows: sessions.length, bytes: _bytesOf(sinkRows)),
      );
    }

    record(
      intervalStream,
      await _uploadSessionScoped(
        stream: intervalStream,
        pageLimit: bulkPageSize,
        read: _db.dirtyIntervals,
        table: 'interval',
        conflictColumns: const ['vehicle_id', 'session_id', 'start_utc_millis'],
        // The last minute of a session is written again when the session
        // closes, because its width and coverage settle then.
        merge: true,
        clearDirty: _db.clearDirtyIntervals,
      ),
    );

    record(
      trackStream,
      await _uploadSessionScoped(
        stream: trackStream,
        pageLimit: pageSize,
        read: _db.dirtyTracks,
        table: 'track',
        conflictColumns: const ['vehicle_id', 'session_id'],
        // The car rewrites the row with raw points on every close tick and
        // simplifies it once when the session closes, so the same session's
        // route grows and then settles rather than adding a second route to
        // the same drive.
        merge: true,
        clearDirty: _db.clearDirtyTracks,
      ),
    );

    record(
      eventStream,
      await _uploadSessionScoped(
        stream: eventStream,
        pageLimit: bulkPageSize,
        read: _db.dirtyEvents,
        table: 'telemetry_events',
        conflictColumns: const [
          'vehicle_id',
          'occurred_at_utc_millis',
          'occurred_at_elapsed_nanos',
          'type',
          'signal_id',
        ],
        merge: false,
        clearDirty: _db.clearDirtyEvents,
        drop: const {'id'},
        // The cloud key cannot hold a null, and an event with no signal is
        // normal: a trip arming names no signal at all.
        defaults: const {'signal_id': ''},
      ),
    );

    final cycles = await _page(cycleStream, pageSize, _db.dirtyCycles);
    if (cycles.isNotEmpty) {
      final vehicleId = await _singleVehicleId();
      if (vehicleId != null) {
        await _uploadVehiclesForIds([vehicleId]);
        final sinkRows = [
          for (final row in cycles) _row(row, vehicleId: vehicleId),
        ];
        await sink.upsert(
          'battery_cycles',
          sinkRows,
          // The start time is the cycle's identity: it comes from the
          // cycle's first session and survives the ledger renumbering that
          // an ordinal does not. The open cycle is refolded every time it
          // grows, and a rebuilt ledger may reuse an ordinal for a different
          // cycle — only the start time tells those apart.
          conflictColumns: const ['vehicle_id', 'start_utc_millis'],
          merge: true,
        );
        await _db.clearDirtyCycles([for (final row in cycles) _rowId(row)]);
        record(
          cycleStream,
          StreamUploadStats(rows: cycles.length, bytes: _bytesOf(sinkRows)),
        );
      }
    }

    return CloudUploadReport(perStream);
  }

  /// Uploads one page of a stream whose rows name a session but not a
  /// vehicle — `interval`, `track`, `sample` and `event` all take this exact
  /// shape: page, resolve each row's vehicle through its session, claim the
  /// vehicles, spell the rows for the cloud, upsert, clear the mark.
  ///
  /// `session` and `battery_cycles` are not this shape and stay out of it:
  /// a session names its own vehicle directly, and a cycle names none at all
  /// and is scoped by asking whether the phone holds exactly one.
  ///
  /// Returns null when the page held nothing uploadable, so a caller can
  /// tell "nothing to record" from "recorded zero" without a sentinel stat.
  Future<StreamUploadStats?> _uploadSessionScoped({
    required String stream,
    required int pageLimit,
    required Future<List<Map<String, Object?>>> Function({int limit}) read,
    required String table,
    required List<String> conflictColumns,
    required bool merge,
    required Future<void> Function(Iterable<int> rowIds) clearDirty,
    Set<String> drop = const {},
    Map<String, Object?> defaults = const {},
  }) async {
    final all = await _page(stream, pageLimit, read);
    final vehicles = await _vehiclesFor(all);
    // A row whose session has no vehicle yet cannot be scoped, and the cloud
    // refuses it. It keeps its mark and goes up with the session.
    final rows = [
      for (final row in all)
        if (vehicles.containsKey(row['sessionId'])) row,
    ];
    if (rows.isEmpty) return null;
    await _uploadVehiclesForIds(vehicles.values);
    final sinkRows = [
      for (final row in rows)
        _row(
          row,
          drop: drop,
          vehicleId: vehicles[row['sessionId']],
          defaults: defaults,
        ),
    ];
    await sink.upsert(
      table,
      sinkRows,
      conflictColumns: conflictColumns,
      merge: merge,
    );
    await clearDirty([for (final row in rows) _rowId(row)]);
    return StreamUploadStats(rows: rows.length, bytes: _bytesOf(sinkRows));
  }

  /// The encoded size of [rows], the way they cross the wire to the cloud.
  static int _bytesOf(List<Map<String, Object?>> rows) =>
      rows.fold(0, (sum, row) => sum + utf8.encode(jsonEncode(row)).length);

  /// One page of [stream], or nothing once the stream has run out.
  ///
  /// A page shorter than the limit is the last one: no row arrives while a
  /// run is in flight, so the stream is marked and no later pass asks it
  /// again.
  Future<List<Map<String, Object?>>> _page(
    String stream,
    int limit,
    Future<List<Map<String, Object?>>> Function({int limit}) read,
  ) async {
    if (_exhaustedStreams.contains(stream)) return const [];
    final rows = await read(limit: limit);
    if (rows.length < limit) _exhaustedStreams.add(stream);
    return rows;
  }

  /// The name this database gives the row, taken with the page.
  ///
  /// A page that arrives without it is a bug in the read, not a row the run
  /// can skip: the mark would be cleared for rows that never went up, or not
  /// cleared for rows that did. It says so, with the keys the row does carry,
  /// rather than failing as a bare cast that names nothing.
  static int _rowId(Map<String, Object?> row) {
    final value = row[CompanionDatabase.rowIdKey];
    if (value is num) return value.toInt();
    throw StateError(
      'a dirty row came back with no ${CompanionDatabase.rowIdKey}; '
      'it carries ${row.keys.toList()}',
    );
  }

  /// The vehicle a row belongs to, or null when it belongs to none yet.
  ///
  /// `unassigned` is what the phone's own schema defaults to. It is a stand-in
  /// for "the car had not minted its id when this arrived", never an id.
  static String? _scopedVehicleId(Object? value) {
    if (value is! String) return null;
    if (value.isEmpty || value == 'unassigned') return null;
    return value;
  }

  Future<void> _uploadVehiclesFor(List<Map<String, Object?>> sessions) async {
    final ids = <String>{
      for (final row in sessions) ?_scopedVehicleId(row['vehicleId']),
    };
    await _uploadVehiclesForIds(ids);
  }

  Future<void> _uploadVehiclesForIds(Iterable<String> ids) async {
    final scoped = <String>{for (final id in ids) ?_scopedVehicleId(id)}
      ..removeAll(_claimedVehicles);
    if (scoped.isEmpty) return;
    await sink.upsert(
      'vehicle',
      [
        for (final id in scoped) {'vehicle_id': id, 'account_id': accountId},
      ],
      conflictColumns: const ['vehicle_id'],
      merge: false,
    );
    // The claim above cannot fail, and that is the problem it is read back
    // for. A car is one row keyed by its own id, so a car another account
    // already claimed makes this an `ON CONFLICT DO NOTHING`: no row written,
    // no error raised, and the same car still named by every measurement that
    // follows. The refusal then arrived two tables later as `42501 · session`,
    // which names the ownership boundary and says nothing about whose car it is.
    //
    // So the ownership is asked, once, right here. It is the one place that
    // can answer it while the answer still means something.
    final mine = await sink.ownedVehicles(scoped);
    final taken = scoped.difference(mine);
    if (taken.isNotEmpty) throw CloudVehicleTaken(taken.first);
    _claimedVehicles.addAll(scoped);
  }

  /// The vehicle of each session named by [rows], with the unscoped ones left
  /// out. A row whose session has no vehicle yet is not uploadable, and it
  /// stays marked until the session gains one.
  Future<Map<String, String>> _vehiclesFor(
    List<Map<String, Object?>> rows,
  ) async {
    final found = await _db.vehicleIdsForSessions([
      for (final row in rows)
        if (row['sessionId'] is String) row['sessionId'] as String,
    ]);
    return {
      for (final entry in found.entries)
        if (_scopedVehicleId(entry.value) != null)
          entry.key: _scopedVehicleId(entry.value)!,
    };
  }

  /// The vehicle a battery cycle belongs to.
  ///
  /// A cycle row names no session and no vehicle: on the car it is a fold over
  /// the whole history of the one car it was recorded on. A phone paired with
  /// two cars therefore cannot say which of them a cycle came from, and
  /// uploading it under a guess would merge two batteries. Until the car sends
  /// the vehicle with the cycle, a phone that holds more than one vehicle
  /// uploads no cycles at all.
  Future<String?> _singleVehicleId() async {
    final sessions = await _db.sessions(limit: 0);
    final ids = <String>{
      for (final row in sessions)
        if (row['vehicleId'] is String) row['vehicleId'] as String,
    }..removeWhere((id) => id.isEmpty || id == 'unassigned');
    return ids.length == 1 ? ids.first : null;
  }

  /// The car's row as the cloud spells it.
  ///
  /// The car writes camelCase and Postgres folds an unquoted identifier to
  /// lower case, so the transform is mechanical and lives here, in one place.
  /// The device-local ids are dropped: they mean nothing outside one database
  /// and a wipe restarts them.
  ///
  /// Null values are dropped, not sent: under
  /// `Prefer: resolution=merge-duplicates` PostgREST builds
  /// `ON CONFLICT ... DO UPDATE` from the keys present, so an omitted key
  /// leaves the existing column untouched while an explicit null would wipe
  /// it (e.g. a session re-uploaded on close wiping a column the open upload
  /// had set). The local store keeps its nulls; only the wire omits them.
  Map<String, Object?> _row(
    Map<String, Object?> row, {
    Set<String> drop = const {},
    String? vehicleId,
    Map<String, Object?> defaults = const {},
  }) {
    final out = <String, Object?>{};
    row.forEach((key, value) {
      if (drop.contains(key)) return;
      // A key that leads with an underscore names the row inside this phone's
      // own database — the sqlite rowid that the dirty page carries. It means
      // nothing to the cloud and never leaves here.
      if (key.startsWith('_')) return;
      if (value == null) return;
      out[snakeCase(key)] = value;
    });
    defaults.forEach((key, value) {
      if (out[key] == null) out[key] = value;
    });
    out['account_id'] = accountId;
    if (vehicleId != null) out['vehicle_id'] = vehicleId;
    return out;
  }
}

/// `startedAtUtcMillis` becomes `started_at_utc_millis`.
String snakeCase(String name) {
  final out = StringBuffer();
  for (var i = 0; i < name.length; i++) {
    final char = name[i];
    final upper = char.toUpperCase();
    if (char == upper && char != char.toLowerCase() && i > 0) {
      out.write('_');
    }
    out.write(char.toLowerCase());
  }
  return out.toString();
}

/// A car this phone holds that belongs to another account in the cloud.
///
/// The cloud keys a car by the id the car itself minted, so the first account
/// to upload one owns it. This is not a transfer and it is not a merge: the
/// two accounts hold the same measurements, and nothing here can decide which
/// of them the history belongs to. It stops the run instead, before a single
/// session row is offered under the wrong owner.
class CloudVehicleTaken implements Exception {
  const CloudVehicleTaken(this.vehicleId);

  final String vehicleId;

  @override
  String toString() => 'CloudVehicleTaken($vehicleId)';
}
