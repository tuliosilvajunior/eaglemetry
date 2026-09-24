import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/capy_ui.dart';

void main() {
  testWidgets('three-column layout keeps a 1:2:1 ratio', (tester) async {
    const leadingKey = Key('leading');
    const primaryKey = Key('primary');
    const trailingKey = Key('trailing');

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: SizedBox(
            width: 1000,
            height: 500,
            child: ThreeColumnLayout(
              leading: ColoredBox(key: leadingKey, color: Colors.red),
              primary: ColoredBox(key: primaryKey, color: Colors.green),
              trailing: ColoredBox(key: trailingKey, color: Colors.blue),
            ),
          ),
        ),
      ),
    );

    final leading = tester.getSize(find.byKey(leadingKey));
    final primary = tester.getSize(find.byKey(primaryKey));
    final trailing = tester.getSize(find.byKey(trailingKey));

    expect(primary.width, closeTo(leading.width * 2, 0.01));
    expect(trailing.width, closeTo(leading.width, 0.01));
    expect(leading.height, primary.height);
    expect(trailing.height, primary.height);
  });

  testWidgets('extended two-column layout preserves Trips before scrolling', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const primaryKey = Key('primary');
    const trailingKey = Key('trailing');
    const extensionKey = Key('extension');
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SizedBox(
            width: 1000,
            height: 500,
            child: HorizontallyExtendedTwoColumnLayout(
              controller: scrollController,
              primary: const ColoredBox(key: primaryKey, color: Colors.green),
              trailing: const ColoredBox(key: trailingKey, color: Colors.blue),
              extension: const ColoredBox(key: extensionKey, color: Colors.red),
            ),
          ),
        ),
      ),
    );

    const viewportWidth = 1000.0;
    const quarterWidth = (viewportWidth - AppSpacing.gridGutter) / 4;
    const primaryWidth = quarterWidth * 3;
    final primary = tester.getRect(find.byKey(primaryKey));
    final trailing = tester.getRect(find.byKey(trailingKey));
    final extension = tester.getRect(find.byKey(extensionKey));

    expect(primary.width, closeTo(primaryWidth, 0.01));
    expect(trailing.width, closeTo(quarterWidth, 0.01));
    expect(primary.left, 0);
    expect(trailing.right, closeTo(viewportWidth, 0.01));
    expect(
      extension.left,
      closeTo(viewportWidth + AppSpacing.gridGutter, 0.01),
    );
    expect(extension.width, closeTo(primaryWidth, 0.01));

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle();

    expect(scrollController.offset, greaterThan(0));
  });

  group('chrome hiding', () {
    Future<CardStageController> pumpScaffold(
      WidgetTester tester, {
      GlobalKey<_HarnessState>? key,
    }) async {
      tester.view.physicalSize = const Size(1000, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      key ??= GlobalKey<_HarnessState>();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: _Harness(key: key),
        ),
      );
      await tester.pumpAndSettle();
      return key.currentState!.stage;
    }

    testWidgets('a staged journey keeps its pill row while docked', (
      tester,
    ) async {
      await pumpScaffold(tester);
      expect(tester.getTopLeft(find.text('One')).dy, greaterThan(0));
    });

    testWidgets('an expanding card pushes the pill row off screen', (
      tester,
    ) async {
      final stage = await pumpScaffold(tester);
      final before = tester.getTopLeft(find.text('One'));

      stage.expand();
      await tester.pumpAndSettle();

      expect(tester.getTopLeft(find.text('One')).dy, lessThan(before.dy));
      expect(stage.chromeVisibility, 0);
    });

    testWidgets('collapsing brings the pill row back', (tester) async {
      final stage = await pumpScaffold(tester);
      final docked = tester.getTopLeft(find.text('One'));

      stage.expand();
      await tester.pumpAndSettle();
      stage.collapse();
      await tester.pumpAndSettle();

      expect(tester.getTopLeft(find.text('One')).dy, docked.dy);
    });

    testWidgets('the footer holds its place under the body while docked', (
      tester,
    ) async {
      await pumpScaffold(tester);
      final footer = tester.getRect(find.text('Footer'));
      final body = tester.getRect(find.byKey(const Key('body')));

      expect(footer.top, greaterThan(body.bottom));
      expect(footer.bottom, lessThanOrEqualTo(500));
    });

    testWidgets('a stale navigation-bar inset does not push the footer up', (
      tester,
    ) async {
      await pumpScaffold(tester);
      final withoutInset = tester.getRect(find.byKey(const Key('footer')));

      // What Android reports for the first frames after launch, with the bars
      // already hidden by immersive mode.
      tester.view.viewPadding = const FakeViewPadding(bottom: 48);
      tester.view.padding = const FakeViewPadding(bottom: 48);
      await tester.pumpAndSettle();

      expect(tester.getRect(find.byKey(const Key('footer'))), withoutInset);
    });

    testWidgets('the footer takes a quarter of the screen', (tester) async {
      await pumpScaffold(tester);

      final footer = tester.getRect(find.byKey(const Key('footer')));

      expect(footer.height, closeTo(500 / 4, 0.01));
    });

    testWidgets('a viewport too short for a quarter gives the body a floor', (
      tester,
    ) async {
      await pumpScaffold(tester);
      tester.view.physicalSize = const Size(1000, 200);
      await tester.pumpAndSettle();

      final footer = tester.getRect(find.byKey(const Key('footer')));
      final body = tester.getRect(find.byKey(const Key('body')));

      expect(footer.height, lessThan(200 / 4));
      expect(body.height, greaterThanOrEqualTo(AppSizes.minTouchTarget));
    });

    testWidgets('an expanding card pushes the footer off the bottom', (
      tester,
    ) async {
      final stage = await pumpScaffold(tester);
      final before = tester.getTopLeft(find.text('Footer'));

      stage.expand();
      await tester.pumpAndSettle();

      expect(tester.getTopLeft(find.text('Footer')).dy, greaterThan(before.dy));
    });

    testWidgets('the body takes both strips while the card is fullscreen', (
      tester,
    ) async {
      final stage = await pumpScaffold(tester);
      final docked = tester.getRect(find.byKey(const Key('body')));

      stage.expand();
      await tester.pumpAndSettle();
      final expanded = tester.getRect(find.byKey(const Key('body')));

      expect(expanded.top, lessThan(docked.top));
      expect(expanded.bottom, greaterThan(docked.bottom));
    });

    testWidgets('collapsing brings the footer back', (tester) async {
      final stage = await pumpScaffold(tester);
      final docked = tester.getTopLeft(find.text('Footer'));

      stage.expand();
      await tester.pumpAndSettle();
      stage.collapse();
      await tester.pumpAndSettle();

      expect(tester.getTopLeft(find.text('Footer')).dy, docked.dy);
    });

    testWidgets('a destination that wants no footer takes its strip', (
      tester,
    ) async {
      final key = GlobalKey<_HarnessState>();
      await pumpScaffold(tester, key: key);
      final docked = tester.getRect(find.byKey(const Key('body')));
      final footer = tester.getTopLeft(find.text('Footer'));

      key.currentState!.setFooterVisible(false);
      await tester.pumpAndSettle();

      expect(tester.getTopLeft(find.text('Footer')).dy, greaterThan(footer.dy));
      expect(
        tester.getRect(find.byKey(const Key('body'))).bottom,
        greaterThan(docked.bottom),
      );
      // The pill row stays where it was: only the bottom strip gives way.
      expect(tester.getTopLeft(find.text('One')).dy, greaterThan(0));
    });

    testWidgets('a fullscreen card cannot move the static bar', (tester) async {
      final stage = await pumpScaffold(tester);
      final docked = tester.getRect(find.byKey(const Key('static-bar')));

      stage.expand();
      await tester.pumpAndSettle();

      // The two strips that belong to the journey have both left by now — the
      // tests above pin that. This one has not moved a pixel, which is the
      // whole reason it is a sibling of the stack rather than an overlay in
      // it.
      expect(tester.getRect(find.byKey(const Key('static-bar'))), docked);
    });

    testWidgets('a destination that wants no footer cannot move it either', (
      tester,
    ) async {
      final key = GlobalKey<_HarnessState>();
      await pumpScaffold(tester, key: key);
      final docked = tester.getRect(find.byKey(const Key('static-bar')));

      key.currentState!.setFooterVisible(false);
      await tester.pumpAndSettle();

      expect(tester.getRect(find.byKey(const Key('static-bar'))), docked);
    });

    testWidgets('the footer sits above the static bar, never under it', (
      tester,
    ) async {
      await pumpScaffold(tester);

      final bar = tester.getRect(find.byKey(const Key('static-bar')));
      final footer = tester.getRect(find.text('Footer'));

      expect(footer.bottom, lessThanOrEqualTo(bar.top));
    });

    testWidgets('the journey keeps the height the static bar leaves', (
      tester,
    ) async {
      final key = GlobalKey<_HarnessState>();
      await pumpScaffold(tester, key: key);
      final withBar = tester.getRect(find.byKey(const Key('body')));

      key.currentState!.setStaticBar(false);
      await tester.pumpAndSettle();

      // Taking the bar out gives its height back to the body rather than
      // leaving a gap: the bar is measured before the journey, not over it.
      expect(find.byKey(const Key('static-bar')), findsNothing);
      expect(
        tester.getRect(find.byKey(const Key('body'))).height,
        greaterThan(withBar.height),
      );
    });

    testWidgets('a viewport too short for the static bar drops it whole', (
      tester,
    ) async {
      await pumpScaffold(tester);
      tester.view.physicalSize = const Size(1000, 200);
      await tester.pumpAndSettle();

      // All or nothing: half a bar is not a control anyone can press, so the
      // body keeps its floor and the bar leaves rather than shrinking.
      expect(find.byKey(const Key('static-bar')), findsNothing);
      expect(
        tester.getRect(find.byKey(const Key('body'))).height,
        greaterThanOrEqualTo(AppSizes.minTouchTarget),
      );
    });

    testWidgets('dropping the static bar also drops the bezel colour', (
      tester,
    ) async {
      await pumpScaffold(tester);
      tester.view.physicalSize = const Size(1000, 200);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('static-bar')), findsNothing);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        AppColors.canvas,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is ColoredBox &&
              widget.color == AppColors.climateBarSurface,
        ),
        findsNothing,
      );
    });

    testWidgets(
      'a mid-height viewport drops the footer rather than crushing it',
      (tester) async {
        await pumpScaffold(tester);
        tester.view.physicalSize = const Size(1000, 300);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('static-bar')), findsOneWidget);
        expect(tester.getRect(find.byKey(const Key('footer'))).height, 0);
        expect(
          tester.getRect(find.byKey(const Key('body'))).height,
          greaterThanOrEqualTo(AppSizes.minTouchTarget),
        );
      },
    );

    testWidgets('the static bar insets the journey into a rounded window', (
      tester,
    ) async {
      final key = GlobalKey<_HarnessState>();
      await pumpScaffold(tester, key: key);

      final window = tester.getRect(find.byKey(const Key('journey-window')));
      expect(window.left, AppSpacing.bezelInset);
      expect(window.top, AppSpacing.bezelInset);

      // The bar's ends line up with the window's, so the frame reads as one
      // shape rather than a panel laid on a border.
      final bar = tester.getRect(find.byKey(const Key('static-bar')));
      expect(bar.left, window.left);
      expect(bar.right, window.right);

      key.currentState!.setStaticBar(false);
      await tester.pumpAndSettle();

      // No bar, no bezel: the canvas runs to the edges as it always did.
      expect(find.byKey(const Key('journey-window')), findsNothing);
      expect(find.byKey(const Key('journey-body-clip')), findsNothing);
    });

    testWidgets('the footer has its own clip, shorter than the body clip', (
      tester,
    ) async {
      await pumpScaffold(tester);

      expect(
        find.descendant(
          of: find.byKey(const Key('journey-body-clip')),
          matching: find.byKey(const Key('footer')),
        ),
        findsNothing,
      );
      expect(find.byKey(const Key('journey-footer-clip')), findsOneWidget);

      final bodyClip = tester.getRect(
        find.byKey(const Key('journey-body-clip')),
      );
      final footerClip = tester.getRect(
        find.byKey(const Key('journey-footer-clip')),
      );
      expect(footerClip.height, lessThan(bodyClip.height));
      expect(
        tester
            .widget<ClipRRect>(find.byKey(const Key('journey-body-clip')))
            .borderRadius,
        const BorderRadius.only(
          topLeft: Radius.circular(AppRadii.xxl),
          topRight: Radius.circular(AppRadii.xxl),
        ),
      );
      expect(
        tester
            .widget<ClipRRect>(find.byKey(const Key('journey-footer-clip')))
            .borderRadius,
        const BorderRadius.only(
          bottomLeft: Radius.circular(AppRadii.xxl),
          bottomRight: Radius.circular(AppRadii.xxl),
        ),
      );
    });

    testWidgets('hiding the footer gives the body clip all four corners', (
      tester,
    ) async {
      final key = GlobalKey<_HarnessState>();
      await pumpScaffold(tester, key: key);

      key.currentState!.setFooterVisible(false);
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<ClipRRect>(find.byKey(const Key('journey-body-clip')))
            .borderRadius,
        AppRadii.xxlRadius,
      );
      expect(
        tester.getRect(find.byKey(const Key('journey-footer-clip'))).height,
        0,
      );
    });

    testWidgets('hiding the footer does not re-enter what it holds', (
      tester,
    ) async {
      final key = GlobalKey<_HarnessState>();
      await pumpScaffold(tester, key: key);
      final mounts = _MountCountingText.mounts;

      key.currentState!.setFooterVisible(false);
      await tester.pumpAndSettle();
      key.currentState!.setFooterVisible(true);
      await tester.pumpAndSettle();

      expect(_MountCountingText.mounts, mounts);
    });
  });

  group('instant readout bar', () {
    Future<void> pumpBar(WidgetTester tester, List<Widget> readings) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SizedBox(
              height: AppSizes.minTouchTarget,
              child: InstantReadoutBar(readings: readings),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a tap moves to the next reading and wraps around', (
      tester,
    ) async {
      await pumpBar(tester, const [Text('A'), Text('B')]);
      expect(find.text('A'), findsOneWidget);

      await tester.tap(find.byType(AnimatedSwitcher).last);
      await tester.pumpAndSettle();
      expect(find.text('B'), findsOneWidget);

      await tester.tap(find.byType(AnimatedSwitcher).last);
      await tester.pumpAndSettle();
      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('a single reading does not cycle', (tester) async {
      await pumpBar(tester, const [Text('A')]);

      await tester.tap(find.byType(AnimatedSwitcher).last);
      await tester.pumpAndSettle();

      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('a shorter list does not strand the index past the end', (
      tester,
    ) async {
      await pumpBar(tester, const [Text('A'), Text('B'), Text('C')]);
      await tester.tap(find.byType(AnimatedSwitcher).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(AnimatedSwitcher).last);
      await tester.pumpAndSettle();
      expect(find.text('C'), findsOneWidget);

      await pumpBar(tester, const [Text('A')]);

      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('a reading takes the width it asks for, and the height', (
      tester,
    ) async {
      await pumpBar(tester, const [SizedBox(key: Key('reading'), width: 120)]);

      final reading = tester.getRect(find.byKey(const Key('reading')));

      expect(reading.width, 120);
      expect(reading.left, 0);
      expect(reading.height, AppSizes.minTouchTarget);
    });

    testWidgets('an empty list renders the strip without a value', (
      tester,
    ) async {
      await pumpBar(tester, const []);

      expect(find.byType(InstantReadoutBar), findsOneWidget);
      expect(find.byType(Text), findsNothing);
    });
  });
}

class _Harness extends StatefulWidget {
  const _Harness({super.key});

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> with TickerProviderStateMixin {
  late final CardStageController stage = CardStageController(vsync: this);

  bool footerVisible = true;

  void setFooterVisible(bool value) => setState(() => footerVisible = value);

  bool staticBar = true;

  void setStaticBar(bool value) => setState(() => staticBar = value);

  @override
  void dispose() {
    stage.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppJourneyScaffold<int>(
      tabs: const [TabItem(value: 0, label: 'One')],
      selected: 0,
      onSelected: (_) {},
      stage: stage,
      footer: const Align(
        key: Key('footer'),
        child: _MountCountingText('Footer'),
      ),
      footerVisible: footerVisible,
      staticBar: staticBar
          ? const SizedBox(key: Key('static-bar'), height: 64)
          : null,
      body: const SizedBox.expand(key: Key('body')),
    );
  }
}

/// Text that counts how many times it has been mounted, so a test can tell a
/// hidden strip from a torn-down one.
class _MountCountingText extends StatefulWidget {
  const _MountCountingText(this.text);

  static int mounts = 0;

  final String text;

  @override
  State<_MountCountingText> createState() => _MountCountingTextState();
}

class _MountCountingTextState extends State<_MountCountingText> {
  @override
  void initState() {
    super.initState();
    _MountCountingText.mounts++;
  }

  @override
  Widget build(BuildContext context) => Text(widget.text);
}
