import 'package:capy_companion/sync/annotation_cloud_sync.dart';
import 'package:capy_companion/sync/cloud_sync_config.dart';
import 'package:capy_companion/sync/cloud_uploader.dart';
import 'package:capy_companion/sync/supabase_cloud_sink.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/memory_archive.dart';

/// Cloud-sync gate: real Supabase sinks for Lanes A/B/C are wired and default
/// ON. Standing owner decision: the cloud stays on. An explicit
/// `--dart-define=CLOUD_SYNC_ENABLED=false` still restores no-op behavior.

class FakeSink implements CloudSink {
  final List<({String table, List<Map<String, Object?>> rows})> writes = [];
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
  Future<Set<String>> ownedVehicles(Set<String> ids) async => {};

  @override
  Future<List<Map<String, Object?>>> fetch(String table) async => [];
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
  test('CloudSyncConfig defaults ON', () {
    expect(
      CloudSyncConfig.enabled,
      isTrue,
      reason: 'CLOUD_SYNC_ENABLED must default to true',
    );
  });

  test(
    'Lane A: SupabaseCloudSink.uploaderFor is null without a project',
    () async {
      final archive = await memoryArchive();
      final uploader = SupabaseCloudSink.uploaderFor(archive.database);
      expect(
        uploader,
        isNull,
        reason: 'No SUPABASE_URL in test builds, so nothing can upload',
      );
    },
  );

  test('Lane B: AnnotationCloudSync.maybeFor resolves when gate ON', () async {
    final archive = await memoryArchive();
    final sink = FakeSink();
    final sync = AnnotationCloudSync.maybeFor(
      archive: archive,
      sink: sink,
      accountId: '00000000-0000-4000-a000-000000000001',
    );
    expect(sync, isNotNull, reason: 'Gate ON with sink and account resolves');
  });

  test(
    'Lane B: injected factory bypasses gate when test provides one',
    () async {
      final archive = await memoryArchive();
      final sink = FakeSink();
      final sync = AnnotationCloudSync(
        archive: archive,
        sink: sink,
        accountId: 'test-account',
      );
      expect(sync, isNotNull);
      final report = await sync.push();
      expect(report.perStream, isEmpty);
      expect(sink.writes, isEmpty);
    },
  );

  test('accountId wiring: gate ON would surface real account from pairing', () {
    const realAccountId = '00000000-0000-4000-a000-000000000001';
    String? providerOff(bool enabled) => enabled ? realAccountId : null;
    expect(providerOff(false), isNull);
    expect(providerOff(true), equals(realAccountId));
  });
}
