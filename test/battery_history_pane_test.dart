import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/mock_telemetry_source.dart';
import 'package:capy_energy/core/telemetry_api.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/screens_v2/history/battery_history_pane.dart';
import 'package:capy_ui/capy_ui.dart';

/// The pane exists to print what a battery bought, and to stay silent about
/// what it cannot support. These pin the silence, because that is the part a
/// later change would quietly undo.
void main() {
  Future<void> pump(WidgetTester tester, TelemetryApi api) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: BatteryHistoryPane(telemetryApi: api)),
      ),
    );
    await tester.pump();
  }

  testWidgets('one bar per battery, newest first', (tester) async {
    await pump(tester, TelemetryApi(source: MockTelemetrySource()));

    expect(find.byType(CycleBar), findsWidgets);
    // The newest battery is the open one, and it is the first row.
    expect(find.text('#6'), findsOneWidget);
    expect(find.text('In progress'), findsOneWidget);
  });

  testWidgets('a battery with no trusted capacity prints no efficiency', (
    tester,
  ) async {
    await pump(tester, _OneCycleApi(_cycle(energyIncomplete: true)));

    // The bar and the distance need no capacity, so they stay.
    expect(find.text('100'), findsOneWidget);
    expect(find.text('372'), findsOneWidget);
    expect(find.text('Capacity unknown'), findsOneWidget);
    // Energy, efficiency and usable capacity all divide a floor.
    expect(find.text('--'), findsNWidgets(3));
  });

  testWidgets('two currencies leave the row with no money at all', (
    tester,
  ) async {
    await pump(tester, _OneCycleApi(_cycle(mixedCurrency: true)));

    expect(find.text('Two currencies'), findsOneWidget);
    // The cost and the price per kWh, and nothing else.
    expect(find.text('--'), findsNWidgets(2));
  });

  testWidgets('a part-priced battery says how much of it was priced', (
    tester,
  ) async {
    await pump(
      tester,
      _OneCycleApi(
        _cycle(cost: 21.9, pricedEnergyKwh: 27.4, unpricedEnergyKwh: 12.2),
      ),
    );

    expect(find.text('69% priced'), findsOneWidget);
    // The share that was paid for is a real figure and stays printed.
    expect(find.text(r'R$ 21.90'), findsOneWidget);
  });

  testWidgets('an empty record says so instead of drawing a bar', (
    tester,
  ) async {
    await pump(tester, _NoCyclesApi());

    expect(find.byType(CycleBar), findsNothing);
    expect(
      find.text('The car has not used a whole battery yet.'),
      findsOneWidget,
    );
  });
}

BatteryCycleSummary _cycle({
  double dischargePercent = 100,
  double distanceKm = 371.5,
  double tripEnergyKwh = 39.6,
  double pricedEnergyKwh = 39.6,
  double unpricedEnergyKwh = 0,
  double? cost = 30.0,
  bool energyIncomplete = false,
  bool mixedCurrency = false,
}) => BatteryCycleSummary.fromMap({
  'ordinal': 3,
  'startUtcMillis': 1700000000000,
  'endUtcMillis': 1700600000000,
  'dischargePercent': dischargePercent,
  'distanceKm': distanceKm,
  'tripEnergyKwh': tripEnergyKwh,
  'parkedEnergyKwh': 0.0,
  'parkedSocPercent': 0.0,
  'pricedEnergyKwh': pricedEnergyKwh,
  'unpricedEnergyKwh': unpricedEnergyKwh,
  'isOpen': false,
  'isPartial': false,
  'energyIncomplete': energyIncomplete,
  'mixedCurrency': mixedCurrency,
  'updatedAtUtcMillis': 1700600000000,
  'cost': cost,
  'costCurrency': 'BRL',
  'frozenAtUtcMillis': null,
});

class _OneCycleApi extends TelemetryApi {
  _OneCycleApi(this.cycle) : super(source: MockTelemetrySource());

  final BatteryCycleSummary cycle;

  @override
  Future<BatteryCyclesResult> getBatteryCycles({int limit = 50}) async =>
      BatteryCyclesResult(cycles: [cycle], totalCount: 1, limit: limit);
}

class _NoCyclesApi extends TelemetryApi {
  _NoCyclesApi() : super(source: MockTelemetrySource());

  @override
  Future<BatteryCyclesResult> getBatteryCycles({int limit = 50}) async =>
      const BatteryCyclesResult(cycles: [], totalCount: 0, limit: 50);
}
