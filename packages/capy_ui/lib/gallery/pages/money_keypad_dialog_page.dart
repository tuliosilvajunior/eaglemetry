import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

enum _CostField { rate, total }

class MoneyKeypadDialogGalleryPage extends StatefulWidget {
  const MoneyKeypadDialogGalleryPage({super.key});

  @override
  State<MoneyKeypadDialogGalleryPage> createState() =>
      _MoneyKeypadDialogGalleryPageState();
}

class _MoneyKeypadDialogGalleryPageState
    extends State<MoneyKeypadDialogGalleryPage> {
  double? _rate = 0.32;
  double? _total = 7.68;

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'MoneyKeypadDialog',
      summary:
          'Payment-terminal digits, right to left. Nothing is written '
          'until confirm. Two fields add a segmented selector.',
      note:
          'There is no decimal key. Each tap is one more cent position, so '
          'the value moves from 0,00 to 0,05 to 0,55.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'This charge',
            subtitle: _rate == null
                ? 'Unpriced'
                : '€${_rate!.toStringAsFixed(2)} / kWh · €${(_total ?? 0).toStringAsFixed(2)}',
            child: Builder(
              builder: (anchorContext) {
                return SoftActionTile(
                  icon: Icons.payments,
                  label: 'Edit cost',
                  onPressed: () => showMoneyKeypadDialog<_CostField>(
                    context: context,
                    anchorContext: anchorContext,
                    currencySymbol: '€',
                    title: 'Charge cost',
                    description:
                        'A rate prices the energy. A total is a receipt. '
                        'Clear leaves the charge unpriced.',
                    saveLabel: 'Save',
                    clearLabel: 'Clear',
                    deleteLabel: 'Delete last digit',
                    barrierLabel: 'Close money keypad',
                    fields: [
                      MoneyKeypadField(
                        value: _CostField.rate,
                        label: 'Rate',
                        amount: _rate,
                        unit: '/kWh',
                      ),
                      MoneyKeypadField(
                        value: _CostField.total,
                        label: 'Total',
                        amount: _total,
                      ),
                    ],
                    onSubmitted: (result) => setState(() {
                      switch (result.field) {
                        case _CostField.rate:
                          _rate = result.amount;
                        case _CostField.total:
                          _total = result.amount;
                      }
                    }),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
