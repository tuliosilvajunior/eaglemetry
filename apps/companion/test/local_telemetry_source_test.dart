import 'package:capy_companion/sync/local_telemetry_source.dart';
import 'package:capy_companion/sync/sqflite_store.dart';
import 'package:telemetry_core/telemetry_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/memory_archive.dart';

void main() {
  test('lists trips newest first, through the store', () async {
    final archive = await memoryArchive();
    await archive.upsertTrip({
      'id': 'old',
      'status': 'CLOSED',
      'startedAtUtcMillis': 1,
    });
    await archive.upsertTrip({
      'id': 'new',
      'status': 'CLOSED',
      'startedAtUtcMillis': 9,
    });
    final page = await SqfliteStore(archive.database).listSessions(
      filter: const SessionFilter(kind: SessionKind.trip),
      page: const PageRequest(limit: 10),
    );
    expect(page.sessions.map((s) => s.id), ['new', 'old']);
    expect(page.totalCount, 2);
  });

  test('a drive answers its intervals through the store', () async {
    final archive = await memoryArchive();
    await archive.upsertTrip({
      'id': 'trip-1',
      'status': 'CLOSED',
      'startedAtUtcMillis': 1,
      'endedAtUtcMillis': 2,
      'startSocPercent': 80,
      'endSocPercent': 70,
    });
    await archive.upsertInterval({
      'sessionId': 'trip-1',
      'startUtcMillis': 1000,
      'widthMillis': 60000,
      'tractionWh': 100.0,
    });
    final series = await SqfliteStore(archive.database).series('trip-1');
    expect(series.sessionId, 'trip-1');
    expect(series.intervals, hasLength(1));
  });

  test('a charge cost write lands locally and in the outbox', () async {
    final archive = await memoryArchive();
    final source = LocalTelemetrySource(archive);
    await archive.upsertCharge({
      'id': 'c1',
      'kind': 'CHARGE',
      'status': 'CLOSED',
      'startedAtUtcMillis': 1,
      'endedAtUtcMillis': 2,
    });
    final update = await source.updateChargeSessionCost(
      sessionId: 'c1',
      costPerKwh: 1,
      paidAmount: null,
      currency: 'BRL',
    );
    expect(update.ok, isTrue);
    final cost = await archive.database.sessionCost('c1');
    expect(cost, isNotNull);
    expect(cost?['costPerKwh'], 1);
    final pending = await archive.database.pendingAnnotationPush();
    expect(pending, hasLength(1));
    expect(pending.single.stream, SyncStreamType.sessionCosts.name);
  });

  test('a vehicle command is still refused', () async {
    final source = LocalTelemetrySource(await memoryArchive());
    expect(
      () => source.mergeChargeSessions(['a', 'b']),
      throwsA(isA<SyncWriteBackDeferred>()),
    );
  });
}
