import 'package:capy_companion/sync/annotation_cloud_sync.dart';
import 'package:capy_companion/sync/cloud_migration.dart';
import 'package:capy_companion/sync/cloud_uploader.dart';
import 'package:capy_companion/sync/companion_archive.dart';
import 'package:capy_companion/sync/preference_control_cloud.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

import 'support/memory_archive.dart';

class FakeAnnotationSink implements CloudSink {
  final List<({String table, List<Map<String, Object?>> rows})> writes = [];
  String? failOnUpsertOnce;
  int failCount = 0;

  @override
  Future<void> upsert(
    String table,
    List<Map<String, Object?>> rows, {
    required List<String> conflictColumns,
    required bool merge,
  }) async {
    if (failOnUpsertOnce != null && table == failOnUpsertOnce) {
      failOnUpsertOnce = null;
      failCount++;
      throw StateError('refused $table');
    }
    writes.add((table: table, rows: rows));
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
  }) async {
    final all = await fetch(table);
    if (offset >= all.length) return const [];
    final end = (offset + limit).clamp(0, all.length);
    return all.sublist(offset, end);
  }
}

class FakeControlCloud implements PreferenceControlCloud {
  final List<Map<String, Object?>> desiredWrites = [];
  String? failOnKey;

  @override
  bool get isConfigured => true;

  @override
  String get accountId => '00000000-0000-4000-a000-000000000001';

  @override
  Future<void> writeDesired({
    required String accountId,
    required String vehicleId,
    required String key,
    String? value,
    required int proposedAtUtcMillis,
    required String origin,
  }) async {
    if (failOnKey != null && key == failOnKey) {
      failOnKey = null;
      throw StateError('refused desired $key');
    }
    desiredWrites.add({
      'account_id': accountId,
      'vehicle_id': vehicleId,
      'key': key,
      'value': value,
      'proposed_at_utc_millis': proposedAtUtcMillis,
      'origin': origin,
    });
  }

  @override
  Future<List<PreferenceControlStatusRow>> readStatus() async => const [];
}

