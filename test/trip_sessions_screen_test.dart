import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/mock_telemetry_source.dart';
import 'package:capy_energy/core/mock_telemetry_store.dart';
import 'package:capy_energy/core/telemetry_api.dart';

import 'support/session_records.dart';
import 'package:capy_energy/core/telemetry_scope.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/screens/trips/trip_event_card.dart';
import 'package:capy_energy/screens/trips/trip_sessions_screen.dart';

const MethodChannel _vehicleSpeed = MethodChannel(
  'com.timhss.capyenergy/telemetry/vehicle-speed',
);
const StandardMethodCodec _codec = StandardMethodCodec();

SessionRecord _trip({
  required String id,
  required String status,
  required bool open,
}) {
  final now = DateTime.now();
  final started = now.subtract(const Duration(minutes: 24));
  return tripRecord(
    id: id,
    status: status,
    startedAtUtcMillis: started.millisecondsSinceEpoch,
    startedAtElapsedNanos: 1000000000,
    endedAtUtcMillis: open
        ? null
        : now.subtract(const Duration(minutes: 4)).millisecondsSinceEpoch,
    endedAtElapsedNanos: open ? null : 1200000000000,
    startSoc: 74.0,
    endSoc: open ? null : 69.0,
    startOdometerKm: 12800.0,
    endOdometerKm: open ? null : 12812.4,
    startGear: 8,
    endReason: open ? null : 'VEHICLE_IDLE',
  );
}

/// Sessions with timestamps that do not move between reads, so a refresh
/// returns identical rows the display cache is expected to reuse.
List<SessionRecord> _stableTrips(int count) {
  const startedAt = 1754200000000;
  return [
    for (var index = 0; index < count; index++)
      tripRecord(
        id: 'trip-stable-$index',
        startedAtUtcMillis: startedAt + index * 3600000,
        startedAtElapsedNanos: 1000000000,
        endedAtUtcMillis: startedAt + index * 3600000 + 1200000,
        endedAtElapsedNanos: 1200000000000,
        startSoc: 74.0,
        endSoc: 69.0,
        startOdometerKm: 12800.0,
        endOdometerKm: 12812.4,
        startGear: 8,
        endReason: 'VEHICLE_IDLE',
      ),
  ];
}

/// When set, replaces the default payload so a test can control row count and
/// timestamp stability.
List<SessionRecord>? _sessionsOverride;

/// The list asks the store its first question, so the rows are given to a
/// store rather than to the messenger.
TelemetryApi _api() => TelemetryApi(
  source: MockTelemetrySource(),
  store: MockTelemetryStore(
    sessions:
        _sessionsOverride ??
        [
          _trip(id: 'trip-live-0002', status: 'ACTIVE', open: true),
          _trip(id: 'trip-closed-0001', status: 'ENDED', open: false),
        ],
  ),
);

void _installChannel() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
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

void _removeChannel() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_vehicleSpeed, null);
  _sessionsOverride = null;
}

Widget _app() => TelemetryScope(
  api: _api(),
  child: MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('pt'),
    home: const TripSessionsScreen(),
  ),
);

Future<void> _settle(WidgetTester tester) async {
  for (var index = 0; index < 4; index++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(_installChannel);
  tearDown(_removeChannel);

  testWidgets('sessão aberta ganha destaque live e sai do histórico', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app());
    await _settle(tester);

    final loc = await AppLocalizations.delegate.load(const Locale('pt'));
    expect(find.text(loc.liveTripRowTitle), findsOneWidget);
    expect(find.text(loc.liveTripOpen), findsOneWidget);
    expect(find.text('48 ${loc.unitKmh}'), findsOneWidget);
    expect(find.byType(TripEventCard), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('destaque live cabe no viewport estreito', (tester) async {
    await tester.pumpWidget(_app());
    await _settle(tester);

    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('histórico longo constrói só os cards perto do viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    _sessionsOverride = _stableTrips(60);

    await tester.pumpWidget(_app());
    await _settle(tester);

    // A Column-based list would materialise all 60 cards regardless of the
    // viewport; the sliver only builds what is visible plus the cache extent.
    final built = tester.widgetList<TripEventCard>(find.byType(TripEventCard));
    expect(built, isNotEmpty);
    expect(built.length, lessThan(30));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('refresh de 5s reaproveita as linhas já formatadas', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    _sessionsOverride = _stableTrips(6);

    await tester.pumpWidget(_app());
    await _settle(tester);

    final before = tester
        .widget<TripEventCard>(find.byType(TripEventCard).first)
        .row;

    // Fire the periodic refresh; the payload is unchanged, so every row should
    // come back as the same TripSessionDisplay instead of being reformatted.
    await tester.pump(const Duration(seconds: 5));
    await _settle(tester);

    final after = tester
        .widget<TripEventCard>(find.byType(TripEventCard).first)
        .row;

    expect(identical(before, after), isTrue);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
