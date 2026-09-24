import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/capy_ui.dart';

Widget _host({
  String temperatureValue = '21.5',
  VoidCallback? onDecreaseTemperature,
  VoidCallback? onIncreaseTemperature,
  int fanSpeedLevel = 3,
  int fanSpeedMaxLevel = 9,
  VoidCallback? onDecreaseFanSpeed,
  VoidCallback? onIncreaseFanSpeed,
  ValueChanged<bool>? onAutoChanged,
  bool autoEnabled = false,
}) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(
      body: Center(
        child: ClimateControlCard(
          title: 'Climate control',
          temperatureValue: temperatureValue,
          temperatureUnit: '°C',
          decreaseTemperatureLabel: 'Decrease temperature',
          increaseTemperatureLabel: 'Increase temperature',
          onDecreaseTemperature: onDecreaseTemperature,
          onIncreaseTemperature: onIncreaseTemperature,
          autoLabel: 'Auto',
          autoEnabled: autoEnabled,
          onAutoChanged: onAutoChanged,
          fanSpeedLevel: fanSpeedLevel,
          fanSpeedMaxLevel: fanSpeedMaxLevel,
          decreaseFanSpeedLabel: 'Decrease fan speed',
          increaseFanSpeedLabel: 'Increase fan speed',
          onDecreaseFanSpeed: onDecreaseFanSpeed,
          onIncreaseFanSpeed: onIncreaseFanSpeed,
          acLabel: 'A/C',
          acEnabled: true,
          syncLabel: 'Sync',
          syncEnabled: false,
          defrostLabel: 'Front defrost',
          defrostEnabled: false,
          seatHeatLabel: 'Seat heat',
          seatHeatEnabled: false,
          steeringWheelHeatLabel: 'Wheel heat',
          steeringWheelHeatEnabled: false,
          petModeLabel: 'Pet mode',
          petModeEnabled: false,
          climateScheduleLabel: 'Climate schedule',
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('shows the temperature as a metric and a unit', (tester) async {
    await tester.pumpWidget(_host());

    expect(find.text('21.5'), findsOneWidget);
    expect(find.text('°C'), findsOneWidget);
  });

  testWidgets('the temperature steppers meet the automotive touch minimum', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(onDecreaseTemperature: () {}, onIncreaseTemperature: () {}),
    );

    for (final label in ['Decrease temperature', 'Increase temperature']) {
      final button = find.byWidgetPredicate(
        (widget) => widget is SquareIconButton && widget.tooltip == label,
      );
      expect(tester.getSize(button).shortestSide, greaterThanOrEqualTo(64));
    }
  });

  testWidgets('a null temperature callback disables that stepper', (
    tester,
  ) async {
    await tester.pumpWidget(_host(onIncreaseTemperature: () {}));

    final decrease = tester.widget<SquareIconButton>(
      find.byWidgetPredicate(
        (widget) =>
            widget is SquareIconButton &&
            widget.tooltip == 'Decrease temperature',
      ),
    );
    final increase = tester.widget<SquareIconButton>(
      find.byWidgetPredicate(
        (widget) =>
            widget is SquareIconButton &&
            widget.tooltip == 'Increase temperature',
      ),
    );
    expect(decrease.onPressed, isNull);
    expect(increase.onPressed, isNotNull);
  });

  testWidgets('a stopped fan is drawn as an outline', (tester) async {
    await tester.pumpWidget(_host(fanSpeedLevel: 0));

    final fan = tester.widget<FanIcon>(find.byType(FanIcon));
    expect(fan.filled, isFalse);
  });

  testWidgets('a running fan is drawn filled', (tester) async {
    await tester.pumpWidget(_host(fanSpeedLevel: 3));

    final fan = tester.widget<FanIcon>(find.byType(FanIcon));
    expect(fan.filled, isTrue);
  });

  testWidgets('a zero max fan level draws no dots', (tester) async {
    await tester.pumpWidget(_host(fanSpeedMaxLevel: 0, fanSpeedLevel: 0));

    expect(find.byKey(const Key('climate-fan-dots')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('climate-fan-dots')),
        matching: find.byType(AnimatedContainer),
      ),
      findsNothing,
    );
  });

  testWidgets('a null auto callback leaves the tile in the tree, disabled', (
    tester,
  ) async {
    await tester.pumpWidget(_host());

    expect(find.text('Auto'), findsOneWidget);
    await tester.tap(find.text('Auto'));
    await tester.pump();
  });

  testWidgets('an auto tap reports the inverted value', (tester) async {
    bool? reported;
    await tester.pumpWidget(
      _host(onAutoChanged: (value) => reported = value, autoEnabled: false),
    );

    await tester.tap(find.text('Auto'));
    await tester.pump();
    expect(reported, isTrue);
  });
}
