import 'dart:convert';
import 'dart:typed_data';

import 'package:capy_companion/ble/ble_transport.dart';
import 'package:capy_companion/ble/live_telemetry_ble_client.dart';
import 'package:capy_companion/ble/live_telemetry_frame_codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

import 'support/fake_ble_transport.dart';

final String _secretBase64 = base64Encode(
  utf8.encode('test-secret-key-for-ble-auth-32b'),
);

final _snapshot = LiveTelemetrySnapshot(
  utcMillis: 1724443200000,
  socPercent: 82.5,
  speedKmh: 45.0,
  powerKw: 12.0,
  isCharging: false,
);

Uint8List _frame(int counter, {String? secretBase64}) =>
    LiveTelemetryFrameCodec(
      secretBase64 ?? _secretBase64,
    ).encryptWithCounter(_snapshot.toBinaryPayload(), counter);

const _car = BleDiscoveredDevice(
  id: 'AA:BB:CC:DD:EE:01',
  name: 'GEELY EX2',
  advertisesCapyService: true,
);

LiveTelemetryBleClient _client(FakeBleTransport transport) =>
    LiveTelemetryBleClient(
      transport: transport,
      sleep: (_) async {},
      initialRetryDelay: Duration.zero,
      maxRetryDelay: Duration.zero,
    );

void main() {
  group('BleDiscoveredDevice', () {
    test('accepts the vehicle name families and the service advertisement', () {
      for (final name in ['GEELY EX2', 'MTK MT0788', 'Capy Car', 'ECARXP']) {
        expect(
          BleDiscoveredDevice(
            id: 'x',
            name: name,
            advertisesCapyService: false,
          ).looksLikeVehicle,
          isTrue,
          reason: name,
        );
      }
      expect(
        const BleDiscoveredDevice(
          id: 'x',
          name: 'Someone AirPods',
          advertisesCapyService: false,
        ).looksLikeVehicle,
        isFalse,
      );
      expect(
        const BleDiscoveredDevice(
          id: 'x',
          name: '',
          advertisesCapyService: true,
        ).looksLikeVehicle,
        isTrue,
      );
    });
  });

  group('LiveTelemetryBleClient', () {
    test('streams snapshots pushed by the car', () async {
      final transport = FakeBleTransport(known: [_car], maxConnects: 1);
      final client = _client(transport);
      final received = <LiveTelemetrySnapshot>[];
      client.snapshotStream.listen(received.add);

      final loop = client.start(sharedSecretBase64: _secretBase64);
      await pumpEventQueue();

      final connection = transport.connections.single;
      connection.push(_frame(10));
      connection.push(_frame(11));
      await pumpEventQueue();

      expect(received.length, 2);
      expect(client.state, BleConnectionState.streaming);
      expect(received.first.socPercent, closeTo(82.5, 0.01));

      await client.stop();
      await loop;
      expect(client.state, BleConnectionState.disconnected);
    });

    test('ignores frames addressed to another paired phone', () async {
      final transport = FakeBleTransport(known: [_car], maxConnects: 1);
      final client = _client(transport);
      final received = <LiveTelemetrySnapshot>[];
      client.snapshotStream.listen(received.add);

      final loop = client.start(sharedSecretBase64: _secretBase64);
      await pumpEventQueue();

      final connection = transport.connections.single;
      connection.push(
        _frame(
          10,
          secretBase64: base64Encode(
            utf8.encode('wrong-secret-key-for-ble-auth32b'),
          ),
        ),
      );
      await pumpEventQueue();

      expect(received, isEmpty);
      expect(client.rejectedFrameCount, 1);

      await client.stop();
      await loop;
    });

    test('drops a replayed frame', () async {
      final transport = FakeBleTransport(known: [_car], maxConnects: 1);
      final client = _client(transport);
      final received = <LiveTelemetrySnapshot>[];
      client.snapshotStream.listen(received.add);

      final loop = client.start(sharedSecretBase64: _secretBase64);
      await pumpEventQueue();

      final connection = transport.connections.single;
      connection.push(_frame(10));
      connection.push(_frame(10));
      await pumpEventQueue();

      expect(received.length, 1);
      expect(client.rejectedFrameCount, 1);

      await client.stop();
      await loop;
    });

    test('retries a connect that times out at weak signal', () async {
      final transport = FakeBleTransport(
        known: [_car],
        failedConnects: 2,
        maxConnects: 1,
      );
      final client = _client(transport);

      final loop = client.start(sharedSecretBase64: _secretBase64);
      await pumpEventQueue();

      expect(transport.connectCalls, 3);
      expect(transport.successfulConnects, 1);

      await client.stop();
      await loop;
    });

    test('reconnects after the car drops the link', () async {
      final transport = FakeBleTransport(known: [_car], maxConnects: 2);
      final client = _client(transport);

      final loop = client.start(sharedSecretBase64: _secretBase64);
      await pumpEventQueue();

      expect(transport.connections.length, 1);
      transport.connections.first.drop();
      await pumpEventQueue();

      expect(transport.connections.length, 2);
      await client.stop();
      await loop;
    });

    test('finds the car by scan when it is not a system device', () async {
      final transport = FakeBleTransport(
        advertised: const [
          BleDiscoveredDevice(
            id: 'other',
            name: 'Someone AirPods',
            advertisesCapyService: false,
          ),
          _car,
        ],
        maxConnects: 1,
      );
      final client = _client(transport);

      final loop = client.start(sharedSecretBase64: _secretBase64);
      await pumpEventQueue();

      expect(transport.successfulConnects, 1);
      expect(transport.stopScanCalls, greaterThan(0));

      await client.stop();
      await loop;
    });

    test('start is idempotent while a stream is running', () async {
      final transport = FakeBleTransport(known: [_car], maxConnects: 1);
      final client = _client(transport);

      final loop = client.start(sharedSecretBase64: _secretBase64);
      await pumpEventQueue();
      await client.start(sharedSecretBase64: _secretBase64);
      await pumpEventQueue();

      expect(transport.connectCalls, 1);
      await client.stop();
      await loop;
    });

    test('stop disconnects the open link', () async {
      final transport = FakeBleTransport(known: [_car], maxConnects: 1);
      final client = _client(transport);

      final loop = client.start(sharedSecretBase64: _secretBase64);
      await pumpEventQueue();
      final connection = transport.connections.single;

      await client.stop();
      await loop;

      expect(connection.disconnected, isTrue);
      expect(client.isRunning, isFalse);
    });
  });
}
