import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/mock_telemetry_store.dart';
import 'package:capy_energy/core/mock_telemetry_source.dart';
import 'package:capy_energy/core/telemetry_api.dart';
import 'package:capy_energy/core/telemetry_scope.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/screens/trips/trip_session_detail_screen.dart';

import 'support/session_records.dart';

/// Does the stored integral point the way the state of charge moved?
String _agreement = 'agrees';

const int _start = 1000;
const int _end = 301000;
const int _startNanos = 1000000000;

SessionRecord _sessionRecord() => tripRecord(
  id: 'trip-measured-0001',
  startedAtUtcMillis: _start,
  startedAtElapsedNanos: _startNanos,
  endedAtUtcMillis: _end,
  endedAtElapsedNanos: 301000000000,
  startSoc: 80.0,
  endSoc: 79.0,
  startOdometerKm: 1000.0,
  endOdometerKm: 1004.0,
  startGear: 8,
  endReason: 'VEHICLE_IDLE',
  meanAmbientTempC: 22.0,
  socAgreesWithIntegral: _agreement,
  sessionRollup: rollup(
    distanceKm: 4.0,
    tractionWh: 500.0,
    regenWh: 125.0,
    auxiliaryWh: 19.0,
    integratedSeconds: 300.0,
  ),
);

/// The charge that filled the car, priced. The drive is scored at its rate.
SessionRecord _pricedCharge() => chargeRecord(
  id: 'charge-before',
  startedAtUtcMillis: _start - 3600000,
  plugDisconnectedAtUtcMillis: _start - 1800000,
  costPerKwh: 0.92,
  costCurrency: 'BRL',
  deliveredWh: 10000.0,
);

MockTelemetryStore _store() {
  const id = 'trip-measured-0001';
  final track = TrackCodec.encode(const [
    TrackPoint(
      latitude: -23.55,
      longitude: -46.63,
      tSeconds: 0,
      speedKmh: 0,
      altitudeM: 700,
    ),
    TrackPoint(
      latitude: -23.56,
      longitude: -46.64,
      tSeconds: 300,
      speedKmh: 48,
      altitudeM: 710,
    ),
  ]);
  return MockTelemetryStore(
    sessions: [_sessionRecord(), _pricedCharge()],
    intervals: {
      id: [
        intervalRecord(
          sessionId: id,
          startUtcMillis: _start,
          tractionWh: 250.0,
          regenWh: 60.0,
          auxiliaryWh: 9.0,
          distanceKm: 2.0,
          startSoc: 80.0,
          endSoc: 79.5,
        ),
        intervalRecord(
          sessionId: id,
          startUtcMillis: _start + 60000,
          tractionWh: 250.0,
          regenWh: 65.0,
          auxiliaryWh: 10.0,
          distanceKm: 2.0,
          startSoc: 79.5,
          endSoc: 79.0,
        ),
      ],
    },
    tracks: {id: track},
  );
}

Widget _app() => MaterialApp(
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('pt'),
  home: TelemetryScope(
    api: TelemetryApi(source: MockTelemetrySource(), store: _store()),
    child: TripSessionDetailScreen(session: _sessionRecord()),
  ),
);

