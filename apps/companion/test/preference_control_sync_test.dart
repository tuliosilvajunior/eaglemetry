import 'package:capy_companion/sync/cloud_uploader.dart';
import 'package:capy_companion/sync/preference_control_cloud.dart';
import 'package:capy_companion/sync/preference_control_sync.dart';
import 'package:flutter_test/flutter_test.dart';

const accountId = '00000000-0000-4000-a000-000000000001';
const vehicleId = 'VIN-CAR-1';

/// A fake [PreferenceControlCloud] that records writes and serves a seeded
/// view — the car-side tests' fake-double style. Nothing here touches a
/// network.
class FakePreferenceControlCloud implements PreferenceControlCloud {
  FakePreferenceControlCloud({required this.accountId});

  @override
  final String accountId;
  bool configured = true;

  /// Rows the fake returns from `readStatus`, seeded by tests.
  List<Map<String, Object?>> viewRows = [];

  /// The desired rows `writeDesired` was asked to send, in order.
  final List<Map<String, Object?>> wrote = [];

  Object? failRead;
  Object? failWrite;

  @override
  bool get isConfigured => configured;

  @override
  Future<void> writeDesired({
    required String accountId,
    required String vehicleId,
    required String key,
    String? value,
    required int proposedAtUtcMillis,
    required String origin,
  }) async {
    if (failWrite != null) {
      final error = failWrite!;
      failWrite = null;
      throw error;
    }
    wrote.add({
      'account_id': accountId,
      'vehicle_id': vehicleId,
      'key': key,
      'value': value,
      'proposed_at_utc_millis': proposedAtUtcMillis,
      'origin': origin,
    });
  }

  @override
  Future<List<PreferenceControlStatusRow>> readStatus() async {
    if (failRead != null) {
      final error = failRead!;
      failRead = null;
      throw error;
    }
    return [
      for (final row in viewRows) PreferenceControlStatusRow.fromViewMap(row),
    ];
  }
}

/// A [CloudSink] recorder for the real `SupabasePreferenceControlCloud`.
class _FakeSink implements CloudSink {
  final writes = <({String table, List<Map<String, Object?>> rows})>[];
  List<Map<String, Object?>> fetches = [];

  @override
  Future<void> upsert(
    String table,
    List<Map<String, Object?>> rows, {
    required List<String> conflictColumns,
    required bool merge,
  }) async {
    writes.add((table: table, rows: rows));
  }

  @override
  Future<Set<String>> ownedVehicles(Set<String> ids) async => ids;

