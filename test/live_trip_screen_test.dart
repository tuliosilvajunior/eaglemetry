import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

import 'support/session_records.dart';
import 'package:capy_energy/core/telemetry_api.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/screens/trips/live_trip_detail_screen.dart';

const MethodChannel _telemetry = MethodChannel(
  'com.timhss.capyenergy/telemetry',
);
const MethodChannel _vehicleSpeed = MethodChannel(
  'com.timhss.capyenergy/telemetry/vehicle-speed',
);
const StandardMethodCodec _codec = StandardMethodCodec();

final List<String> _methodCalls = <String>[];

final SessionRecord _session = tripRecord(
  id: 'trip-live-0001-aaaa-bbbb',
  status: 'ACTIVE',
  startedAtUtcMillis: DateTime.now()
      .subtract(const Duration(minutes: 12))
      .millisecondsSinceEpoch,
  startSoc: 71.0,
  startOdometerKm: 12800.0,
  startGear: 8,
);

void _installChannelProbe() {
  _methodCalls.clear();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_telemetry, (call) async {
    _methodCalls.add(call.method);
    return null;
  });
  messenger.setMockMethodCallHandler(_vehicleSpeed, (call) async {
    if (call.method == 'listen') {
      Future<void>.microtask(() async {
        await messenger.handlePlatformMessage(
          _vehicleSpeed.name,
          _codec.encodeSuccessEnvelope({
            'speedKmh': 48.0,
            'quality': 'MEASURED',
            'source': 'VHAL_CALLBACK',
            'receivedAtUtcMillis': DateTime.now().millisecondsSinceEpoch,
            'receivedAtElapsedNanos': 2000000000,
            'sourceTimestampNanos': 2000000000,
          }),
          (_) {},
        );
      });
    }
    return null;
  });
}

void _removeChannelProbe() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_telemetry, null);
  messenger.setMockMethodCallHandler(_vehicleSpeed, null);
}

Widget _app() {
  return MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('pt'),
    home: LiveTripDetailScreen(session: _session),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var index = 0; index < 4; index++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _teardownScreen(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  setUp(_installChannelProbe);
  tearDown(_removeChannelProbe);

  testWidgets('abre o painel híbrido no layout largo', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app());
    await _settle(tester);

    expect(find.text('TRIP AO VIVO'), findsOneWidget);
    expect(find.text('VELOCIDADE'), findsWidgets);
    expect(find.text('INCLINAÇÃO ATUAL DA VIA'), findsOneWidget);
    expect(find.text('48'), findsOneWidget);
    expect(find.text('VHAL'), findsOneWidget);
    expect(find.text('ECO COACH'), findsOneWidget);
    expect(find.text('Coletando amostras da condução'), findsOneWidget);
    expect(find.text('CORRENTE BATERIA'), findsWidgets);
    expect(find.byKey(const ValueKey('live_trip_duration')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('live_trip_soc_equation')),
      findsOneWidget,
    );
    expect(find.text('71.0%'), findsOneWidget);
    expect(find.text('TOTAIS DA VIAGEM'), findsNothing);
    expect(find.text('Traçado Bateria'), findsNothing);
    expect(find.text('--'), findsWidgets);
    expect(find.textContaining('Ponte CAN offline'), findsOneWidget);
    expect(_methodCalls, isEmpty);
    expect(tester.takeException(), isNull);

    await _teardownScreen(tester);
  });

  testWidgets('empilha sem estourar no viewport estreito', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app());
    await _settle(tester);

    expect(find.text('TRIP AO VIVO'), findsOneWidget);
    expect(find.text('VELOCIDADE'), findsWidgets);
    expect(_methodCalls, isEmpty);
    expect(tester.takeException(), isNull);

    await _teardownScreen(tester);
  });
}
