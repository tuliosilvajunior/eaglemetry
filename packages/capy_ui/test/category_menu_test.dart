import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/capy_ui.dart';

const _groups = [
  CategoryMenuGroup<String>([
    CategoryMenuEntry(value: 'guide', label: 'Guide', icon: Icons.menu_book),
  ]),
  CategoryMenuGroup<String>([
    CategoryMenuEntry(value: 'displays', label: 'Displays', icon: Icons.tv),
    CategoryMenuEntry(
      value: 'lighting',
      label: 'Lighting',
      icon: Icons.lightbulb,
    ),
  ]),
];

Widget _host({ValueChanged<String>? onSelected}) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(
      backgroundColor: AppColors.canvas,
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showCategoryMenu<String>(
              context: context,
              groups: _groups,
              initialSelected: 'displays',
              barrierLabel: 'Close menu',
              onSelected: onSelected,
              search: const CategoryMenuSearch(
                hint: 'Search',
                emptyLabel: 'Nothing matches',
              ),
              detailBuilder: (context, selected) => Text('detail:$selected'),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

Future<void> _open(WidgetTester tester) async {
  await tester.pumpWidget(_host());
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the detail of the initially selected category', (
    tester,
  ) async {
    await _open(tester);

    expect(find.byKey(const Key('category-menu-panel')), findsOneWidget);
    expect(find.text('detail:displays'), findsOneWidget);
  });

  testWidgets('selecting a category swaps the detail and reports it', (
    tester,
  ) async {
    final selections = <String>[];
    await tester.pumpWidget(_host(onSelected: selections.add));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Lighting'));
    await tester.pumpAndSettle();

    expect(selections, ['lighting']);
    expect(find.text('detail:lighting'), findsOneWidget);
    expect(find.text('detail:displays'), findsNothing);
  });

  testWidgets('search filters the rail and keeps the current detail', (
    tester,
  ) async {
    await _open(tester);

    await tester.enterText(find.byType(TextField), 'light');
    await tester.pumpAndSettle();

    expect(find.text('Lighting'), findsOneWidget);
    expect(find.text('Displays'), findsNothing);
    expect(find.text('Guide'), findsNothing);
    // Filtering is a view of the rail, not a change of selection.
    expect(find.text('detail:displays'), findsOneWidget);
  });

  testWidgets('a query that matches nothing states so', (tester) async {
    await _open(tester);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();

    expect(find.text('Nothing matches'), findsOneWidget);
  });

  testWidgets('every category row keeps the automotive touch target', (
    tester,
  ) async {
    await _open(tester);

    for (final label in ['Guide', 'Displays', 'Lighting']) {
      final row = find.ancestor(
        of: find.text(label),
        matching: find.byType(InkWell),
      );
      expect(tester.getSize(row.first).height, greaterThanOrEqualTo(64));
    }
  });

  testWidgets('tapping the scrim closes the menu', (tester) async {
    await _open(tester);

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('category-menu-panel')), findsNothing);
  });
}
