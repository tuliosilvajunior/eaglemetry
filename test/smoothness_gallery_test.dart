import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/driving_smoothness.dart';
import 'package:capy_ui/gallery/smoothness_gallery_screen.dart';
import 'package:capy_ui/capy_ui.dart';

/// The harness exists to review the pill, so what these tests hold is that it
/// reviews the *shipped* reading rather than one of its own.
void main() {
  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: SmoothnessGalleryScreen()));
  }

  /// Lets the harness run for [ticks] of its 50 ms simulated clock.
  Future<void> run(WidgetTester tester, int ticks) async {
    for (var i = 0; i < ticks; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  DrivingSmoothness reading(WidgetTester tester) => tester
      .widgetList<SmoothnessLevel>(find.byType(SmoothnessLevel))
      .first
      .smoothness;

  /// Taps a control, scrolling it into view first.
  ///
  /// The style control is horizontally scrollable, so a segment past the card's
  /// edge is clipped and a plain `tap` silently misses it. That is not a
  /// cosmetic problem in a test: a missed tap leaves the previous style
  /// selected and the assertion then passes against the wrong reading.
  Future<void> choose(WidgetTester tester, String label) async {
    final target = find.text(label);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pump();
  }

  /// Leaves the screen so its timer is cancelled before the test ends.
  Future<void> stop(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
  }

  testWidgets('the pill starts with nothing to show', (tester) async {
    // The window is empty on mount, and an empty window is not a smooth drive.
    await pump(tester);
    expect(reading(tester).state, SmoothnessState.unavailable);
    await stop(tester);
  });

  testWidgets('a simulated drive fills the window and moves the pill', (
    tester,
  ) async {
    await pump(tester);
    // Two hundred ticks is forty simulated seconds, past the thirty-second
    // window.
    await run(tester, 200);

    final value = reading(tester);
    expect(value.state, SmoothnessState.measured);
    expect(value.standing, isNotNull);
    expect(value.rampKwPerKm, isNotNull);
    await stop(tester);
  });

  testWidgets('steady driving reads at the top of the track', (tester) async {
    // The property the previous reading failed: holding a speed is the same
    // correct act however fast, and must read as such.
    await pump(tester);
    await choose(tester, 'Steady');
    await run(tester, 400);

    expect(reading(tester).standing, 1);
    await stop(tester);
  });

  testWidgets('aggressive driving ranks below gentle driving', (tester) async {
    Future<double> standingFor(String style) async {
      await pump(tester);
      await choose(tester, style);
      await run(tester, 600);
      final value = reading(tester).standing!;
      await stop(tester);
      return value;
    }

    // The order is the instrument. The reading this replaced had it backwards.
    final gentle = await standingFor('Gentle');
    final aggressive = await standingFor('Aggressive');
    expect(gentle, greaterThan(aggressive));
    // And by a margin a driver could see, not by a rounding difference. A pill
    // that separates the two styles by a pixel separates nothing.
    expect(gentle - aggressive, greaterThan(0.15));
  });

  testWidgets('manual mode drives the pill from the sliders', (tester) async {
    await pump(tester);
    await choose(tester, 'Manual');
    // The manual defaults hold a fixed power, which is a perfectly steady
    // drive, so the knob must climb to the top.
    await run(tester, 400);

    expect(reading(tester).standing, 1);
    expect(find.byType(Slider), findsNWidgets(3));
    await stop(tester);
  });

  testWidgets('reset clears the reading rather than freezing it', (
    tester,
  ) async {
    await pump(tester);
    await run(tester, 200);
    expect(reading(tester).state, SmoothnessState.measured);

    await choose(tester, 'Reset');

    expect(reading(tester).state, SmoothnessState.unavailable);
    await stop(tester);
  });
}
