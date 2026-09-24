import 'dart:io';

import 'package:capy_companion/runtime/companion_runtime.dart';
import 'package:capy_companion/sync/companion_archive.dart';
import 'package:capy_companion/sync/companion_database.dart';
import 'package:capy_companion/sync/pairing_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_ble_transport.dart';

/// A paired phone, so only the beta switch decides whether the radio opens.
const _secret = 'VGhpcyBpcyBhIDMyLWJ5dGUgc2hhcmVkIHNlY3JldCE=';

Future<PairingStore> _pairedStore(Directory root) async {
  final store = PairingStore(directory: root);
  await store.load();
  await store.completeClaim(
    vehicleId: 'v-1',
    accountId: 'a-1',
    deviceName: 'Test Phone',
    sharedSecret: _secret,
  );
  return store;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('capy-beta-gate');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<CompanionRuntime> startRuntime(FakeBleTransport transport) async {
    final runtime = CompanionRuntime(
      archive: CompanionArchive(await CompanionDatabase.open(':memory:')),
      pairing: await _pairedStore(root),
      bleTransport: transport,
      documents: () async => root,
    );
    await runtime.start();
    return runtime;
  }

  test('a paired phone opens no radio while the beta switch is off', () async {
    final transport = FakeBleTransport();

    final runtime = await startRuntime(transport);
    await pumpEventQueue();

    // Nothing was asked of the transport, so nothing asked for a Bluetooth
    // permission either. That is the whole point of the gate.
    expect(runtime.ble!.isRunning, isFalse);
    expect(transport.knownDevicesCalls, 0);
    expect(transport.scanCalls, 0);
    expect(transport.connectCalls, 0);
  });

  test('switching the beta on opens the radio, and off closes it', () async {
    final transport = FakeBleTransport(
      known: const [BleDiscoveredDeviceFixture.car],
      maxConnects: 1,
    );

    final runtime = await startRuntime(transport);
    await pumpEventQueue();
    expect(transport.connectCalls, 0);

    await runtime.abrpSettings!.setEnabled(true);
    await pumpEventQueue();

    expect(runtime.ble!.isRunning, isTrue);
    expect(transport.successfulConnects, 1);
    final connection = transport.connections.single;

    await runtime.abrpSettings!.setEnabled(false);
    await pumpEventQueue();

    expect(runtime.ble!.isRunning, isFalse);
    expect(connection.disconnected, isTrue);
  });
}
