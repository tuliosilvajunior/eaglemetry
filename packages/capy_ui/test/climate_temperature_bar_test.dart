import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/capy_ui.dart';

Widget _host({
  required ThemeData theme,
  double driverTempC = 21.5,
  double passengerTempC = 22.0,
  VoidCallback? onDriverDecrease,
  VoidCallback? onDriverIncrease,
  VoidCallback? onPassengerDecrease,
  VoidCallback? onPassengerIncrease,
}) {
  return MaterialApp(
    theme: theme,
    home: Scaffold(
      backgroundColor: AppColors.canvas,
      body: Center(
        child: ClimateTemperatureBar(
          driverValue: driverTempC.toStringAsFixed(1),
          driverCaption: 'AUTO',
          driverDecreaseLabel: 'Decrease driver temperature',
          driverIncreaseLabel: 'Increase driver temperature',
          onDriverDecrease: onDriverDecrease,
          onDriverIncrease: onDriverIncrease,
          passengerValue: passengerTempC.toStringAsFixed(1),
          passengerCaption: 'OFF',
          passengerFanActive: false,
          passengerDecreaseLabel: 'Decrease passenger temperature',
          passengerIncreaseLabel: 'Increase passenger temperature',
          onPassengerDecrease: onPassengerDecrease,
          onPassengerIncrease: onPassengerIncrease,
        ),
      ),
    ),
  );
}

const _driverDecrease = Key('climate-temperature-bar-driver-decrease');
const _driverIncrease = Key('climate-temperature-bar-driver-increase');
const _passengerDecrease = Key('climate-temperature-bar-passenger-decrease');
const _passengerIncrease = Key('climate-temperature-bar-passenger-increase');

