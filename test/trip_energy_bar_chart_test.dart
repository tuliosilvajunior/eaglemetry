import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/screens_v2/charts/energy_state_band.dart';
import 'package:capy_energy/screens_v2/charts/trip_energy_bar_chart.dart';
import 'package:capy_energy/screens_v2/energy_bucket_tooltip.dart';
import 'package:capy_ui/capy_ui.dart';
import 'package:telemetry_core/telemetry_core.dart';

final _base = DateTime(2026, 8, 3, 6);

EnergyBucket _minute(
  int minute, {
  double traction = 40,
  double auxiliary = 5,
  double deliveredWh = 0,
  double? startSoc,
  double? endSoc,
}) => EnergyBucket(
  start: _base.add(Duration(minutes: minute)),
  width: EnergyBucket.oneMinute,
  tractionWh: traction,
  regeneratedWh: 0,
  auxiliaryWh: auxiliary,
  deliveredWh: deliveredWh,
  integratedSeconds: 60,
  startSoc: startSoc,
  endSoc: endSoc,
);

Widget _host(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SizedBox(width: 900, height: 260, child: child)),
  );
}

/// A tooltip floats free of any chart-sized box; it wants only the loose
/// constraints [ChartTooltip]'s own tests already host it under.
Widget _tooltipHost(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: Center(child: child)),
  );
}

/// A minute stamped with the boot-default clock of the incident (May 2025):
/// the wall time lies, the slot order tells the truth.
EnergyBucket _pendingMinute(int minute) => EnergyBucket(
  start: DateTime(2025, 5, 24, 1, 8).add(Duration(minutes: minute)),
  width: EnergyBucket.oneMinute,
  tractionWh: 40,
  regeneratedWh: 0,
  auxiliaryWh: 5,
  integratedSeconds: 60,
);

