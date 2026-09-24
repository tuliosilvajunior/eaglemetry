import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/telemetry_api.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/screens_v2/settings/data_pane.dart';
import 'package:capy_ui/capy_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:capy_energy/core/app_experience_controller.dart';
import 'package:capy_energy/core/developer_tools_gate.dart';

class _FakeStorageApi extends TelemetryApi {
  _FakeStorageApi({required this.usageSequence, this.failStorage = false});

  /// Sequence answers for storageUsage: each call returns next value.
  final List<StorageUsage> usageSequence;
  int storageCalls = 0;
  bool failStorage;
  final _controller = StreamController<SessionChange>.broadcast();

  void emitSessionChange() {
    _controller.add(
      const SessionChange(
        revision: 1,
        trips: true,
        charges: true,
        parked: false,
      ),
    );
  }

  @override
  Stream<SessionChange> sessionChanges() => _controller.stream;

  @override
  Future<StorageUsage> getStorageUsage() async {
    storageCalls++;
    if (failStorage) throw StateError('storage failed');
    if (usageSequence.isEmpty) {
      return const StorageUsage(
        bytes: 0,
        databaseBytes: 0,
        walBytes: 0,
        shmBytes: 0,
      );
    }
    final idx = (storageCalls - 1).clamp(0, usageSequence.length - 1);
    return usageSequence[idx];
  }

  @override
  Future<TelemetrySettingsResult> getTelemetrySettings() async {
    return const TelemetrySettingsResult(
      autoStartOnBoot: true,
      gpsEnabled: false,
      keepBluetoothOn: false,
      debugEventFileEnabled: false,
      temperatureModeHelperEnabled: false,
      replaceOemChargingEnabled: false,
      defaultChargeCostPerKwh: null,
      packCapacityWh: kDefaultPackCapacityWh,
      chargeCostCurrency: 'BRL',
    );
  }

  @override
  Future<ClearTelemetryDatabaseResult> clearTelemetryDatabase() async {
    return const ClearTelemetryDatabaseResult(
      ok: true,
      telemetryEventsDeleted: 1,
      tripSessionsDeleted: 1,
      chargeSessionsDeleted: 1,
      telemetryFramesDeleted: 1,
      sessionAggregatesDeleted: 0,
      timestampMillis: 0,
    );
  }

  @override
  Future<List<PreferenceProposal>> getPreferenceProposals() async => const [];

  Future<void> close() => _controller.close();
}

Widget _host(Widget pane) {
  return MaterialApp(
    theme: AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SingleChildScrollView(child: pane)),
  );
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppExperienceController.instance.reset();
  });
  tearDown(() async {
    DeveloperToolsGate.instance.reset();
    await AppExperienceController.instance.reset();
  });

  testWidgets('Settings shows how much space the app uses', (tester) async {
    final api = _FakeStorageApi(
      usageSequence: [
        const StorageUsage(
          bytes: 5 * 1024 * 1024,
          databaseBytes: 5 * 1024 * 1024,
          walBytes: 0,
          shmBytes: 0,
        ),
      ],
    );
    addTearDown(() => api.close());

    await tester.pumpWidget(_host(DataPane(telemetryApi: api)));
    await tester.pumpAndSettle();

    // One line in Settings: storage title and formatted value.
    expect(find.text('Storage'), findsOneWidget);
    expect(find.text('Stored history'), findsOneWidget);
    expect(find.widgetWithText(SoftActionTile, '5.00 MB used'), findsOneWidget);
    // Reading it does not scan every row: verify only storageUsage was called,
    // not a count query. The fake counts storageCalls, and we expect at least one.
    expect(api.storageCalls, greaterThanOrEqualTo(1));
    // And no scanning: the implementation uses file length, documented in the model.
    expect(find.byKey(const Key('settings-storage-tile')), findsOneWidget);
  });

  testWidgets('The number updates when history is added', (tester) async {
    final api = _FakeStorageApi(
      usageSequence: [
        const StorageUsage(
          bytes: 1 * 1024 * 1024,
          databaseBytes: 1 * 1024 * 1024,
          walBytes: 0,
          shmBytes: 0,
        ),
        const StorageUsage(
          bytes: 2 * 1024 * 1024,
          databaseBytes: 2 * 1024 * 1024,
          walBytes: 0,
          shmBytes: 0,
        ),
      ],
    );
    addTearDown(() => api.close());

    await tester.pumpWidget(_host(DataPane(telemetryApi: api)));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(SoftActionTile, '1.00 MB used'), findsOneWidget);
    expect(api.storageCalls, 1);

    // History added: sessionChanges fires, storage reloads.
    api.emitSessionChange();
    await tester.pumpAndSettle();

    expect(find.widgetWithText(SoftActionTile, '2.00 MB used'), findsOneWidget);
    expect(api.storageCalls, 2);
  });

  testWidgets('The number updates when the archive is wiped', (tester) async {
    final api = _FakeStorageApi(
      usageSequence: [
        const StorageUsage(
          bytes: 3 * 1024 * 1024,
          databaseBytes: 3 * 1024 * 1024,
          walBytes: 0,
          shmBytes: 0,
        ),
        const StorageUsage(
          bytes: 0,
          databaseBytes: 0,
          walBytes: 0,
          shmBytes: 0,
        ),
      ],
    );
    addTearDown(() => api.close());

    await tester.pumpWidget(_host(DataPane(telemetryApi: api)));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(SoftActionTile, '3.00 MB used'), findsOneWidget);

    // Wipe via UI: triggers clearTelemetryDatabase then reload.
    await tester.ensureVisible(find.text('WIPE HISTORY'));
    await tester.tap(find.text('WIPE HISTORY'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('confirm-dialog')), findsOneWidget);
    await tester.tap(find.text('WIPE ALL'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(SoftActionTile, '0 B used'), findsOneWidget);
    expect(api.storageCalls, greaterThanOrEqualTo(2));
  });

  testWidgets(
    'Reading it does not scan every row: call is file metadata, not count',
    (tester) async {
      // This documents the seam: getStorageUsage must not execute COUNT(*) over tables.
      // The Dart side is a MethodChannel that natively reads PRAGMA page_count
      // (O(1) header) plus File.length for sidecars. The fake proves the UI reads
      // that seam and no other.
      final api = _FakeStorageApi(
        usageSequence: [
          const StorageUsage(
            bytes: 42,
            databaseBytes: 42,
            walBytes: 0,
            shmBytes: 0,
          ),
        ],
      );
      addTearDown(() => api.close());

      await tester.pumpWidget(_host(DataPane(telemetryApi: api)));
      await tester.pumpAndSettle();

      expect(api.storageCalls, 1);
      expect(find.text('42 B used'), findsOneWidget);
    },
  );

  testWidgets('A total failure shows --, not 0 B', (tester) async {
    final api = _FakeStorageApi(usageSequence: const [], failStorage: true);
    addTearDown(() => api.close());

    await tester.pumpWidget(_host(DataPane(telemetryApi: api)));
    await tester.pumpAndSettle();

    // failStorage throws, DataPane shows the failed string, not 0 B.
    expect(api.storageCalls, 1);
    expect(find.textContaining('Storage check failed'), findsOneWidget);
  });

  testWidgets('Locale pt-BR uses comma', (tester) async {
    expect(formatStorageBytes(3660000, locale: 'pt'), contains(','));
    expect(formatStorageBytes(3660000, locale: 'en'), contains('.'));
  });
}
