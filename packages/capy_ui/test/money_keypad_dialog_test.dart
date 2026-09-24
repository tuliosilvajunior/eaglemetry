import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/capy_ui.dart';

enum _Field { rate, total }

Widget _host({
  required ValueChanged<MoneyKeypadResult<_Field>> onSubmitted,
  List<MoneyKeypadField<_Field>>? fields,
  _Field? initialField,
}) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(
      backgroundColor: AppColors.canvas,
      body: Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: 180,
          child: AnchoredTooltipTrigger(
            side: AnchoredTooltipSide.left,
            barrierLabel: 'Close the price keypad',
            tooltipBuilder: (context) => MoneyKeypadDialog<_Field>(
              fields:
                  fields ??
                  const [
                    MoneyKeypadField(value: _Field.rate, label: 'Price/kWh'),
                  ],
              initialField: initialField,
              currencySymbol: r'R$',
              title: 'Charge price',
              description: 'Applies to this charge only.',
              saveLabel: 'Save',
              clearLabel: 'Clear the amount',
              deleteLabel: 'Delete the last digit',
              onSubmitted: onSubmitted,
            ),
            builder: (context, isOpen, open) => SoftActionTile(
              label: 'Price',
              centered: true,
              selected: isOpen,
              onPressed: open,
            ),
          ),
        ),
      ),
    ),
  );
}

/// The head unit, so the whole keypad is on screen. The default test viewport
/// is shorter than any car display and would scroll the keys out of reach.
void _useHeadUnitViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('Price'));
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String digits) async {
  for (final digit in digits.split('')) {
    await tester.tap(find.widgetWithText(InkWell, digit));
    await tester.pump();
  }
}

String _readout(WidgetTester tester) {
  final readout = find.byKey(const Key('money-keypad-readout'));
  return tester
      .widgetList<Text>(
        find.descendant(of: readout, matching: find.byType(Text)),
      )
      .map((text) => text.data)
      .join(' ');
}

void main() {
  testWidgets('starts at zero and fills the cents from the right', (
    tester,
  ) async {
    _useHeadUnitViewport(tester);
    await tester.pumpWidget(_host(onSubmitted: (_) {}));
    await _open(tester);

    expect(_readout(tester), contains('0,00'));

    await _type(tester, '9');
    expect(_readout(tester), contains('0,09'));

    await _type(tester, '45');
    expect(_readout(tester), contains('9,45'));
  });

  testWidgets('reports the typed amount only when the reader confirms', (
    tester,
  ) async {
    final submitted = <MoneyKeypadResult<_Field>>[];
    _useHeadUnitViewport(tester);
    await tester.pumpWidget(_host(onSubmitted: submitted.add));
    await _open(tester);

    await _type(tester, '123');
    expect(submitted, isEmpty);

    await tester.tap(find.byKey(const Key('money-keypad-save')));
    await tester.pumpAndSettle();

    expect(submitted, hasLength(1));
    expect(submitted.single.field, _Field.rate);
    expect(submitted.single.amount, 1.23);
  });

  testWidgets('a leading zero is not a digit position', (tester) async {
    _useHeadUnitViewport(tester);
    await tester.pumpWidget(_host(onSubmitted: (_) {}));
    await _open(tester);

    await _type(tester, '00');
    expect(_readout(tester), contains('0,00'));

    await _type(tester, '5');
    expect(_readout(tester), contains('0,05'));
  });

  testWidgets('delete removes one digit and clear empties the amount', (
    tester,
  ) async {
    final submitted = <MoneyKeypadResult<_Field>>[];
    _useHeadUnitViewport(tester);
    await tester.pumpWidget(_host(onSubmitted: submitted.add));
    await _open(tester);

    await _type(tester, '1250');
    await tester.tap(find.byKey(const Key('money-keypad-delete')));
    await tester.pump();
    expect(_readout(tester), contains('1,25'));

    await tester.tap(find.byKey(const Key('money-keypad-clear')));
    await tester.pump();
    expect(_readout(tester), contains('0,00'));

    await tester.tap(find.byKey(const Key('money-keypad-save')));
    await tester.pumpAndSettle();

    // An empty amount is "no price saved", not a price of zero.
    expect(submitted.single.amount, isNull);
  });

  testWidgets('one field shows no selector', (tester) async {
    _useHeadUnitViewport(tester);
    await tester.pumpWidget(_host(onSubmitted: (_) {}));
    await _open(tester);

    expect(find.byType(TrackSegmentedControl<_Field>), findsNothing);
  });

  testWidgets('each field keeps the digits typed in it', (tester) async {
    final submitted = <MoneyKeypadResult<_Field>>[];
    _useHeadUnitViewport(tester);
    await tester.pumpWidget(
      _host(
        onSubmitted: submitted.add,
        initialField: _Field.rate,
        fields: const [
          MoneyKeypadField(
            value: _Field.rate,
            label: 'Price/kWh',
            amount: 0.95,
            unit: '/kWh',
          ),
          MoneyKeypadField(value: _Field.total, label: 'Total paid'),
        ],
      ),
    );
    await _open(tester);

    expect(_readout(tester), contains('0,95'));
    expect(find.byType(TrackSegmentedControl<_Field>), findsOneWidget);

    await tester.tap(find.text('Total paid'));
    await tester.pump();
    expect(_readout(tester), contains('0,00'));

    await _type(tester, '4000');
    await tester.tap(find.text('Price/kWh'));
    await tester.pump();
    // The rate is untouched by what was typed into the total.
    expect(_readout(tester), contains('0,95'));

    await tester.tap(find.text('Total paid'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('money-keypad-save')));
    await tester.pumpAndSettle();

    expect(submitted.single.field, _Field.total);
    expect(submitted.single.amount, 40.0);
  });
}
