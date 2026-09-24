import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/capy_ui.dart';

Widget _host() {
  return MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(
      backgroundColor: AppColors.canvas,
      body: Align(
        alignment: Alignment.centerLeft,
        child: AnchoredTooltipTrigger(
          side: AnchoredTooltipSide.right,
          caretAlignment: 0.08,
          anchorInsets: const EdgeInsets.all(AppSpacing.x4),
          barrierLabel: 'Close information',
          tooltipBuilder: (context) => const InformationTooltipPanel(
            title: 'Which charge limit should I pick?',
            children: [
              InformationCard(value: '70%', description: 'Daily driving'),
              InformationCard(value: '85%', description: 'Extended distance'),
              InformationCard(value: '100%', description: 'Maximum range'),
            ],
          ),
          builder: (context, isOpen, open) => InfoIconButton(
            selected: isOpen,
            onPressed: open,
            tooltip: 'About charge limits',
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('info trigger opens reusable anchored information cards', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    expect(find.byIcon(Icons.info_outline), findsOneWidget);

    await tester.tap(find.byType(InfoIconButton));
    await tester.pumpAndSettle();

    expect(find.text('Which charge limit should I pick?'), findsOneWidget);
    expect(find.byType(InformationCard), findsNWidgets(3));
    expect(find.text('70%'), findsOneWidget);
    expect(find.text('85%'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(find.byIcon(Icons.info), findsOneWidget);

    final card = tester.widget<Container>(
      find
          .ancestor(of: find.text('70%'), matching: find.byType(Container))
          .first,
    );
    expect((card.decoration! as BoxDecoration).color, AppColors.control);
  });

  testWidgets('caret targets the center height and trigger resets on close', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.tap(find.byType(InfoIconButton));
    await tester.pumpAndSettle();

    final buttonRect = tester.getRect(find.byType(InfoIconButton));
    final caretRect = tester.getRect(
      find.byKey(const Key('anchored-tooltip-caret-right')),
    );
    final visualCircle = tester.getRect(
      find.descendant(
        of: find.byType(InfoIconButton),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect(caretRect.center.dy, closeTo(buttonRect.center.dy, 0.01));
    expect(caretRect.left, lessThan(visualCircle.right));
    expect(caretRect.left, closeTo(visualCircle.right - 4, 0.01));

    await tester.tapAt(const Offset(790, 10));
    await tester.pumpAndSettle();

    expect(find.text('Which charge limit should I pick?'), findsNothing);
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
  });

  testWidgets(
    'a card link is its own tappable line and the card opens nothing',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Center(
              child: InformationCard(
                value: 'API key',
                description: 'Open the page below.',
                linkLabel: 'https://example.test/keys',
                onLinkPressed: () => taps++,
              ),
            ),
          ),
        ),
      );

      final link = find.text('https://example.test/keys');
      expect(link, findsOneWidget);

      // A thumb target, not a span inside the paragraph.
      expect(
        tester
            .getSize(
              find.ancestor(of: link, matching: find.byType(InkWell)).first,
            )
            .height,
        greaterThanOrEqualTo(AppSizes.minTouchTarget),
      );

      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(taps, 1);
    },
  );

  testWidgets('a card with no link renders no tappable line', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: const Scaffold(
          body: Center(
            child: InformationCard(value: '70%', description: 'Daily charge.'),
          ),
        ),
      ),
    );

    expect(find.byType(InkWell), findsNothing);
  });
}
