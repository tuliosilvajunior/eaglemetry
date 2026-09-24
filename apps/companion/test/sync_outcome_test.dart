import 'dart:io';

import 'package:capy_companion/sync/cloud_run_report.dart';
import 'package:capy_companion/sync/cloud_telemetry_pull.dart';
import 'package:capy_companion/sync/cloud_uploader.dart';
import 'package:capy_companion/sync/supabase_cloud_sink.dart';
import 'package:capy_companion/sync/sync_controller.dart';
import 'package:capy_companion/l10n/app_localizations.dart';
import 'package:capy_companion/screens/home_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/memory_archive.dart';

void main() {
  group('syncOutcomeKind', () {
    test('no report has not run', () {
      expect(
        syncOutcomeKind(null, cloudEnabled: true),
        SyncOutcomeKind.neverRun,
      );
      expect(
        syncOutcomeKind(null, cloudEnabled: false),
        SyncOutcomeKind.neverRun,
      );
    });

    test('work arrived reads as completed either way', () {
      const report = SyncRunReport(
        status: SyncRunStatus.completed,
        ackedRecords: 7,
      );
      expect(
        syncOutcomeKind(report, cloudEnabled: true),
        SyncOutcomeKind.completed,
      );
      expect(
        syncOutcomeKind(report, cloudEnabled: false),
        SyncOutcomeKind.completed,
      );
    });

    test('gate off turns any failure into cloudDisabled, not car blame', () {
      const bare = SyncRunReport(status: SyncRunStatus.failed, ackedRecords: 0);
      expect(
        syncOutcomeKind(bare, cloudEnabled: false),
        SyncOutcomeKind.cloudDisabled,
      );
      // Even a network error under a disabled gate is the build, not the link:
      // the cloud was never tried.
      final noisy = SyncRunReport(
        status: SyncRunStatus.failed,
        ackedRecords: 0,
        error: const SocketException('Connection failed'),
      );
      expect(
        syncOutcomeKind(noisy, cloudEnabled: false),
        SyncOutcomeKind.cloudDisabled,
      );
    });

    test('network errors name this phone, not the car', () {
      final wifi = SyncRunReport(
        status: SyncRunStatus.failed,
        ackedRecords: 0,
        error: const SocketException('Connection failed'),
      );
      expect(
        syncOutcomeKind(wifi, cloudEnabled: true),
        SyncOutcomeKind.phoneOffline,
      );
      final socket = SyncRunReport(
        status: SyncRunStatus.failed,
        ackedRecords: 0,
        error: const CloudUploadFailure('session', 'SocketException', 0),
      );
      expect(
        syncOutcomeKind(socket, cloudEnabled: true),
        SyncOutcomeKind.phoneOffline,
      );
      final raw = SyncRunReport(
        status: SyncRunStatus.failed,
        ackedRecords: 0,
        error: const SocketException('Connection refused'),
      );
      expect(
        syncOutcomeKind(raw, cloudEnabled: true),
        SyncOutcomeKind.phoneOffline,
      );
    });

    test('server refusals stay generic failures', () {
      final refused = SyncRunReport(
        status: SyncRunStatus.failed,
        ackedRecords: 0,
        error: const CloudUploadFailure('session', '42501', 3),
      );
      expect(
        syncOutcomeKind(refused, cloudEnabled: true),
        SyncOutcomeKind.failed,
      );
    });

    test(
      'empty cloud with gate on is car silence, gate off is nothing new',
      () {
        const empty = SyncRunReport(
          status: SyncRunStatus.completed,
          ackedRecords: 0,
        );
        expect(
          syncOutcomeKind(empty, cloudEnabled: true),
          SyncOutcomeKind.carSilent,
        );
        expect(
          syncOutcomeKind(empty, cloudEnabled: false),
          SyncOutcomeKind.nothingNew,
        );
      },
    );
  });

  group('syncOutcomeLine', () {
    // Every kind must reach the reader as its own sentence. A build with the
    // cloud gate off never produces three of them, so the card alone cannot
    // prove the reader would ever see them.
    test('every kind has its own line, in every locale', () async {
      const report = SyncRunReport(
        status: SyncRunStatus.completed,
        ackedRecords: 7,
      );
      for (final locale in AppLocalizations.supportedLocales) {
        final l10n = await AppLocalizations.delegate.load(locale);
        final lines = <String, SyncOutcomeKind>{};
        for (final kind in SyncOutcomeKind.values) {
          final line = syncOutcomeLine(l10n, kind, report);
          expect(line.trim(), isNotEmpty, reason: '$locale $kind');
          // Two kinds sharing one sentence would hide the difference the
          // reader has to act on.
          expect(
            lines.containsKey(line),
            isFalse,
            reason: '$locale: $kind reads the same as ${lines[line]}',
          );
          lines[line] = kind;
        }
        // The count is the reader's proof that something arrived.
        expect(
          syncOutcomeLine(l10n, SyncOutcomeKind.completed, report),
          contains('7'),
          reason: '$locale',
        );
      }
    });
  });

  group('CloudTelemetryPull failures', () {
    test('a dead link fails the pull instead of reading as empty', () async {
      final archive = await memoryArchive();
      final pull = CloudTelemetryPull(
        archive: archive,
        sink: _ThrowingSink(),
        accountId: 'acct-1',
      );
      final report = await pull.pull();
      // A swallowed fault would land here as completed/0 — the reading the
      // screens give the car's silence. It must not wear that reading.
      expect(report.status, SyncRunStatus.failed);
      expect(report.error, isNotNull);
      expect(
        syncOutcomeKind(report, cloudEnabled: true),
        SyncOutcomeKind.phoneOffline,
      );
    });
  });
}

/// A cloud that answers nothing because the link is down.
class _ThrowingSink implements CloudSink {
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
  Future<List<Map<String, Object?>>> fetch(String table) async =>
      throw const SocketException('Connection refused');

  @override
  Future<List<Map<String, Object?>>> fetchRange(
    String table, {
    required int offset,
    required int limit,
  }) async {
    throw const SocketException('Connection refused');
  }
}
