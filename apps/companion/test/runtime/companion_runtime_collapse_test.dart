import 'dart:io';

import 'package:capy_companion/runtime/companion_runtime.dart';
import 'package:capy_companion/sync/annotation_cloud_sync.dart';
import 'package:capy_companion/sync/cloud_uploader.dart';
import 'package:capy_companion/sync/companion_archive.dart';
import 'package:capy_companion/sync/cloud_run_report.dart';
import 'package:capy_companion/sync/pairing_controller.dart';
import 'package:capy_companion/sync/pairing_store.dart';
import 'package:capy_companion/sync/sync_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../ble/support/fake_ble_transport.dart';
import '../support/memory_archive.dart';

Future<CompanionArchive> _archive() => memoryArchive();

class FakeCarLink implements CarLink {
  FakeCarLink({this.archive});

  @override
  final CompanionArchive? archive;

  int syncCalls = 0;
  int uploadCalls = 0;
  int annotationSyncCalls = 0;
  int wipeCalls = 0;

  @override
  Future<SyncRunReport> syncFromCloud({
    void Function(SyncProgress progress)? onProgress,
  }) async {
    syncCalls++;
    return const SyncRunReport(
      status: SyncRunStatus.completed,
      ackedRecords: 1,
    );
  }

  @override
  Future<CloudUploadReport?> uploadToCloud({
    void Function(CloudUploadProgress progress)? onProgress,
  }) async {
    uploadCalls++;
    return null;
  }

  @override
  Future<AnnotationCloudSyncReport?> syncAnnotationsToCloud() async {
    annotationSyncCalls++;
    return null;
  }

  @override
  Future<void> wipeArchive() async => wipeCalls++;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('start returns one non-nullable services value', () async {
    final runtime = CompanionRuntime(
      archive: await _archive(),
      pairing: PairingStore(),
      bleTransport: FakeBleTransport(),
      documents: () async => Directory.systemTemp.createTempSync('capy-start'),
    );
    expect(runtime.isReady, isFalse);
    expect(runtime.maybeServices, isNull);
    final services = await runtime.start();
    expect(runtime.isReady, isTrue);
    expect(identical(runtime.services, services), isTrue);
    expect(services.archive, isNotNull);
    expect(services.pairing, isNotNull);
    expect(services.pairingController, isNotNull);
    expect(services.source, isNotNull);
    expect(services.store, isNotNull);
    expect(services.journeys, isNotNull);
    expect(services.ble, isNotNull);
    expect(services.abrpSettings, isNotNull);
    expect(services.abrpForwarder, isNotNull);
    expect(services.onboarding, isNotNull);
    // Not started is not representable downstream: CompanionApp.fromServices
    // takes the non-nullable value.
    expect(services.pairingController, isA<PairingController>());
    await runtime.dispose();
  });

  test('start is idempotent', () async {
    final runtime = CompanionRuntime(
      archive: await _archive(),
      pairing: PairingStore(),
      bleTransport: FakeBleTransport(),
      documents: () async => Directory.systemTemp.createTempSync('capy-idem'),
    );
    final a = await runtime.start();
    final b = await runtime.start();
    expect(identical(a, b), isTrue);
    await runtime.dispose();
  });

  test('SyncController depends on CarLink, not on full runtime', () async {
    final archive = await _archive();
    final link = FakeCarLink(archive: archive);
    final controller = SyncController(car: link);
    addTearDown(controller.dispose);

    // The slim fake is enough: no temp directory, no FFI sqlite for the
    // sync itself. Counts come from the archive the link carries.
    await controller.refreshCounts();
    // Nothing asks the car any more: the counts and the outbox are both the
    // phone's own, so a card can state them with the car away.
    expect(link.syncCalls, 0);
    expect(controller.pendingCount, 0);

    await controller.runNow();
    expect(link.syncCalls, 1);
    // The run pushes this phone's own edits in the same press, so the outbox
    // has a drain and "still to send" can reach zero.
    expect(link.annotationSyncCalls, 1);
    expect(controller.tripCount, 0); // archive empty, no DB needed for the run

    await controller.wipe();
    expect(link.wipeCalls, 1);
  });

  test(
    'SyncController can still be built with deprecated runtime param',
    () async {
      final runtime = CompanionRuntime(
        archive: await _archive(),
        pairing: PairingStore(),
        bleTransport: FakeBleTransport(),
        documents: () async => Directory.systemTemp.createTempSync('capy-depr'),
      );
      await runtime.start();
      final controller = SyncController(runtime: runtime);
      addTearDown(controller.dispose);
      expect(controller.car, same(runtime));
      expect(controller.archive, same(runtime.archive));
      await runtime.dispose();
    },
  );

  test('dispose unhooks the two listeners', () async {
    final root = Directory.systemTemp.createTempSync('capy-dispose');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final transport = FakeBleTransport(
      known: const [BleDiscoveredDeviceFixture.car],
      maxConnects: 10,
    );
    final pairingStore = PairingStore(directory: root);
    await pairingStore.completeClaim(
      vehicleId: 'v-1',
      accountId: 'a-1',
      sharedSecret: 'VGhpcyBpcyBhIDMyLWJ5dGUgc2hhcmVkIHNlY3JldCE=',
    );
    final runtime = CompanionRuntime(
      archive: await _archive(),
      pairing: pairingStore,
      bleTransport: transport,
      documents: () async => root,
    );
    await runtime.start();
    // Beta off -> no radio
    expect(runtime.ble!.isRunning, isFalse);
    // Turning beta on opens radio via the two gates
    await runtime.abrpSettings!.setEnabled(true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(runtime.ble!.isRunning, isTrue);
    final connectsBefore = transport.successfulConnects;

    await runtime.dispose();

    // After dispose, flipping the gates must not touch the radio again.
    await runtime.abrpSettings!.setEnabled(false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // No new connects, and no close triggered by the gate (dispose already
    // unhooked, so the gate is silent).
    expect(transport.successfulConnects, connectsBefore);

    // Re-enabling also does nothing after dispose.
    await runtime.abrpSettings!.setEnabled(true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(transport.successfulConnects, connectsBefore);

    // Cleanup the ble client left running (dispose did not stop it, only
    // unhooked; stop it explicitly so the test does not leak).
    await runtime.ble!.stop();
  });

  test('CompanionRuntime.instance is final and not reassignable via type', () {
    expect(CompanionRuntime.instance, isA<CompanionRuntime>());
    // The static is final: the library declares `static final`.
    // This test documents the contract: deleting the module must not be
    // possible by reassigning the global.
  });

  test(
    'CompanionArchive counts come from CarLink archive, not runtime fields',
    () async {
      final archive = await _archive();
      await archive.upsertSession({
        'id': 'trip-1',
        'vehicleId': 'VIN1',
        'kind': 'TRIP',
        'status': 'CLOSED',
        'startedAtUtcMillis': 1000,
        'startedAtElapsedNanos': 1,
        'noLongerReducible': 0,
        'createdAtUtcMillis': 1000,
        'updatedAtUtcMillis': 1000,
      });
      final link = FakeCarLink(archive: archive);
      final controller = SyncController(car: link);
      addTearDown(controller.dispose);
      await controller.refreshCounts();
      expect(controller.tripCount, 1);
      expect(controller.chargeCount, 0);
    },
  );
}
