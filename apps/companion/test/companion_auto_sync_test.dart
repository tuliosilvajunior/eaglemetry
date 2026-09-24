import 'package:capy_companion/runtime/companion_runtime.dart';
import 'package:capy_companion/sync/annotation_cloud_sync.dart';
import 'package:capy_companion/sync/cloud_uploader.dart';
import 'package:capy_companion/sync/companion_archive.dart';
import 'package:capy_companion/sync/cloud_run_report.dart';
import 'package:capy_companion/sync/sync_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// A link that counts cloud pulls without a network, account or database.
class _CountingLink implements CarLink {
  @override
  CompanionArchive? get archive => null;

  int cloudCalls = 0;

  @override
  Future<SyncRunReport> syncFromCloud({
    void Function(SyncProgress progress)? onProgress,
  }) async {
    cloudCalls += 1;
    return const SyncRunReport(
      status: SyncRunStatus.completed,
      ackedRecords: 3,
    );
  }

  @override
  Future<CloudUploadReport?> uploadToCloud({
    void Function(CloudUploadProgress progress)? onProgress,
  }) async => null;

  @override
  Future<AnnotationCloudSyncReport?> syncAnnotationsToCloud() async => null;

  @override
  Future<void> wipeArchive() async {}
}

SyncController _controller(_CountingLink link, {bool Function()? gate}) =>
    SyncController(
      car: link,
      // Cloud runner straight at the fake; no archive, no database needed.
      runner: link.syncFromCloud,
      autoSyncGate: gate ?? () => true,
    );

void main() {
  testWidgets('the automatic pull runs at once without a tap', (tester) async {
    final link = _CountingLink();
    final sync = _controller(link);
    addTearDown(sync.dispose);

    sync.startAutoSync();
    await tester.pump();

    // The reader opened the app and pressed nothing.
    expect(link.cloudCalls, 1);
    expect(sync.lastReport?.ackedRecords, 3);

    sync.stopAutoSync();
  });

  testWidgets('the automatic pull repeats on the interval', (tester) async {
    final link = _CountingLink();
    final sync = _controller(link);
    addTearDown(sync.dispose);

    sync.startAutoSync();
    await tester.pump();
    expect(link.cloudCalls, 1);

    await tester.pump(SyncController.autoSyncInterval);
    await tester.pump();

    expect(link.cloudCalls, 2);

    sync.stopAutoSync();
  });

  testWidgets('the gate off means no pull', (tester) async {
    final link = _CountingLink();
    final sync = _controller(link, gate: () => false);
    addTearDown(sync.dispose);

    sync.startAutoSync();
    await tester.pump(SyncController.autoSyncInterval);
    await tester.pump();

    expect(link.cloudCalls, 0);
    expect(sync.lastReport, isNull);

    sync.stopAutoSync();
  });

  testWidgets('a stopped automatic pull asks nothing more', (tester) async {
    final link = _CountingLink();
    final sync = _controller(link);
    addTearDown(sync.dispose);

    sync.startAutoSync();
    await tester.pump();
    sync.stopAutoSync();
    final asked = link.cloudCalls;

    await tester.pump(SyncController.autoSyncInterval * 3);
    expect(link.cloudCalls, asked);
  });

  testWidgets('starting twice still pulls once', (tester) async {
    final link = _CountingLink();
    final sync = _controller(link);
    addTearDown(sync.dispose);

    sync.startAutoSync();
    sync.startAutoSync();
    await tester.pump();

    expect(link.cloudCalls, 1);

    sync.stopAutoSync();
  });
}
