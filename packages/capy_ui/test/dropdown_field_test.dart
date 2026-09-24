import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/capy_ui.dart';

const _options = [
  DropdownOption(value: 'current', label: 'Current drive'),
  DropdownOption(value: 'previous', label: 'Previous drive'),
  DropdownOption(value: 'charge', label: 'Since last charge'),
];

Widget _host({
  Alignment alignment = Alignment.bottomCenter,
  DropdownMenuDirection direction = DropdownMenuDirection.auto,
  bool enabled = true,
}) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: _DropdownHost(
      alignment: alignment,
      direction: direction,
      enabled: enabled,
    ),
  );
}

class _DropdownHost extends StatefulWidget {
  const _DropdownHost({
    required this.alignment,
    required this.direction,
    required this.enabled,
  });

  final Alignment alignment;
  final DropdownMenuDirection direction;
  final bool enabled;

  @override
  State<_DropdownHost> createState() => _DropdownHostState();
}

class _DropdownHostState extends State<_DropdownHost> {
  String _value = 'current';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: Padding(
        padding: AppSpacing.screenPadding,
        child: Align(
          alignment: widget.alignment,
          child: DropdownField<String>(
            width: 280,
            value: _value,
            options: _options,
            onChanged: widget.enabled
                ? (value) => setState(() => _value = value)
                : null,
            barrierLabel: 'Close drive menu',
            direction: widget.direction,
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('tap darkens the field and opens a width-matched menu', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.tap(find.byType(DropdownField<String>));
    await tester.pumpAndSettle();

    final fieldMaterial = tester.widget<Material>(
      find.byKey(const Key('dropdown-field-material')),
    );
    final fieldRect = tester.getRect(find.byType(DropdownField<String>));
    final menuRect = tester.getRect(
      find.byKey(const Key('dropdown-menu-surface')),
    );

    expect(fieldMaterial.color, AppColors.selectionFill);
    expect(find.byIcon(Icons.keyboard_arrow_up), findsOneWidget);
    expect(find.text('Current drive'), findsNWidgets(2));
    expect(find.text('Previous drive'), findsOneWidget);
    expect(find.text('Since last charge'), findsOneWidget);
    expect(
      tester
          .widget<Material>(
            find
                .ancestor(
                  of: find.byKey(const ValueKey<Object?>('current')),
                  matching: find.byType(Material),
                )
                .first,
          )
          .color,
      AppColors.selectionFill,
    );
    expect(menuRect.width, closeTo(fieldRect.width, 0.01));
    expect(menuRect.left, closeTo(fieldRect.left, 0.01));
    expect(menuRect.right, closeTo(fieldRect.right, 0.01));
    expect(menuRect.bottom, closeTo(fieldRect.bottom, 0.01));
    expect(menuRect.top, lessThan(fieldRect.top));

    final barrier = tester.widget<AnimatedModalBarrier>(
      find.byType(AnimatedModalBarrier),
    );
    expect(barrier.color.value, AppColors.modalScrim);
  });

  testWidgets('menu fades and moves upward as it opens', (tester) async {
    await tester.pumpWidget(_host());
    await tester.tap(find.byType(DropdownField<String>));
    await tester.pump();

    final menu = find.byKey(const Key('dropdown-menu-surface'));
    SlideTransition slide() => tester.widget<SlideTransition>(
      find.ancestor(of: menu, matching: find.byType(SlideTransition)),
    );
    FadeTransition fade() => tester.widget<FadeTransition>(
      find.ancestor(of: menu, matching: find.byType(FadeTransition)),
    );

    expect(slide().position.value.dy, closeTo(0.06, 0.001));
    expect(fade().opacity.value, closeTo(0, 0.001));

    await tester.pump(const Duration(milliseconds: 110));
    expect(slide().position.value.dy, inExclusiveRange(0, 0.06));
    expect(fade().opacity.value, inExclusiveRange(0, 1));
  });

  testWidgets(
    'selection updates the field before the reverse transition ends',
    (tester) async {
      await tester.pumpWidget(_host());
      await tester.tap(find.byType(DropdownField<String>));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Previous drive'));
      await tester.pump(const Duration(milliseconds: 110));
      expect(
        find.descendant(
          of: find.byType(DropdownField<String>),
          matching: find.text('Previous drive'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('dropdown-menu-surface')), findsOneWidget);
      expect(
        tester
            .widget<Material>(
              find
                  .ancestor(
                    of: find.byKey(const ValueKey<Object?>('previous')),
                    matching: find.byType(Material),
                  )
                  .first,
            )
            .color,
        AppColors.selectionFill,
      );

      await tester.pumpAndSettle();
      expect(find.text('Previous drive'), findsOneWidget);
      expect(find.byKey(const Key('dropdown-menu-surface')), findsNothing);
      expect(
        tester
            .widget<Material>(find.byKey(const Key('dropdown-field-material')))
            .color,
        AppColors.control,
      );
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
    },
  );

  testWidgets('preferred direction flips when only the other side fits', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        alignment: Alignment.topCenter,
        direction: DropdownMenuDirection.up,
      ),
    );
    await tester.tap(find.byType(DropdownField<String>));
    await tester.pumpAndSettle();

    final fieldRect = tester.getRect(find.byType(DropdownField<String>));
    final menuRect = tester.getRect(
      find.byKey(const Key('dropdown-menu-surface')),
    );
    expect(menuRect.top, closeTo(fieldRect.top, 0.01));
    expect(menuRect.bottom, greaterThan(fieldRect.bottom));
  });

  testWidgets('disabled field does not open', (tester) async {
    await tester.pumpWidget(_host(enabled: false));
    await tester.tap(find.byType(DropdownField<String>));
    await tester.pump();

    expect(find.byKey(const Key('dropdown-menu-surface')), findsNothing);
    expect(
      tester
          .widget<Material>(find.byKey(const Key('dropdown-field-material')))
          .color,
      AppColors.control,
    );
  });
}
