import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

/// HMAC auth cases live with the companion client.
/// This suite keeps the envelope and HLC rules in telemetry_core.
void main() {
  const fixturePath = 'testdata/sync_protocol_cases.json';

  final fixture =
      jsonDecode(File(fixturePath).readAsStringSync()) as Map<String, Object?>;

  test('streamNames match the Dart SyncStreamType spelling', () {
    final names = (fixture['streamNames']! as List<Object?>).cast<String>();
    expect(SyncStreamType.values.map((v) => v.name).toList(), equals(names));
  });

  test('envelopeVersion and envelopeKeys match Dart SyncBatch definition', () {
    final expectedVersion = fixture['envelopeVersion'] as int;
    expect(SyncBatch.currentProtocolVersion, equals(expectedVersion));

    final expectedKeys = (fixture['envelopeKeys']! as List<Object?>)
        .cast<String>();
    const batch = SyncBatch(
      protocolVersion: 2,
      streamType: SyncStreamType.sessions,
      items: [],
      nextCursor: 'cursor-1',
      hasMore: false,
      generatedAtUtcMillis: 1700000000000,
    );
    expect(batch.toMap().keys.toList(), equals(expectedKeys));
  });

  test('hlcMaxDriftMillis matches HlcTimestamp.maxDriftMillis', () {
    final maxDrift = fixture['hlcMaxDriftMillis'] as int;
    expect(maxDrift, equals(HlcTimestamp.maxDriftMillis));
  });

  final hlcOrderCases = (fixture['hlcOrderCases']! as List<Object?>)
      .cast<Map<String, Object?>>();

  for (var i = 0; i < hlcOrderCases.length; i++) {
    final c = hlcOrderCases[i];
    final mapA = c['a']! as Map<String, Object?>;
    final mapB = c['b']! as Map<String, Object?>;
    final expectedSign = c['expectedSign']! as int;

    test('HLC order case #$i: $mapA vs $mapB', () {
      final a = HlcTimestamp.fromMap(mapA)!;
      final b = HlcTimestamp.fromMap(mapB)!;
      final cmp = a.compareTo(b);
      final sign = cmp == 0 ? 0 : (cmp > 0 ? 1 : -1);
      expect(sign, equals(expectedSign));
    });
  }
}
