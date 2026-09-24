import 'package:capy_companion/abrp/abrp_client.dart';
import 'package:capy_companion/abrp/abrp_settings_store.dart';
import 'package:capy_companion/abrp/abrp_telemetry_forwarder.dart';
import 'package:capy_companion/ble/live_telemetry_ble_client.dart';
import 'package:capy_companion/ble/live_telemetry_frame_codec.dart';
import 'package:capy_companion/l10n/app_localizations.dart';
import 'package:capy_companion/pairing/device_pairing_gateway.dart';
import 'package:capy_companion/screens/home_screen.dart';
import 'package:capy_companion/sync/pairing_controller.dart';
import 'package:capy_companion/sync/pairing_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';
import 'support/fake_ble_transport.dart';

import '../support/fake_device_pairing_gateway.dart';

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

Future<PairingController> _pairedController() async {
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
  testWidgets('renders BLE live telemetry card with metrics when streaming', (
    tester,
  ) async {
    final pairing = await _pairedController();

    const secret = 'VGhpcyBpcyBhIDMyLWJ5dGUgc2hhcmVkIHNlY3JldCE=';
    // The card only renders; the runtime owns the stream lifecycle.
    final bleClient = LiveTelemetryBleClient(
      transport: FakeBleTransport(),
      sharedSecretBase64: secret,
    );
    final abrpStore = FileAbrpSettingsStore(enabled: true, userToken: 'token');
    final forwarder = AbrpTelemetryForwarder(
      settingsStore: abrpStore,
      clientSender: (s, t) async =>
          const AbrpSendResult(isSuccess: true, statusCode: 200),
    );

    await tester.pumpWidget(
      _host(
        HomeScreen(
          pairing: pairing,
          ble: bleClient,
          abrpForwarder: forwarder,
          abrpSettings: abrpStore,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const Key('sync-ble-card')), findsOneWidget);

    expect(find.text('Disconnected'), findsOneWidget);

    // The car pushes one encrypted snapshot on the live characteristic.
    final snapshot = LiveTelemetrySnapshot(
      utcMillis: 1724443200000,
      socPercent: 82.5,
      speedKmh: 58.0,
      powerKw: 14.2,
      isCharging: false,
    );
    bleClient.onFrameReceived(
      LiveTelemetryFrameCodec(
        secret,
      ).encryptWithCounter(snapshot.toBinaryPayload(), 42),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Live'), findsOneWidget);
    expect(find.text('82.5'), findsOneWidget);
    expect(find.text('%'), findsOneWidget);
    expect(find.text('58'), findsOneWidget);
    expect(find.text('km/h'), findsOneWidget);
    expect(find.text('+14.2'), findsOneWidget);
    expect(find.text('kW'), findsOneWidget);
    expect(find.text('Battery'), findsOneWidget);
    expect(find.text('Speed'), findsOneWidget);
    expect(find.text('Power'), findsOneWidget);
  });

  testWidgets('the live card is absent while the beta switch is off', (
    tester,
  ) async {
    final pairing = await _pairedController();

    final bleClient = LiveTelemetryBleClient(
      transport: FakeBleTransport(),
      sharedSecretBase64: 'VGhpcyBpcyBhIDMyLWJ5dGUgc2hhcmVkIHNlY3JldCE=',
    );
    final abrpStore = FileAbrpSettingsStore();

    await tester.pumpWidget(
      _host(
        HomeScreen(pairing: pairing, ble: bleClient, abrpSettings: abrpStore),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sync-ble-card')), findsNothing);

    // Switching the beta on brings the card back without a rebuild from above.
    await abrpStore.setEnabled(true);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sync-ble-card')), findsOneWidget);
  });
}
