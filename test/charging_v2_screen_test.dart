import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/mock_telemetry_source.dart';
import 'package:capy_energy/core/range_estimate_controller.dart';
import 'package:capy_energy/core/telemetry_api.dart';
import 'package:capy_energy/core/vehicle_state_controller.dart';
import 'package:capy_energy/l10n/app_localizations.dart';

import 'support/session_records.dart';
import 'package:capy_energy/screens_v2/charging/charging_energy_panel.dart';
import 'package:capy_energy/core/charge_climate_warning.dart';
import 'package:capy_energy/screens_v2/charging/charging_graph_panel.dart';
import 'package:capy_energy/screens_v2/charging/charging_constants.dart';
import 'package:capy_energy/screens_v2/charging/charging_limit_panel.dart';
import 'package:capy_energy/screens_v2/charging/charging_v2_screen.dart';
import 'package:capy_ui/capy_ui.dart';

void main() {
  testWidgets('left charging panel shows separate vehicle and app ranges', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _FakeTelemetryApi();
    final controller = VehicleStateController()
      ..applySnapshotForTest(_snapshot(isCharging: true));
    final rangeController = RangeEstimateController(telemetryApi: api);
    await rangeController.refresh();

    await tester.pumpWidget(
      _app(
        ChargingV2Screen(
          title: 'Charging',
          vehicleStateController: controller,
          rangeEstimateController: rangeController,
          telemetryApi: api,
        ),
      ),
    );
    await tester.pump();

    // The vehicle value and the app estimate stay separate: 266 km is the
    // car's distance-to-empty, 178 km is the SOC-based estimate.
    expect(find.text('266'), findsOneWidget);
    expect(find.text('178'), findsOneWidget);
    expect(find.text('Vehicle range'), findsOneWidget);
    expect(find.text('Estimate from closed trips'), findsOneWidget);
    expect(find.text('Stop charging'), findsNothing);
    expect(find.text('7 A'), findsNothing);
    expect(find.text('Open charge port'), findsNothing);
    expect(find.text('Prepare for fast charging'), findsNothing);
    expect(find.text('Outlets'), findsNothing);
    expect(find.text('Level'), findsNothing);
    expect(find.text('Schedule'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the charging screen offers no control over the vehicle', (
    tester,
  ) async {
    // Issue #190: charging is controlled by the dedicated native app. This
    // screen reads the charge; it must offer nothing that writes to the car,
    // whether a session is running or not.
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final charging in [true, false]) {
      final api = _FakeTelemetryApi();
      final controller = VehicleStateController()
        ..applySnapshotForTest(_snapshot(isCharging: charging));
      final rangeController = RangeEstimateController(telemetryApi: api);
      await rangeController.refresh();

      await tester.pumpWidget(
        _app(
          ChargingV2Screen(
            key: ValueKey('control-free-$charging'),
            title: 'Charging',
            vehicleStateController: controller,
            rangeEstimateController: rangeController,
            telemetryApi: api,
          ),
        ),
      );
      await tester.pump();

      final reason = charging ? 'while charging' : 'while idle';

      // No target picker, in any of the shapes it ever had.
      expect(find.byType(LimitSlider), findsNothing, reason: reason);
      expect(find.byType(Slider), findsNothing, reason: reason);

      // No command, in any of the words it ever used.
      for (final label in const [
        'Stop charging',
        'STOP CHARGING',
        'Force charging',
        'Charge limit',
        'Daily',
        'Extended',
        'Maximum',
      ]) {
        expect(find.text(label), findsNothing, reason: '$label $reason');
      }

      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'shows LimitSlider and tabs when externalChargeControlEnabled is active',
    (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = _FakeTelemetryApi()..externalChargeControlEnabled = true;
      final controller = VehicleStateController()
        ..applySnapshotForTest(_snapshot(isCharging: true));
      final rangeController = RangeEstimateController(telemetryApi: api);
      await rangeController.refresh();

      await tester.pumpWidget(
        _app(
          ChargingV2Screen(
            title: 'Charging',
            vehicleStateController: controller,
            rangeEstimateController: rangeController,
            telemetryApi: api,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(LimitSlider), findsOneWidget);
      expect(find.text('Level'), findsOneWidget);
      expect(find.text('Graph'), findsOneWidget);
      expect(find.text('Daily'), findsOneWidget);
      expect(find.text('Extended'), findsOneWidget);
      expect(find.text('Max'), findsOneWidget);

      // Switching to Graph tab shows the chart
      await tester.tap(find.text('Graph'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(EnergyBarChart), findsOneWidget);

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'synchronizes charge target Soc bidirectionally with external controller',
    (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = _FakeTelemetryApi()
        ..externalChargeControlEnabled = true
        ..chargeTargetSoc = 70;
      final controller = VehicleStateController()
        ..applySnapshotForTest(_snapshot(isCharging: true));
      final rangeController = RangeEstimateController(telemetryApi: api);
      await rangeController.refresh();

      await tester.pumpWidget(
        _app(
          ChargingV2Screen(
            title: 'Charging',
            vehicleStateController: controller,
            rangeEstimateController: rangeController,
            telemetryApi: api,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final slider = tester.widget<LimitSlider>(find.byType(LimitSlider));
      expect(slider.value, 70.0);

      // 1. Tapping preset (e.g. Max = 100) commits target to api
      await tester.tap(find.text('Max'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(api.chargeTargetSoc, 100);

      // 2. Incoming external change updates the slider
      api.targetSocChangesController.add(85);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final updatedSlider = tester.widget<LimitSlider>(
        find.byType(LimitSlider),
      );
      expect(updatedSlider.value, 85.0);
    },
  );

  testWidgets('no charge control reaches the screen while the switch is off', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // The reader has not handed charge control to Geely Charge Control, so
    // Capy Energy is a telemetry analyser and shows no control at all.
    final api = _FakeTelemetryApi()
      ..externalChargeControlEnabled = false
      ..chargeControlState = const ChargeControlState(
        targetSoc: 80,
        amps: 8,
        minAmps: 5,
        maxAmps: 32,
      );
    final controller = VehicleStateController()
      ..applySnapshotForTest(_snapshot(isCharging: true));
    final rangeController = RangeEstimateController(telemetryApi: api);
    await rangeController.refresh();

    await tester.pumpWidget(
      _app(
        ChargingV2Screen(
          title: 'Charging',
          vehicleStateController: controller,
          rangeEstimateController: rangeController,
          telemetryApi: api,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('8 A'), findsNothing);
    expect(find.text('-- A'), findsNothing);
    expect(find.byType(LimitSlider), findsNothing);
    expect(find.text('Stop Charging'), findsNothing);
    expect(find.text('Force Charging'), findsNothing);
    expect(find.text('Daily'), findsNothing);
    expect(find.text('Extended'), findsNothing);
    expect(find.text('Max'), findsNothing);
  });

  /// The switch is not only a way to hide the controls. A panel handed no
  /// callback draws no control at all, so nothing on the screen can write to
  /// the car even if a layout renders it.
  testWidgets('a limit panel with no way to write draws no knob', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(
        ChargingLimitPanel(
          // The switch says yes, but no callback was given.
          externalChargeControlEnabled: true,
          tab: ChargePanelTab.level,
          target: 80,
          currentSoc: 55,
          isCharging: true,
          climateWarning: ChargeClimateWarning.none,
          climateKw: null,
          chargingPowerKw: 7.0,
          session: null,
          detail: null,
          recentHistory: null,
          defaultCostPerKwh: null,
          chargeCostCurrency: 'BRL',
          savingCost: false,
          onCostChanged: (_) {},
          graphLoading: false,
          graphFailed: false,
          graphSelection: null,
          graphDismissed: false,
          onGraphSelected: (_) {},
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(LimitSlider), findsNothing);
    expect(find.text('Daily'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an energy panel with no way to write draws no control', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(
        const ChargingEnergyPanel(
          vehicleRangeKm: 266,
          vehicleRangeAvailable: true,
          appRangeKm: 178,
          appRangeCaption: 'Estimate from closed trips',
          externalChargeControlEnabled: true,
          isActivelyCharging: true,
          chargeControlState: ChargeControlState(amps: 8, minAmps: 5),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Stop Charging'), findsNothing);
    expect(find.text('Force Charging'), findsNothing);
    expect(find.text('8 A'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an amperage the car has not reported reads as unknown, not as a number',
    (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = _FakeTelemetryApi()
        ..externalChargeControlEnabled = true
        // No read-back yet: Geely Charge Control has not answered, or the
        // command it answered failed.
        ..chargeControlState = const ChargeControlState(
          targetSoc: 80,
          minAmps: 5,
          maxAmps: 32,
        );
      final controller = VehicleStateController()
        ..applySnapshotForTest(_snapshot(isCharging: true));
      final rangeController = RangeEstimateController(telemetryApi: api);
      await rangeController.refresh();

      await tester.pumpWidget(
        _app(
          ChargingV2Screen(
            title: 'Charging',
            vehicleStateController: controller,
            rangeEstimateController: rangeController,
            telemetryApi: api,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('-- A'), findsOneWidget);
      expect(find.text('5 A'), findsNothing);
    },
  );

  testWidgets('a refused charge command tells the reader why', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _FakeTelemetryApi()..externalChargeControlEnabled = true;
    final controller = VehicleStateController()
      ..applySnapshotForTest(_snapshot(isCharging: true));
    final rangeController = RangeEstimateController(telemetryApi: api);
    await rangeController.refresh();

    await tester.pumpWidget(
      _app(
        ChargingV2Screen(
          title: 'Charging',
          vehicleStateController: controller,
          rangeEstimateController: rangeController,
          telemetryApi: api,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    api.chargeControlStateChangesController.add(
      const ChargeControlState(
        lastCommandOk: false,
        lastError: 'Sem conexão com o veículo',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Sem conexão com o veículo'), findsOneWidget);
  });

  testWidgets(
    'shows AC amperage stepper, force charging, and stop charging controls in left panel when enabled',
    (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = _FakeTelemetryApi()
        ..externalChargeControlEnabled = true
        ..chargeControlState = const ChargeControlState(
          targetSoc: 80,
          amps: 16,
          minAmps: 5,
          maxAmps: 32,
          forceCharging: false,
        );
      final controller = VehicleStateController()
        ..applySnapshotForTest(_snapshot(isCharging: true));
      final rangeController = RangeEstimateController(telemetryApi: api);
      await rangeController.refresh();

      await tester.pumpWidget(
        _app(
          ChargingV2Screen(
            title: 'Charging',
            vehicleStateController: controller,
            rangeEstimateController: rangeController,
            telemetryApi: api,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // 1. Amperage Tile and Tooltip Dialog
      expect(find.text('16 A'), findsOneWidget);
      await tester.tap(find.text('16 A'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(ChargingAmperageDialog), findsOneWidget);
      expect(find.text('Charging amperage'), findsOneWidget);
      expect(find.text('Vehicle range 5–32 A'), findsOneWidget);

      // Increase amperage via chevron
      await tester.tap(find.byKey(const Key('charging-amperage-increase')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(api.chargeControlState.amps, 17);

      // Close dialog by tapping barrier
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // 2. Force Charging Toggle
      expect(find.text('Force Charging'), findsOneWidget);
      await tester.tap(find.text('Force Charging'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(api.chargeControlState.forceCharging, isTrue);

      // 3. Stop Charging
      expect(find.text('Stop Charging'), findsOneWidget);
      await tester.tap(find.text('Stop Charging'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(api.stopChargingCalls, 1);
    },
  );

  testWidgets('unavailable and degraded estimates get distinct captions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = VehicleStateController()
      ..applySnapshotForTest(_snapshot(isCharging: false));

    // Unavailable: both values show `--` and the app caption says so.
    final unavailableApi = _FakeTelemetryApi(rangeAvailable: false);
    final unavailableRange = RangeEstimateController(
      telemetryApi: unavailableApi,
    );
    await unavailableRange.refresh();
    await tester.pumpWidget(
      _app(
        ChargingV2Screen(
          key: const ValueKey('unavailable'),
          title: 'Charging',
          vehicleStateController: controller,
          rangeEstimateController: unavailableRange,
          telemetryApi: unavailableApi,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Vehicle range'), findsOneWidget);
    expect(find.text('Estimate unavailable'), findsOneWidget);
    expect(find.text('--'), findsNWidgets(2));
    expect(tester.takeException(), isNull);

    // Degraded: the cached estimate is shown but flags the delayed history.
    final degradedApi = _FakeTelemetryApi(rangeDegraded: true);
    final degradedRange = RangeEstimateController(telemetryApi: degradedApi);
    await degradedRange.refresh();
    await tester.pumpWidget(
      _app(
        ChargingV2Screen(
          key: const ValueKey('degraded'),
          title: 'Charging',
          vehicleStateController: controller,
          rangeEstimateController: degradedRange,
          telemetryApi: degradedApi,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('178'), findsOneWidget);
    expect(
      find.text('Estimate delayed · history update pending'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a failed range read is reported instead of passing for no data',
    (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _FakeTelemetryApi(
        rangeReadFailed: true,
        failHistory: true,
        failSettings: true,
      );
      final controller = VehicleStateController()
        ..applySnapshotForTest(_snapshot(isCharging: false));
      final rangeController = RangeEstimateController(telemetryApi: api);
      await rangeController.refresh();

      await tester.pumpWidget(
        _app(
          ChargingV2Screen(
            title: 'Charging',
            vehicleStateController: controller,
            rangeEstimateController: rangeController,
            telemetryApi: api,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The estimate says why instead of passing for a car with no data.
      expect(find.text('Estimate unavailable · read failed'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ChargingEnergyPanel),
          matching: find.text('--'),
        ),
        findsNWidgets(2),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a failed refresh labels the retained estimate as delayed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _FakeTelemetryApi();
    final vehicle = VehicleStateController()
      ..applySnapshotForTest(_snapshot(isCharging: false));
    final range = RangeEstimateController(telemetryApi: api);
    await range.refresh();
    api.rangeReadFailed = true;
    await range.refresh();

    await tester.pumpWidget(
      _app(
        ChargingV2Screen(
          title: 'Charging',
          vehicleStateController: vehicle,
          rangeEstimateController: range,
          telemetryApi: api,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('178'), findsOneWidget);
    expect(find.text('Estimate delayed · range read failed'), findsOneWidget);
    expect(find.text('Estimate from closed trips'), findsNothing);
  });

  testWidgets('a charge write reaches the panel without waiting for a tick', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _FakeTelemetryApi();
    addTearDown(() => api.sessions.close());
    // Not charging, so the tick is off. Before the push existed this panel had
    // nothing left to notice a merge, a close or a priced session with.
    final controller = VehicleStateController()
      ..applySnapshotForTest(_snapshot(isCharging: false));

    await tester.pumpWidget(
      _app(
        ChargingV2Screen(
          title: 'Charging',
          vehicleStateController: controller,
          telemetryApi: api,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final afterOpen = api.detailRequestCount;

    api.sessions.add(
      const SessionChange(revision: 1, trips: false, charges: true),
    );
    await tester.pumpAndSettle();

    expect(api.detailRequestCount, afterOpen + 1);

    // A trip write is not this panel's business, and re-reading a charge for
    // one would undo the saving the filter exists for.
    api.sessions.add(
      const SessionChange(revision: 2, trips: true, charges: false),
    );
    await tester.pumpAndSettle();

    expect(api.detailRequestCount, afterOpen + 1);
  });

  testWidgets('a closed session is not re-read every five seconds', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _FakeTelemetryApi();
    addTearDown(() => api.sessions.close());
    final controller = VehicleStateController()
      ..applySnapshotForTest(_snapshot(isCharging: false));

    await tester.pumpWidget(
      _app(
        ChargingV2Screen(
          title: 'Charging',
          vehicleStateController: controller,
          telemetryApi: api,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final afterOpen = api.detailRequestCount;

    // A closed session cannot grow another bar, so rebuilding its series from
    // its frames every five seconds asks the database for an answer that
    // cannot have changed.
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();

    expect(api.detailRequestCount, afterOpen);
  });

  testWidgets('a running charge redraws the graph on the tick', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _FakeTelemetryApi()..sessionStatus = 'CHARGING';
    addTearDown(() => api.sessions.close());
    final controller = VehicleStateController()
      ..applySnapshotForTest(_snapshot(isCharging: true));

    await tester.pumpWidget(
      _app(
        ChargingV2Screen(
          title: 'Charging',
          vehicleStateController: controller,
          telemetryApi: api,
        ),
      ),
    );
    // A running charge animates its bars, so this tree never settles. The
    // pumps are counted rather than settled for that reason.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final afterOpen = api.detailRequestCount;

    // The session write event does not fire per frame, so a charge in progress
    // grows its bars on the tick. Turning the tick off for a closed session
    // must not turn it off for this one.
    await tester.pump(const Duration(seconds: 12));
    await tester.pump(const Duration(milliseconds: 50));

    expect(api.detailRequestCount, greaterThan(afterOpen));
  });

  testWidgets('the graph closes its reading when touched beside', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _FakeTelemetryApi();
    final controller = VehicleStateController()
      ..applySnapshotForTest(_snapshot(isCharging: false));

    await tester.pumpWidget(
      _app(
        ChargingV2Screen(
          title: 'Charging',
          vehicleStateController: controller,
          telemetryApi: api,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // This graph rests on its newest column rather than on nothing, so it
    // opens with a reading nobody asked for — which is exactly the case where
    // clearing the index is not enough to close it.
    expect(find.byType(ChartTooltip), findsOneWidget);

    // Anything that is not the chart — here the energy panel beside it.
    await tester.tap(find.byType(ChargingEnergyPanel));
    await tester.pumpAndSettle();

    expect(find.byType(ChartTooltip), findsNothing);

    // Opening one again brings the reading back, so the close is a state the
    // reader can leave.
    await tester.tap(find.byType(EnergyBarChart));
    await tester.pumpAndSettle();
    expect(find.byType(ChartTooltip), findsOneWidget);
  });

  testWidgets('graph loads the latest charge session with fixed time buckets', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _FakeTelemetryApi();
    final controller = VehicleStateController()
      ..applySnapshotForTest(_snapshot(isCharging: false));

    await tester.pumpWidget(
      _app(
        ChargingV2Screen(
          title: 'Charging',
          vehicleStateController: controller,
          telemetryApi: api,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final chart = tester.widget<EnergyBarChart>(find.byType(EnergyBarChart));
    expect(chart.bars, hasLength(36));
    expect(chart.profile, AppSizes.chartDenseBarProfile);
    expect(chart.xTicks, hasLength(3));
    expect(chart.xTicks.map((tick) => tick.position), [0, 0.4, 0.8]);
    expect(chart.ticks.map((tick) => tick.label), ['80', '30', '10', '0']);
    // The edge buckets carry their measured power, not a fabricated zero: the
    // curve reaches the baseline through the anchor, so it agrees with what the
    // tooltip reports for the same bucket. This session is closed, so both ends
    // are anchored.
    expect(chart.overlayAnchor, ChartOverlayAnchor.both);
    expect(chart.overlay!.first, greaterThan(0));
    expect(chart.overlay!.last, greaterThan(0));
    expect(find.text('+135'), findsOneWidget);
    expect(find.text('+18.8'), findsOneWidget);
    expect(find.text(r'$ 16.92'), findsOneWidget);
    // ignore: avoid_print
    expect(find.text('1 hr 48 min'), findsNWidgets(2));
    expect(api.requestedSessionId, 'charge-latest');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the cost stat prices this charge on the keypad', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _FakeTelemetryApi();
    final controller = VehicleStateController()
      ..applySnapshotForTest(_snapshot(isCharging: false));

    await tester.pumpWidget(
      _app(
        ChargingV2Screen(
          title: 'Charging',
          vehicleStateController: controller,
          telemetryApi: api,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The stat is the trigger, and it says so: a pencil beside the caption.
    final stat = find.ancestor(
      of: find.text('Cost · EST'),
      matching: find.byType(StatColumn),
    );
    expect(tester.widget<StatColumn>(stat).onPressed, isNotNull);
    expect(
      find.descendant(of: stat, matching: find.byIcon(Icons.edit)),
      findsOneWidget,
    );

    await tester.tap(find.text(r'$ 16.92'));
    await tester.pumpAndSettle();
    expect(find.text('Charge price'), findsOneWidget);

    // The unpriced charge opens on the default rate, so the reader corrects a
    // figure rather than typing one from nothing.
    await tester.tap(find.byKey(const Key('money-keypad-clear')));
    await tester.pump();
    for (final digit in ['1', '2', '0']) {
      await tester.tap(find.widgetWithText(InkWell, digit));
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('money-keypad-save')));
    await tester.pumpAndSettle();

    expect(api.costWrites, hasLength(1));
    expect(api.costWrites.single[0], 'charge-latest');
    expect(api.costWrites.single[1], 1.20);
    // The total the reader did not type is sent back as it stands, because the
    // collector writes both columns in one statement.
    expect(api.costWrites.single[2], isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('idle time after the limit reads apart from the charge', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Charged for 80 of the 108 plugged-in minutes, then sat at its limit.
    final api = _FakeTelemetryApi(targetReachedAfterMinutes: 80);
    final controller = VehicleStateController()
      ..applySnapshotForTest(_snapshot(isCharging: false));

    await tester.pumpWidget(
      _app(
        ChargingV2Screen(
          title: 'Charging',
          vehicleStateController: controller,
          telemetryApi: api,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final chart = tester.widget<EnergyBarChart>(find.byType(EnergyBarChart));
    final held = chart.bars.where((bar) => bar.state == EnergyBarState.held);
    // The tail is drawn, in its own colour, carrying the SOC it settled at.
    expect(held, isNotEmpty);
    expect(held.every((bar) => bar.value.isFinite), isTrue);
    // The bars before the limit stay the charge's own colour.
    expect(chart.bars.first.state, EnergyBarState.actual);

    // Duration reports the charge, not the plug-in, and the moment the limit
    // was met is stated outright.
    expect(find.text('Limit reached'), findsOneWidget);
    // 1 hr 48 min plugged in; the charge itself is the sum of the minutes
    // that delivered energy, which is the eighty before the limit was met.
    expect(find.text('1 hr 48 min'), findsOneWidget);
    expect(find.text('1 hr 20 min'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('graph accepts a charge session selected by a future list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _FakeTelemetryApi();
    final controller = VehicleStateController()
      ..applySnapshotForTest(_snapshot(isCharging: false));
    final selected = _chargeSessionRecord(id: 'charge-selected');

    await tester.pumpWidget(
      _app(
        ChargingV2Screen(
          title: 'Charging',
          session: selected,
          vehicleStateController: controller,
          telemetryApi: api,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(api.sessionsRequestCount, 0);
    expect(api.requestedSessionId, 'charge-selected');
  });

  testWidgets('right panel shows only battery and climate energy categories', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = VehicleStateController()
      ..applySnapshotForTest(_snapshot(isCharging: false));

    await tester.pumpWidget(
      _app(
        ChargingV2Screen(
          title: 'Charging',
          vehicleStateController: controller,
          telemetryApi: _FakeTelemetryApi(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final panel = find.byType(ChargeSessionSummaryCard);
    expect(panel, findsOneWidget);
    expect(find.text('Last charge session'), findsOneWidget);
    expect(
      find.descendant(of: panel, matching: find.text('1 hr 48 min')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panel, matching: find.text('18.8 kWh')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panel, matching: find.text('-- kWh')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panel, matching: find.byIcon(Icons.battery_full)),
      findsNWidgets(2),
    );
    expect(
      find.descendant(of: panel, matching: find.byIcon(Icons.thermostat)),
      findsOneWidget,
    );
    final donut = tester.widget<SegmentedDonut>(
      find.descendant(of: panel, matching: find.byType(SegmentedDonut)),
    );
    expect(donut.segments, hasLength(1));
    expect(donut.total, 18.8);
  });

  testWidgets('right panel draws the measured climate energy as a slice', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = VehicleStateController()
      ..applySnapshotForTest(_snapshot(isCharging: false));

    await tester.pumpWidget(
      _app(
        ChargingV2Screen(
          title: 'Charging',
          vehicleStateController: controller,
          telemetryApi: _FakeTelemetryApi(
            climateEnergyKwh: 0.6,
            // The session runs 1 hr 48 min, and the integral covers all of it.
            climateIntegratedSeconds: 108 * 60,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final panel = find.byType(ChargeSessionSummaryCard);
    expect(find.text('19.4'), findsOneWidget);
    expect(find.text('0.6 kWh'), findsOneWidget);
    final donut = tester.widget<SegmentedDonut>(
      find.descendant(of: panel, matching: find.byType(SegmentedDonut)),
    );
    expect(donut.segments, hasLength(2));
    expect(donut.total, closeTo(19.4, 0.001));
  });

  testWidgets('right panel refuses a climate integral that saw almost none', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = VehicleStateController()
      ..applySnapshotForTest(_snapshot(isCharging: false));

    await tester.pumpWidget(
      _app(
        ChargingV2Screen(
          title: 'Charging',
          vehicleStateController: controller,
          telemetryApi: _FakeTelemetryApi(
            climateEnergyKwh: 0.6,
            // A tenth of the charge watched. Below the sanity floor, this is
            // not the session's load even as a minimum.
            climateIntegratedSeconds: 11 * 60,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final panel = find.byType(ChargeSessionSummaryCard);
    expect(find.text('-- kWh'), findsOneWidget);
    expect(find.text('0.6 kWh'), findsNothing);
    final donut = tester.widget<SegmentedDonut>(
      find.descendant(of: panel, matching: find.byType(SegmentedDonut)),
    );
    expect(donut.segments, hasLength(1));
    expect(donut.total, 18.8);
  });

  testWidgets('right panel marks a partly covered climate figure as a floor', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = VehicleStateController()
      ..applySnapshotForTest(_snapshot(isCharging: false));

    await tester.pumpWidget(
      _app(
        ChargingV2Screen(
          title: 'Charging',
          vehicleStateController: controller,
          telemetryApi: _FakeTelemetryApi(
            climateEnergyKwh: 0.6,
            // The 2026-08-11 case: 96.6 % of a long charge watched. The quiet
            // seconds can only have added climate energy, so 0.6 kWh is a
            // minimum — which is worth more to the reader than `--`.
            climateIntegratedSeconds: 108 * 60 * 0.966,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final panel = find.byType(ChargeSessionSummaryCard);
    expect(find.text('\u2265 0.6 kWh'), findsOneWidget);
    final donut = tester.widget<SegmentedDonut>(
      find.descendant(of: panel, matching: find.byType(SegmentedDonut)),
    );
    expect(donut.segments, hasLength(2));
  });

  testWidgets('warns when the climate draw passes half the charging rate', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = VehicleStateController()
      ..applySnapshotForTest(_snapshot(isCharging: true));

    await tester.pumpWidget(
      _app(
        ChargingV2Screen(
          title: 'Charging',
          vehicleStateController: controller,
          // 6.5 kW of the 11.0 kW the car reports it is taking in.
          telemetryApi: _FakeTelemetryApi(liveClimateKw: 6.5),
        ),
      ),
    );
    // A running charge animates its bars and the banner breathes, so this
    // tree never settles. The pumps are counted for that reason.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(BreathingWarningBanner), findsOneWidget);
    expect(find.text('Climate is using your charge'), findsOneWidget);
    expect(find.textContaining('draws 6.5 kW of the 11.0 kW'), findsOneWidget);

    // Above the level/graph card, not inside it. What the banner says is about
    // the charge as a whole; inside the card it would read as a note on
    // whichever tab is open.
    final card = find.ancestor(
      of: find.byType(ChargeGraphPanel),
      matching: find.byType(AppCard),
    );
    // Without this the assertion below would pass on an empty finder.
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.byType(BreathingWarningBanner)),
      findsNothing,
    );
  });

  testWidgets('stays quiet when the climate draw is a small share', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = VehicleStateController()
      ..applySnapshotForTest(_snapshot(isCharging: true));

    await tester.pumpWidget(
      _app(
        ChargingV2Screen(
          title: 'Charging',
          vehicleStateController: controller,
          telemetryApi: _FakeTelemetryApi(liveClimateKw: 1.2),
        ),
      ),
    );
    // A running charge animates its bars and the banner breathes, so this
    // tree never settles. The pumps are counted for that reason.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(BreathingWarningBanner), findsNothing);
  });

  testWidgets('says nothing about climate while the car is not charging', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = VehicleStateController()
      ..applySnapshotForTest(_snapshot(isCharging: false));

    await tester.pumpWidget(
      _app(
        ChargingV2Screen(
          title: 'Charging',
          vehicleStateController: controller,
          // A draw that would trip the banner if there were a charge to
          // measure it against. There is no charging rate, so there is no
          // share, and the banner must not guess one.
          telemetryApi: _FakeTelemetryApi(liveClimateKw: 6.5),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(BreathingWarningBanner), findsNothing);
  });

  testWidgets('the banner appears when the climate read lands after build', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = VehicleStateController()
      ..applySnapshotForTest(_snapshot(isCharging: true));

    await tester.pumpWidget(
      _app(
        ChargingV2Screen(
          title: 'Charging',
          vehicleStateController: controller,
          telemetryApi: _FakeTelemetryApi(
            liveClimateKw: 6.5,
            climateReadDelay: const Duration(milliseconds: 200),
          ),
        ),
      ),
    );
    await tester.pump();

    // The read has not landed. Nothing is claimed yet.
    expect(find.byType(BreathingWarningBanner), findsNothing);

    await tester.pump(const Duration(milliseconds: 250));

    // It landed, and the screen repainted for it. Without the query in the
    // screen's listenable set this stays absent until some other read happens
    // to notify, which is the defect this pins.
    expect(find.byType(BreathingWarningBanner), findsOneWidget);
  });
}

Widget _app(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}

class _FakeTelemetryApi extends TelemetryApi {
  _FakeTelemetryApi({
    this.failHistory = false,
    this.failSettings = false,
    this.rangeAvailable = true,
    this.rangeDegraded = false,
    this.rangeReadFailed = false,
    this.targetReachedAfterMinutes,
    this.climateEnergyKwh,
    this.climateIntegratedSeconds,
    this.liveClimateKw,
    this.climateReadDelay,
  }) : super(source: MockTelemetrySource());

  /// Holds the climate read open, so the first build happens without it. It is
  /// what makes the banner depend on the query repainting the screen.
  final Duration? climateReadDelay;

  /// The climate draw the open charge reports, kW. Null leaves the mock's own
  /// series in place.
  final double? liveClimateKw;

  /// The climate integral the charge detail reports, and how much of the
  /// session it covered. Null for a car whose bus published no climate power.
  final double? climateEnergyKwh;
  final double? climateIntegratedSeconds;

  /// Minutes into the session at which the charge limit was met, if it was.
  final int? targetReachedAfterMinutes;

  final bool failHistory;
  final bool failSettings;
  final bool rangeAvailable;
  final bool rangeDegraded;
  bool rangeReadFailed;
  String? requestedSessionId;
  int sessionsRequestCount = 0;
  int detailRequestCount = 0;
  String sessionStatus = 'COMPLETE';

  /// Every price written, as `[sessionId, costPerKwh, paidAmount, currency]`.
  final costWrites = <List<Object?>>[];

  /// The car's session-change push, driven by the test.
  final sessions = StreamController<SessionChange>.broadcast();

  @override
  Stream<SessionChange> sessionChanges() => sessions.stream;

  @override
  Future<RangeEstimate> getRangeEstimate() async {
    if (rangeReadFailed) throw Exception('range read failed');
    const capacityKwh = 39.1;
    const efficiency = 7.18;
    final full = capacityKwh * efficiency;
    final ownAvailable = rangeAvailable || rangeDegraded;
    final own = ownAvailable ? 63.4 / 100 * full : null;
    return RangeEstimate.fromMap({
      'timestampMillis': 1,
      'carRangeKm': rangeAvailable ? 266.0 : null,
      'carRangeQuality': rangeAvailable ? 'AVAILABLE' : 'UNAVAILABLE',
      'carRangeReason': rangeAvailable
          ? null
          : rangeDegraded
          ? 'EFFICIENCY_REFRESH_FAILED'
          : 'NO_VALID_EFFICIENCY',
      'carRangePropertyId': 289407752,
      'carRangeSignalSource': rangeAvailable ? 'VHAL_CALLBACK' : null,
      'carRangeReceivedAtUtcMillis': rangeAvailable ? 1 : null,
      'carRangeSourceTimestampNanos': rangeAvailable ? 1 : null,
      'socPercent': rangeAvailable ? 63.4 : null,
      'capacityKwh': capacityKwh,
      'capacitySource': 'SETTINGS',
      'efficiencyKmPerKwh': efficiency,
      'efficiencySource': 'CLOSED_TRIPS_7D',
      'efficiencyWindowDays': 7,
      'efficiencyTripCount': 2,
      'efficiencyDistanceKm': 24.7,
      'efficiencyNetEnergyKwh': 3.44,
      'efficiencyUpdatedAtUtcMillis': 1,
      'fullRangeKm': own == null ? null : full,
      'ownRangeKm': own,
      'ownRangeQuality': rangeDegraded
          ? 'DEGRADED'
          : rangeAvailable
          ? 'AVAILABLE'
          : 'UNAVAILABLE',
      'ownRangeReason': rangeDegraded ? 'EFFICIENCY_REFRESH_FAILED' : null,
    });
  }

  @override
  Future<ChargeSessionCostUpdateResult> updateChargeSessionCost({
    required String sessionId,
    double? costPerKwh,
    double? paidAmount,
    String currency = 'BRL',
  }) async {
    costWrites.add([sessionId, costPerKwh, paidAmount, currency]);
    return const ChargeSessionCostUpdateResult(
      ok: true,
      updatedRows: 1,
      session: null,
    );
  }

  @override
  Future<SessionListPage> listSessions({
    SessionFilter? filter,
    PageRequest? page,
  }) async {
    if (filter?.kind == SessionKind.trip) {
      // The recent-efficiency read. Two drives at 7.18 km/kWh.
      if (failHistory) throw Exception('history read failed');
      return SessionListPage(
        sessions: [
          for (var i = 0; i < 2; i++)
            tripRecord(
              id: 'trip-$i',
              startedAtUtcMillis: 1,
              endedAtUtcMillis: 2,
              endedAtElapsedNanos: 2,
              sessionRollup: rollup(
                distanceKm: 71.8,
                tractionWh: 10000,
                regenWh: 0,
                auxiliaryWh: 0,
              ),
            ),
        ],
        totalCount: 2,
        page: const PageRequest(limit: 200),
        hasMore: false,
      );
    }
    sessionsRequestCount++;
    return SessionListPage(
      sessions: [_chargeSessionRecord(status: sessionStatus)],
      totalCount: 1,
      page: page ?? const PageRequest(),
      hasMore: false,
    );
  }

  @override
  Future<SessionDetail?> getSession(String id) async {
    requestedSessionId = id;
    detailRequestCount++;
    return SessionDetail(
      session: _chargeSessionRecord(id: id, status: sessionStatus),
      events: [
        if (targetReachedAfterMinutes case final reached?)
          TelemetryEventRecord(
            id: 1,
            sessionId: id,
            type: kChargeLimitReachedEvent,
            occurredAtUtcMillis: _sessionStartUtcMillis + reached * 60 * 1000,
            occurredAtElapsedNanos: 1 + reached * 60 * 1000000000,
          ),
      ],
    );
  }

  TelemetrySeries? lastSeries;

  @override
  Future<TelemetrySeries> getSeries(
    String id, {
    Set<String>? keys,
    int? widthMillis,
  }) async => lastSeries = _chargeSeriesFor(
    id,
    targetReachedAfterMinutes: targetReachedAfterMinutes,
    climateEnergyKwh: climateEnergyKwh,
    climateIntegratedSeconds: climateIntegratedSeconds,
  );

  @override
  Future<LiveEnergyBucketsResult> getLiveChargeEnergyBuckets() async {
    final kw = liveClimateKw;
    if (kw == null) return super.getLiveChargeEnergyBuckets();
    if (climateReadDelay != null) await Future<void>.delayed(climateReadDelay!);
    return LiveEnergyBucketsResult.fromMap({
      'sessionId': 'charge-1',
      'bucketMillis': 60000,
      'buckets': [
        {
          'startUtcMillis': _sessionStartUtcMillis,
          'tractionWh': 0.0,
          'regeneratedWh': 0.0,
          'auxiliaryWh': 0.0,
          'integratedSeconds': 0.0,
          'speedDistanceKm': 0.0,
          'odometerDistanceKm': 0.0,
          'speedIntegratedSeconds': 0.0,
          'climateWh': kw * 60 / 3.6,
          'climateIntegratedSeconds': 60.0,
        },
      ],
    });
  }

  bool externalChargeControlEnabled = false;
  int chargeTargetSoc = 80;
  ChargeControlState chargeControlState = const ChargeControlState();
  final targetSocChangesController = StreamController<int>.broadcast();
  final chargeControlStateChangesController =
      StreamController<ChargeControlState>.broadcast();
  int stopChargingCalls = 0;

  @override
  Stream<int> chargeTargetSocChanges() => targetSocChangesController.stream;

  @override
  Stream<ChargeControlState> chargeControlStateChanges() =>
      chargeControlStateChangesController.stream;

  @override
  Future<ChargeControlState> getChargeControlState() async =>
      chargeControlState;

  @override
  Future<ChargeControlState> setChargingAmperage(int amps) async {
    chargeControlState = ChargeControlState(
      targetSoc: chargeControlState.targetSoc,
      amps: amps,
      minAmps: chargeControlState.minAmps,
      maxAmps: chargeControlState.maxAmps,
      forceCharging: chargeControlState.forceCharging,
    );
    chargeControlStateChangesController.add(chargeControlState);
    return chargeControlState;
  }

  @override
  Future<ChargeControlState> setForceCharging(bool force) async {
    chargeControlState = ChargeControlState(
      targetSoc: chargeControlState.targetSoc,
      amps: chargeControlState.amps,
      minAmps: chargeControlState.minAmps,
      maxAmps: chargeControlState.maxAmps,
      forceCharging: force,
    );
    chargeControlStateChangesController.add(chargeControlState);
    return chargeControlState;
  }

  @override
  Future<bool> stopCharging() async {
    stopChargingCalls++;
    return true;
  }

  @override
  Future<TelemetrySettingsResult> setChargeTargetSoc(int percent) async {
    chargeTargetSoc = percent;
    targetSocChangesController.add(percent);
    return getTelemetrySettings();
  }

  @override
  Future<TelemetrySettingsResult> getTelemetrySettings() async {
    if (failSettings) throw Exception('settings read failed');
    return TelemetrySettingsResult.fromMap({
      'autoStartOnBoot': true,
      'gpsEnabled': true,
      'debugEventFileEnabled': false,
      'temperatureModeHelperEnabled': false,
      'externalChargeControlEnabled': externalChargeControlEnabled,
      'chargeTargetSoc': chargeTargetSoc,
      'defaultChargeCostPerKwh': 0.9,
      'chargeCostCurrency': 'BRL',
    });
  }
}

const _sessionStartUtcMillis = 1760000000000;

/// One charge, as the store answers it: 108 minutes at about 11 kW.
SessionRecord _chargeSessionRecord({
  String id = 'charge-latest',
  String status = 'COMPLETE',
}) {
  const start = _sessionStartUtcMillis;
  return chargeRecord(
    id: id,
    status: status,
    startedAtUtcMillis: start,
    startedAtElapsedNanos: 1,
    chargeStartedAtUtcMillis: start,
    chargeEndedAtUtcMillis: start + 108 * 60 * 1000,
    plugDisconnectedAtUtcMillis: start + 108 * 60 * 1000,
    plugDisconnectedAtElapsedNanos: 1 + 108 * 60 * 1000000000,
    startSoc: 52.0,
    endSoc: 80.0,
    plugType: 605225491,
    startPowerKw: 11.0,
    deliveredWh: 18800.0,
    costCurrency: 'BRL',
    endReason: 'COMPLETED',
  );
}

/// The minutes and samples behind that charge.
///
/// The power drops to zero at [targetReachedAfterMinutes], which is what makes
/// the idle tail on the plot a real absence of charging rather than a gap.
TelemetrySeries _chargeSeriesFor(
  String id, {
  int? targetReachedAfterMinutes,
  double? climateEnergyKwh,
  double? climateIntegratedSeconds,
}) {
  const start = _sessionStartUtcMillis;
  final stopAt = targetReachedAfterMinutes ?? 108;
  final climateMinuteWh = climateEnergyKwh == null
      ? 0.0
      : climateEnergyKwh * 1000 / 108;
  final climateMinuteSeconds = climateIntegratedSeconds == null
      ? 0.0
      : climateIntegratedSeconds / 108;
  return TelemetrySeries(
    sessionId: id,
    intervals: [
      for (var minute = 0; minute < 108; minute++)
        intervalRecord(
          sessionId: id,
          startUtcMillis: start + minute * 60000,
          deliveredWh: minute >= stopAt ? 0.0 : 11.0 * 1000 / 60,
          deliveredCoveredSeconds: minute >= stopAt ? 0.0 : 60,
          climateWh: climateMinuteWh,
          climateCoveredSeconds: climateMinuteSeconds,
          startSoc: 52 + minute / 108 * 28,
          endSoc: 52 + (minute + 1) / 108 * 28,
        ),
    ],
  );
}

TelemetrySnapshot _snapshot({required bool isCharging}) {
  Map<String, Object?> reading(double? value) => {
    'ok': value != null,
    'value': value,
    'source': 'test',
    'details': '',
  };
  return TelemetrySnapshot.fromMap({
    'timestampMillis': 1,
    'batteryPercent': reading(63.4),
    'speedKmh': reading(null),
    'odometerKm': reading(null),
    'charging': {
      'ok': true,
      'isCharging': isCharging,
      'acPowerKw': isCharging ? 7.4 : null,
      'dcPowerKw': isCharging ? 11.0 : null,
      'source': 'test',
      'details': '',
    },
    'gear': reading(null),
  });
}