Future<void> _load(WidgetTester tester) async {
  await tester.pumpWidget(_app());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUp(() => _agreement = 'agrees');

  testWidgets('mostra o balanço medido somente quando ele concorda com SOC', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _load(tester);

    final summary = find.text('RESUMO DA VIAGEM');
    final balance = find.text('BALANÇO DE ENERGIA');
    final speedChart = find.text('Traçado Velocidade');
    final powerChart = find.text('Potência Medida');
    final elevationChart = find.text('Perfil de Elevação por Distância');
    final map = find.text('Mapa da Rota');
    expect(summary, findsOneWidget);
    expect(balance, findsOneWidget);
    expect(speedChart, findsOneWidget);
    expect(powerChart, findsOneWidget);
    expect(elevationChart, findsOneWidget);
    expect(map, findsOneWidget);
    expect(
      tester.getTopLeft(summary).dy,
      lessThan(tester.getTopLeft(balance).dy),
    );
    expect(
      tester.getTopLeft(summary).dx,
      lessThan(tester.getTopLeft(speedChart).dx),
    );
    expect(
      tester.getTopLeft(speedChart).dx,
      lessThan(tester.getTopLeft(map).dx),
    );
    expect(find.byTooltip('Expandir gráfico'), findsNWidgets(4));
    expect(find.byIcon(Icons.open_in_full), findsNWidgets(5));
    await tester.tap(find.byTooltip('Expandir gráfico').first);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.close_fullscreen), findsOneWidget);
    expect(find.text('Traçado Velocidade'), findsNWidgets(2));
    await tester.tap(find.byIcon(Icons.close_fullscreen));
    await tester.pumpAndSettle();
    expect(find.text('BATERIA'), findsOneWidget);
    expect(find.text('TRAÇÃO'), findsOneWidget);
    expect(find.text('Traçado Temperatura Externa'), findsNothing);
    final charts = tester
        .widgetList<LineChart>(find.byType(LineChart))
        .toList();
    expect(charts, hasLength(4));
    expect(charts[1].data.lineBarsData, hasLength(2));
    // A stored minute stated as a power: 250 - 60 + 9 Wh over 60 s is
    // 11.94 kW at the pack, and 250 - 60 Wh is 11.4 kW at the wheels.
    expect(
      charts[1].data.lineBarsData.first.spots.first.y,
      closeTo(11.94, 0.01),
    );
    expect(charts[1].data.lineBarsData.last.spots.first.y, closeTo(11.4, 0.01));
    expect(charts[3].data.lineBarsData.single.spots.last.x, greaterThan(1.0));
    expect(find.text('MEDIDO'), findsOneWidget);
    expect(find.text('MOVIMENTO DO VEÍCULO'), findsOneWidget);
    expect(
      find.text('Energia usada para movimentar o veículo.'),
      findsOneWidget,
    );
    expect(find.text('RECUPERADA POR REGENERAÇÃO'), findsOneWidget);
    expect(
      find.text('Energia devolvida pela frenagem regenerativa.'),
      findsOneWidget,
    );
    expect(find.text('SISTEMAS AUXILIARES'), findsOneWidget);
    expect(
      find.text('Estimativa de climatização, eletrônica e sistema de 12 V.'),
      findsOneWidget,
    );
    expect(find.text('ENERGIA LÍQUIDA DA BATERIA'), findsOneWidget);
    expect(find.text('0.50'), findsOneWidget);
    expect(find.text('0.13'), findsOneWidget);
    expect(find.text('0.02'), findsOneWidget);
    expect(find.text('0.39'), findsOneWidget);
    expect(find.text('+'), findsNWidgets(2));
    expect(find.text('−'), findsOneWidget);
    expect(find.text('='), findsOneWidget);
    expect(find.text('EST'), findsOneWidget);
    expect(find.text('CONFERÊNCIA POR SOC'), findsNothing);
    expect(find.text('RENDIMENTO'), findsNothing);
    expect(find.text('ENERGIA LÍQ'), findsNothing);
    expect(find.text('REGEN'), findsNothing);
    expect(find.text('MARCHA INÍCIO'), findsNothing);
    expect(find.text('MOTIVO FIM'), findsNothing);
    expect(find.text('AUXILIAR / TEMP. EXTERNA'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('oculta a integral quando a medição diverge do SOC', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    _agreement = 'contradicts';

    await _load(tester);

    expect(
      find.text(
        'A energia medida diverge da estimativa por SOC. '
        'Os valores estão ocultos.',
      ),
      findsOneWidget,
    );
    expect(find.text('0.39'), findsNothing);
    expect(find.text('MEDIDO'), findsNothing);
    expect(
      find.text(
        'A potência medida está oculta porque diverge da estimativa por SOC.',
      ),
      findsOneWidget,
    );
    // A contradicted drive has no energy the app will publish, so it has no
    // cost either. The SOC estimate that used to fill this in was removed by
    // decision 5, and nothing may price a number the car does not trust.
    expect(find.text('R\$ 0.36'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empilha o resumo e a conta sem overflow no viewport compacto', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _load(tester);

    expect(find.text('RESUMO DA VIAGEM'), findsOneWidget);
    expect(find.text('CUSTO ESTIMADO'), findsOneWidget);
    expect(find.text('R\$ 0.36'), findsOneWidget);
    expect(
      find.text(
        'Baseado no preço de R\$ 0.92/kWh do último carregamento com valor '
        'informado.',
      ),
      findsOneWidget,
    );
    expect(find.text('BALANÇO DE ENERGIA'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
