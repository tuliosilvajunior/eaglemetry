import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/gallery/efficiency_gallery_screen.dart';
import 'package:capy_ui/capy_ui.dart';

/// The harness never ships, so this does not check what it looks like.
///
/// It checks the one property the harness has to have to be worth looking at:
/// that it rebuilds the way the product does. The pill runs at bus rate and the
/// line does not, and a harness that rebuilt everything at bus rate would show a
/// smoothness the card cannot deliver — which is a decision made on a lie.
void main() {
  testWidgets('the pulse moves the pill without rebuilding the line', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: EfficiencyGalleryScreen()));

    final before = tester.widget<EfficiencyCard>(find.byType(EfficiencyCard));
    final knobBefore = tester
        .widget<SmoothnessLevel>(find.byType(SmoothnessLevel))
        .smoothness;

    // Two pulses, and well short of the simulator's 160 ms bucket tick, so the
    // only thing that ran is the pill's clock.
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 40));

    final after = tester.widget<EfficiencyCard>(find.byType(EfficiencyCard));
    final knobAfter = tester
        .widget<SmoothnessLevel>(find.byType(SmoothnessLevel))
        .smoothness;

    // The same widget instance: the screen did not call `setState`, so nothing
    // above the pill was rebuilt.
    expect(identical(before, after), isTrue);
    // The pill did move, so the pulse is reaching it through the notifier.
    expect(identical(knobBefore, knobAfter), isFalse);

    // Let the screen dispose, so its timers are cancelled.
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
