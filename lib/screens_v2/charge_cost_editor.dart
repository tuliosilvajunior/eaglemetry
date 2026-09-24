import 'package:flutter/material.dart';

import '../core/telemetry_api.dart';
import '../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';

/// The two amounts a charge can be priced by.
///
/// They are alternatives, not a pair: a rate is multiplied by the energy the
/// charge delivered, while a total is the figure on the receipt and answers
/// for the whole session. `chargeEstimatedCost` prefers the total when one is
/// present, so the reader picks which of the two the footer states.
enum ChargeCostField { rate, total }

/// The keypad's fields for one charge, in reading order.
///
/// Shared, and not built at each call site: the charging screen and the
/// history detail price the same column of the same table, so a difference
/// between the two — a default offered on one screen and not the other, a
/// field missing its unit — would be a difference in what the reader is
/// allowed to type, not a difference in looks.
List<MoneyKeypadField<ChargeCostField>> chargeCostKeypadFields({
  required AppLocalizations loc,
  required SessionRecord session,
  required double? defaultCostPerKwh,
}) => [
  MoneyKeypadField(
    value: ChargeCostField.rate,
    label: loc.v2ChargeCostFieldRate,
    // The default is offered as the starting point of an unpriced charge, so
    // the reader corrects a figure instead of typing one from nothing. It is
    // not saved until they confirm it.
    amount: session.costPerKwh ?? defaultCostPerKwh,
    unit: loc.v2ChargeCostUnitRate,
  ),
  MoneyKeypadField(
    value: ChargeCostField.total,
    label: loc.v2ChargeCostFieldTotal,
    amount: session.paidAmount,
  ),
];

/// Which field the keypad opens on: the receipt when there is one.
ChargeCostField initialChargeCostField(SessionRecord session) =>
    session.paidAmount == null ? ChargeCostField.rate : ChargeCostField.total;

/// The currency this session is priced in, or the app default when it has
/// never been priced.
String chargeCostCurrencyOf(SessionRecord session, {required String fallback}) {
  final currency = session.costCurrency;
  return currency == null || currency.isEmpty ? fallback : currency;
}

/// Writes the price of one charge, and only that charge.
///
/// The collector writes both cost columns in one statement, so the field the
/// reader did not type is sent back as it stands. Sending only the edited one
/// would clear the other.
///
/// Returns null when nothing was written, so the caller can say so. Otherwise
/// the reply carries the priced session, which is the fresher answer than the
/// list row the caller is holding. Pricing a charge is also a session change,
/// so a caller that reads through a query is refreshed by the event rather
/// than from here.
Future<ChargeSessionCostUpdateResult?> writeChargeCost({
  required TelemetryApi api,
  required SessionRecord session,
  required MoneyKeypadResult<ChargeCostField> result,
  required String fallbackCurrency,
}) async {
  try {
    return await api.updateChargeSessionCost(
      sessionId: session.id,
      costPerKwh: result.field == ChargeCostField.rate
          ? result.amount
          : session.costPerKwh,
      paidAmount: result.field == ChargeCostField.total
          ? result.amount
          : session.paidAmount,
      currency: chargeCostCurrencyOf(session, fallback: fallbackCurrency),
    );
  } catch (_) {
    // The stored price stands. The caller states that nothing was written.
    return null;
  }
}

/// Opens the money keypad for one charge, anchored at [anchorContext].
///
/// For a surface that has no stat of its own to press — a mosaic tile, a list
/// row. A footer stat uses [ChargeCostStat], which is this same keypad with
/// the pressable reading attached to it.
Future<void> showChargeCostKeypad({
  required BuildContext context,
  required BuildContext anchorContext,
  required SessionRecord session,
  required double? defaultCostPerKwh,
  required String currencySymbol,
  required ValueChanged<MoneyKeypadResult<ChargeCostField>> onSubmitted,
  AnchoredTooltipSide side = AnchoredTooltipSide.auto,
}) {
  final loc = AppLocalizations.of(context)!;
  return showMoneyKeypadDialog<ChargeCostField>(
    context: context,
    anchorContext: anchorContext,
    anchorSide: side,
    fields: chargeCostKeypadFields(
      loc: loc,
      session: session,
      defaultCostPerKwh: defaultCostPerKwh,
    ),
    initialField: initialChargeCostField(session),
    currencySymbol: currencySymbol,
    decimalSeparator: chargeDecimalSeparatorForLocale(loc.localeName),
    title: loc.v2ChargeCostTitle,
    description: loc.v2ChargeCostDescription,
    saveLabel: loc.v2MoneyKeypadSave,
    clearLabel: loc.v2MoneyKeypadClear,
    deleteLabel: loc.v2MoneyKeypadDelete,
    barrierLabel: loc.v2MoneyKeypadClose,
    onSubmitted: onSubmitted,
  );
}

/// The cost stat, and the keypad that prices this charge.
///
/// It is the one stat in a footer that the reader can change, so it sits on a
/// `control` step with a pencil while the readings beside it stay plain. The
/// price it writes belongs to this session alone; the default in Settings is
/// what an unpriced charge falls back to.
class ChargeCostStat extends StatelessWidget {
  const ChargeCostStat({
    required this.session,
    required this.defaultCostPerKwh,
    required this.cost,
    required this.symbol,
    required this.saving,
    required this.onCostChanged,
    super.key,
  });

  final SessionRecord session;
  final double? defaultCostPerKwh;

  /// The amount the stat prints, already chosen between receipt and rate.
  final double? cost;

  final String symbol;

  /// True while a price write is in flight. The keypad stays shut until the
  /// collector has answered, so two prices cannot race for one session.
  final bool saving;

  final ValueChanged<MoneyKeypadResult<ChargeCostField>> onCostChanged;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final separator = chargeDecimalSeparatorForLocale(loc.localeName);
    return AnchoredTooltipTrigger(
      side: AnchoredTooltipSide.left,
      barrierLabel: loc.v2MoneyKeypadClose,
      tooltipBuilder: (context) => MoneyKeypadDialog<ChargeCostField>(
        fields: chargeCostKeypadFields(
          loc: loc,
          session: session,
          defaultCostPerKwh: defaultCostPerKwh,
        ),
        initialField: initialChargeCostField(session),
        currencySymbol: symbol,
        decimalSeparator: separator,
        title: loc.v2ChargeCostTitle,
        description: loc.v2ChargeCostDescription,
        saveLabel: loc.v2MoneyKeypadSave,
        clearLabel: loc.v2MoneyKeypadClear,
        deleteLabel: loc.v2MoneyKeypadDelete,
        onSubmitted: onCostChanged,
      ),
      builder: (context, isOpen, open) => StatColumn(
        value: chargeAmountLabel(
          cost,
          symbol: symbol,
          decimalSeparator: separator,
        ),
        caption: loc.v2ChargeGraphCostEstimate,
        editLabel: loc.v2ChargeCostEdit,
        onPressed: saving ? null : open,
      ),
    );
  }
}
