import 'dart:async';

import 'package:capy_companion/pairing/device_pairing_gateway.dart';
import 'package:capy_companion/sync/cloud_uploader.dart';
import 'package:capy_companion/sync/pairing_controller.dart';
import 'package:capy_companion/sync/pairing_restore.dart';
import 'package:capy_companion/sync/pairing_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_device_pairing_gateway.dart';

class _SeedSink implements CloudSink {
  _SeedSink({this.vehicles = const [], this.ownerships = const []});

  final List<Map<String, Object?>> vehicles;
  final List<Map<String, Object?>> ownerships;
  var fetchCount = 0;

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
  Future<List<Map<String, Object?>>> fetch(String table) async {
    fetchCount++;
    return switch (table) {
      'vehicle' => vehicles,
      'vehicle_ownership' => ownerships,
      _ => const [],
    };
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

class _ThrowingSink extends _SeedSink {
  @override
  Future<List<Map<String, Object?>>> fetch(String table) async {
    throw StateError('offline');
  }
}

Map<String, Object?> _vehicle(String id, String createdAt) => {
  'vehicle_id': id,
  'account_id': 'a-1',
  'created_at': createdAt,
};

Map<String, Object?> _ownership(
  String vehicleId,
  String accountId,
  String createdAt, {
  String? revokedAt,
}) => {
  'vehicle_id': vehicleId,
  'account_id': accountId,
  'created_at': createdAt,
  'revoked_at': revokedAt,
};

void main() {
  group('restoreOwnedVehicle', () {
    test('answers null when the account has no cars', () async {
      final found = await restoreOwnedVehicle(
        sink: _SeedSink(),
        accountId: 'a-1',
      );
      expect(found, isNull);
    });

    test('answers null when the lookup fails', () async {
      final found = await restoreOwnedVehicle(
        sink: _ThrowingSink(),
        accountId: 'a-1',
      );
      expect(found, isNull);
    });

    test('restores the single owned car', () async {
      final found = await restoreOwnedVehicle(
        sink: _SeedSink(vehicles: [_vehicle('v-1', '2025-01-01T00:00:00Z')]),
        accountId: 'a-1',
      );
      expect(found, isNotNull);
      expect(found!.vehicleId, 'v-1');
      expect(found.accountId, 'a-1');
    });

    test('picks the newest vehicle when no ownership rows exist', () async {
      final found = await restoreOwnedVehicle(
        sink: _SeedSink(
          vehicles: [
            _vehicle('v-old', '2024-01-01T00:00:00Z'),
            _vehicle('v-new', '2025-06-01T00:00:00Z'),
          ],
        ),
        accountId: 'a-1',
      );
      expect(found!.vehicleId, 'v-new');
    });

    test('prefers ownership time over vehicle time', () async {
      final found = await restoreOwnedVehicle(
        sink: _SeedSink(
          vehicles: [
            _vehicle('v-old-car', '2024-01-01T00:00:00Z'),
            _vehicle('v-new-car', '2025-06-01T00:00:00Z'),
          ],
          ownerships: [_ownership('v-old-car', 'a-1', '2026-01-01T00:00:00Z')],
        ),
        accountId: 'a-1',
      );
      expect(found!.vehicleId, 'v-old-car');
    });

    test(
      'newer ownership time wins even if other car has newer vehicle time',
      () async {
        final found = await restoreOwnedVehicle(
          sink: _SeedSink(
            vehicles: [
              _vehicle('v-owned-newer', '2024-01-01T00:00:00Z'),
              _vehicle('v-veh-newer', '2026-01-01T00:00:00Z'),
            ],
            ownerships: [
              _ownership('v-owned-newer', 'a-1', '2025-06-01T00:00:00Z'),
              _ownership('v-veh-newer', 'a-1', '2025-01-01T00:00:00Z'),
            ],
          ),
          accountId: 'a-1',
        );
        expect(found!.vehicleId, 'v-owned-newer');
      },
    );

    test('skips a car whose ownership is revoked', () async {
      final found = await restoreOwnedVehicle(
        sink: _SeedSink(
          vehicles: [
            _vehicle('v-revoked', '2026-01-01T00:00:00Z'),
            _vehicle('v-live', '2024-01-01T00:00:00Z'),
          ],
          ownerships: [
            _ownership(
              'v-revoked',
              'a-1',
              '2025-01-01T00:00:00Z',
              revokedAt: '2026-02-01T00:00:00Z',
            ),
          ],
        ),
        accountId: 'a-1',
      );
      expect(found!.vehicleId, 'v-live');
    });

    test('answers null when the only car is revoked', () async {
      final found = await restoreOwnedVehicle(
        sink: _SeedSink(
          vehicles: [_vehicle('v-1', '2026-01-01T00:00:00Z')],
          ownerships: [
            _ownership(
              'v-1',
              'a-1',
              '2025-01-01T00:00:00Z',
              revokedAt: '2026-02-01T00:00:00Z',
            ),
          ],
        ),
        accountId: 'a-1',
      );
      expect(found, isNull);
    });

    test('does not restore car transferred to another account', () async {
      final found = await restoreOwnedVehicle(
        sink: _SeedSink(
          vehicles: [_vehicle('v-1', '2025-01-01T00:00:00Z')],
          ownerships: [_ownership('v-1', 'a-2', '2026-01-01T00:00:00Z')],
        ),
        accountId: 'a-1',
      );
      expect(found, isNull);
    });

    test(
      'does not restore car belonging to another account in vehicle table',
      () async {
        final found = await restoreOwnedVehicle(
          sink: _SeedSink(
            vehicles: [
              {
                'vehicle_id': 'v-other',
                'account_id': 'a-2',
                'created_at': '2025-01-01T00:00:00Z',
              },
            ],
          ),
          accountId: 'a-1',
        );
        expect(found, isNull);
      },
    );

    test('tie in ownership time broken by reserve vehicle time', () async {
      final found = await restoreOwnedVehicle(
        sink: _SeedSink(
          vehicles: [
            _vehicle('v-old-veh', '2024-01-01T00:00:00Z'),
            _vehicle('v-new-veh', '2025-06-01T00:00:00Z'),
          ],
          ownerships: [
            _ownership('v-old-veh', 'a-1', '2025-01-01T00:00:00Z'),
            _ownership('v-new-veh', 'a-1', '2025-01-01T00:00:00Z'),
          ],
        ),
        accountId: 'a-1',
      );
      expect(found!.vehicleId, 'v-new-veh');
    });

    test('missing ownership time falls back to vehicle time', () async {
      final found = await restoreOwnedVehicle(
        sink: _SeedSink(
          vehicles: [
            _vehicle('v-with-owned-time', '2024-01-01T00:00:00Z'),
            _vehicle('v-missing-owned-time', '2025-06-01T00:00:00Z'),
          ],
          ownerships: [
            _ownership('v-with-owned-time', 'a-1', '2024-06-01T00:00:00Z'),
            {
              'vehicle_id': 'v-missing-owned-time',
              'account_id': 'a-1',
              'created_at': null,
              'revoked_at': null,
            },
          ],
        ),
        accountId: 'a-1',
      );
      expect(found!.vehicleId, 'v-missing-owned-time');
    });
  });

  group('PairingController.restore', () {
    test('pairs an empty store from the cloud lookup', () async {
      final store = PairingStore();
      final controller = PairingController(
        store: store,
        restoreLookup: () async => (vehicleId: 'v-1', accountId: 'a-1'),
      );
      await controller.restore();
      expect(controller.isPaired, isTrue);
      expect(store.current?.vehicleId, 'v-1');
      expect(store.current?.accountId, 'a-1');
    });

    test('does not call the lookup when already paired', () async {
      final store = PairingStore();
      await store.completeClaim(vehicleId: 'v-1', accountId: 'a-1');
      var calls = 0;
      final controller = PairingController(
        store: store,
        restoreLookup: () async {
          calls++;
          return (vehicleId: 'v-2', accountId: 'a-1');
        },
      );
      await controller.restore();
      expect(calls, 0);
      expect(store.current?.vehicleId, 'v-1');
    });

    test(
      'offline failure does not clear or alter existing valid pairing',
      () async {
        final store = PairingStore();
        await store.completeClaim(vehicleId: 'v-existing', accountId: 'a-1');
        final controller = PairingController(
          store: store,
          restoreLookup: () async => throw StateError('offline'),
        );
        await controller.restore();
        expect(controller.isPaired, isTrue);
        expect(store.current?.vehicleId, 'v-existing');
      },
    );

    test('lookup failure leaves the store unpaired without error', () async {
      final store = PairingStore();
      final controller = PairingController(
        store: store,
        restoreLookup: () async => throw StateError('offline'),
      );
      await controller.restore();
      expect(controller.isPaired, isFalse);
    });

    test('no cars leaves the store unpaired without error', () async {
      final store = PairingStore();
      final controller = PairingController(
        store: store,
        restoreLookup: () async => null,
      );
      await controller.restore();
      expect(controller.isPaired, isFalse);
    });

    test('ClaimAlreadyOwnedBySelf now pairs an empty store', () async {
      final store = PairingStore();
      final gateway = FakeDevicePairingGateway(
        claimResult: const ClaimResult.alreadyOwnedBySelf(),
      );
      final controller = PairingController(
        store: store,
        gateway: gateway,
        restoreLookup: () async => (vehicleId: 'v-1', accountId: 'a-1'),
      );
      await controller.submit('847291');
      expect(controller.lastResult, isA<ClaimAlreadyOwnedBySelf>());
      expect(controller.error, isNull);
      expect(controller.isPaired, isTrue);
      expect(store.current?.vehicleId, 'v-1');
    });

    test(
      'ClaimAlreadyOwnedBySelf does not overwrite already paired store with another car',
      () async {
        final store = PairingStore();
        await store.completeClaim(vehicleId: 'v-existing', accountId: 'a-1');
        var lookupCalled = false;
        final gateway = FakeDevicePairingGateway(
          claimResult: const ClaimResult.alreadyOwnedBySelf(),
        );
        final controller = PairingController(
          store: store,
          gateway: gateway,
          restoreLookup: () async {
            lookupCalled = true;
            return (vehicleId: 'v-new', accountId: 'a-1');
          },
        );
        await controller.submit('847291');
        expect(lookupCalled, isFalse);
        expect(store.current?.vehicleId, 'v-existing');
      },
    );

    test(
      'in-flight restore does not overwrite manual claim that finished during lookup',
      () async {
        final store = PairingStore();
        final lookupCompleter = Completer<RestoredPairing?>();
        final gateway = FakeDevicePairingGateway(
          claimResult: const ClaimResult.success(
            ClaimSuccess(vehicleId: 'v-manual', accountId: 'a-1'),
          ),
        );
        final controller = PairingController(
          store: store,
          gateway: gateway,
          restoreLookup: () => lookupCompleter.future,
        );

        // Start restore in background (unawaited)
        final restoreFuture = controller.restore();

        // User performs manual pairing while lookup is still in flight
        await controller.submit('123456');
        expect(controller.isPaired, isTrue);
        expect(store.current?.vehicleId, 'v-manual');

        // Now lookup resolves with old vehicle
        lookupCompleter.complete((vehicleId: 'v-restored', accountId: 'a-1'));
        await restoreFuture;

        // Must NOT overwrite manual pairing!
        expect(store.current?.vehicleId, 'v-manual');
      },
    );

    test('concurrent restore calls share the same in-flight lookup', () async {
      final store = PairingStore();
      var calls = 0;
      final completer = Completer<RestoredPairing?>();
      final controller = PairingController(
        store: store,
        restoreLookup: () {
          calls++;
          return completer.future;
        },
      );

      final f1 = controller.restore();
      final f2 = controller.restore();

      expect(calls, 1);
      completer.complete((vehicleId: 'v-1', accountId: 'a-1'));
      await Future.wait([f1, f2]);
      expect(calls, 1);
      expect(store.current?.vehicleId, 'v-1');
    });
  });
}