  @override
  Future<List<Map<String, Object?>>> fetch(String table) async => fetches;
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

void main() {
  group('PreferenceControlController — write path', () {
    test(
      'proposes for the owned vehicle with the correct desired row',
      () async {
        final cloud = FakePreferenceControlCloud(accountId: accountId);
        final controller = PreferenceControlController(
          cloud: cloud,
          accountId: accountId,
          vehicleIdProvider: () => vehicleId,
          clock: () => 500,
        );

        final result = await controller.propose(
          key: 'pack_capacity_wh',
          value: '64000',
        );

        expect(result.wrote, isTrue);
        expect(cloud.wrote, hasLength(1));
        final row = cloud.wrote.single;
        expect(row['account_id'], accountId);
        // The write targets the owned vehicle the provider named.
        expect(row['vehicle_id'], vehicleId);
        expect(row['key'], 'pack_capacity_wh');
        expect(row['value'], '64000');
        expect(row['proposed_at_utc_millis'], 500);
        expect(row['origin'], 'phone');
      },
    );

    test('refuses to write when it cannot name an owned vehicle', () async {
      final cloud = FakePreferenceControlCloud(accountId: accountId);
      final controller = PreferenceControlController(
        cloud: cloud,
        accountId: accountId,
        vehicleIdProvider: () => null,
      );

      final result = await controller.propose(
        key: 'pack_capacity_wh',
        value: '64000',
      );

      expect(result.wrote, isFalse);
      expect(result.refusal, ProposalRefusal.unknownVehicle);
      expect(cloud.wrote, isEmpty);
    });

    test('refuses to write when the control plane is not configured', () async {
      final cloud = FakePreferenceControlCloud(accountId: accountId)
        ..configured = false;
      final controller = PreferenceControlController(
        cloud: cloud,
        accountId: accountId,
        vehicleIdProvider: () => vehicleId,
      );

      final result = await controller.propose(key: 'pack_capacity_wh');

      expect(result.wrote, isFalse);
      expect(result.refusal, ProposalRefusal.unconfigured);
      expect(cloud.wrote, isEmpty);
    });

    test(
      'a write failure surfaces as an error, never a false status',
      () async {
        final cloud = FakePreferenceControlCloud(accountId: accountId)
          ..failWrite = StateError('ownership refused');
        final controller = PreferenceControlController(
          cloud: cloud,
          accountId: accountId,
          vehicleIdProvider: () => vehicleId,
        );

        await expectLater(
          controller.propose(key: 'pack_capacity_wh'),
          throwsStateError,
        );
        expect(controller.lastError, isA<StateError>());
      },
    );
  });

  group('PreferenceControlController — read path', () {
    test('surfaces all five view-derived statuses', () async {
      final cloud = FakePreferenceControlCloud(accountId: accountId)
        ..viewRows = [
          _row('pack_capacity_wh', status: 'pending'),
          _row('default_charge_cost_per_kwh', status: 'confirmed'),
          _row('key-stale', status: 'stale'),
          _row('key-refused', status: 'refused'),
          _row('key-reported', status: 'reported_only'),
        ];
      final controller = PreferenceControlController(
        cloud: cloud,
        accountId: accountId,
        vehicleIdProvider: () => vehicleId,
      );

      final count = await controller.refresh();

      expect(count, 5);
      expect(
        controller.rowFor('pack_capacity_wh')!.status,
        PreferenceControlStatus.pending,
      );
      expect(
        controller.rowFor('default_charge_cost_per_kwh')!.status,
        PreferenceControlStatus.confirmed,
      );
      expect(
        controller.rowFor('key-stale')!.status,
        PreferenceControlStatus.stale,
      );
      expect(
        controller.rowFor('key-refused')!.status,
        PreferenceControlStatus.refused,
      );
      expect(
        controller.rowFor('key-reported')!.status,
        PreferenceControlStatus.reportedOnly,
      );
    });

    test('a desire with no report surfaces pending, never confirmed', () async {
      final cloud = FakePreferenceControlCloud(accountId: accountId)
        ..viewRows = [
          {
            'vehicle_id': vehicleId,
            'account_id': accountId,
            'key': 'pack_capacity_wh',
            'desired_value': '64000',
            'proposed_at_utc_millis': 1000,
            'reported_value': null,
            'reported_status': null,
            'decided_at_utc_millis': null,
            'reported_at_utc_millis': null,
            'status': 'pending',
          },
        ];
      final controller = PreferenceControlController(
        cloud: cloud,
        accountId: accountId,
        vehicleIdProvider: () => vehicleId,
      );

      await controller.refresh();

      final row = controller.rowFor('pack_capacity_wh')!;
      expect(row.desiredValue, '64000');
      expect(row.reportedValue, isNull);
      expect(row.status, PreferenceControlStatus.pending);
      expect(row.status, isNot(PreferenceControlStatus.confirmed));
    });

    test(
      'proposing writes then reads the view back — never optimistically',
      () async {
        final cloud = FakePreferenceControlCloud(accountId: accountId)
          ..viewRows = [
            {
              'vehicle_id': vehicleId,
              'account_id': accountId,
              'key': 'pack_capacity_wh',
              'desired_value': '64000',
              'proposed_at_utc_millis': 500,
              'reported_value': null,
              'reported_status': null,
              'decided_at_utc_millis': null,
              'reported_at_utc_millis': null,
              'status': 'pending',
            },
          ];
        final controller = PreferenceControlController(
          cloud: cloud,
          accountId: accountId,
          vehicleIdProvider: () => vehicleId,
        );

        final result = await controller.propose(
          key: 'pack_capacity_wh',
          value: '64000',
        );

        expect(result.wrote, isTrue);
        // The status is whatever the view says — a fresh proposal with no car
        // decision is pending, never a locally-asserted applied.
        expect(result.row!.status, PreferenceControlStatus.pending);
      },
    );
  });

  group('SupabasePreferenceControlCloud — transport shape', () {
    test('writes the right desired row through the sink', () async {
      final sink = _FakeSink();
      final cloud = SupabasePreferenceControlCloud(sink, accountId);

      await cloud.writeDesired(
        accountId: accountId,
        vehicleId: vehicleId,
        key: 'default_charge_cost_per_kwh',
        value: '0.85',
        proposedAtUtcMillis: 1234,
        origin: 'phone',
      );

      expect(sink.writes, hasLength(1));
      final write = sink.writes.single;
      expect(write.table, 'preference_desired');
      final row = write.rows.single;
      expect(row['account_id'], accountId);
      expect(row['vehicle_id'], vehicleId);
      expect(row['key'], 'default_charge_cost_per_kwh');
      expect(row['value'], '0.85');
      expect(row['proposed_at_utc_millis'], 1234);
      expect(row['origin'], 'phone');
    });

    test('reads the status view through the sink', () async {
      final sink = _FakeSink()
        ..fetches = [
          {
            'vehicle_id': vehicleId,
            'account_id': accountId,
            'key': 'pack_capacity_wh',
            'desired_value': null,
            'proposed_at_utc_millis': null,
            'reported_value': '39600',
            'reported_status': 'accepted',
            'decided_at_utc_millis': 10,
            'reported_at_utc_millis': 11,
            'status': 'reported_only',
          },
        ];
      final cloud = SupabasePreferenceControlCloud(sink, accountId);

      final rows = await cloud.readStatus();

      expect(rows, hasLength(1));
      expect(rows.single.status, PreferenceControlStatus.reportedOnly);
      expect(rows.single.reportedValue, '39600');
    });

    test(
      'rejects an unknown view status rather than guessing confirmed',
      () async {
        final sink = _FakeSink()
          ..fetches = [
            {
              'vehicle_id': vehicleId,
              'account_id': accountId,
              'key': 'pack_capacity_wh',
              'status': 'something_unexpected',
            },
          ];
        final cloud = SupabasePreferenceControlCloud(sink, accountId);

        await expectLater(cloud.readStatus(), throwsFormatException);
      },
    );
  });
}

Map<String, Object?> _row(String key, {required String status}) => {
  'vehicle_id': vehicleId,
  'account_id': accountId,
  'key': key,
  'desired_value': null,
  'proposed_at_utc_millis': null,
  'reported_value': null,
  'reported_status': null,
  'decided_at_utc_millis': null,
  'reported_at_utc_millis': null,
  'status': status,
};
