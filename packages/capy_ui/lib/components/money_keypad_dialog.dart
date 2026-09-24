import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import 'anchored_tooltip.dart';
import 'pill_tab_bar.dart';
import 'track_segmented_control.dart';

/// One amount the keypad can edit.
///
/// A dialog with a single field shows no selector. Two or more fields add a
/// [TrackSegmentedControl] over the readout, because the amounts are different
/// readings of the same charge and the reader must see which one is being
/// typed.
@immutable
class MoneyKeypadField<T> {
  const MoneyKeypadField({
    required this.value,
    required this.label,
    this.amount,
    this.unit,
  });

  /// Identifies the field to the caller.
  final T value;

  /// Localized segment label.
  final String label;

  /// Current amount, or null when nothing is saved.
  final double? amount;

  /// Localized suffix after the amount (`/kWh`). Null for a plain total.
  final String? unit;
}

/// What the reader typed, for the field they typed it in.
@immutable
class MoneyKeypadResult<T> {
  const MoneyKeypadResult({required this.field, required this.amount});

  final T field;

  /// The new amount, or null when the reader cleared the field.
  final double? amount;
}

/// Opens the money keypad beside [anchorContext].
///
/// The caller owns the stored value. This dialog owns only the digits while
/// its route is visible, and reports one amount when the reader confirms.
Future<void> showMoneyKeypadDialog<T>({
  required BuildContext context,
  required BuildContext anchorContext,
  required List<MoneyKeypadField<T>> fields,
  required String currencySymbol,
  required String title,
  required String description,
  required String saveLabel,
  required String clearLabel,
  required String deleteLabel,
  required String barrierLabel,
  required ValueChanged<MoneyKeypadResult<T>> onSubmitted,
  T? initialField,
  String decimalSeparator = ',',
  AnchoredTooltipSide anchorSide = AnchoredTooltipSide.auto,
  double caretAlignment = 0.5,
}) {
  return showAnchoredTooltip(
    context: context,
    anchorContext: anchorContext,
    side: anchorSide,
    caretAlignment: caretAlignment,
    barrierLabel: barrierLabel,
    tooltipBuilder: (context) => MoneyKeypadDialog<T>(
      fields: fields,
      initialField: initialField,
      currencySymbol: currencySymbol,
      title: title,
      description: description,
      saveLabel: saveLabel,
      clearLabel: clearLabel,
      deleteLabel: deleteLabel,
      decimalSeparator: decimalSeparator,
      onSubmitted: onSubmitted,
    ),
  );
}

/// Floating editor for a monetary amount.
///
/// The reader types the amount digit by digit, right to left, in the way a
/// payment terminal accepts one: each key is one more cent position, so the
/// value moves from `0,00` to `0,05` to `0,55`. There is no decimal key and no
/// caret to place, because a keyboard is not reachable while driving and a
/// free-text field would accept `1.2.3`.
///
/// Nothing is written while the digits move. The amount reaches the caller
/// only through the confirm action, since a price applied per keystroke would
/// save `9,00` on the way to `9,45`.
class MoneyKeypadDialog<T> extends StatefulWidget {
  const MoneyKeypadDialog({
    required this.fields,
    required this.currencySymbol,
    required this.title,
    required this.description,
    required this.saveLabel,
    required this.clearLabel,
    required this.deleteLabel,
    required this.onSubmitted,
    this.initialField,
    this.decimalSeparator = ',',
    super.key,
  }) : assert(fields.length > 0);

  final List<MoneyKeypadField<T>> fields;

  /// Field selected when the dialog opens. Defaults to the first one.
  final T? initialField;

  /// Localized currency symbol, supplied by the caller.
  final String currencySymbol;

  final String title;
  final String description;
  final String saveLabel;

  /// Label of the key that empties the amount.
  final String clearLabel;

  /// Label of the key that removes the last digit.
  final String deleteLabel;

  /// Localized decimal mark between units and cents.
  final String decimalSeparator;

  final ValueChanged<MoneyKeypadResult<T>> onSubmitted;

  /// Most a reader can type. Nine digits hold 9 999 999,99, which is more than
  /// any per-kWh price or charge total this app records.
  static const maxDigits = 9;

