import 'package:telemetry_core/telemetry_core.dart';

import 'cloud_run_report.dart';
import 'cloud_uploader.dart';
import 'companion_archive.dart';
import 'supabase_cloud_sink.dart';

/// Pulls the car's Lane A history from the cloud replica into the phone's
/// local archive.
///
/// The car uploads to Supabase (via [CloudUploader] → [CloudSink] →
/// Postgres) and the phone reads it back here. Rows are keyed the same,
/// upserted through the same [CompanionArchive] helpers, and read by the
/// same `SqfliteStore`/`JourneyStore`. The only difference from any older
/// path is the source: cloud rows are already stamped by the cloud and must
/// not be re-uploaded.
///
/// Ordering mirrors the uploader's foreign-key order: session before anything
/// that names a session, so an interval never lands before its session.
/// Every write is idempotent — fetching the same page twice replaces, never
/// duplicates.
///
/// The only sync path. See `SyncController.runNow` for the Force Sync entry
/// point that calls this pull directly.
class CloudTelemetryPull {
  CloudTelemetryPull({
    required this.archive,
    required this.sink,
    required this.accountId,
  });

  final CompanionArchive archive;
  final CloudSink sink;
  final String accountId;

  /// How many rows one cloud page fetches.
  static const pageSize = 1000;

  /// Pulls every measurement table the phone's archive holds.
  ///
  /// Progress is reported per stream via [onProgress] with the same
  /// [SyncProgress] shape the Wi-Fi engine uses, so the card can draw either
  /// source without knowing which ran.
  Future<SyncRunReport> pull({
    void Function(SyncProgress progress)? onProgress,
  }) async {
    var acked = 0;

    void report(SyncStreamType stream, int written, [int? remaining]) {
      onProgress?.call(
        SyncProgress(
          stream: stream,
          recordsWritten: written,
          remaining: remaining,
        ),
      );
    }

    try {
      // 1) Sessions — the root. Everything else names one.
      final sessionRows = await _fetchAll('session');
      var sessionsWritten = 0;
      for (final snake in sessionRows) {
        final camel = _toCamel(snake);
        // Cloud rows carry account_id/vehicle_id already; keep vehicleId for local store.
        // The archive helper stores the whole map as row json, with vehicleId/kind/status/startedAt.
        // Mark as from-cloud so dirty stays 0 — already in cloud.
        try {
          await archive.upsertSessionFromCloud(camel);
          sessionsWritten++;
          acked++;
        } catch (_) {
          // One bad row must not abort the whole pull — the car may have written
          // a row this phone's schema does not understand yet.
        }
      }
      report(SyncStreamType.sessions, sessionsWritten, 0);
      await archive.persist();

      // 2) Battery cycles — scoped by single-vehicle fallback same as uploader.
      final cycleRows = await _fetchAll('battery_cycles');
      var cyclesWritten = 0;
      for (final snake in cycleRows) {
        final camel = _toCamel(snake);
        try {
          await archive.upsertCycleFromCloud(camel);
          cyclesWritten++;
          acked++;
        } catch (_) {}
      }
      report(SyncStreamType.batteryCycles, cyclesWritten, 0);
      await archive.persist();

      // 3) Intervals — session-scoped, bulk.
      final intervalRows = await _fetchAll('interval');
      var intervalsWritten = 0;
      for (final snake in intervalRows) {
        final camel = _toCamel(snake);
        try {
          await archive.upsertIntervalFromCloud(camel);
          intervalsWritten++;
          acked++;
        } catch (_) {}
      }
      report(SyncStreamType.intervals, intervalsWritten, 0);
      await archive.persist();

      // 4) Telemetry events — natural-key rows.
      final eventRows = await _fetchAll('telemetry_events');
      var eventsWritten = 0;
      for (final snake in eventRows) {
        final camel = _toCamel(snake);
        try {
          // Cloud events carry snake keys: signal_id, occurred_at_utc_millis etc.
          // Convert signal_id -> signalId for the archive path.
          await archive.upsertEventFromCloud(camel);
          eventsWritten++;
          acked++;
        } catch (_) {}
      }
      report(SyncStreamType.events, eventsWritten, 0);
      await archive.persist();

      // 5) Tracks — one per session.
      final trackRows = await _fetchAll('track');
      var tracksWritten = 0;
      for (final snake in trackRows) {
        final camel = _toCamel(snake);
        try {
          await archive.upsertTrackFromCloud(camel);
          tracksWritten++;
          acked++;
        } catch (_) {}
      }
      report(SyncStreamType.tracks, tracksWritten, 0);
      await archive.persist();

      return SyncRunReport(
        status: SyncRunStatus.completed,
        ackedRecords: acked,
      );
    } on CloudUploadFailure catch (error) {
      // Transport/RLS failure surfaced as CloudUploadFailure by the sink guard.
      return SyncRunReport(
        status: SyncRunStatus.failed,
        ackedRecords: acked,
        error: error,
      );
    } on Object catch (error) {
      return SyncRunReport(
        status: SyncRunStatus.failed,
        ackedRecords: acked,
        error: error,
      );
    }
  }

