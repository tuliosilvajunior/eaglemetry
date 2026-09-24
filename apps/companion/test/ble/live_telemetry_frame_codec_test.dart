import 'dart:convert';
import 'dart:typed_data';

import 'package:capy_companion/ble/live_telemetry_frame_codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

final String _secretBase64 = base64Encode(
  utf8.encode('test-secret-key-for-ble-auth-32b'),
);

Uint8List _hex(String value) => Uint8List.fromList([
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
]);

void main() {
  group('LiveTelemetryFrameCodec', () {
    test('decrypts the frozen frame produced by the car cipher', () {
      // Same vector as LiveTelemetryStreamCipherTest.producesKnownCrossLanguageVector.
      final frame = _hex(
        '0201020304050607087300fa09bf4dde9f801e75c8fc47c23bb619bebd700d52f9228ca427',
      );

      final plaintext = LiveTelemetryFrameCodec(_secretBase64).decrypt(frame);

      expect(plaintext, Uint8List.fromList(List<int>.generate(12, (i) => i)));
      expect(LiveTelemetryFrameCodec.counterOf(frame), 0x0102030405060708);
    });

    test('builds the frozen frame the car builds', () {
      final codec = LiveTelemetryFrameCodec(_secretBase64);

      final frame = codec.encryptWithCounter(
        Uint8List.fromList(List<int>.generate(12, (i) => i)),
        0x0102030405060708,
      );

      expect(
        frame.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        '0201020304050607087300fa09bf4dde9f801e75c8fc47c23bb619bebd700d52f9228ca427',
      );
    });

    test('nonce is four zero bytes then the counter', () {
      final nonce = LiveTelemetryFrameCodec.nonceFor(0x0102030405060708);

      expect(nonce.length, 12);
      expect(nonce.sublist(0, 4), everyElement(0));
      expect(nonce[4], 0x01);
      expect(nonce[11], 0x08);
    });

    test('rejects a tampered frame', () {
      final codec = LiveTelemetryFrameCodec(_secretBase64);
      final frame = codec.encryptWithCounter(Uint8List(16), 7);
      frame[frame.length - 1] ^= 0x01;

      expect(codec.decrypt(frame), isNull);
    });

    test('rejects a frame encrypted for another paired phone', () {
      final other = LiveTelemetryFrameCodec(
        base64Encode(utf8.encode('wrong-secret-key-for-ble-auth32b')),
      );
      final frame = LiveTelemetryFrameCodec(
        _secretBase64,
      ).encryptWithCounter(Uint8List(16), 7);

      expect(other.decrypt(frame), isNull);
    });

    test('rejects truncated frames and unknown versions', () {
      final codec = LiveTelemetryFrameCodec(_secretBase64);

      expect(codec.decrypt(Uint8List(0)), isNull);
      expect(codec.decrypt(Uint8List(9)), isNull);

      final frame = codec.encryptWithCounter(Uint8List(16), 7);
      frame[0] = 1;
      expect(codec.decrypt(frame), isNull);
    });

    test('rejects a secret that is not 32 bytes', () {
      expect(
        () => LiveTelemetryFrameCodec(base64Encode(List<int>.filled(16, 0))),
        throwsArgumentError,
      );
    });
  });

  group('LiveTelemetryFrameReader', () {
    Uint8List frameFor(LiveTelemetrySnapshot snapshot, int counter) =>
        LiveTelemetryFrameCodec(
          _secretBase64,
        ).encryptWithCounter(snapshot.toBinaryPayload(), counter);

    final snapshot = LiveTelemetrySnapshot(
      utcMillis: 1724443200000,
      socPercent: 82.5,
      speedKmh: 45.0,
      powerKw: 12.0,
      isCharging: false,
    );

    test('reads a snapshot out of a car frame', () {
      final reader = LiveTelemetryFrameReader(_secretBase64);

      final decoded = reader.read(frameFor(snapshot, 100));

      expect(decoded, isNotNull);
      expect(decoded!.utcMillis, snapshot.utcMillis);
      expect(decoded.socPercent, closeTo(82.5, 0.01));
      expect(decoded.speedKmh, closeTo(45.0, 0.01));
      expect(decoded.powerKw, closeTo(12.0, 0.01));
      expect(decoded.isCharging, isFalse);
    });

    test('drops replays and out-of-order frames', () {
      final reader = LiveTelemetryFrameReader(_secretBase64);
      final frame = frameFor(snapshot, 100);

      expect(reader.read(frame), isNotNull);
      expect(reader.read(frame), isNull);
      expect(reader.read(frameFor(snapshot, 99)), isNull);
      expect(reader.read(frameFor(snapshot, 101)), isNotNull);
    });

    test('accepts a lower counter after the car restarts its stream', () {
      final reader = LiveTelemetryFrameReader(_secretBase64);
      expect(reader.read(frameFor(snapshot, 5000)), isNotNull);

      reader.resetCounters();

      final newer = LiveTelemetrySnapshot(
        utcMillis: snapshot.utcMillis + 1000,
        socPercent: 82.0,
      );
      expect(
        reader.read(
          LiveTelemetryFrameCodec(
            _secretBase64,
          ).encryptWithCounter(newer.toBinaryPayload(), 12),
        ),
        isNotNull,
      );
    });

    test('a reconnect does not reopen the window on an old capture', () {
      final reader = LiveTelemetryFrameReader(_secretBase64);
      final captured = frameFor(snapshot, 5000);
      expect(reader.read(captured), isNotNull);

      // What an attacker gets by forcing a disconnect: the frame counter
      // window restarts, but the snapshot clock does not.
      reader.resetCounters();

      expect(reader.read(captured), isNull);
    });

    test('drops frames meant for another paired phone', () {
      final reader = LiveTelemetryFrameReader(_secretBase64);
      final foreign = LiveTelemetryFrameCodec(
        base64Encode(utf8.encode('wrong-secret-key-for-ble-auth32b')),
      ).encryptWithCounter(snapshot.toBinaryPayload(), 100);

      expect(reader.read(foreign), isNull);
    });
  });
}