Future<CompanionArchive> _archiveWithHistory() async {
  final archive = await memoryArchive();
  // Need a session to give knownVehicleIds for Lane C
  await archive.upsertSession({
    'id': 'sess-1',
    'vehicleId': 'VIN1',
    'kind': 'TRIP',
    'status': 'CLOSED',
    'startedAtUtcMillis': 1750000000000,
    'startedAtElapsedNanos': 1,
    'noLongerReducible': 0,
    'createdAtUtcMillis': 1750000000000,
    'updatedAtUtcMillis': 1750000000000,
  });
  await archive.upsertPlace({
    'id': 'place-1',
    'name': 'Home',
    'latitude': 12.34,
    'longitude': 56.78,
    'radiusM': 150.0,
    'createdAtUtcMillis': 1000,
    'updatedAtUtcMillis': 5000,
    'origin': kAnnotationOriginPhone,
    'hlcMillis': 5000,
    'hlcCounter': 0,
    'hlcDeviceId': kAnnotationOriginPhone,
  });
  await archive.upsertJourney({
    'id': 'journey-1',
    'name': 'Holiday',
    'startedAtUtcMillis': 1700000000000,
    'endedAtUtcMillis': 1700003600000,
    'note': 'test',
    'createdAtUtcMillis': 1700000000000,
    'updatedAtUtcMillis': 1700003600000,
    'origin': kAnnotationOriginPhone,
    'hlcMillis': 1700003600000,
    'hlcCounter': 0,
    'hlcDeviceId': kAnnotationOriginPhone,
  });
  // Control preference — should go via Lane C
  await archive.upsertPreference({
    'scope': 'account',
    'key': 'pack_capacity_wh',
    'value': '64000',
    'updatedAtUtcMillis': 1234,
    'origin': kAnnotationOriginPhone,
    'hlcMillis': 1234,
    'hlcCounter': 0,
    'hlcDeviceId': kAnnotationOriginPhone,
  });
  // Annotation preference — via Lane B
  await archive.upsertPreference({
    'scope': 'account',
    'key': 'theme_id',
    'value': 'dark',
    'updatedAtUtcMillis': 1235,
    'origin': kAnnotationOriginPhone,
    'hlcMillis': 1235,
    'hlcCounter': 0,
    'hlcDeviceId': kAnnotationOriginPhone,
  });
  return archive;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CloudMigration', () {
    test(
      'fresh install with existing history + gate enabled triggers exactly once',
      () async {
        final archive = await _archiveWithHistory();
        final sink = FakeAnnotationSink();
        final control = FakeControlCloud();

        final annotationSync = AnnotationCloudSync(
          archive: archive,
          sink: sink,
          accountId: control.accountId,
        );

        final migration = CloudMigration(
          archive: archive,
          annotationSyncFactory: () => annotationSync,
          controlCloudFactory: () => control,
          enabledProvider: () => true,
        );

        await migration.load();
        expect(await migration.isCompleted(), isFalse);
        expect(migration.state, CloudMigrationState.idle);

        final first = await migration.runIfNeeded();
        expect(first, isTrue);
        expect(await migration.isCompleted(), isTrue);
        expect(migration.state, CloudMigrationState.done);
        expect(sink.writes, isNotEmpty, reason: 'Lane B should have pushed');
        expect(
          control.desiredWrites.any((r) => r['key'] == 'pack_capacity_wh'),
          isTrue,
        );

        final writesAfterFirst = sink.writes.length;
        final desiredAfterFirst = control.desiredWrites.length;

        // Second launch must not re-trigger.
        final second = await migration.runIfNeeded();
        expect(second, isFalse);
        expect(
          sink.writes.length,
          writesAfterFirst,
          reason: 'second launch must not re-upload',
        );
        expect(control.desiredWrites.length, desiredAfterFirst);
      },
    );

    test('gate OFF does not trigger even with history', () async {
      final archive = await _archiveWithHistory();
      final sink = FakeAnnotationSink();
      final control = FakeControlCloud();
      final sync = AnnotationCloudSync(
        archive: archive,
        sink: sink,
        accountId: control.accountId,
      );
      final migration = CloudMigration(
        archive: archive,
        annotationSyncFactory: () => sync,
        controlCloudFactory: () => control,
        enabledProvider: () => false,
      );
      await migration.load();
      final ran = await migration.runIfNeeded();
      expect(ran, isFalse);
      expect(await migration.isCompleted(), isFalse);
      expect(sink.writes, isEmpty);
      expect(control.desiredWrites, isEmpty);
      expect(migration.state, CloudMigrationState.idle);
    });

    test('interrupted migration resumes and completes', () async {
      final archive = await _archiveWithHistory();
      final sink = FakeAnnotationSink()..failOnUpsertOnce = 'insight_places';
      final control = FakeControlCloud();
      final sync = AnnotationCloudSync(
        archive: archive,
        sink: sink,
        accountId: control.accountId,
      );
      final migration = CloudMigration(
        archive: archive,
        annotationSyncFactory: () => sync,
        controlCloudFactory: () => control,
        enabledProvider: () => true,
      );
      await migration.load();

      final first = await migration.runIfNeeded();
      expect(first, isFalse, reason: 'first attempt should fail');
      expect(await migration.isCompleted(), isFalse);
      expect(migration.state, CloudMigrationState.failed);
      expect(sink.failCount, 1);

      // Retry — should resume and verifiably succeed, marking completed only now.
      final second = await migration.runIfNeeded();
      expect(second, isTrue);
      expect(await migration.isCompleted(), isTrue);
      expect(migration.state, CloudMigrationState.done);
      // Verify real response: writes actually present after retry
      expect(sink.writes.any((w) => w.table == 'insight_places'), isTrue);
      expect(
        control.desiredWrites.any((r) => r['key'] == 'pack_capacity_wh'),
        isTrue,
      );
    });

    test('interrupted Lane C resumes', () async {
      final archive = await _archiveWithHistory();
      final sink = FakeAnnotationSink();
      final control = FakeControlCloud()..failOnKey = 'pack_capacity_wh';
      final sync = AnnotationCloudSync(
        archive: archive,
        sink: sink,
        accountId: control.accountId,
      );
      final migration = CloudMigration(
        archive: archive,
        annotationSyncFactory: () => sync,
        controlCloudFactory: () => control,
        enabledProvider: () => true,
      );
      await migration.load();

      final first = await migration.runIfNeeded();
      expect(first, isFalse);
      expect(migration.state, CloudMigrationState.failed);
      expect(await migration.isCompleted(), isFalse);

      final second = await migration.runIfNeeded();
      expect(second, isTrue);
      expect(await migration.isCompleted(), isTrue);
      expect(
        control.desiredWrites.any((r) => r['key'] == 'pack_capacity_wh'),
        isTrue,
      );
    });

    test(
      'upload is idempotent — natural-key upsert, no duplicate rows',
      () async {
        final archive = await _archiveWithHistory();
        final sink = FakeAnnotationSink();
        final control = FakeControlCloud();

        // Use real AnnotationCloudSync push twice via migration re-run.
        // We clear the completed flag between runs to force a re-upload, then
        // verify the logical cloud rows dedup by natural key.
        final sync = AnnotationCloudSync(
          archive: archive,
          sink: sink,
          accountId: control.accountId,
        );

        Future<void> runMigrationOnce() async {
          final migration = CloudMigration(
            archive: archive,
            annotationSyncFactory: () => sync,
            controlCloudFactory: () => control,
            enabledProvider: () => true,
          );
          await migration.load();
          // Ensure not already completed for second run
          await archive.database.deleteMeta(CloudMigration.completedKey);
          await migration.load();
          final ok = await migration.runForTest();
          expect(ok, isTrue);
        }

        await runMigrationOnce();
        final firstWanted = sink.writes
            .where((w) => w.table == 'insight_places')
            .expand((w) => w.rows)
            .length;
        final firstDesired = control.desiredWrites.length;

        await runMigrationOnce();

        // Count unique logical rows by natural key after two idempotent pushes.
        // Lane B: insight_places keyed by (account_id, id)
        final allPlaceRows = sink.writes
            .where((w) => w.table == 'insight_places')
            .expand((w) => w.rows)
            .toList();
        final dedupedPlaces = <String, Map<String, Object?>>{};
        for (final row in allPlaceRows) {
          final key = '${row['account_id']}:${row['id']}';
          dedupedPlaces[key] = row;
        }
        expect(
          dedupedPlaces.length,
          firstWanted,
          reason: 'repeat upsert must not create duplicate place rows',
        );
        // Lane C: preference_desired keyed by (account_id, vehicle_id, key)
        final dedupedDesired = <String, Map<String, Object?>>{};
        for (final row in control.desiredWrites) {
          final key = '${row['account_id']}:${row['vehicle_id']}:${row['key']}';
          dedupedDesired[key] = row;
        }
        // After two runs, logical count must equal one run's count
        expect(dedupedDesired.length, firstDesired);
        // And each deduped row must still be the last value from local history
        expect(
          dedupedDesired.values.any((r) => r['key'] == 'pack_capacity_wh'),
          isTrue,
        );
      },
    );

    test('no local history marks done without needing sink', () async {
      final archive = await memoryArchive();
      await archive.upsertSession({
        'id': 'sess-empty',
        'vehicleId': 'VIN1',
        'kind': 'TRIP',
        'status': 'CLOSED',
        'startedAtUtcMillis': 1750000000000,
        'startedAtElapsedNanos': 1,
        'noLongerReducible': 0,
        'createdAtUtcMillis': 1750000000000,
        'updatedAtUtcMillis': 1750000000000,
      });
      // No places/journeys/preferences beyond the session (which is not part of migration)
      final migration = CloudMigration(
        archive: archive,
        annotationSyncFactory: () => null,
        controlCloudFactory: () => null,
        enabledProvider: () => true,
      );
      await migration.load();
      final ran = await migration.runIfNeeded();
      // No history to migrate -> still marks completed (no work)
      expect(ran, isTrue);
      expect(await migration.isCompleted(), isTrue);
    });

    test('UI state surfaces syncing/done/failed', () async {
      final archive = await _archiveWithHistory();
      final sink = FakeAnnotationSink()..failOnUpsertOnce = 'insight_places';
      final control = FakeControlCloud();
      final sync = AnnotationCloudSync(
        archive: archive,
        sink: sink,
        accountId: control.accountId,
      );
      final migration = CloudMigration(
        archive: archive,
        annotationSyncFactory: () => sync,
        controlCloudFactory: () => control,
        enabledProvider: () => true,
      );
      await migration.load();
      expect(migration.state, CloudMigrationState.idle);
      // Kick off but fail
      await migration.runIfNeeded();
      expect(migration.state, CloudMigrationState.failed);
      expect(migration.error, isNotNull);
      // Next run succeeds -> done
      await migration.runIfNeeded();
      expect(migration.state, CloudMigrationState.done);
      expect(migration.error, isNull);
    });
  });
}
