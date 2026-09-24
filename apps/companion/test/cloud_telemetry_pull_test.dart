import 'package:capy_companion/runtime/companion_runtime.dart';
import 'package:capy_companion/sync/annotation_cloud_sync.dart';
import 'package:capy_companion/sync/cloud_telemetry_pull.dart';
import 'package:capy_companion/sync/cloud_uploader.dart';
import 'package:capy_companion/sync/companion_archive.dart';
import 'package:capy_companion/sync/cloud_run_report.dart';
import 'package:capy_companion/sync/sync_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:telemetry_core/telemetry_core.dart';

import 'support/memory_archive.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('CloudTelemetryPull → local archive', () {
    test('pulls sessions/intervals/events/tracks/cycles into archive', () async {
      final archive = await memoryArchive();
      // Seed cloud with snake_case rows as Supabase would return them.
      final sink = FakeCloudSink({
        'session': [
          {
            'vehicle_id': 'VIN-CLOUD-1',
            'id': 'sess-cloud-1',
            'account_id': 'acct-1',
            'kind': 'TRIP',
            'status': 'CLOSED',
            'started_at_utc_millis': 1750000000000,
            'started_at_elapsed_nanos': 1000,
            'created_at_utc_millis': 1750000000000,
            'updated_at_utc_millis': 1750000005000,
            'updated_at_elapsed_nanos': 2000,
          },
        ],
        'interval': [
          {
            'vehicle_id': 'VIN-CLOUD-1',
            'session_id': 'sess-cloud-1',
            'account_id': 'acct-1',
            'start_utc_millis': 1750000000000,
            'width_millis': 60000,
            'traction_wh': 100.0,
            'regen_wh': 10.0,
            'auxiliary_wh': 5.0,
            'climate_wh': 2.0,
            'delivered_wh': 0.0,
            'distance_km': 1.2,
            'covered_seconds': 60.0,
            'climate_covered_seconds': 60.0,
            'speed_covered_seconds': 60.0,
            'delivered_covered_seconds': 60.0,
            'updated_at_utc_millis': 1750000000000,
          },
        ],
        'telemetry_events': [
          {
            'vehicle_id': 'VIN-CLOUD-1',
            'session_id': 'sess-cloud-1',
            'account_id': 'acct-1',
            'type': 'TRIP_STARTED',
            'occurred_at_utc_millis': 1750000000001,
            'occurred_at_elapsed_nanos': 1001,
            'signal_id': '',
            'value': null,
            'previous_value': null,
          },
        ],
        'track': [
          {
            'vehicle_id': 'VIN-CLOUD-1',
            'session_id': 'sess-cloud-1',
            'account_id': 'acct-1',
            'encoding_version': 1,
            'point_count': 2,
            't': 'encoded-t',
            'path': 'encoded-path',
            'speed': 'encoded-speed',
            'alt': 'encoded-alt',
            'updated_at_utc_millis': 1750000000000,
          },
        ],
        'battery_cycles': [
          {
            'vehicle_id': 'VIN-CLOUD-1',
            'ordinal': 1,
            'account_id': 'acct-1',
            'start_utc_millis': 1749000000000,
            'end_utc_millis': 1750000000000,
            'discharge_percent': 20.0,
            'distance_km': 50.0,
            'trip_energy_kwh': 10.0,
            'parked_energy_kwh': 1.0,
            'parked_soc_percent': 5.0,
            'priced_energy_kwh': 8.0,
            'unpriced_energy_kwh': 2.0,
            'is_open': false,
            'is_partial': false,
            'energy_incomplete': false,
            'mixed_currency': false,
            'opening_priced_fraction': 1.0,
            'opening_blended_price': 0.2,
            'created_at_utc_millis': 1749000000000,
            'updated_at_utc_millis': 1750000000000,
          },
        ],
      });

      final pull = CloudTelemetryPull(
        archive: archive,
        sink: sink,
        accountId: 'acct-1',
      );

      final progress = <SyncProgress>[];
      final report = await pull.pull(onProgress: progress.add);

      expect(report.status, SyncRunStatus.completed);
      expect(report.ackedRecords, 5);
      // Progress per stream
      expect(progress.map((p) => p.stream), contains(SyncStreamType.sessions));
      expect(progress.map((p) => p.stream), contains(SyncStreamType.intervals));
      expect(progress.map((p) => p.stream), contains(SyncStreamType.events));
      expect(progress.map((p) => p.stream), contains(SyncStreamType.tracks));

      // Archive now holds the rows, with correct counts.
      expect(await archive.database.countSessions(), 1);
      expect(await archive.database.countIntervals(), 1);
      expect(await archive.database.trackCount(), 1);
      expect(await archive.database.countCycles(), 1);
      final events = await archive.database.eventsForSession('sess-cloud-1');
      expect(events.length, 1);
      expect(events.first['type'], 'TRIP_STARTED');

      // Cloud rows must NOT be marked dirty — they are already in the replica.
      expect(await archive.database.countDirtyRows(), 0);

      // Idempotent: pulling again replaces, does not duplicate.
      final report2 = await pull.pull();
      expect(report2.ackedRecords, 5);
      expect(await archive.database.countSessions(), 1);
    });

    test('empty cloud returns 0 and completed', () async {
      final archive = await memoryArchive();
      final sink = FakeCloudSink({});
      final pull = CloudTelemetryPull(
        archive: archive,
        sink: sink,
        accountId: 'acct-1',
      );
      final report = await pull.pull();
      expect(report.status, SyncRunStatus.completed);
      expect(report.ackedRecords, 0);
      expect(await archive.database.countSessions(), 0);
    });

    test('pagination works — more than one page', () async {
      final archive = await memoryArchive();
      // 2500 sessions, pageSize is 1000, so 3 pages.
      final sessions = [
        for (var i = 0; i < 2500; i++)
          {
            'vehicle_id': 'VIN-1',
            'id': 'sess-$i',
            'account_id': 'acct-1',
            'kind': 'TRIP',
            'status': 'CLOSED',
            'started_at_utc_millis': 1750000000000 + i,
            'created_at_utc_millis': 1750000000000,
            'updated_at_utc_millis': 1750000000000,
          },
      ];
      final sink = FakeCloudSink({'session': sessions});
      final pull = CloudTelemetryPull(
        archive: archive,
        sink: sink,
        accountId: 'acct-1',
      );
      final report = await pull.pull();
      expect(report.ackedRecords, 2500);
      expect(await archive.database.countSessions(), 2500);
    });
  });

  group('SyncController cloud wiring', () {
    test('reports the cloud pull answer with progress', () async {
      final archive = await memoryArchive();
      final fakeRuntime = _FakeRuntime(archive: archive);
      var cloudCalled = false;
      final controller = SyncController(
        car: fakeRuntime,
        runner: ({onProgress}) async {
          cloudCalled = true;
          onProgress?.call(
            const SyncProgress(
              stream: SyncStreamType.sessions,
              recordsWritten: 5,
            ),
          );
          return const SyncRunReport(
            status: SyncRunStatus.completed,
            ackedRecords: 5,
          );
        },
      );
      await controller.runNow();
      expect(cloudCalled, isTrue);
      expect(controller.lastReport?.ackedRecords, 5);
      expect(controller.pages[SyncStreamType.sessions]?.recordsWritten, 5);
    });

    test('a cloud failure is final — no local path left', () async {
      final archive = await memoryArchive();
      final fakeRuntime = _FakeRuntime(archive: archive);
      final controller = SyncController(
        car: fakeRuntime,
        runner: ({onProgress}) async => SyncRunReport(
          status: SyncRunStatus.failed,
          ackedRecords: 0,
          error: StateError('network down'),
        ),
      );
      await controller.runNow();
      expect(controller.lastReport?.status, SyncRunStatus.failed);
    });
  });

  group('CompanionDatabase cloud dirty flag', () {
    test('cloud upserts leave dirty at 0', () async {
      final archive = await memoryArchive();
      final db = archive.database;
      await db.upsertSessionFromCloud({
        'id': 'sess-1',
        'vehicleId': 'VIN-1',
        'kind': 'TRIP',
        'status': 'CLOSED',
        'startedAtUtcMillis': 1,
      });
      await db.upsertIntervalFromCloud({
        'sessionId': 'sess-1',
        'startUtcMillis': 1,
        'widthMillis': 60000,
      });
      await db.upsertTrackFromCloud({
        'sessionId': 'sess-1',
        'pointCount': 1,
        'updatedAtUtcMillis': 1,
      });
      await db.upsertCycleFromCloud({'ordinal': 1});
      await db.upsertEventFromCloud({
        'sessionId': 'sess-1',
        'type': 'TRIP_STARTED',
        'occurredAtUtcMillis': 1,
        'occurredAtElapsedNanos': 1,
      });
      expect(await db.countDirtyRows(), 0);
      // Local upserts would be dirty.
      await db.upsertSession({
        'id': 'sess-2',
        'vehicleId': 'VIN-1',
        'kind': 'TRIP',
        'status': 'CLOSED',
        'startedAtUtcMillis': 2,
      });
      expect(await db.countDirtyRows(), 1);
    });
  });
}

class _FakeRuntime implements CarLink {
  @override
  final CompanionArchive? archive;
  _FakeRuntime({this.archive});

  @override
  Future<SyncRunReport> syncFromCloud({
    void Function(SyncProgress progress)? onProgress,
  }) async =>
      const SyncRunReport(status: SyncRunStatus.failed, ackedRecords: 0);

  @override
  Future<CloudUploadReport?> uploadToCloud({
    void Function(CloudUploadProgress progress)? onProgress,
  }) async => null;

  @override
  Future<AnnotationCloudSyncReport?> syncAnnotationsToCloud() async => null;

  @override
  Future<void> wipeArchive() async {}
}
