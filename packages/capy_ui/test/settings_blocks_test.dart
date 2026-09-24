import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/capy_ui.dart';

Widget _host({required Widget child, double width = 390}) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: MediaQuery(
      data: MediaQueryData(size: Size(width, 800)),
      child: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

void main() {
  group('SettingsEntry', () {
    testWidgets('renders title, description and child', (tester) async {
      await tester.pumpWidget(
        _host(
          child: const SettingsEntry(
            title: 'Test Setting',
            description: 'This is a description',
            child: Text('Child Control'),
          ),
        ),
      );

      expect(find.text('Test Setting'), findsOneWidget);
      expect(find.text('This is a description'), findsOneWidget);
      expect(find.text('Child Control'), findsOneWidget);
    });

    testWidgets('omits description spacing when description is empty', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          child: const SettingsEntry(
            title: 'No Desc',
            description: '',
            child: Text('Child Only'),
          ),
        ),
      );

      expect(find.text('No Desc'), findsOneWidget);
      expect(find.text('Child Only'), findsOneWidget);
      // Only 1 SizedBox for child spacing
      expect(find.byType(SizedBox), findsOneWidget);
    });
  });

  group('SettingsSections', () {
    testWidgets('stacks children with gridGutter between them', (tester) async {
      await tester.pumpWidget(
        _host(
          child: const SettingsSections(
            children: [Text('Section 1'), Text('Section 2'), Text('Section 3')],
          ),
        ),
      );

      expect(find.text('Section 1'), findsOneWidget);
      expect(find.text('Section 2'), findsOneWidget);
      expect(find.text('Section 3'), findsOneWidget);
      // Two spacers between 3 children
      final sizedBoxes = tester
          .widgetList<SizedBox>(find.byType(SizedBox))
          .where((box) => box.height == AppSpacing.gridGutter)
          .toList();
      expect(sizedBoxes.length, 2);
    });
  });

  group('SettingsRows', () {
    testWidgets('stacks children with x5 between them', (tester) async {
      await tester.pumpWidget(
        _host(
          child: const SettingsRows(children: [Text('Row 1'), Text('Row 2')]),
        ),
      );

      expect(find.text('Row 1'), findsOneWidget);
      expect(find.text('Row 2'), findsOneWidget);
      final sizedBoxes = tester
          .widgetList<SizedBox>(find.byType(SizedBox))
          .where((box) => box.height == AppSpacing.x5)
          .toList();
      expect(sizedBoxes.length, 1);
    });
  });

  group('SettingsAdaptiveGrid', () {
    testWidgets('renders single column for compact width class', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          width: 390,
          child: SettingsAdaptiveGrid(
            capabilities: SurfaceCapabilities.fromWidth(390),
            children: const [Text('Card 1'), Text('Card 2'), Text('Card 3')],
          ),
        ),
      );

      expect(find.text('Card 1'), findsOneWidget);
      expect(find.text('Card 2'), findsOneWidget);
      expect(find.text('Card 3'), findsOneWidget);
      expect(find.byType(IntrinsicHeight), findsNothing);
    });

    testWidgets('renders 2-column grid for medium/expanded width class', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          width: 960,
          child: SettingsAdaptiveGrid(
            capabilities: SurfaceCapabilities.fromWidth(960),
            children: const [Text('Card 1'), Text('Card 2'), Text('Card 3')],
          ),
        ),
      );

      expect(find.text('Card 1'), findsOneWidget);
      expect(find.text('Card 2'), findsOneWidget);
      expect(find.text('Card 3'), findsOneWidget);
      // 2 rows: first with 2 cards, second with 1 card + Spacer
      expect(find.byType(IntrinsicHeight), findsNWidgets(2));
      expect(find.byType(Spacer), findsOneWidget);
    });
  });
}
