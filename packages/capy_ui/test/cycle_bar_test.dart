import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/capy_ui.dart';

/// The pill is a reading, not a control. These pin the two things that make it
/// one: the scale is always the whole battery, and nothing about it moves.
void main() {
  Future<void> pump(WidgetTester tester, Widget bar) => tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Center(child: SizedBox(width: 400, child: bar)),
      ),
    ),
  );

  testWidgets('the fill is the share of the whole battery', (tester) async {
    await pump(
      tester,
      const CycleBar(fillPercent: 25, leadingLabel: '#6', valueLabel: '25'),
    );

    final box = tester.getSize(find.byType(FractionallySizedBox).first);
    // The pill is the battery. A quarter of it is a quarter of the width, not
    // a quarter of some range that starts above zero.
    expect(box.width, closeTo(100, 0.5));
    // And it is as tall as the pill. A fill with no height is a grey bar that
    // says the battery was never used.
    expect(box.height, AppSizes.cycleBarHeight);
  });

  testWidgets('a spent battery fills the pill', (tester) async {
    await pump(
      tester,
      const CycleBar(fillPercent: 100, leadingLabel: '#5', valueLabel: '100'),
    );

    expect(tester.getSize(find.byType(FractionallySizedBox).first).width, 400);
  });

  testWidgets('an impossible reading cannot overflow the pill', (tester) async {
    await pump(
      tester,
      const CycleBar(fillPercent: 140, leadingLabel: '#4', valueLabel: '100'),
    );

    expect(tester.getSize(find.byType(FractionallySizedBox).first).width, 400);
  });

  testWidgets('a partial battery keeps an outline over the empty end', (
    tester,
  ) async {
    await pump(
      tester,
      const CycleBar(
        fillPercent: 62,
        leadingLabel: '#1',
        valueLabel: '62',
        isPartial: true,
      ),
    );

    expect(find.byType(DecoratedBox), findsWidgets);
  });

  testWidgets('the bar never animates', (tester) async {
    await pump(
      tester,
      const CycleBar(
        fillPercent: 41,
        leadingLabel: '#6',
        valueLabel: '41',
        valueUnit: '%',
      ),
    );

    // A list of these repeats down a moving car's screen. If any of them
    // breathed, the frame after settle would differ from the first one.
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(find.text('41'), findsOneWidget);
    expect(find.text('%'), findsOneWidget);
  });
}
