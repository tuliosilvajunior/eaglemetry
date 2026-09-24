import 'package:capy_companion/sync/annotation_cloud_sync.dart';
import 'package:capy_companion/sync/cloud_uploader.dart';
import 'package:capy_companion/sync/companion_archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

import 'support/memory_archive.dart';

class FakeAnnotationSink implements CloudSink {
  final List<
    ({
      String table,
      List<Map<String, Object?>> rows,
      List<String> conflictColumns,
      bool merge,
    })
  >
  writes = [];

  String? failOnUpsert;
  String? failOnFetch;

  final Map<String, List<Map<String, Object?>>> remoteTables = {};

  List<Map<String, Object?>> rowsFor(String table) => [
    for (final w in writes)
      if (w.table == table) ...w.rows,
  ];

  @override
  Future<void> upsert(
    String table,
    List<Map<String, Object?>> rows, {
    required List<String> conflictColumns,
    required bool merge,
  }) async {
    if (table == failOnUpsert) {
      failOnUpsert = null;
      throw StateError('refused $table');
    }
    writes.add((
      table: table,
      rows: rows,
      conflictColumns: conflictColumns,
      merge: merge,
    ));
  }

  @override
  Future<Set<String>> ownedVehicles(Set<String> ids) async => ids;

  @override
  Future<List<Map<String, Object?>>> fetch(String table) async {
    if (table == failOnFetch) {
      failOnFetch = null;
      throw StateError('fetch failed $table');
    }
    return remoteTables[table] ?? const [];
  }

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

Future<CompanionArchive> _archiveWithSession({
  String sessionId = 'sess-1',
  String vehicleId = 'VIN1',
}) async {
  final archive = await memoryArchive();
  await archive.upsertSession({
    'id': sessionId,
    'vehicleId': vehicleId,
    'kind': 'TRIP',
    'status': 'CLOSED',
    'startedAtUtcMillis': 1750000000000,
    'startedAtElapsedNanos': 1,
    'noLongerReducible': 0,
    'createdAtUtcMillis': 1750000000000,
    'updatedAtUtcMillis': 1750000000000,
  });
  return archive;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AnnotationCloudSync push', () {
    test(
      'insight_places: full per-group HLC row and conflict columns',
      () async {
        final archive = await memoryArchive();
        await archive.upsertPlace({
          'id': 'place-1',
          'name': 'Home',
          'latitude': 12.34,
          'longitude': 56.78,
          'radiusM': 150.0,
          'autoName': 'Auto Home',
          'autoNameUpdatedAtUtcMillis': 999,
          'autoNameSource': 'nominatim',
          'createdAtUtcMillis': 1000,
          'updatedAtUtcMillis': 5000,
          'origin': kAnnotationOriginPhone,
          'deletedAtUtcMillis': null,
          'hlcMillis': 5000,
          'hlcCounter': 2,
          'hlcDeviceId': 'phone-device-1',
        });

        final sink = FakeAnnotationSink();
        final sync = AnnotationCloudSync(
          archive: archive,
          sink: sink,
          accountId: 'acct-1',
        );
        final report = await sync.push();

        expect(report.perStream[AnnotationCloudSync.insightPlacesTable], 1);
        final row = sink.rowsFor(AnnotationCloudSync.insightPlacesTable).single;
        // Conflict columns
        final write = sink.writes.singleWhere(
          (w) => w.table == AnnotationCloudSync.insightPlacesTable,
        );
        expect(
          write.conflictColumns,
          AnnotationCloudSync.insightPlacesConflict,
        );
        expect(write.merge, isTrue);

        // Full row shape
        expect(row['account_id'], 'acct-1');
        expect(row['id'], 'place-1');
        expect(row['name'], 'Home');
        expect(row['latitude'], 12.34);
        expect(row['longitude'], 56.78);
        expect(row['radius_m'], 150.0);
        expect(row['auto_name'], 'Auto Home');
        expect(row['origin'], kAnnotationOriginPhone);

        // Every HLC group present and equal to the single local HLC (fan-out)
        for (final prefix in ['name_hlc', 'geofence_hlc', 'auto_name_hlc']) {
          expect(row['${prefix}_millis'], 5000);
          expect(row['${prefix}_counter'], 2);
          expect(row['${prefix}_device_id'], 'phone-device-1');
        }
      },
    );

    test(
      'session_costs: vehicle scoping, full HLC row, conflict columns',
      () async {
        final archive = await _archiveWithSession();
        await archive.upsertSessionCost({
          'sessionId': 'sess-1',
          'costPerKwh': 0.75,
          'paidAmount': 12.5,
          'costCurrency': 'BRL',
          'updatedAtUtcMillis': 6000,
          'origin': kAnnotationOriginPhone,
          'hlcMillis': 6000,
          'hlcCounter': 1,
          'hlcDeviceId': 'phone-device-2',
        });

        final sink = FakeAnnotationSink();
        final sync = AnnotationCloudSync(
          archive: archive,
          sink: sink,
          accountId: 'acct-1',
        );
        final report = await sync.push();
        expect(report.perStream[AnnotationCloudSync.sessionCostsTable], 1);
        final row = sink.rowsFor(AnnotationCloudSync.sessionCostsTable).single;
        final write = sink.writes.singleWhere(
          (w) => w.table == AnnotationCloudSync.sessionCostsTable,
        );
        expect(write.conflictColumns, AnnotationCloudSync.sessionCostsConflict);
        expect(write.merge, isTrue);
        expect(row['vehicle_id'], 'VIN1');
        expect(row['session_id'], 'sess-1');
        expect(row['account_id'], 'acct-1');
        expect(row['cost_per_kwh'], 0.75);
        expect(row['cost_currency'], 'BRL');
        expect(row['cost_hlc_millis'], 6000);
        expect(row['cost_hlc_counter'], 1);
        expect(row['cost_hlc_device_id'], 'phone-device-2');
      },
    );

    test('journeys: full per-group HLC row and conflict columns', () async {
      final archive = await memoryArchive();
      await archive.upsertJourney({
        'id': 'journey-1',
        'name': 'Road trip',
        'startedAtUtcMillis': 1000,
        'endedAtUtcMillis': 2000,
        'note': 'Nice',
        'createdAtUtcMillis': 900,
        'updatedAtUtcMillis': 7000,
        'origin': kAnnotationOriginPhone,
        'hlcMillis': 7000,
        'hlcCounter': 3,
        'hlcDeviceId': 'phone-device-3',
      });

      final sink = FakeAnnotationSink();
      final sync = AnnotationCloudSync(
        archive: archive,
        sink: sink,
        accountId: 'acct-1',
      );
      final report = await sync.push();
      expect(report.perStream[AnnotationCloudSync.journeysTable], 1);
      final row = sink.rowsFor(AnnotationCloudSync.journeysTable).single;
      final write = sink.writes.singleWhere(
        (w) => w.table == AnnotationCloudSync.journeysTable,
      );
      expect(write.conflictColumns, AnnotationCloudSync.journeysConflict);
      for (final prefix in ['name_hlc', 'note_hlc', 'time_range_hlc']) {
        expect(row['${prefix}_millis'], 7000);
        expect(row['${prefix}_counter'], 3);
        expect(row['${prefix}_device_id'], 'phone-device-3');
      }
      expect(row['account_id'], 'acct-1');
      expect(row['name'], 'Road trip');
    });

    test('preferences: row-level HLC and conflict columns', () async {
      final archive = await memoryArchive();
      await archive.upsertPreference({
        'scope': 'account',
        'key': 'theme_id',
        'value': 'dark',
        'updatedAtUtcMillis': 8000,
        'origin': kAnnotationOriginPhone,
        'hlcMillis': 8000,
        'hlcCounter': 0,
        'hlcDeviceId': 'phone-device-4',
      });

      final sink = FakeAnnotationSink();
      final sync = AnnotationCloudSync(
        archive: archive,
        sink: sink,
        accountId: 'acct-1',
      );
      final report = await sync.push();
      expect(report.perStream[AnnotationCloudSync.preferencesTable], 1);
      final row = sink.rowsFor(AnnotationCloudSync.preferencesTable).single;
      final write = sink.writes.singleWhere(
        (w) => w.table == AnnotationCloudSync.preferencesTable,
      );
      expect(write.conflictColumns, AnnotationCloudSync.preferencesConflict);
      expect(row['account_id'], 'acct-1');
      expect(row['scope'], 'account');
      expect(row['key'], 'theme_id');
      expect(row['value'], 'dark');
      expect(row['hlc_millis'], 8000);
      expect(row['hlc_counter'], 0);
      expect(row['hlc_device_id'], 'phone-device-4');
    });

    test(
      'push is durable: offline write retried on next pass (full set)',
      () async {
        final archive = await memoryArchive();
        await archive.upsertPreference({
          'scope': 'account',
          'key': 'theme_id',
          'value': 'dark',
          'updatedAtUtcMillis': 1000,
          'origin': kAnnotationOriginPhone,
          'hlcMillis': 1000,
          'hlcCounter': 0,
          'hlcDeviceId': 'phone-1',
        });
        final sink = FakeAnnotationSink()..failOnUpsert = 'preferences';
        final sync = AnnotationCloudSync(
          archive: archive,
          sink: sink,
          accountId: 'acct-1',
        );
        final first = await sync.push();
        // First pass failed, nothing counted
        expect(first.perStream[AnnotationCloudSync.preferencesTable], isNull);
        expect(
          first.errors.containsKey(AnnotationCloudSync.preferencesTable),
          isTrue,
        );
        // Next pass retries and succeeds (no dirty clear, full set)
        final second = await sync.push();
        expect(second.perStream[AnnotationCloudSync.preferencesTable], 1);
      },
    );

    test('failed table does not block other tables', () async {
      final archive = await memoryArchive();
      await archive.upsertPlace({
        'id': 'p1',
        'name': 'Home',
        'latitude': 0,
        'longitude': 0,
        'updatedAtUtcMillis': 1000,
        'origin': kAnnotationOriginPhone,
        'hlcMillis': 1000,
        'hlcCounter': 0,
        'hlcDeviceId': 'phone-1',
      });
      await archive.upsertPreference({
        'scope': 'account',
        'key': 'theme_id',
        'value': 'dark',
        'updatedAtUtcMillis': 1000,
        'origin': kAnnotationOriginPhone,
        'hlcMillis': 1000,
        'hlcCounter': 0,
        'hlcDeviceId': 'phone-1',
      });

      final sink = FakeAnnotationSink()
        ..failOnUpsert = AnnotationCloudSync.insightPlacesTable;
      final sync = AnnotationCloudSync(
        archive: archive,
        sink: sink,
        accountId: 'acct-1',
      );
      final report = await sync.push();
      expect(
        report.errors.containsKey(AnnotationCloudSync.insightPlacesTable),
        isTrue,
      );
      // Preferences still went up
      expect(report.perStream[AnnotationCloudSync.preferencesTable], 1);
      expect(sink.rowsFor(AnnotationCloudSync.preferencesTable), hasLength(1));
    });
  });

  group('AnnotationCloudSync pull', () {
    test('remote newer wins (millis greater)', () async {
      final archive = await memoryArchive();
      await archive.upsertPreference({
        'scope': 'account',
        'key': 'theme_id',
        'value': 'dark',
        'updatedAtUtcMillis': 1000,
        'origin': kAnnotationOriginPhone,
        'hlcMillis': 1000,
        'hlcCounter': 0,
        'hlcDeviceId': 'phone-1',
      });

      final sink = FakeAnnotationSink();
      sink.remoteTables[AnnotationCloudSync.preferencesTable] = [
        {
          'account_id': 'acct-1',
          'scope': 'account',
          'key': 'theme_id',
          'value': 'light',
          'updated_at_utc_millis': 2000,
          'origin': kAnnotationOriginCar,
          'deleted_at_utc_millis': null,
          'hlc_millis': 2000,
          'hlc_counter': 0,
          'hlc_device_id': 'car-1',
        },
      ];

      final sync = AnnotationCloudSync(
        archive: archive,
        sink: sink,
        accountId: 'acct-1',
      );
      await sync.pull();

      final rows = await archive.database.allPreferences();
      expect(rows.single['value'], 'light');
    });

    test(
      'local newer wins (millis greater) — remote stale is ignored',
      () async {
        final archive = await memoryArchive();
        await archive.upsertPreference({
          'scope': 'account',
          'key': 'theme_id',
          'value': 'midnight',
          'updatedAtUtcMillis': 3000,
          'origin': kAnnotationOriginPhone,
          'hlcMillis': 3000,
          'hlcCounter': 0,
          'hlcDeviceId': 'phone-1',
        });

        final sink = FakeAnnotationSink();
        sink.remoteTables[AnnotationCloudSync.preferencesTable] = [
          {
            'account_id': 'acct-1',
            'scope': 'account',
            'key': 'theme_id',
            'value': 'light',
            'updated_at_utc_millis': 1000,
            'origin': kAnnotationOriginCar,
            'deleted_at_utc_millis': null,
            'hlc_millis': 1000,
            'hlc_counter': 0,
            'hlc_device_id': 'car-1',
          },
        ];

        final sync = AnnotationCloudSync(
          archive: archive,
          sink: sink,
          accountId: 'acct-1',
        );
        await sync.pull();

        final rows = await archive.database.allPreferences();
        expect(rows.single['value'], 'midnight');
      },
    );

    test(
      'tie resolved by device_id lexicographic (zzz wins over aaa)',
      () async {
        final archive = await memoryArchive();
        await archive.upsertPreference({
          'scope': 'account',
          'key': 'theme_id',
          'value': 'dark',
          'updatedAtUtcMillis': 1000,
          'origin': kAnnotationOriginPhone,
          'hlcMillis': 1000,
          'hlcCounter': 0,
          'hlcDeviceId': 'aaa',
        });

        final sink = FakeAnnotationSink();
        sink.remoteTables[AnnotationCloudSync.preferencesTable] = [
          {
            'account_id': 'acct-1',
            'scope': 'account',
            'key': 'theme_id',
            'value': 'light',
            'updated_at_utc_millis': 1000,
            'origin': kAnnotationOriginCar,
            'deleted_at_utc_millis': null,
            'hlc_millis': 1000,
            'hlc_counter': 0,
            'hlc_device_id': 'zzz',
          },
        ];

        final sync = AnnotationCloudSync(
          archive: archive,
          sink: sink,
          accountId: 'acct-1',
        );
        await sync.pull();

        final rows = await archive.database.allPreferences();
        // zzz > aaa, so remote wins
        expect(rows.single['value'], 'light');

        // Reverse: local zzz should win over remote aaa
        final archive2 = await memoryArchive();
        await archive2.upsertPreference({
          'scope': 'account',
          'key': 'theme_id',
          'value': 'dark',
          'updatedAtUtcMillis': 1000,
          'origin': kAnnotationOriginPhone,
          'hlcMillis': 1000,
          'hlcCounter': 0,
          'hlcDeviceId': 'zzz',
        });
        final sink2 = FakeAnnotationSink();
        sink2.remoteTables[AnnotationCloudSync.preferencesTable] = [
          {
            'account_id': 'acct-1',
            'scope': 'account',
            'key': 'theme_id',
            'value': 'light',
            'updated_at_utc_millis': 1000,
            'origin': kAnnotationOriginCar,
            'deleted_at_utc_millis': null,
            'hlc_millis': 1000,
            'hlc_counter': 0,
            'hlc_device_id': 'aaa',
          },
        ];
        final sync2 = AnnotationCloudSync(
          archive: archive2,
          sink: sink2,
          accountId: 'acct-1',
        );
        await sync2.pull();
        final rows2 = await archive2.database.allPreferences();
        expect(rows2.single['value'], 'dark');
      },
    );

    test('pull merges session_costs with HLC tie-break', () async {
      final archive = await _archiveWithSession();
      await archive.upsertSessionCost({
        'sessionId': 'sess-1',
        'costPerKwh': 0.5,
        'paidAmount': 10.0,
        'costCurrency': 'USD',
        'updatedAtUtcMillis': 1000,
        'origin': kAnnotationOriginPhone,
        'hlcMillis': 1000,
        'hlcCounter': 0,
        'hlcDeviceId': 'aaa',
      });

      final sink = FakeAnnotationSink();
      sink.remoteTables[AnnotationCloudSync.sessionCostsTable] = [
        {
          'vehicle_id': 'VIN1',
          'session_id': 'sess-1',
          'account_id': 'acct-1',
          'cost_per_kwh': 0.9,
          'paid_amount': 20.0,
          'cost_currency': 'EUR',
          'updated_at_utc_millis': 2000,
          'origin': kAnnotationOriginCar,
          'cost_hlc_millis': 2000,
          'cost_hlc_counter': 0,
          'cost_hlc_device_id': 'car-1',
        },
      ];

      final sync = AnnotationCloudSync(
        archive: archive,
        sink: sink,
        accountId: 'acct-1',
      );
      await sync.pull();
      final cost = await archive.database.sessionCost('sess-1');
      expect(cost?['costPerKwh'], 0.9);
      expect(cost?['costCurrency'], 'EUR');
    });

    test(
      'pull does not crash on per-row failure, other rows still merged',
      () async {
        final archive = await memoryArchive();
        // One good preference already local
        await archive.upsertPreference({
          'scope': 'account',
          'key': 'theme_id',
          'value': 'dark',
          'updatedAtUtcMillis': 1000,
          'origin': kAnnotationOriginPhone,
          'hlcMillis': 1000,
          'hlcCounter': 0,
          'hlcDeviceId': 'aaa',
        });

        final sink = FakeAnnotationSink();
        sink.remoteTables[AnnotationCloudSync.preferencesTable] = [
          // Bad row missing scope/key -> should be skipped, not crash
          {
            'account_id': 'acct-1',
            'value': 'bad',
            'updated_at_utc_millis': 2000,
            'origin': kAnnotationOriginCar,
            'hlc_millis': 2000,
            'hlc_counter': 0,
            'hlc_device_id': 'car-1',
          },
          // Good row with newer HLC
          {
            'account_id': 'acct-1',
            'scope': 'account',
            'key': 'theme_id',
            'value': 'light',
            'updated_at_utc_millis': 2000,
            'origin': kAnnotationOriginCar,
            'deleted_at_utc_millis': null,
            'hlc_millis': 2000,
            'hlc_counter': 0,
            'hlc_device_id': 'car-1',
          },
        ];

        final sync = AnnotationCloudSync(
          archive: archive,
          sink: sink,
          accountId: 'acct-1',
        );
        // Should not throw
        await sync.pull();
        final rows = await archive.database.allPreferences();
        expect(rows.single['value'], 'light');
      },
    );

    test('fetch failure per-table does not block other tables', () async {
      final archive = await memoryArchive();
      await archive.upsertPreference({
        'scope': 'account',
        'key': 'theme_id',
        'value': 'dark',
        'updatedAtUtcMillis': 1000,
        'origin': kAnnotationOriginPhone,
        'hlcMillis': 1000,
        'hlcCounter': 0,
        'hlcDeviceId': 'aaa',
      });

      final sink = FakeAnnotationSink();
      sink.failOnFetch = AnnotationCloudSync.journeysTable;
      sink.remoteTables[AnnotationCloudSync.preferencesTable] = [
        {
          'account_id': 'acct-1',
          'scope': 'account',
          'key': 'theme_id',
          'value': 'light',
          'updated_at_utc_millis': 2000,
          'origin': kAnnotationOriginCar,
          'deleted_at_utc_millis': null,
          'hlc_millis': 2000,
          'hlc_counter': 0,
          'hlc_device_id': 'car-1',
        },
      ];

      final sync = AnnotationCloudSync(
        archive: archive,
        sink: sink,
        accountId: 'acct-1',
      );
      final report = await sync.pull();
      expect(
        report.errors.containsKey(AnnotationCloudSync.journeysTable),
        isTrue,
      );
      // Preferences still merged despite journeys fetch failure
      final rows = await archive.database.allPreferences();
      expect(rows.single['value'], 'light');
    });

    test(
      'places pull applies per-group merge and respects device_id tie',
      () async {
        final archive = await memoryArchive();
        await archive.upsertPlace({
          'id': 'place-1',
          'name': 'Phone Home',
          'latitude': 1.0,
          'longitude': 1.0,
          'radiusM': 150.0,
          'updatedAtUtcMillis': 1000,
          'origin': kAnnotationOriginPhone,
          'hlcMillis': 1000,
          'hlcCounter': 0,
          'hlcDeviceId': 'aaa',
        });

        final sink = FakeAnnotationSink();
        sink.remoteTables[AnnotationCloudSync.insightPlacesTable] = [
          {
            'id': 'place-1',
            'account_id': 'acct-1',
            'name': 'Car Home',
            'latitude': 1.0,
            'longitude': 1.0,
            'radius_m': 150.0,
            'created_at_utc_millis': 1000,
            'updated_at_utc_millis': 1000,
            'origin': kAnnotationOriginCar,
            'deleted_at_utc_millis': null,
            'auto_name': null,
            'auto_name_updated_at_utc_millis': null,
            'auto_name_source': null,
            'name_hlc_millis': 1000,
            'name_hlc_counter': 0,
            'name_hlc_device_id': 'zzz',
            'geofence_hlc_millis': 1000,
            'geofence_hlc_counter': 0,
            'geofence_hlc_device_id': 'zzz',
            'auto_name_hlc_millis': 0,
            'auto_name_hlc_counter': 0,
            'auto_name_hlc_device_id': '',
          },
        ];

        final sync = AnnotationCloudSync(
          archive: archive,
          sink: sink,
          accountId: 'acct-1',
        );
        await sync.pull();
        final rows = await archive.database.allPlaces();
        // zzz > aaa with same millis/counter, so car wins
        expect(rows.single['name'], 'Car Home');
      },
    );

    test(
      'places pull mixed per-field: local name wins, remote geofence wins',
      () async {
        final archive = await memoryArchive();
        // Local has newer name HLC (5000) but older overall? We use single HLC 5000.
        // To simulate mixed, we need local HLC 5000, remote name HLC 1000 (loses),
        // remote geofence HLC 6000 (wins). Since local stores single HLC, we
        // simulate by setting local HLC to 5000 and remote groups accordingly.
        // Local row: name=LocalName, geofence=1,1
        await archive.upsertPlace({
          'id': 'place-mix',
          'name': 'LocalName',
          'latitude': 1.0,
          'longitude': 1.0,
          'radiusM': 100.0,
          'updatedAtUtcMillis': 5000,
          'origin': kAnnotationOriginPhone,
          'hlcMillis': 5000,
          'hlcCounter': 0,
          'hlcDeviceId': 'phone-1',
          'autoName': 'AutoLocal',
          'autoNameUpdatedAtUtcMillis': 5000,
          'autoNameSource': 'local',
        });

        final sink = FakeAnnotationSink();
        sink.remoteTables[AnnotationCloudSync.insightPlacesTable] = [
          {
            'id': 'place-mix',
            'account_id': 'acct-1',
            'name': 'RemoteName',
            'latitude': 2.0,
            'longitude': 2.0,
            'radius_m': 200.0,
            'created_at_utc_millis': 1000,
            'updated_at_utc_millis': 6000,
            'origin': kAnnotationOriginCar,
            'deleted_at_utc_millis': null,
            'auto_name': 'AutoRemote',
            'auto_name_updated_at_utc_millis': 6000,
            'auto_name_source': 'remote',
            // name loses (1000 < 5000)
            'name_hlc_millis': 1000,
            'name_hlc_counter': 0,
            'name_hlc_device_id': 'car-1',
            // geofence wins (6000 > 5000)
            'geofence_hlc_millis': 6000,
            'geofence_hlc_counter': 0,
            'geofence_hlc_device_id': 'car-1',
            // auto_name loses (1000 < 5000)
            'auto_name_hlc_millis': 1000,
            'auto_name_hlc_counter': 0,
            'auto_name_hlc_device_id': 'car-1',
          },
        ];

        final sync = AnnotationCloudSync(
          archive: archive,
          sink: sink,
          accountId: 'acct-1',
        );
        await sync.pull();
        final rows = await archive.database.allPlaces();
        final row = rows.single;
        // Local name preserved, remote geofence applied.
        expect(row['name'], 'LocalName');
        expect(row['latitude'], 2.0);
        expect(row['longitude'], 2.0);
        expect(row['radiusM'], 200.0);
        // autoName stays local because remote auto_name HLC lost
        expect(row['autoName'], 'AutoLocal');
      },
    );

    test(
      'places pull remote tombstone wins even when no field group wins (M-1)',
      () async {
        final archive = await memoryArchive();
        await archive.upsertPlace({
          'id': 'place-tomb',
          'name': 'Alive',
          'latitude': 1.0,
          'longitude': 1.0,
          'radiusM': 100.0,
          'updatedAtUtcMillis': 5000,
          'origin': kAnnotationOriginPhone,
          'hlcMillis': 5000,
          'hlcCounter': 0,
          'hlcDeviceId': 'phone-1',
        });

        final sink = FakeAnnotationSink();
        // Remote is deleted with tombstone clock 6000 > local 5000,
        // but all field HLCs are stale (1000) — so only tombstone should win.
        sink.remoteTables[AnnotationCloudSync.insightPlacesTable] = [
          {
            'id': 'place-tomb',
            'account_id': 'acct-1',
            'name': 'Alive',
            'latitude': 1.0,
            'longitude': 1.0,
            'radius_m': 100.0,
            'created_at_utc_millis': 1000,
            'updated_at_utc_millis': 6000,
            'origin': kAnnotationOriginCar,
            'deleted_at_utc_millis': 6000,
            'auto_name': null,
            'auto_name_updated_at_utc_millis': null,
            'auto_name_source': null,
            'name_hlc_millis': 1000,
            'name_hlc_counter': 0,
            'name_hlc_device_id': 'car-1',
            'geofence_hlc_millis': 1000,
            'geofence_hlc_counter': 0,
            'geofence_hlc_device_id': 'car-1',
            'auto_name_hlc_millis': 1000,
            'auto_name_hlc_counter': 0,
            'auto_name_hlc_device_id': 'car-1',
          },
        ];

        final sync = AnnotationCloudSync(
          archive: archive,
          sink: sink,
          accountId: 'acct-1',
        );
        await sync.pull();
        final rows = await archive.database.allPlaces();
        expect(rows.single['deletedAtUtcMillis'], 6000);
      },
    );

    test(
      'places pull local tombstone + remote resurrect via field beating tombstone',
      () async {
        final archive = await memoryArchive();
        await archive.upsertPlace({
          'id': 'place-resurrect',
          'name': 'Old',
          'latitude': 1.0,
          'longitude': 1.0,
          'radiusM': 100.0,
          'updatedAtUtcMillis': 5000,
          'origin': kAnnotationOriginPhone,
          'hlcMillis': 5000,
          'hlcCounter': 0,
          'hlcDeviceId': 'phone-1',
          'deletedAtUtcMillis': 5000,
        });

        final sink = FakeAnnotationSink();
        // Remote is alive with name HLC 6000 > tombstone 5000, should resurrect.
        sink.remoteTables[AnnotationCloudSync.insightPlacesTable] = [
          {
            'id': 'place-resurrect',
            'account_id': 'acct-1',
            'name': 'Resurrected',
            'latitude': 1.0,
            'longitude': 1.0,
            'radius_m': 100.0,
            'created_at_utc_millis': 1000,
            'updated_at_utc_millis': 6000,
            'origin': kAnnotationOriginCar,
            'deleted_at_utc_millis': null,
            'auto_name': null,
            'auto_name_updated_at_utc_millis': null,
            'auto_name_source': null,
            'name_hlc_millis': 6000,
            'name_hlc_counter': 0,
            'name_hlc_device_id': 'car-1',
            'geofence_hlc_millis': 1000,
            'geofence_hlc_counter': 0,
            'geofence_hlc_device_id': 'car-1',
            'auto_name_hlc_millis': 0,
            'auto_name_hlc_counter': 0,
            'auto_name_hlc_device_id': '',
          },
        ];

        final sync = AnnotationCloudSync(
          archive: archive,
          sink: sink,
          accountId: 'acct-1',
        );
        await sync.pull();
        final rows = await archive.database.allPlaces();
        final row = rows.single;
        expect(row['deletedAtUtcMillis'], isNull);
        expect(row['name'], 'Resurrected');
      },
    );

    test(
      'places pull local tombstone + remote resurrect fails when field does not beat tombstone',
      () async {
        final archive = await memoryArchive();
        await archive.upsertPlace({
          'id': 'place-stay-deleted',
          'name': 'Old',
          'latitude': 1.0,
          'longitude': 1.0,
          'radiusM': 100.0,
          'updatedAtUtcMillis': 5000,
          'origin': kAnnotationOriginPhone,
          'hlcMillis': 5000,
          'hlcCounter': 0,
          'hlcDeviceId': 'phone-1',
          'deletedAtUtcMillis': 5000,
        });

        final sink = FakeAnnotationSink();
        // Remote alive but field HLC 4000 < tombstone 5000, should stay deleted.
        sink.remoteTables[AnnotationCloudSync.insightPlacesTable] = [
          {
            'id': 'place-stay-deleted',
            'account_id': 'acct-1',
            'name': 'ShouldNotResurrect',
            'latitude': 9.0,
            'longitude': 9.0,
            'radius_m': 999.0,
            'created_at_utc_millis': 1000,
            'updated_at_utc_millis': 4000,
            'origin': kAnnotationOriginCar,
            'deleted_at_utc_millis': null,
            'auto_name': null,
            'auto_name_updated_at_utc_millis': null,
            'auto_name_source': null,
            'name_hlc_millis': 4000,
            'name_hlc_counter': 0,
            'name_hlc_device_id': 'car-1',
            'geofence_hlc_millis': 4000,
            'geofence_hlc_counter': 0,
            'geofence_hlc_device_id': 'car-1',
            'auto_name_hlc_millis': 0,
            'auto_name_hlc_counter': 0,
            'auto_name_hlc_device_id': '',
          },
        ];

        final sync = AnnotationCloudSync(
          archive: archive,
          sink: sink,
          accountId: 'acct-1',
        );
        await sync.pull();
        final rows = await archive.database.allPlaces();
        final row = rows.single;
        expect(row['deletedAtUtcMillis'], 5000);
        expect(row['name'], 'Old');
      },
    );

    test('places pull both deleted keeps newer tombstone', () async {
      final archive = await memoryArchive();
      await archive.upsertPlace({
        'id': 'place-both-del',
        'name': 'Gone',
        'latitude': 1.0,
        'longitude': 1.0,
        'radiusM': 100.0,
        'updatedAtUtcMillis': 4000,
        'origin': kAnnotationOriginPhone,
        'hlcMillis': 4000,
        'hlcCounter': 0,
        'hlcDeviceId': 'phone-1',
        'deletedAtUtcMillis': 4000,
      });

      final sink = FakeAnnotationSink();
      sink.remoteTables[AnnotationCloudSync.insightPlacesTable] = [
        {
          'id': 'place-both-del',
          'account_id': 'acct-1',
          'name': 'Gone',
          'latitude': 1.0,
          'longitude': 1.0,
          'radius_m': 100.0,
          'created_at_utc_millis': 1000,
          'updated_at_utc_millis': 6000,
          'origin': kAnnotationOriginCar,
          'deleted_at_utc_millis': 6000,
          'auto_name': null,
          'auto_name_updated_at_utc_millis': null,
          'auto_name_source': null,
          'name_hlc_millis': 1000,
          'name_hlc_counter': 0,
          'name_hlc_device_id': 'car-1',
          'geofence_hlc_millis': 1000,
          'geofence_hlc_counter': 0,
          'geofence_hlc_device_id': 'car-1',
          'auto_name_hlc_millis': 0,
          'auto_name_hlc_counter': 0,
          'auto_name_hlc_device_id': '',
        },
      ];

      final sync = AnnotationCloudSync(
        archive: archive,
        sink: sink,
        accountId: 'acct-1',
      );
      await sync.pull();
      final rows = await archive.database.allPlaces();
      // Newer tombstone wins (6000)
      expect(rows.single['deletedAtUtcMillis'], 6000);
      expect(rows.single['updatedAtUtcMillis'], 6000);
    });

    test('journeys pull applies per-group merge', () async {
      final archive = await memoryArchive();
      await archive.upsertJourney({
        'id': 'journey-1',
        'name': 'Local Journey',
        'note': 'Local note',
        'startedAtUtcMillis': 1000,
        'endedAtUtcMillis': 2000,
        'createdAtUtcMillis': 900,
        'updatedAtUtcMillis': 5000,
        'origin': kAnnotationOriginPhone,
        'hlcMillis': 5000,
        'hlcCounter': 0,
        'hlcDeviceId': 'phone-1',
      });

      final sink = FakeAnnotationSink();
      sink.remoteTables[AnnotationCloudSync.journeysTable] = [
        {
          'id': 'journey-1',
          'account_id': 'acct-1',
          'name': 'Remote Journey',
          'note': 'Remote note',
          'started_at_utc_millis': 3000,
          'ended_at_utc_millis': 4000,
          'created_at_utc_millis': 900,
          'updated_at_utc_millis': 6000,
          'origin': kAnnotationOriginCar,
          'deleted_at_utc_millis': null,
          'name_hlc_millis': 1000,
          'name_hlc_counter': 0,
          'name_hlc_device_id': 'car-1',
          'note_hlc_millis': 6000,
          'note_hlc_counter': 0,
          'note_hlc_device_id': 'car-1',
          'time_range_hlc_millis': 6000,
          'time_range_hlc_counter': 0,
          'time_range_hlc_device_id': 'car-1',
        },
      ];

      final sync = AnnotationCloudSync(
        archive: archive,
        sink: sink,
        accountId: 'acct-1',
      );
      await sync.pull();
      final rows = await archive.database.allJourneys();
      final row = rows.single;
      // name stays local (remote 1000 < 5000), note and time_range win.
      expect(row['name'], 'Local Journey');
      expect(row['note'], 'Remote note');
      expect(row['startedAtUtcMillis'], 3000);
      expect(row['endedAtUtcMillis'], 4000);
    });

    test('places pull auto_name respects origin rank (car > phone)', () async {
      final archive = await memoryArchive();
      await archive.upsertPlace({
        'id': 'place-auto-rank',
        'name': 'Home',
        'latitude': 1.0,
        'longitude': 1.0,
        'radiusM': 100.0,
        'updatedAtUtcMillis': 1000,
        'origin': kAnnotationOriginPhone,
        'hlcMillis': 1000,
        'hlcCounter': 0,
        'hlcDeviceId': 'zzz',
        'autoName': 'PhoneAuto',
        'autoNameUpdatedAtUtcMillis': 1000,
        'autoNameSource': 'phone',
      });

      final sink = FakeAnnotationSink();
      // Same millis/counter/deviceId tie? Use car origin with same HLC millis.
      // With origin rank, car should win over phone even with same millis/counter/deviceId lexicographically smaller.
      sink.remoteTables[AnnotationCloudSync.insightPlacesTable] = [
        {
          'id': 'place-auto-rank',
          'account_id': 'acct-1',
          'name': 'Home',
          'latitude': 1.0,
          'longitude': 1.0,
          'radius_m': 100.0,
          'created_at_utc_millis': 1000,
          'updated_at_utc_millis': 1000,
          'origin': kAnnotationOriginCar,
          'deleted_at_utc_millis': null,
          'auto_name': 'CarAuto',
          'auto_name_updated_at_utc_millis': 1000,
          'auto_name_source': 'car',
          'name_hlc_millis': 0,
          'name_hlc_counter': 0,
          'name_hlc_device_id': '',
          'geofence_hlc_millis': 0,
          'geofence_hlc_counter': 0,
          'geofence_hlc_device_id': '',
          'auto_name_hlc_millis': 1000,
          'auto_name_hlc_counter': 0,
          // Use same deviceId 'aaa' which is < 'zzz', so deviceId tie would lose,
          // but origin rank car(2) > phone(1) should still win.
          'auto_name_hlc_device_id': 'aaa',
        },
      ];

      final sync = AnnotationCloudSync(
        archive: archive,
        sink: sink,
        accountId: 'acct-1',
      );
      await sync.pull();
      final rows = await archive.database.allPlaces();
      expect(rows.single['autoName'], 'CarAuto');

      // Reverse: phone should not beat car with same millis.
      final archive2 = await memoryArchive();
      await archive2.upsertPlace({
        'id': 'place-auto-rank2',
        'name': 'Home',
        'latitude': 1.0,
        'longitude': 1.0,
        'radiusM': 100.0,
        'updatedAtUtcMillis': 1000,
        'origin': kAnnotationOriginCar,
        'hlcMillis': 1000,
        'hlcCounter': 0,
        'hlcDeviceId': 'zzz',
        'autoName': 'CarAuto',
        'autoNameUpdatedAtUtcMillis': 1000,
        'autoNameSource': 'car',
      });
      final sink2 = FakeAnnotationSink();
      sink2.remoteTables[AnnotationCloudSync.insightPlacesTable] = [
        {
          'id': 'place-auto-rank2',
          'account_id': 'acct-1',
          'name': 'Home',
          'latitude': 1.0,
          'longitude': 1.0,
          'radius_m': 100.0,
          'created_at_utc_millis': 1000,
          'updated_at_utc_millis': 1000,
          'origin': kAnnotationOriginPhone,
          'deleted_at_utc_millis': null,
          'auto_name': 'PhoneAuto',
          'auto_name_updated_at_utc_millis': 1000,
          'auto_name_source': 'phone',
          'name_hlc_millis': 0,
          'name_hlc_counter': 0,
          'name_hlc_device_id': '',
          'geofence_hlc_millis': 0,
          'geofence_hlc_counter': 0,
          'geofence_hlc_device_id': '',
          'auto_name_hlc_millis': 1000,
          'auto_name_hlc_counter': 0,
          'auto_name_hlc_device_id': 'zzz',
        },
      ];
      final sync2 = AnnotationCloudSync(
        archive: archive2,
        sink: sink2,
        accountId: 'acct-1',
      );
      await sync2.pull();
      final rows2 = await archive2.database.allPlaces();
      // Car's auto name should remain because phone rank is lower with equal millis/counter/deviceId
      expect(rows2.single['autoName'], 'CarAuto');
    });

    test(
      'preferences pull stale remote delete + winning value stays alive (N-1 branch B)',
      () async {
        final archive = await memoryArchive();
        await archive.upsertPreference({
          'scope': 'account',
          'key': 'theme_id',
          'value': 'dark',
          'updatedAtUtcMillis': 5000,
          'origin': 'phone-A',
          'hlcMillis': 5000,
          'hlcCounter': 0,
          'hlcDeviceId': 'phone-A',
          'deletedAtUtcMillis': null,
        });
        final sink = FakeAnnotationSink();
        sink.remoteTables[AnnotationCloudSync.preferencesTable] = [
          {
            'account_id': 'acct-1',
            'scope': 'account',
            'key': 'theme_id',
            'value': 'light',
            'updated_at_utc_millis': 5000,
            'origin': 'car-B',
            'deleted_at_utc_millis': 5000,
            'hlc_millis': 5000,
            'hlc_counter': 1,
            'hlc_device_id': 'car-B',
          },
        ];
        final sync = AnnotationCloudSync(
          archive: archive,
          sink: sink,
          accountId: 'acct-1',
        );
        await sync.pull();
        final rows = await archive.database.allPreferences();
        final row = rows.single;
        expect(row['value'], 'light');
        expect(row['deletedAtUtcMillis'], isNull);
      },
    );

    test(
      'preferences pull both deleted keeps newer local tombstone while applying gated value (N-1 branch D)',
      () async {
        final archive = await memoryArchive();
        await archive.upsertPreference({
          'scope': 'account',
          'key': 'theme_id',
          'value': 'dark',
          'updatedAtUtcMillis': 5000,
          'origin': 'phone-A',
          'hlcMillis': 5000,
          'hlcCounter': 0,
          'hlcDeviceId': 'phone-A',
          'deletedAtUtcMillis': 5000,
        });
        final sink = FakeAnnotationSink();
        sink.remoteTables[AnnotationCloudSync.preferencesTable] = [
          {
            'account_id': 'acct-1',
            'scope': 'account',
            'key': 'theme_id',
            'value': 'light',
            'updated_at_utc_millis': 4000,
            'origin': 'car-B',
            'deleted_at_utc_millis': 4000,
            'hlc_millis': 6000,
            'hlc_counter': 0,
            'hlc_device_id': 'car-B',
          },
        ];
        final sync = AnnotationCloudSync(
          archive: archive,
          sink: sink,
          accountId: 'acct-1',
        );
        await sync.pull();
        final rows = await archive.database.allPreferences();
        final row = rows.single;
        expect(row['value'], 'light');
        expect(row['deletedAtUtcMillis'], 5000);
        expect(row['updatedAtUtcMillis'], 5000);
      },
    );
  });

  group('Finding 1 — phone outbox drains on successful cloud Lane B push', () {
    test(
      'cloud push drains outbox for pushed streams so cutover can become ready',
      () async {
        final archive = await memoryArchive();
        // Create a place and enqueue an outbox row — phone has pending annotation.
        await archive.upsertPlace({
          'id': 'place-f1',
          'name': 'Home',
          'latitude': 1.0,
          'longitude': 2.0,
          'radiusM': 100.0,
          'createdAtUtcMillis': 1000,
          'updatedAtUtcMillis': 1000,
          'origin': 'phone-A',
          'hlcMillis': 1000,
          'hlcCounter': 0,
          'hlcDeviceId': 'phone-A',
        });
        await archive.database.enqueueAnnotationPush('places', {
          'id': 'place-f1',
          'op': 'rename',
        });
        await archive.database.enqueueAnnotationPush('preferences', {
          'scope': 'account',
          'key': 'theme_id',
          'value': 'dark',
        });
        expect((await archive.database.pendingAnnotationPush()).length, 2);

        final sink = FakeAnnotationSink();
        final sync = AnnotationCloudSync(
          archive: archive,
          sink: sink,
          accountId: 'acct-1',
        );
        final report = await sync.push();
        expect(report.hasErrors, isFalse);
        // After successful cloud push, the corresponding outbox rows must be drained.
        expect(
          await archive.database.pendingAnnotationPush(),
          isEmpty,
          reason: 'outbox must drain after cloud Lane B push (Finding 1 fix)',
        );
      },
    );

    test('outbox for failed table is preserved for retry', () async {
      final archive = await memoryArchive();
      await archive.upsertPlace({
        'id': 'place-f2',
        'name': 'Work',
        'latitude': 3.0,
        'longitude': 4.0,
        'radiusM': 150.0,
        'createdAtUtcMillis': 1000,
        'updatedAtUtcMillis': 1000,
        'origin': 'phone-A',
        'hlcMillis': 1000,
        'hlcCounter': 0,
        'hlcDeviceId': 'phone-A',
      });
      await archive.upsertPreference({
        'scope': 'account',
        'key': 'theme_id',
        'value': 'light',
        'updatedAtUtcMillis': 1000,
        'origin': 'phone-A',
        'hlcMillis': 1000,
        'hlcCounter': 0,
        'hlcDeviceId': 'phone-A',
      });
      await archive.database.enqueueAnnotationPush('places', {
        'id': 'place-f2',
      });
      await archive.database.enqueueAnnotationPush('preferences', {
        'scope': 'account',
        'key': 'theme_id',
        'value': 'light',
      });

      final sink = FakeAnnotationSink()
        ..failOnUpsert = AnnotationCloudSync.preferencesTable;
      final sync = AnnotationCloudSync(
        archive: archive,
        sink: sink,
        accountId: 'acct-1',
      );
      final report = await sync.push();
      expect(report.hasErrors, isTrue);
      expect(
        report.errors.containsKey(AnnotationCloudSync.preferencesTable),
        isTrue,
      );
      // Places succeeded so its outbox should be drained; preferences failed so preserved.
      final remaining = await archive.database.pendingAnnotationPush();
      expect(remaining.map((e) => e.stream), contains('preferences'));
      expect(remaining.map((e) => e.stream), isNot(contains('places')));
    });
  });
}
