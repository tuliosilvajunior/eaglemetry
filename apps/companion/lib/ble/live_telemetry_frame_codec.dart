import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';
import 'package:pointycastle/api.dart';
import 'package:telemetry_core/telemetry_core.dart';

/// Decoder for the one-way BLE live telemetry stream.
///
/// The head unit never receives ATT requests from its own vendor Bluetooth
/// stack, so the car cannot answer a challenge and cannot see a CCCD write.
/// The car therefore pushes notifications to every connected client and the
/// protection moves into the payload: AES-256-GCM under the Wi-Fi pairing
/// shared secret, with a strictly increasing counter that doubles as the GCM
/// nonce suffix.
///
/// Frame layout on `0xCB02` (mirrors `LiveTelemetryStreamCipher.kt`):
///
/// ```
/// [0]     version = 2
/// [1..8]  counter, uint64 big-endian
/// [9..]   ciphertext || 128-bit GCM tag
/// ```
///
/// nonce = 4 zero bytes || counter (12 bytes), key = base64-decoded secret.
class LiveTelemetryFrameCodec {
  LiveTelemetryFrameCodec(String sharedSecretBase64)
    : _key = _decodeKey(sharedSecretBase64);

  static const int frameVersion = 2;
  static const int headerBytes = 9;
  static const int tagBytes = 16;
  static const int _macBits = 128;

  final Uint8List _key;

  static Uint8List _decodeKey(String sharedSecretBase64) {
    final bytes = base64Decode(sharedSecretBase64);
    if (bytes.length != 32) {
      throw ArgumentError.value(
        sharedSecretBase64,
        'sharedSecretBase64',
        'Shared secret must decode to 32 bytes, was ${bytes.length}',
      );
    }
    return Uint8List.fromList(bytes);
  }

  /// The 12-byte GCM nonce for [counter]: four zero bytes, then the counter.
  static Uint8List nonceFor(int counter) {
    final nonce = Uint8List(12);
    ByteData.view(nonce.buffer).setUint64(4, counter, Endian.big);
    return nonce;
  }

  /// Reads the counter of [frame] without authenticating it.
  ///
  /// Returns null when the frame is too short or carries another version.
  static int? counterOf(Uint8List frame) {
    if (frame.length <= headerBytes) return null;
    if (frame[0] != frameVersion) return null;
    return ByteData.view(
      frame.buffer,
      frame.offsetInBytes,
    ).getUint64(1, Endian.big);
  }

  /// Returns the plaintext of [frame], or null when it is malformed, was
  /// encrypted under another paired phone's secret, or was tampered with.
  Uint8List? decrypt(Uint8List frame) {
    final counter = counterOf(frame);
    if (counter == null) return null;
    final ciphertext = Uint8List.sublistView(frame, headerBytes);
    if (ciphertext.length < tagBytes) return null;
    try {
      return _run(
        forEncryption: false,
        nonce: nonceFor(counter),
        input: ciphertext,
      );
    } catch (_) {
      return null;
    }
  }

  /// Builds a frame the way the car does. Used by tests and by the reference
  /// vector that pins this codec to `LiveTelemetryStreamCipher.kt`.
  Uint8List encryptWithCounter(Uint8List plaintext, int counter) {
    final ciphertext = _run(
      forEncryption: true,
      nonce: nonceFor(counter),
      input: plaintext,
    );
    final frame = Uint8List(headerBytes + ciphertext.length);
    frame[0] = frameVersion;
    ByteData.view(frame.buffer).setUint64(1, counter, Endian.big);
    frame.setRange(headerBytes, frame.length, ciphertext);
    return frame;
  }

  Uint8List _run({
    required bool forEncryption,
    required Uint8List nonce,
    required Uint8List input,
  }) {
    final gcm = GCMBlockCipher(AESEngine())
      ..init(
        forEncryption,
        AEADParameters(KeyParameter(_key), _macBits, nonce, Uint8List(0)),
      );
    return gcm.process(input);
  }
}

/// Turns car notifications into snapshots, and drops replays.
///
/// Every connected phone receives every frame, one per paired secret, so
/// frames that belong to another phone simply fail to decrypt. A frame whose
/// counter does not advance is a replay and is dropped as well.
///
/// Two counters guard a replay, because one is not enough. The frame counter
/// catches a repeat inside one link, but it restarts with every new link, so
/// forcing a disconnect would reopen the window. The snapshot clock closes it:
/// a snapshot never moves backwards in time, whatever the link did.
class LiveTelemetryFrameReader {
  LiveTelemetryFrameReader(String sharedSecretBase64)
    : _codec = LiveTelemetryFrameCodec(sharedSecretBase64);

  final LiveTelemetryFrameCodec _codec;
  int? _lastCounter;
  int? _lastUtcMillis;

  /// Clears the frame counter window on a new link. The snapshot clock is
  /// deliberately kept: it is what stops a replay of an old capture after a
  /// forced disconnect.
  void resetCounters() => _lastCounter = null;

  /// Returns the snapshot carried by [frame], or null when the frame is not
  /// for this phone, is a replay, or does not decode.
  LiveTelemetrySnapshot? read(Uint8List frame) {
    final plaintext = _codec.decrypt(frame);
    if (plaintext == null) return null;
    final counter = LiveTelemetryFrameCodec.counterOf(frame)!;
    final last = _lastCounter;
    if (last != null && counter <= last) return null;
    final LiveTelemetrySnapshot snapshot;
    try {
      snapshot = LiveTelemetrySnapshot.fromBinaryPayload(plaintext);
    } catch (_) {
      return null;
    }
    final lastMillis = _lastUtcMillis;
    if (lastMillis != null) {
      // Inside one link the frame counter already proved the frame is new, so
      // two snapshots stamped in the same millisecond are both kept. On the
      // first frame of a new link there is no counter to lean on, so the
      // clock alone has to prove it: it must be strictly newer.
      final isFirstOfLink = last == null;
      final tooOld = isFirstOfLink
          ? snapshot.utcMillis <= lastMillis
          : snapshot.utcMillis < lastMillis;
      if (tooOld) return null;
    }
    _lastCounter = counter;
    _lastUtcMillis = snapshot.utcMillis;
    return snapshot;
  }
}
