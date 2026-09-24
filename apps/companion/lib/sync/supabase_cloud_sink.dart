import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/supabase_config.dart';
import 'cloud_sync_config.dart';

import 'cloud_uploader.dart';
import 'companion_database.dart';

/// The one file in the sync layer that knows the cloud is Supabase.
///
/// It mirrors `SupabaseAccountGateway`, and for the same reason: the provider's
/// own exception carries server text, which is not localized and changes
/// between releases of the service. Nothing above this class sees a
/// `PostgrestException`.
class SupabaseCloudSink implements CloudSink {
  SupabaseCloudSink(this._client);

  /// The client the account layer already started, or null when this build
  /// carries no project. A build with no project uploads nothing; it is not a
  /// broken build, and the pairing, the sync and the archive are unaffected.
  static SupabaseCloudSink? of(SupabaseClient? client) =>
      client == null ? null : SupabaseCloudSink(client);

  final SupabaseClient _client;

  /// How many rows one request carries.
  ///
  /// It is not the uploader's page. The page is what one read of the phone's
  /// database costs and what one clear of the mark covers, and it is large on
  /// purpose. This is what one **request** carries, and a request is a body
  /// that has to cross a mobile connection whole: too big and what comes back
  /// is a gateway's own error page, at a status and in a shape that is not
  /// the provider's. Splitting here keeps the page large and the body small.
  ///
  /// Each part is its own upsert. That is safe for the same reason a repeat
  /// is safe: every write is keyed, so a part that lands twice is a no-op and
  /// a run that stops between two parts leaves a shorter history, never a
  /// broken one.
  static const maxRowsPerRequest = 1000;

  /// The uploader for whoever is signed in, or null when nothing can upload.
  ///
  /// Null has four causes and they are one answer here: the cloud-sync gate
  /// ([CloudSyncConfig.enabled], default ON) is off, this build carries no
  /// project, nobody is signed in, or the session has no user. All four mean
  /// the phone keeps its archive and sends nothing, which is a working phone
  /// rather than a failure — pairing, sync and history never needed a server.
  ///
  /// This is also the only place the account id is read. `AccountGateway`
  /// deliberately answers an email and a confirmation, not a provider id, and
  /// the id is what a measurement row is stamped with.
  static CloudUploader? uploaderFor(
    CompanionDatabase database, {
    String? Function()? activeVehicleIdProvider,
    Iterable<String> Function()? activeVehicleIdsProvider,
  }) {
    // Cloud-sync gate — defaults ON. See `CloudSyncConfig`.
    if (!CloudSyncConfig.enabled) return null;
    if (!SupabaseConfig.isConfigured) return null;
    final client = Supabase.instance.client;
    final accountId = client.auth.currentUser?.id;
    if (accountId == null) return null;
    return CloudUploader(
      database: database,
      sink: SupabaseCloudSink(client),
      accountId: accountId,
      activeVehicleIdProvider: activeVehicleIdProvider,
      activeVehicleIdsProvider: activeVehicleIdsProvider,
    );
  }

  /// The strip lives in the callers that can take it: the telemetry uploader
  /// ([CloudUploader._row]) omits null keys, because plain
  /// `ON CONFLICT ... DO UPDATE` leaves an omitted column untouched. The
  /// annotation tables keep their explicit nulls all the way through here:
  /// the per-group merge trigger (`20260902130000_annotation_merge_trigger`)
  /// reads `NEW.deleted_at_utc_millis` to tell alive from deleted, so an
  /// omitted tombstone would pin a cloud-deleted row deleted forever.
  @override
  Future<void> upsert(
    String table,
    List<Map<String, Object?>> rows, {
    required List<String> conflictColumns,
    required bool merge,
  }) async {
    if (rows.isEmpty) return;
    for (final part in requestParts(rows, maxRowsPerRequest)) {
      await _guard(table, part.length, () async {
        await _client
            .from(table)
            .upsert(
              part,
              onConflict: conflictColumns.join(','),
              ignoreDuplicates: !merge,
            );
      });
    }
  }

  /// Runs [request] and lets no provider error out as itself.
  ///
  /// The catch is on `Object`, not on `PostgrestException`, and that is the
  /// point. A refusal that Postgres itself wrote arrives as a
  /// `PostgrestException` and carries a code. Everything else on the way to
  /// Postgres — a socket that closed, a gateway that answered with its own
  /// page, a body the client could not read — arrives as whatever type that
  /// layer throws, and one of those reached a screen as the bare word
  /// `_TypeError`. It names nothing a reader can act on and nothing a report
  /// can be filed against. The type is kept as the code instead, next to the
  /// table and the size of the request that failed.
  Future<void> _guard(
    String table,
    int rows,
    Future<void> Function() request,
  ) async {
    try {
      await request();
    } on PostgrestException catch (error) {
      throw CloudUploadFailure(table, error.code, rows);
    } on Object catch (error) {
      throw CloudUploadFailure(table, error.runtimeType.toString(), rows);
    }
  }

  @override
  Future<Set<String>> ownedVehicles(Set<String> ids) async {
    if (ids.isEmpty) return const {};
    final owned = <String>{};
    await _guard('vehicle', ids.length, () async {
      final rows = await _client
          .from('vehicle')
          .select('vehicle_id')
          .inFilter('vehicle_id', ids.toList());
      for (final row in rows) {
        if (row['vehicle_id'] case final String id) owned.add(id);
      }
    });
    return owned;
  }

  @override
  Future<List<Map<String, Object?>>> fetch(String table) async {
    var result = <Map<String, Object?>>[];
    await _guard(table, 0, () async {
      final rows = await _client.from(table).select();
      result = [for (final row in rows) Map<String, Object?>.from(row as Map)];
    });
    return result;
  }

  @override
  Future<List<Map<String, Object?>>> fetchRange(
    String table, {
    required int offset,
    required int limit,
  }) async {
    var result = <Map<String, Object?>>[];
    await _guard(table, 0, () async {
      final rows = await _client
          .from(table)
          .select()
          .range(offset, offset + limit - 1);
      result = [for (final row in rows) Map<String, Object?>.from(row as Map)];
    });
    return result;
  }
}

/// [rows] cut into the parts one request each can carry.
///
/// A list shorter than [size] is one part, and the last part is whatever is
/// left. It is separated out because it is the one piece of the split that
/// can be wrong in a way nothing would notice: a part dropped off the end is
/// rows that never went up and a mark that was cleared anyway.
List<List<T>> requestParts<T>(List<T> rows, int size) => [
  for (var start = 0; start < rows.length; start += size)
    rows.sublist(
      start,
      start + size > rows.length ? rows.length : start + size,
    ),
];

/// An upload that the cloud refused.
///
/// It carries the Postgres code rather than the message, because the code is
/// what names the fault and survives a release of the service: `42501` is the
/// ownership boundary refusing, `23503` is a row that names a vehicle the cloud does
/// not have, `23505` is a key that is already there.
///
/// When the fault never reached Postgres there is no code, and the name of the
/// thrown type takes its place. It is a poorer name, but it is a name, and it
/// arrives with the table and the size of the request instead of alone.
class CloudUploadFailure implements Exception {
  const CloudUploadFailure(this.table, this.code, this.rows);

  final String table;
  final String? code;
  final int rows;

  /// What a reader can repeat back. The code comes first because it is what
  /// names the fault: `42501` is the ownership boundary refusing, `23503` a row
  /// naming a vehicle the cloud does not have, `23505` a key already there.
  String get label => '${code ?? 'no code'} · $table · $rows';

  @override
  String toString() => 'CloudUploadFailure($table, code: $code, rows: $rows)';
}