  Future<List<Map<String, Object?>>> _fetchAll(String table) async {
    // Paginated fetch so a phone with 50k intervals does not try to hold them
    // all in one response. Uses the sink's range-aware fetch when available.
    const chunk = pageSize;
    var offset = 0;
    final all = <Map<String, Object?>>[];
    while (true) {
      final page = await _fetchPage(table, offset: offset, limit: chunk);
      if (page.isEmpty) break;
      all.addAll(page);
      if (page.length < chunk) break;
      offset += page.length;
    }
    return all;
  }

  /// One page of [table]. A failure reaches the caller as a `failed` report
  /// with the error attached — never as an empty page. An empty page means
  /// the cloud holds nothing there, and the screens read that as the car's
  /// silence; a swallowed network fault would wear the same reading and
  /// blame the car for this phone's dead link.
  Future<List<Map<String, Object?>>> _fetchPage(
    String table, {
    required int offset,
    required int limit,
  }) => sink.fetchRange(table, offset: offset, limit: limit);

  /// `snake_case` row from PostgREST → `camelCase` wire map the archive expects.
  Map<String, Object?> _toCamel(Map<String, Object?> snake) {
    final out = <String, Object?>{};
    snake.forEach((key, value) {
      if (key == 'account_id') return; // local store does not keep it
      if (key == 'uploaded_at') return; // cloud bookkeeping only
      out[_snakeToCamel(key)] = value;
    });
    return out;
  }

  String _snakeToCamel(String snake) {
    if (!snake.contains('_')) return snake;
    final parts = snake.split('_');
    final first = parts.first;
    final rest = parts
        .skip(1)
        .map((p) => p.isEmpty ? '' : '${p[0].toUpperCase()}${p.substring(1)}');
    return '$first${rest.join()}';
  }
}

/// Helper for tests: a CloudSink that returns seeded rows per table.
class FakeCloudSink implements CloudSink {
  final Map<String, List<Map<String, Object?>>> seeded;

  FakeCloudSink(this.seeded);

  @override
  Future<void> upsert(
    String table,
    List<Map<String, Object?>> rows, {
    required List<String> conflictColumns,
    required bool merge,
  }) async {}

  @override
  Future<Set<String>> ownedVehicles(Set<String> ids) async => ids;

  @override
  Future<List<Map<String, Object?>>> fetch(String table) async =>
      List<Map<String, Object?>>.from(seeded[table] ?? const []);

  @override
  Future<List<Map<String, Object?>>> fetchRange(
    String table, {
    required int offset,
    required int limit,
  }) async {
    final all = seeded[table] ?? const [];
    if (offset >= all.length) return const [];
    final end = (offset + limit).clamp(0, all.length);
    return all
        .sublist(offset, end)
        .map((r) => Map<String, Object?>.from(r))
        .toList();
  }
}
