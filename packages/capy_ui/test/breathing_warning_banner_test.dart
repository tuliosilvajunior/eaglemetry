import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/capy_ui.dart';

Widget _host(
  Widget child, {
  double width = 640,
  bool disableAnimations = false,
}) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, child: child),
        ),
      ),
    ),
  );
}

const _banner = BreathingWarningBanner(
  icon: Icons.battery_charging_full,
  title: 'Warming battery for faster charging',
  message: 'Ready for up to 50 kW',
  color: AppColors.warning,
);

double _scale(WidgetTester tester, String key) {
  return tester
      .widget<Transform>(find.byKey(ValueKey(key)))
      .transform
      .getMaxScaleOnAxis();
}

void main() {
  testWidgets('fills its width and keeps a fixed height', (tester) async {
    await tester.pumpWidget(_host(_banner));

    expect(
      tester.getSize(find.byType(BreathingWarningBanner)),
      const Size(640, AppSizes.warningBannerHeight),
    );
    expect(find.text('Warming battery for faster charging'), findsOneWidget);
    expect(find.text('Ready for up to 50 kW'), findsOneWidget);

    final iconCircle = tester.widget<Container>(
      find.byKey(const ValueKey('breathingWarning.iconCircle')),
    );
    expect((iconCircle.decoration! as BoxDecoration).color, AppColors.warning);
  });

  testWidgets('pulse circles grow by 100 and 200 percent', (tester) async {
    await tester.pumpWidget(_host(_banner));

    expect(_scale(tester, 'breathingWarning.firstPulse'), closeTo(1, 0.001));
    expect(_scale(tester, 'breathingWarning.secondPulse'), closeTo(1, 0.001));

    await tester.pump(AppMotion.breathing);

    expect(_scale(tester, 'breathingWarning.firstPulse'), closeTo(2, 0.001));
    expect(_scale(tester, 'breathingWarning.secondPulse'), closeTo(3, 0.001));
  });

  testWidgets('outer pulse is more transparent than the inner pulse', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_banner));

    final first = tester.widget<Opacity>(
      find.byKey(const ValueKey('breathingWarning.firstOpacity')),
    );
    final second = tester.widget<Opacity>(
      find.byKey(const ValueKey('breathingWarning.secondOpacity')),
    );
    expect(second.opacity, lessThan(first.opacity));
  });

  testWidgets('reduced motion keeps both circles at their initial size', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_banner, disableAnimations: true));
    await tester.pump(AppMotion.breathing * 2);

    expect(_scale(tester, 'breathingWarning.firstPulse'), closeTo(1, 0.001));
    expect(_scale(tester, 'breathingWarning.secondPulse'), closeTo(1, 0.001));
  });

  testWidgets('long copy fits a narrow width without overflow', (tester) async {
    await tester.pumpWidget(
      _host(
        const BreathingWarningBanner(
          icon: Icons.warning,
          title: 'A very long localized warning title that cannot fit',
          message: 'A long supporting message for a narrow automotive panel',
          color: AppColors.critical,
          animate: false,
        ),
        width: 280,
      ),
    );

    expect(
      tester.getSize(find.byType(BreathingWarningBanner)),
      const Size(280, AppSizes.warningBannerHeight),
    );
    expect(tester.takeException(), isNull);
  });
}