void main() {
  group('CONTINUOUS labels on the bar chart (issue 199/208)', () {
    testWidgets(
      'with no labels, nothing changes: no band, one series parked flag',
      (tester) async {
        final buckets = [_minute(0), _minute(1)];
        await tester.pumpWidget(
          _host(TripEnergyBarChart(buckets: buckets, parked: false)),
        );
        await tester.pump();

        expect(find.byType(EnergyStateBand), findsNothing);
        final bars = tester
            .widget<EnergyBarChart>(find.byType(EnergyBarChart))
            .bars;
        expect(bars[0].value, buckets[0].tractionWh / 1000);
        expect(bars[1].value, buckets[1].tractionWh / 1000);
      },
    );

    testWidgets(
      'renders one label band block per bucket, aligned to the buckets',
      (tester) async {
        final buckets = [_minute(0), _minute(1), _minute(2)];
        await tester.pumpWidget(
          _host(
            TripEnergyBarChart(
              buckets: buckets,
              labels: const [
                ContinuousLabel.trip,
                ContinuousLabel.parked,
                ContinuousLabel.charge,
              ],
            ),
          ),
        );
        await tester.pump();

        final band = tester.widget<EnergyStateBand>(
          find.byType(EnergyStateBand),
        );
        expect(band.labels, [
          ContinuousLabel.trip,
          ContinuousLabel.parked,
          ContinuousLabel.charge,
        ]);
      },
    );

    testWidgets(
      'the parked flag is per bucket: a charge minute inside a mixed window keeps its traction',
      (tester) async {
        final buckets = [
          _minute(0, traction: 40),
          _minute(1, traction: 0, auxiliary: 30), // standing, drawing climate
          _minute(2, traction: 40),
        ];
        await tester.pumpWidget(
          _host(
            TripEnergyBarChart(
              buckets: buckets,
              labels: const [
                ContinuousLabel.trip,
                ContinuousLabel.parked,
                ContinuousLabel.trip,
              ],
            ),
          ),
        );
        await tester.pump();

        final bars = tester
            .widget<EnergyBarChart>(find.byType(EnergyBarChart))
            .bars;
        // Trip minutes keep their traction value on the bar.
        expect(bars[0].value, buckets[0].tractionWh / 1000);
        expect(bars[2].value, buckets[2].tractionWh / 1000);
        // The parked-labelled minute is drawn with the parked composition
        // (no traction segment) even though the other two, in the same
        // window, are not.
        expect(bars[1].value, 0);
      },
    );

    testWidgets(
      'a minute inside a charge reads as charge, not as standing time, following precedence',
      (tester) async {
        // The controller already resolves precedence before this widget ever
        // sees a label (issue 203); this exercises the widget's own half of
        // the contract: whatever label it is handed, it draws that one. A
        // non-zero traction term proves it, since the parked composition
        // would force this bar's value to zero regardless of the bucket.
        final buckets = [_minute(0, traction: 25, auxiliary: 12)];
        await tester.pumpWidget(
          _host(
            TripEnergyBarChart(
              buckets: buckets,
              labels: const [ContinuousLabel.charge],
            ),
          ),
        );
        await tester.pump();

        final bars = tester
            .widget<EnergyBarChart>(find.byType(EnergyBarChart))
            .bars;
        // Charge is not drawn as the parked composition: a charge minute's
        // bar keeps the ordinary (non-parked) stack shape.
        expect(bars[0].value, buckets[0].tractionWh / 1000);
      },
    );

    testWidgets('the tooltip names the state and shows start/end SOC', (
      tester,
    ) async {
      final buckets = [_minute(0, startSoc: 61, endSoc: 60)];
      await tester.pumpWidget(
        _host(
          TripEnergyBarChart(
            buckets: buckets,
            labels: const [ContinuousLabel.trip],
          ),
        ),
      );
      await tester.pump();

      final chart = tester.widget<EnergyBarChart>(find.byType(EnergyBarChart));
      final context = tester.element(find.byType(EnergyBarChart));
      final tooltip = chart.tooltipBuilder!(context, 0) as EnergyBucketTooltip;

      expect(tooltip.stateLabel, ContinuousLabel.trip);

      await tester.pumpWidget(_tooltipHost(tooltip));
      await tester.pump();

      expect(find.text('Drive'), findsOneWidget);
      expect(find.text('61% → 60% SOC'), findsOneWidget);
    });

    testWidgets(
      'a minute belonging to no session reads as Powered on, not a blank',
      (tester) async {
        final buckets = [_minute(0)];
        await tester.pumpWidget(
          _host(
            TripEnergyBarChart(
              buckets: buckets,
              labels: const [ContinuousLabel.poweredOn],
            ),
          ),
        );
        await tester.pump();

        final chart = tester.widget<EnergyBarChart>(
          find.byType(EnergyBarChart),
        );
        final context = tester.element(find.byType(EnergyBarChart));
        final tooltip =
            chart.tooltipBuilder!(context, 0) as EnergyBucketTooltip;

        await tester.pumpWidget(_tooltipHost(tooltip));
        await tester.pump();

        expect(find.text('Powered on'), findsOneWidget);
      },
    );

    testWidgets(
      'the tooltip shows the delivered energy on a charging minute (issue 199/211)',
      (tester) async {
        // A charging minute has no traction or auxiliary draw of its own —
        // the delivered credit is the only number worth showing, the same way
        // a regenerating minute's tooltip shows its own credit row.
        final buckets = [
          _minute(0, traction: 0, auxiliary: 0, deliveredWh: 120),
        ];
        await tester.pumpWidget(
          _host(
            TripEnergyBarChart(
              buckets: buckets,
              labels: const [ContinuousLabel.charge],
            ),
          ),
        );
        await tester.pump();

        final chart = tester.widget<EnergyBarChart>(
          find.byType(EnergyBarChart),
        );
        final context = tester.element(find.byType(EnergyBarChart));
        final tooltip =
            chart.tooltipBuilder!(context, 0) as EnergyBucketTooltip;

        await tester.pumpWidget(_tooltipHost(tooltip));
        await tester.pump();

        expect(find.text('Charging'), findsOneWidget);
        expect(find.text('+0.12 kWh'), findsOneWidget);
      },
    );

    testWidgets(
      'a window that has only charged so far scales the axis to the charge, '
      'not to the default empty-window ceiling (issue 199/211)',
      (tester) async {
        // No traction or auxiliary draw anywhere yet — the session opened
        // straight into a charge. `peak` reads zero, and the axis must not
        // fall back to its unrelated "nothing recorded" default: that default
        // would dwarf a real, small delivered reading into a sliver.
        final buckets = [
          _minute(0, traction: 0, auxiliary: 0, deliveredWh: 50),
        ];
        await tester.pumpWidget(
          _host(
            TripEnergyBarChart(
              buckets: buckets,
              labels: const [ContinuousLabel.charge],
            ),
          ),
        );
        await tester.pump();

        final chart = tester.widget<EnergyBarChart>(
          find.byType(EnergyBarChart),
        );
        final topTick = chart.ticks.first.value;
        final bottomTick = chart.ticks.last.value;

        expect(topTick, -bottomTick);
        expect(topTick, lessThan(1.0));
      },
    );
  });

  group('estimated stretches on the bar chart (issue 199/211)', () {
    testWidgets('an estimated bucket is marked, a measured one is not', (
      tester,
    ) async {
      final buckets = [_minute(0), _minute(1)];
      await tester.pumpWidget(
        _host(
          TripEnergyBarChart(
            buckets: buckets,
            labels: const [ContinuousLabel.parked, ContinuousLabel.parked],
            estimated: const [false, true],
          ),
        ),
      );
      await tester.pump();

      final bars = tester
          .widget<EnergyBarChart>(find.byType(EnergyBarChart))
          .bars;
      expect(bars[0].state, EnergyBarState.actual);
      expect(bars[1].state, EnergyBarState.estimated);
    });

    testWidgets('the tooltip names the estimate on an estimated minute', (
      tester,
    ) async {
      final buckets = [_minute(0)];
      await tester.pumpWidget(
        _host(
          TripEnergyBarChart(
            buckets: buckets,
            labels: const [ContinuousLabel.parked],
            estimated: const [true],
          ),
        ),
      );
      await tester.pump();

      final chart = tester.widget<EnergyBarChart>(find.byType(EnergyBarChart));
      final context = tester.element(find.byType(EnergyBarChart));
      final tooltip = chart.tooltipBuilder!(context, 0) as EnergyBucketTooltip;

      expect(tooltip.estimated, isTrue);

      await tester.pumpWidget(_tooltipHost(tooltip));
      await tester.pump();

      expect(find.text('Parked · EST'), findsOneWidget);
    });

    testWidgets(
      'the label band still renders when part of the stretch is estimated',
      (tester) async {
        final buckets = [_minute(0), _minute(1), _minute(2)];
        await tester.pumpWidget(
          _host(
            TripEnergyBarChart(
              buckets: buckets,
              labels: const [
                ContinuousLabel.parked,
                ContinuousLabel.parked,
                ContinuousLabel.parked,
              ],
              estimated: const [false, true, true],
            ),
          ),
        );
        await tester.pump();

        final band = tester.widget<EnergyStateBand>(
          find.byType(EnergyStateBand),
        );
        expect(band.estimated, [false, true, true]);
      },
    );
  });

  group('time authority pending mark (T6)', () {
    testWidgets(
      'a pending series draws every bar and names the unsynced time',
      (tester) async {
        final buckets = [_minute(0), _minute(1)];
        await tester.pumpWidget(
          _host(TripEnergyBarChart(buckets: buckets, timeUnsynced: true)),
        );
        await tester.pump();

        // The consumer keeps working: both bars draw with real values.
        final bars = tester
            .widget<EnergyBarChart>(find.byType(EnergyBarChart))
            .bars;
        expect(bars, hasLength(2));
        expect(bars[0].value, buckets[0].tractionWh / 1000);
        expect(bars[1].value, buckets[1].tractionWh / 1000);
        // And the mark says the axis time is not synced yet.
        expect(find.textContaining('not synced'), findsOneWidget);
      },
    );

    testWidgets('a synced series draws the same bars with no mark', (
      tester,
    ) async {
      final buckets = [_minute(0), _minute(1)];
      await tester.pumpWidget(
        _host(TripEnergyBarChart(buckets: buckets, timeUnsynced: false)),
      );
      await tester.pump();

      final bars = tester
          .widget<EnergyBarChart>(find.byType(EnergyBarChart))
          .bars;
      expect(bars, hasLength(2));
      expect(find.textContaining('not synced'), findsNothing);
    });

    testWidgets(
      'a pending series with state band draws bars and mark without layout error',
      (tester) async {
        final buckets = [_minute(0), _minute(1)];
        await tester.pumpWidget(
          _host(
            TripEnergyBarChart(
              buckets: buckets,
              timeUnsynced: true,
              labels: const [ContinuousLabel.trip, ContinuousLabel.parked],
              estimated: const [false, true],
            ),
          ),
        );
        await tester.pump();

        final bars = tester
            .widget<EnergyBarChart>(find.byType(EnergyBarChart))
            .bars;
        expect(bars, hasLength(2));
        expect(find.textContaining('not synced'), findsOneWidget);
        expect(find.byType(EnergyStateBand), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });
  group('G4 relative axis while pending (clock late truth)', () {
    testWidgets(
      'a pending series stamped in 2025 labels the axis in relative minutes',
      (tester) async {
        final buckets = [_pendingMinute(0), _pendingMinute(1)];
        await tester.pumpWidget(
          _host(TripEnergyBarChart(buckets: buckets, timeUnsynced: true)),
        );
        await tester.pump();
        final chart = tester.widget<EnergyBarChart>(
          find.byType(EnergyBarChart),
        );
        expect(chart.xTicks.map((tick) => tick.label).toList(), [
          '+0 min',
          '+1 min',
          '+2 min',
        ]);
      },
    );

    testWidgets('a pending axis never shows the lying wall clock', (
      tester,
    ) async {
      final buckets = [for (var i = 0; i < 10; i++) _pendingMinute(i)];
      await tester.pumpWidget(
        _host(TripEnergyBarChart(buckets: buckets, timeUnsynced: true)),
      );
      await tester.pump();
      final chart = tester.widget<EnergyBarChart>(find.byType(EnergyBarChart));
      final labels = chart.xTicks.map((tick) => tick.label).toList();
      expect(labels, ['+0 min', '+4 min', '+8 min']);
      expect(labels.join(' '), isNot(contains('01:08')));
      // Bars keep the ordinal slots the wall axis used.
      expect(chart.xTicks.map((tick) => tick.position).toList(), [0, 0.4, 0.8]);
      expect(
        chart.bars.map((bar) => bar.value).toList(),
        buckets.map((bucket) => bucket.tractionWh / 1000).toList(),
      );
    });

    testWidgets('a synced series keeps the wall clock axis', (tester) async {
      final buckets = [_minute(0), _minute(1)];
      await tester.pumpWidget(
        _host(TripEnergyBarChart(buckets: buckets, timeUnsynced: false)),
      );
      await tester.pump();
      final chart = tester.widget<EnergyBarChart>(find.byType(EnergyBarChart));
      final labels = chart.xTicks.map((tick) => tick.label).toList();
      expect(labels.any((label) => label.startsWith('+')), isFalse);
    });

    testWidgets('a pending tooltip names minutes, never the wall clock', (
      tester,
    ) async {
      final buckets = [for (var i = 0; i < 10; i++) _pendingMinute(i)];
      await tester.pumpWidget(
        _host(TripEnergyBarChart(buckets: buckets, timeUnsynced: true)),
      );
      await tester.pump();
      final chart = tester.widget<EnergyBarChart>(find.byType(EnergyBarChart));
      final context = tester.element(find.byType(EnergyBarChart));
      final tooltip = chart.tooltipBuilder!(context, 3) as EnergyBucketTooltip;
      await tester.pumpWidget(_tooltipHost(tooltip));
      await tester.pump();
      expect(find.textContaining('+3 min'), findsOneWidget);
      expect(find.textContaining('01:1'), findsNothing);
    });

    testWidgets('pending to synced flips the axis back to wall time', (
      tester,
    ) async {
      final pending = [for (var i = 0; i < 10; i++) _pendingMinute(i)];
      await tester.pumpWidget(
        _host(TripEnergyBarChart(buckets: pending, timeUnsynced: true)),
      );
      await tester.pump();
      expect(find.textContaining('not synced'), findsOneWidget);
      final synced = [for (var i = 0; i < 10; i++) _minute(i)];
      await tester.pumpWidget(
        _host(TripEnergyBarChart(buckets: synced, timeUnsynced: false)),
      );
      await tester.pump();
      final chart = tester.widget<EnergyBarChart>(find.byType(EnergyBarChart));
      expect(
        chart.xTicks.map((tick) => tick.label).toList(),
        isNot(['+0 min', '+4 min', '+8 min']),
      );
      expect(find.textContaining('not synced'), findsNothing);
    });
  });
}
