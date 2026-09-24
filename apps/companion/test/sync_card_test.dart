import 'package:capy_companion/main.dart';
import 'package:capy_companion/pairing/device_pairing_gateway.dart';
import 'package:capy_companion/runtime/companion_runtime.dart';
import 'package:capy_companion/sync/pairing_controller.dart';
import 'package:capy_companion/sync/pairing_store.dart';
import 'package:capy_companion/sync/sync_controller.dart';
import 'package:capy_companion/sync/cloud_run_report.dart';
import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

import 'support/fake_device_pairing_gateway.dart';

Future<PairingController> _paired() async {
  final controller = PairingController(
    store: PairingStore(),
    gateway: FakeDevicePairingGateway(
      claimResult: const ClaimResult.success(
        ClaimSuccess(vehicleId: 'v1', accountId: 'a1'),
      ),
    ),
  );
  await controller.submit('123456');
  return controller;
}

void main() {
  testWidgets('the sync card appears only once the car is paired', (
    tester,
  ) async {
    final unpaired = PairingController(
      store: PairingStore(),
      gateway: FakeDevicePairingGateway(),
    );
    await tester.pumpWidget(
      CompanionApp(
        locale: const Locale('en'),
        pairing: unpaired,
        sync: SyncController(
          runtime: CompanionRuntime(),
          runner: ({onProgress}) async => const SyncRunReport(
            status: SyncRunStatus.completed,
            ackedRecords: 0,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sync-now')), findsNothing);
  });

  testWidgets('a run reports what arrived', (tester) async {
    var report = const SyncRunReport(
      status: SyncRunStatus.completed,
      ackedRecords: 7,
    );
    final sync = SyncController(
      runtime: CompanionRuntime(),
      runner: ({onProgress}) async => report,
    );
    await tester.pumpWidget(
      CompanionApp(
        locale: const Locale('en'),
        pairing: await _paired(),
        sync: sync,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Not synced yet'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sync-now')));
    await tester.pumpAndSettle();

    expect(find.text('7 records came down from the cloud.'), findsOneWidget);

    // The cloud answered but the car sent nothing: the phone did its job,
    // the car simply has nothing new yet — not a fault on either end.
    // (This test build has the cloud gate on, so the reading is
    // `carSilent`.)
    report = const SyncRunReport(
      status: SyncRunStatus.completed,
      ackedRecords: 0,
    );
    await tester.tap(find.byKey(const Key('sync-now')));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'The car sent nothing to the cloud. If the car has new trips, check its connection.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a run in flight says where it is', (tester) async {
    final sync = SyncController(
      runtime: CompanionRuntime(),
      runner: ({onProgress}) async {
        onProgress!(
          const SyncProgress(
            stream: SyncStreamType.sessions,
            recordsWritten: 4,
            remaining: 6,
          ),
        );
        // Hold the run open so the card is drawn mid-transfer.
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return const SyncRunReport(
          status: SyncRunStatus.completed,
          ackedRecords: 4,
        );
      },
    );
    await tester.pumpWidget(
      CompanionApp(
        locale: const Locale('en'),
        pairing: await _paired(),
        sync: sync,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('sync-now')));
    await tester.pump();

    // Every stream is listed from the first frame, so the ones the run has
    // not reached say they are waiting rather than appearing one by one.
    expect(find.text('4 of 10'), findsOneWidget);
    expect(find.text('Waiting'), findsNWidgets(4));
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(0.4, 0.001));

    await tester.pumpAndSettle();

    // The run is over, so the bar goes. A progress line left on an idle card
    // would describe a transfer that is not happening.
    expect(find.byKey(const Key('sync-progress')), findsNothing);
  });

  testWidgets('a car that does not say what is left gets a count, not a bar', (
    tester,
  ) async {
    final sync = SyncController(
      runtime: CompanionRuntime(),
      runner: ({onProgress}) async {
        onProgress!(
          const SyncProgress(
            stream: SyncStreamType.intervals,
            recordsWritten: 3,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return const SyncRunReport(
          status: SyncRunStatus.completed,
          ackedRecords: 3,
        );
      },
    );
    await tester.pumpWidget(
      CompanionApp(
        locale: const Locale('en'),
        pairing: await _paired(),
        sync: sync,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('sync-now')));
    await tester.pump();

    expect(find.text('3 written'), findsOneWidget);
    // A bar with no denominator would sit full while the transfer runs.
    expect(find.byType(LinearProgressIndicator), findsNothing);

    await tester.pumpAndSettle();
  });

  testWidgets('the card lists what the last sync brought down', (tester) async {
    final sync = SyncController(
      runtime: CompanionRuntime(),
      runner: ({onProgress}) async {
        onProgress!(
          const SyncProgress(
            stream: SyncStreamType.sessions,
            recordsWritten: 214,
            remaining: 0,
          ),
        );
        onProgress(
          const SyncProgress(
            stream: SyncStreamType.intervals,
            recordsWritten: 40,
            remaining: 0,
          ),
        );
        return const SyncRunReport(
          status: SyncRunStatus.completed,
          ackedRecords: 254,
        );
      },
    );
    await tester.pumpWidget(
      CompanionApp(
        locale: const Locale('en'),
        pairing: await _paired(),
        sync: sync,
      ),
    );
    await tester.pumpAndSettle();

    // Before a run there is nothing to state, and the card says nothing
    // rather than printing zeroes it never fetched.
    expect(find.byKey(const Key('sync-last-run')), findsNothing);

    await tester.tap(find.byKey(const Key('sync-now')));
    await tester.pumpAndSettle();

    // The pages outlive the run, so an idle card still says what arrived.
    expect(find.byKey(const Key('sync-last-run')), findsOneWidget);
    expect(find.text('Trips'), findsOneWidget);
    expect(find.text('214'), findsOneWidget);
    expect(find.text('Intervals'), findsOneWidget);
    expect(find.text('40'), findsOneWidget);
  });

  testWidgets('the idle card says whether anything is still to send', (
    tester,
  ) async {
    final sync = SyncController(
      runtime: CompanionRuntime(),
      runner: ({onProgress}) async =>
          const SyncRunReport(status: SyncRunStatus.completed, ackedRecords: 0),
    );
    await tester.pumpWidget(
      CompanionApp(
        locale: const Locale('en'),
        pairing: await _paired(),
        sync: sync,
      ),
    );
    await tester.pumpAndSettle();

    // The line is the phone's own outbox, so it is answerable with the car
    // away and is never absent.
    expect(find.byKey(const Key('sync-pending')), findsOneWidget);
    expect(find.text('Nothing is waiting to be sent.'), findsOneWidget);

    // The button names itself a stopgap beside the passive cadence.
    expect(find.byKey(const Key('sync-auto-note')), findsOneWidget);
    expect(find.textContaining('temporary'), findsOneWidget);
  });

  testWidgets('clearing the local data asks first', (tester) async {
    final sync = _RecordingWipe(runtime: CompanionRuntime());
    await tester.pumpWidget(
      CompanionApp(
        locale: const Locale('en'),
        pairing: await _paired(),
        sync: sync,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('sync-wipe')));
    await tester.pumpAndSettle();
    expect(find.text('Clear local data?'), findsOneWidget);

    // Backing out must leave the archive alone.
    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();
    expect(sync.wipes, 0);

    await tester.tap(find.byKey(const Key('sync-wipe')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sync-wipe-confirm')));
    await tester.pumpAndSettle();
    expect(sync.wipes, 1);
  });

  testWidgets('a car that sends nothing through the cloud says so', (
    tester,
  ) async {
    // Gate ON by default in tests: an empty cloud pull reads as the car's
    // silence, not "nothing new".
    final sync = SyncController(
      runtime: CompanionRuntime(),
      runner: ({onProgress}) async =>
          const SyncRunReport(status: SyncRunStatus.completed, ackedRecords: 0),
    );
    await tester.pumpWidget(
      CompanionApp(
        locale: const Locale('en'),
        pairing: await _paired(),
        sync: sync,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('sync-now')));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'The car sent nothing to the cloud. If the car has new trips, check its connection.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a failed run reaches the cloud now, not the disabled gate', (
    tester,
  ) async {
    // Tests build with CLOUD_SYNC_ENABLED on by default, so a bare failure
    // lands on the generic reading, never the gate-off line.
    final sync = SyncController(
      runtime: CompanionRuntime(),
      runner: ({onProgress}) async =>
          const SyncRunReport(status: SyncRunStatus.failed, ackedRecords: 0),
    );
    await tester.pumpWidget(
      CompanionApp(
        locale: const Locale('en'),
        pairing: await _paired(),
        sync: sync,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('sync-now')));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Sync did not reach the cloud. Check your connection and try again.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('the annotation streams read as one line', (tester) async {
    final sync = SyncController(
      runtime: CompanionRuntime(),
      runner: ({onProgress}) async {
        onProgress!(
          const SyncProgress(
            stream: SyncStreamType.sessions,
            recordsWritten: 2,
          ),
        );
        for (final stream in const [
          SyncStreamType.places,
          SyncStreamType.preferences,
          SyncStreamType.sessionCosts,
          SyncStreamType.preferenceProposals,
        ]) {
          onProgress(SyncProgress(stream: stream, recordsWritten: 1));
        }
        return const SyncRunReport(
          status: SyncRunStatus.completed,
          ackedRecords: 6,
        );
      },
    );
    await tester.pumpWidget(
      CompanionApp(
        locale: const Locale('en'),
        pairing: await _paired(),
        sync: sync,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('sync-now')));
    await tester.pumpAndSettle();

    // One name, one count. Four lines saying "Annotations" read as four
    // unrelated things rather than one.
    expect(find.text('Annotations'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
  });

  testWidgets(
    'the sync card renders SyncProgressBar when syncProgress is present',
    (tester) async {
      final sync = SyncController(
        runtime: CompanionRuntime(),
        runner: ({onProgress}) async => const SyncRunReport(
          status: SyncRunStatus.completed,
          ackedRecords: 0,
        ),
      )..syncProgress = const SyncProgressData(totalCount: 150, dirtyCount: 15);
      await tester.pumpWidget(
        CompanionApp(
          locale: const Locale('en'),
          pairing: await _paired(),
          sync: sync,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SyncProgressBar), findsOneWidget);
      expect(find.text('Cloud sync progress'), findsOneWidget);
      expect(find.text('15 pending'), findsOneWidget);
      expect(find.text('135 of 150 records in the cloud'), findsOneWidget);
    },
  );
}

/// Counts the wipes instead of running one. A real wipe needs the runtime's
/// database, and what this test is about is the question the card asks first.
class _RecordingWipe extends SyncController {
  _RecordingWipe({required super.runtime})
    : super(
        runner: ({onProgress}) async => const SyncRunReport(
          status: SyncRunStatus.completed,
          ackedRecords: 0,
        ),
      );

  int wipes = 0;

  @override
  Future<void> wipe() async {
    wipes += 1;
    notifyListeners();
  }
}