void main() {
  testWidgets('shows both zone readings, degree sign included', (tester) async {
    await tester.pumpWidget(_host(theme: AppTheme.light()));

    // The pill adds the degree sign, so the caller passes a bare number and
    // the two cannot be separated by a line break.
    expect(find.text('21.5°'), findsOneWidget);
    expect(find.text('22.0°'), findsOneWidget);
  });

  testWidgets('a floor or ceiling label does not take a degree sign', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: Center(
            child: Row(
              children: [
                ClimateZonePill(
                  zoneKeyPrefix: 'lo',
                  value: 'LO',
                  decreaseLabel: 'Cooler',
                  increaseLabel: 'Warmer',
                ),
                ClimateZonePill(
                  zoneKeyPrefix: 'hi',
                  value: 'HI',
                  decreaseLabel: 'Cooler',
                  increaseLabel: 'Warmer',
                ),
                ClimateZonePill(
                  zoneKeyPrefix: 'missing',
                  value: '--',
                  decreaseLabel: 'Cooler',
                  increaseLabel: 'Warmer',
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.text('LO'), findsOneWidget);
    expect(find.text('HI'), findsOneWidget);
    expect(find.text('--'), findsOneWidget);
    expect(find.text('LO°'), findsNothing);
    expect(find.text('HI°'), findsNothing);
    expect(find.text('--°'), findsNothing);
  });

  testWidgets('a large text scale does not overflow the pill', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) {
          return MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          );
        },
        home: Scaffold(
          body: Center(
            child: ClimateTemperatureBar(
              driverValue: '21.5',
              driverCaption: 'AUTO',
              driverDecreaseLabel: 'Decrease driver temperature',
              driverIncreaseLabel: 'Increase driver temperature',
              passengerValue: '22.0',
              passengerCaption: 'OFF',
              passengerDecreaseLabel: 'Decrease passenger temperature',
              passengerIncreaseLabel: 'Increase passenger temperature',
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('a mode line is drawn only where the caller gave one', (
    tester,
  ) async {
    await tester.pumpWidget(_host(theme: AppTheme.light()));
    expect(find.text('AUTO'), findsOneWidget);
    expect(find.text('OFF'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('AUTO')).style?.color,
      AppColors.climateBarOnSurfaceMuted,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: Center(
            child: ClimateZonePill(
              zoneKeyPrefix: 'driver',
              value: '21.0',
              decreaseLabel: 'Cooler',
              increaseLabel: 'Warmer',
            ),
          ),
        ),
      ),
    );

    // No line at all, not an empty one: a pill with no mode is a real state
    // on the reference unit, and a blank line would leave the reading sitting
    // off-centre for nothing.
    expect(find.text('AUTO'), findsNothing);
    expect(find.text('OFF'), findsNothing);
    expect(find.byType(Text), findsOneWidget);
  });

  testWidgets('a stopped fan is drawn as an outline, a running one filled', (
    tester,
  ) async {
    await tester.pumpWidget(_host(theme: AppTheme.light()));

    final fans = tester.widgetList<FanIcon>(find.byType(FanIcon)).toList();
    expect(fans, hasLength(2));
    expect(fans.first.filled, isTrue);
    expect(fans.last.filled, isFalse);
  });

  testWidgets('the four chevrons meet the automotive touch minimum', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        theme: AppTheme.light(),
        onDriverDecrease: () {},
        onDriverIncrease: () {},
        onPassengerDecrease: () {},
        onPassengerIncrease: () {},
      ),
    );

    for (final key in [
      _driverDecrease,
      _driverIncrease,
      _passengerDecrease,
      _passengerIncrease,
    ]) {
      final size = tester.getSize(find.byKey(key));
      expect(size.height, greaterThanOrEqualTo(64));
      expect(size.width, greaterThanOrEqualTo(64));
    }
  });

  testWidgets('each chevron drives its own zone and its own direction', (
    tester,
  ) async {
    var driverDecreases = 0;
    var driverIncreases = 0;
    var passengerDecreases = 0;
    var passengerIncreases = 0;
    await tester.pumpWidget(
      _host(
        theme: AppTheme.light(),
        onDriverDecrease: () => driverDecreases++,
        onDriverIncrease: () => driverIncreases++,
        onPassengerDecrease: () => passengerDecreases++,
        onPassengerIncrease: () => passengerIncreases++,
      ),
    );

    await tester.tap(find.byKey(_driverDecrease));
    await tester.pump();
    expect((driverDecreases, driverIncreases), (1, 0));
    expect((passengerDecreases, passengerIncreases), (0, 0));

    await tester.tap(find.byKey(_driverIncrease));
    await tester.pump();
    expect((driverDecreases, driverIncreases), (1, 1));

    await tester.tap(find.byKey(_passengerDecrease));
    await tester.pump();
    expect((passengerDecreases, passengerIncreases), (1, 0));

    await tester.tap(find.byKey(_passengerIncrease));
    await tester.pump();
    expect((passengerDecreases, passengerIncreases), (1, 1));
    // The driver zone did not move while the passenger zone was tapped.
    expect((driverDecreases, driverIncreases), (1, 1));
  });

  testWidgets('a null callback disables its chevron rather than hiding it', (
    tester,
  ) async {
    await tester.pumpWidget(_host(theme: AppTheme.light()));

    for (final key in [
      _driverDecrease,
      _driverIncrease,
      _passengerDecrease,
      _passengerIncrease,
    ]) {
      expect(find.byKey(key), findsOneWidget);
      final inkWell = tester.widget<InkWell>(
        find.descendant(of: find.byKey(key), matching: find.byType(InkWell)),
      );
      expect(inkWell.onTap, isNull);
    }
  });

  testWidgets('the pills stay the same colour across every theme', (
    tester,
  ) async {
    for (final theme in [
      AppTheme.light(),
      AppTheme.dark(),
      AppTheme.forId(AppThemeId.midnight),
      AppTheme.forId(AppThemeId.tokyoNeon),
    ]) {
      await tester.pumpWidget(_host(theme: theme));

      for (final zone in ['driver', 'passenger']) {
        final decoration = tester
            .widget<Container>(find.byKey(Key('climate-zone-pill-$zone')))
            .decoration;
        expect(decoration, isA<BoxDecoration>());
        expect(
          (decoration as BoxDecoration).color,
          AppColors.climatePillSurface,
        );
      }
    }
  });

  testWidgets('the strip paints no ground of its own', (tester) async {
    await tester.pumpWidget(_host(theme: AppTheme.light()));

    // The two pills float on whatever is behind them — the shell's bezel —
    // so a strip that painted its own field would draw a bar the reference
    // unit does not have.
    expect(
      find.byKey(const Key('climate-temperature-bar-surface')),
      findsOneWidget,
    );
    expect(
      tester.widget(find.byKey(const Key('climate-temperature-bar-surface'))),
      isA<SizedBox>(),
    );
  });
}