  @override
  State<MoneyKeypadDialog<T>> createState() => _MoneyKeypadDialogState<T>();
}

class _MoneyKeypadDialogState<T> extends State<MoneyKeypadDialog<T>> {
  /// Digits typed per field, in cents, most significant first.
  ///
  /// Kept per field so a reader who compares the two amounts does not lose the
  /// one they already typed.
  late final Map<T, String> _digits = {
    for (final field in widget.fields) field.value: _digitsOf(field.amount),
  };

  late T _selected = widget.initialField ?? widget.fields.first.value;

  static String _digitsOf(double? amount) {
    if (amount == null || amount <= 0) return '';
    final cents = (amount * 100).round();
    if (cents <= 0) return '';
    final text = '$cents';
    return text.length > MoneyKeypadDialog.maxDigits
        ? text.substring(0, MoneyKeypadDialog.maxDigits)
        : text;
  }

  MoneyKeypadField<T> get _field =>
      widget.fields.firstWhere((field) => field.value == _selected);

  String get _current => _digits[_selected] ?? '';

  double? get _amount {
    final digits = _current;
    if (digits.isEmpty) return null;
    return int.parse(digits) / 100;
  }

  /// The amount as the reader sees it, always with two cent positions.
  String get _display {
    final padded = _current.padLeft(3, '0');
    final units = padded.substring(0, padded.length - 2);
    final cents = padded.substring(padded.length - 2);
    return '$units${widget.decimalSeparator}$cents';
  }

  void _append(int digit) {
    final digits = _current;
    if (digits.length >= MoneyKeypadDialog.maxDigits) return;
    // A leading zero is not a digit position: it is the empty amount the
    // readout already shows.
    final next = digits.isEmpty && digit == 0 ? '' : '$digits$digit';
    setState(() => _digits[_selected] = next);
  }

  void _delete() {
    final digits = _current;
    if (digits.isEmpty) return;
    setState(() => _digits[_selected] = digits.substring(0, digits.length - 1));
  }

  void _clear() {
    if (_current.isEmpty) return;
    setState(() => _digits[_selected] = '');
  }

  void _submit() {
    widget.onSubmitted(MoneyKeypadResult<T>(field: _selected, amount: _amount));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return AnchoredTooltipSurface(
      // The keypad is the tallest floating surface in the app. On the head
      // unit it fits whole; on a shorter viewport it scrolls rather than
      // cutting a key off the bottom.
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.x6,
            AppSpacing.x6,
            AppSpacing.x6,
            AppSpacing.x5,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.title, style: AppText.cardTitle),
              const SizedBox(height: AppSpacing.x3),
              Text(
                widget.description,
                style: AppText.body.copyWith(color: colors.inkMuted),
              ),
              if (widget.fields.length > 1) ...[
                const SizedBox(height: AppSpacing.x4),
                // The segments share the panel width instead of sizing to
                // their labels: a translated pair of labels is wider than the
                // panel, and a control that sizes itself would run off it.
                LayoutBuilder(
                  builder: (context, constraints) => TrackSegmentedControl<T>(
                    segmentWidth:
                        (constraints.maxWidth - AppSpacing.x2) /
                        widget.fields.length,
                    items: [
                      for (final field in widget.fields)
                        TabItem(value: field.value, label: field.label),
                    ],
                    selected: _selected,
                    onSelected: (value) => setState(() => _selected = value),
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.x5),
              _Readout(
                key: const Key('money-keypad-readout'),
                symbol: widget.currencySymbol,
                amount: _display,
                unit: _field.unit,
              ),
              const SizedBox(height: AppSpacing.x5),
              _Keys(
                onDigit: _append,
                onClear: _clear,
                onDelete: _delete,
                clearLabel: widget.clearLabel,
                deleteLabel: widget.deleteLabel,
              ),
              const SizedBox(height: AppSpacing.x4),
              _SaveButton(
                key: const Key('money-keypad-save'),
                label: widget.saveLabel,
                onPressed: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The amount under edit: symbol, numeral, and an optional unit.
///
/// The three are separate runs so the numeral can carry the weight while the
/// symbol and the unit stay quiet, the same split [MetricValue] makes.
class _Readout extends StatelessWidget {
  const _Readout({
    required this.symbol,
    required this.amount,
    required this.unit,
    super.key,
  });

  final String symbol;
  final String amount;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final unit = this.unit;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.x5,
        vertical: AppSpacing.x4,
      ),
      decoration: BoxDecoration(
        color: colors.control,
        borderRadius: AppRadii.mdRadius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(symbol, style: AppText.unitLg.copyWith(color: colors.inkMuted)),
          const SizedBox(width: AppSpacing.x2),
          Expanded(
            child: Text(
              amount,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: AppText.metricLg.copyWith(color: colors.ink),
            ),
          ),
          if (unit != null) ...[
            const SizedBox(width: AppSpacing.x2),
            Text(unit, style: AppText.unitLg.copyWith(color: colors.inkSubtle)),
          ],
        ],
      ),
    );
  }
}

/// The 3 x 4 keypad: 1 to 9, then clear, 0, and delete.
///
/// The digit order is the telephone order the reader already knows from every
/// keypad in the car, not the calculator order.
class _Keys extends StatelessWidget {
  const _Keys({
    required this.onDigit,
    required this.onClear,
    required this.onDelete,
    required this.clearLabel,
    required this.deleteLabel,
  });

