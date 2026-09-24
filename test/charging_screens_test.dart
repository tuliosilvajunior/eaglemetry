import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/mock_telemetry_source.dart';
import 'package:capy_energy/core/telemetry_api.dart';
import 'package:capy_energy/core/telemetry_scope.dart';
import 'package:capy_energy/core/mock_telemetry_store.dart';
import 'package:capy_energy/l10n/app_localizations.dart';

import 'support/session_records.dart';
import 'package:capy_energy/screens/charging/charging_session_detail_screen.dart';
import 'package:capy_energy/screens/charging/charging_session_display.dart';
import 'package:capy_energy/screens/charging/charging_sessions_screen.dart';
import 'package:capy_energy/screens/charging/live_charge_detail_screen.dart';

const MethodChannel _live = MethodChannel(
  'com.timhss.capyenergy/telemetry/live',
);
const MethodChannel _pathProvider = MethodChannel(
  'plugins.flutter.io/path_provider',
);

/// Chamadas que a lista fez, para verificar que os candidatos a fusão saíram do
/// caminho crítico em vez de continuarem bloqueando a primeira pintura.
final List<String> _calls = <String>[];

/// One charge, as the store answers it.
SessionRecord _chargeSession({
  required String id,
  required String status,
  bool open = false,
}) {
  final now = DateTime.now();
  final connected = now.subtract(const Duration(hours: 2));
  return chargeRecord(
    id: id,
    status: status,
    startedAtUtcMillis: connected.millisecondsSinceEpoch,
    chargeStartedAtUtcMillis: connected
        .add(const Duration(minutes: 1))
        .millisecondsSinceEpoch,
    plugDisconnectedAtUtcMillis: open
        ? null
        : now.subtract(const Duration(minutes: 20)).millisecondsSinceEpoch,
    plugDisconnectedAtElapsedNanos: open ? null : 7200000000000,
    startSoc: 42.0,
    endSoc: open ? null : 81.0,
    plugType: 605225491,
    startPowerKw: 7.2,
    deliveredWh: 14830.0,
    costPerKwh: 0.92,
    costCurrency: 'BRL',
    startAmbientTempC: 21.0,
    endAmbientTempC: 23.0,
    startLatitude: -23.5617,
    startLongitude: -46.6559,
    endReason: open ? null : 'COMPLETED',
  );
}

/// The stored minutes and samples of the closed charge.
///
/// Two hours at about 7.4 kW, which is what the peak-power reading on the
/// detail screen is read from — a stored minute, never an instant.
TelemetrySeries _chargeSeries(SessionRecord session) {
  final start = session.startedAtUtcMillis;
  return TelemetrySeries(
    sessionId: session.id,
    intervals: [
      for (var minute = 0; minute < 120; minute++)
        intervalRecord(
          sessionId: session.id,
          startUtcMillis: start + minute * 60000,
          deliveredWh: (minute == 0 ? 7.4 : 7.1) * 1000 / 60,
          deliveredCoveredSeconds: 60,
          startSoc: 42.0 + minute * 0.325,
          endSoc: 42.0 + (minute + 1) * 0.325,
        ),
    ],
  );
}

Map<String, Object?> _settings() => const {
  'autoStartOnBoot': true,
  'gpsEnabled': true,
  'defaultChargeCostPerKwh': 0.92,
  'chargeCostCurrency': 'BRL',
};

/// The charge list and its merge candidates travel over generated channels,
/// which a test cannot stub by name, so every answer is given to the source.
/// The order the screen asks in is still observable through [_calls].
TelemetryApi _api({bool withOpenSession = false}) {
  final sessions = [
    if (withOpenSession)
      _chargeSession(id: 'charge-open-0002', status: 'CHARGING', open: true),
    _chargeSession(id: 'charge-closed-0001', status: 'ENDED'),
  ];
  return TelemetryApi(
    store: _RecordingStore(
      calls: _calls,
      inner: MockTelemetryStore(
        sessions: sessions,
        intervals: {
          for (final session in sessions)
            session.id: _chargeSeries(session).intervals,
        },
        samples: {
          for (final session in sessions)
            session.id: _chargeSeries(session).samples,
        },
      ),
    ),
    source: MockTelemetrySource(
      answer: (method, arguments) {
        _calls.add(method);
        switch (method) {
          case 'getChargeMergeCandidates':
            return const {'candidates': <Object?>[], 'totalCount': 0};
          case 'getTelemetrySettings':
            return _settings();
          case 'getLiveTelemetrySnapshot':
            return const {
              'timestampMillis': 0,
              'signals': <Object?>[],
              'trip': <String, Object?>{},
              'location': <String, Object?>{},
              'charge': <String, Object?>{},
              'sessions': <String, Object?>{},
              'frames': <String, Object?>{},
              'recentEvents': <Object?>[],
            };
          default:
            return null;
        }
      },
    ),
  );
}

/// The store, with the questions it was asked written down.
///
/// The list's order is what this test is about — the merge candidates left the
/// critical path — and the store is where the list read is now made.
class _RecordingStore implements TelemetryStore {
  _RecordingStore({required this.calls, required this.inner});

  final List<String> calls;
  final TelemetryStore inner;

  @override
  Future<SessionListPage> listSessions({
    SessionFilter? filter,
    PageRequest? page,
  }) {
    calls.add('listSessions');
    return inner.listSessions(filter: filter, page: page);
  }

  @override
  Future<SessionDetail?> session(String id) {
    calls.add('session');
    return inner.session(id);
  }

