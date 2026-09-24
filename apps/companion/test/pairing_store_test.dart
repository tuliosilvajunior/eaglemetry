import 'dart:convert';
import 'dart:io';

import 'package:capy_companion/sync/pairing_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('nothing is paired until a claim is stored', () async {
    final store = PairingStore(nowMillis: () => 1000);
    expect(store.isPaired, isFalse);

    final paired = await store.completeClaim(
      vehicleId: 'v-1',
      accountId: 'a-1',
    );
    expect(paired.isPaired, isTrue);
    expect(store.isPaired, isTrue);
    expect(paired.pairedAtUtcMillis, 1000);
  });

  test('pairing survives a reload from disk', () async {
    final dir = await Directory.systemTemp.createTemp('pairing');
    addTearDown(() => dir.delete(recursive: true));
    final store = PairingStore(directory: dir, nowMillis: () => 2000);
    await store.completeClaim(
      vehicleId: 'v-1',
      accountId: 'a-1',
      deviceName: 'Phone',
    );

    final reloaded = PairingStore(directory: dir);
    await reloaded.load();
    expect(reloaded.current?.vehicleId, 'v-1');
    expect(reloaded.current?.deviceName, 'Phone');
  });

  test('clear removes the file', () async {
    final dir = await Directory.systemTemp.createTemp('pairing-clear');
    addTearDown(() => dir.delete(recursive: true));
    final store = PairingStore(directory: dir, nowMillis: () => 3000);
    await store.completeClaim(vehicleId: 'v-1', accountId: 'a-1');
    await store.clear();
    expect(store.current, isNull);
    expect(File('${dir.path}/pairing.json').existsSync(), isFalse);
  });

  test(
    'legacy local pairing file loads as unpaired without throwing',
    () async {
      final dir = await Directory.systemTemp.createTemp('pairing-legacy');
      addTearDown(() => dir.delete(recursive: true));
      await File('${dir.path}/pairing.json').writeAsString(
        jsonEncode({
          'deviceId': 'd',
          'deviceName': 'Phone',
          'sharedSecret': 's',
          'pairedAtUtcMillis': 1757800000000,
        }),
      );

      final store = PairingStore(directory: dir);
      await store.load();
      expect(store.isPaired, isFalse);
      expect(store.current, isNull);
    },
  );

  test('corrupt pairing file loads as unpaired without throwing', () async {
    final dir = await Directory.systemTemp.createTemp('pairing-corrupt');
    addTearDown(() => dir.delete(recursive: true));
    await File('${dir.path}/pairing.json').writeAsString('not-json{{{');

    final store = PairingStore(directory: dir);
    await store.load();
    expect(store.isPaired, isFalse);
    expect(store.current, isNull);
  });

  test('current format with vehicleId still loads paired', () async {
    final dir = await Directory.systemTemp.createTemp('pairing-current');
    addTearDown(() => dir.delete(recursive: true));
    await File('${dir.path}/pairing.json').writeAsString(
      jsonEncode({
        'deviceId': 'd',
        'deviceName': 'Phone',
        'sharedSecret': 's',
        'pairedAtUtcMillis': 1757800000000,
        'vehicleId': 'v-1',
        'accountId': 'a-1',
      }),
    );

    final store = PairingStore(directory: dir);
    await store.load();
    expect(store.isPaired, isTrue);
    expect(store.current?.vehicleId, 'v-1');
  });

  test('missing pairing file loads as unpaired without throwing', () async {
    final dir = await Directory.systemTemp.createTemp('pairing-missing');
    addTearDown(() => dir.delete(recursive: true));

    final store = PairingStore(directory: dir);
    await store.load();
    expect(store.isPaired, isFalse);
    expect(store.current, isNull);
  });
}