  final ValueChanged<int> onDigit;
  final VoidCallback onClear;
  final VoidCallback onDelete;
  final String clearLabel;
  final String deleteLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var row = 0; row < 3; row++) ...[
          if (row > 0) const SizedBox(height: AppSpacing.x2),
          _Row(
            children: [
              for (var column = 1; column <= 3; column++)
                _DigitKey(
                  digit: row * 3 + column,
                  onPressed: () => onDigit(row * 3 + column),
                ),
            ],
          ),
        ],
        const SizedBox(height: AppSpacing.x2),
        _Row(
          children: [
            _IconKey(
              key: const Key('money-keypad-clear'),
              icon: Icons.clear,
              label: clearLabel,
              onPressed: onClear,
            ),
            _DigitKey(digit: 0, onPressed: () => onDigit(0)),
            _IconKey(
              key: const Key('money-keypad-delete'),
              icon: Icons.backspace_outlined,
              label: deleteLabel,
              onPressed: onDelete,
            ),
          ],
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var index = 0; index < children.length; index++) ...[
          if (index > 0) const SizedBox(width: AppSpacing.x2),
          Expanded(child: children[index]),
        ],
      ],
    );
  }
}

class _DigitKey extends StatelessWidget {
  const _DigitKey({required this.digit, required this.onPressed});

  final int digit;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return _Key(
      keyLabel: '$digit',
      onPressed: onPressed,
      child: Text(
        '$digit',
        style: AppText.metricSm.copyWith(color: colors.ink),
      ),
    );
  }
}

class _IconKey extends StatelessWidget {
  const _IconKey({
    required this.icon,
    required this.label,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return _Key(
      keyLabel: label,
      onPressed: onPressed,
      child: Icon(icon, size: AppSizes.iconMd, color: colors.inkMuted),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({
    required this.keyLabel,
    required this.onPressed,
    required this.child,
  });

  final String keyLabel;
  final VoidCallback onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Semantics(
      button: true,
      label: keyLabel,
      child: Material(
        color: colors.control,
        borderRadius: AppRadii.mdRadius,
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            onPressed();
          },
          borderRadius: AppRadii.mdRadius,
          child: SizedBox(
            height: AppSizes.moneyKeypadKeyHeight,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

class _SaveButton extends StatelessWidget {
  const _SaveButton({required this.label, required this.onPressed, super.key});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: colors.selectionFill,
        borderRadius: AppRadii.mdRadius,
        child: InkWell(
          onTap: onPressed,
          borderRadius: AppRadii.mdRadius,
          child: SizedBox(
            height: AppSizes.actionRowHeight,
            width: double.infinity,
            child: Center(
              child: Text(
                label,
                style: AppText.bodyStrong.copyWith(color: colors.onSelection),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