  @override
  Future<TelemetrySeries> series(
    String id, {
    Set<String>? keys,
    int? widthMillis,
  }) {
    calls.add('series');
    return inner.series(id, keys: keys, widthMillis: widthMillis);
  }
}

void _installChannels() {
  _calls.clear();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_live, (call) async => null);
  messenger.setMockMethodCallHandler(
    _pathProvider,
    (call) async => Directory.systemTemp.path,
  );
}

void _removeChannels() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_live, null);
  messenger.setMockMethodCallHandler(_pathProvider, null);
}

Widget _app(Widget home, {bool withOpenSession = false}) => TelemetryScope(
  api: _api(withOpenSession: withOpenSession),
  child: MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('pt'),
    home: home,
  ),
);

/// Deixa as fontes assíncronas chegarem sem `pumpAndSettle`, que nunca voltaria:
/// estas telas mantêm timers periódicos e um pulso animado em laço.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
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

SessionRecord _closedSummary() =>
    _chargeSession(id: 'charge-closed-0001', status: 'ENDED');

SessionRecord _openSummary() =>
    _chargeSession(id: 'charge-open-0002', status: 'CHARGING', open: true);

void main() {
  test('identifica somente o tipo oficial de plugue DC', () {
    expect(isDcChargePlugType(605225492), isTrue);
    expect(isDcChargePlugType(605225491), isFalse);
    expect(isDcChargePlugType(null), isFalse);
  });

  tearDown(_removeChannels);

  group('lista de carregamento', () {
    testWidgets('desenha o histórico sem esperar os candidatos a fusão', (
      tester,
    ) async {
      _installChannels();
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_app(const ChargingSessionsScreen()));
      await _settle(tester);

      expect(find.byType(ChargingSessionsScreen), findsOneWidget);
      // A lista e as configurações são o caminho crítico; a fusão vem depois.
      expect(_calls.contains('listSessions'), isTrue);
      expect(_calls.contains('getTelemetrySettings'), isTrue);
      expect(
        _calls.indexOf('getChargeMergeCandidates'),
        greaterThan(_calls.indexOf('listSessions')),
      );
      expect(tester.takeException(), isNull);

      await _teardownScreen(tester);
    });

    testWidgets('sessão aberta vira linha ao vivo, fora do histórico', (
      tester,
    ) async {
      _installChannels();
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _app(const ChargingSessionsScreen(), withOpenSession: true),
      );
      await _settle(tester);

      final loc = await AppLocalizations.delegate.load(const Locale('pt'));
      expect(find.text(loc.liveChargeRowTitle), findsOneWidget);
      // A carga aberta aparece uma vez só: repeti-la no histórico daria duas
      // linhas para a mesma sessão, uma delas ainda mudando.
      expect(find.textContaining('charge-op'), findsNothing);
      expect(tester.takeException(), isNull);

      await _teardownScreen(tester);
    });

    testWidgets('não estoura no viewport estreito do teste', (tester) async {
      _installChannels();

      await tester.pumpWidget(_app(const ChargingSessionsScreen()));
      await _settle(tester);

      expect(tester.takeException(), isNull);

      await _teardownScreen(tester);
    });
  });

  group('detalhe de carga encerrada', () {
    testWidgets('mostra energia, custo e as curvas sem a barra antiga', (
      tester,
    ) async {
      _installChannels();
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _app(ChargeSessionDetailScreen(session: _closedSummary())),
      );
      await _settle(tester);

      final loc = await AppLocalizations.delegate.load(const Locale('pt'));
      expect(find.text('14.83'), findsOneWidget);
      expect(find.text(loc.chargeDetailCost), findsOneWidget);
      expect(find.text(loc.chargeDetailPeakPower), findsOneWidget);
      // O botão dedicado saiu: editar custo agora é tocar no cartão do custo.
      expect(find.text(loc.chargeDetailEditCost), findsNothing);
      expect(tester.takeException(), isNull);

      await _teardownScreen(tester);
    });

    testWidgets('não estoura no viewport estreito do teste', (tester) async {
      _installChannels();

      await tester.pumpWidget(
        _app(ChargeSessionDetailScreen(session: _closedSummary())),
      );
      await _settle(tester);

      expect(tester.takeException(), isNull);

      await _teardownScreen(tester);
    });
  });

  group('carga ao vivo', () {
    testWidgets('abre sem barramento e não apresenta valor inventado', (
      tester,
    ) async {
      _installChannels();
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _app(LiveChargeDetailScreen(session: _openSummary())),
      );
      await _settle(tester);

      final loc = await AppLocalizations.delegate.load(const Locale('pt'));
      expect(find.text(loc.liveChargeInputPower), findsWidgets);
      expect(find.text(loc.liveChargePackCurrent), findsWidgets);
      expect(find.text(loc.liveChargeObcEfficiency), findsWidgets);
      // Sem Roadcast no host de teste, cada leitura do barramento é `--`, não um
      // número derivado de uma escala que ninguém leu.
      expect(find.text('--'), findsWidgets);
      expect(
        _calls.contains('series'),
        isFalse,
        reason: 'a tela live não consulta Room pelo MethodChannel',
      );
      expect(
        _calls.contains('getLiveTelemetrySnapshot'),
        isFalse,
        reason: 'a tela live não usa snapshot/property stream',
      );
      expect(tester.takeException(), isNull);

      await _teardownScreen(tester);
    });

    testWidgets('não estoura no viewport estreito do teste', (tester) async {
      _installChannels();

      await tester.pumpWidget(
        _app(LiveChargeDetailScreen(session: _openSummary())),
      );
      await _settle(tester);

      expect(tester.takeException(), isNull);

      await _teardownScreen(tester);
    });
  });
}
