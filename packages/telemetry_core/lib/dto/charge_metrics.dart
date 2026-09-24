part of 'telemetry_dto.dart';

/// Explicit charge power, falling back to |V x I| when absent.
double? chargeFramePowerKw(TelemetryFrame frame) {
  final explicitPower = frame.powerKw?.abs();
  final derivedPower = frame.voltageV != null && frame.currentA != null
      ? frame.voltageV! * frame.currentA!.abs() / 1000
      : null;
  return explicitPower ?? derivedPower;
}

/// Highest instantaneous charge power in the session.
///
/// The average alone hides what the session was capable of: an 80 kW DC leg
/// that tapered to 12 kW averages out looking like a slow charge.
double? chargePeakPowerKw(List<TelemetryFrame> frames) {
  double? peak;
  for (final frame in frames) {
    final power = chargeFramePowerKw(frame)?.abs();
    if (power == null) continue;
    if (peak == null || power > peak) peak = power;
  }
  return peak;
}

double? chargeAveragePowerKw(List<TelemetryFrame> frames) {
  final powers = [
    for (final frame in frames)
      if (chargeFramePowerKw(frame) != null) chargeFramePowerKw(frame)!.abs(),
  ];
  if (powers.isEmpty) return null;
  return powers.reduce((left, right) => left + right) / powers.length;
}

double? chargeEstimatedCost({
  required double? energyKwh,
  required double? costPerKwh,
  required double? paidAmount,
}) {
  if (paidAmount != null && paidAmount >= 0) return paidAmount;
  if (energyKwh == null || costPerKwh == null) return null;
  if (energyKwh < 0 || costPerKwh < 0) return null;
  return energyKwh * costPerKwh;
}

String chargeCostLabel({
  required double? energyKwh,
  required double? costPerKwh,
  required double? paidAmount,
  required String currency,
  String? localeName,
}) {
  final cost = chargeEstimatedCost(
    energyKwh: energyKwh,
    costPerKwh: costPerKwh,
    paidAmount: paidAmount,
  );
  if (cost == null) return '--';
  final symbol = chargeCurrencySymbolForLocale(
    localeName,
    fallbackCurrency: currency,
  );
  return '$symbol ${cost.toStringAsFixed(2)}';
}

/// Mark between units and cents in the reader's locale.
///
/// The money keypad prints the amount itself, digit by digit, so it needs the
/// separator alone rather than a formatted string.
String chargeDecimalSeparatorForLocale(String? localeName) {
  final locale = (localeName ?? '').toLowerCase();
  return locale.startsWith('en') ? '.' : ',';
}

/// An amount as the money keypad shows it: symbol, units, and two cents.
String chargeAmountLabel(
  double? amount, {
  required String symbol,
  required String decimalSeparator,
}) {
  if (amount == null) return '--';
  final text = amount.toStringAsFixed(2).replaceFirst('.', decimalSeparator);
  return '$symbol $text';
}

String chargeCurrencySymbolForLocale(
  String? localeName, {
  String fallbackCurrency = 'BRL',
}) {
  final locale = (localeName ?? '').toLowerCase();
  if (locale.startsWith('pt')) return 'R\$';
  if (locale.startsWith('ru')) return '₽';
  if (locale.startsWith('en')) return '\$';
  if (locale.startsWith('es')) return '\$';

  switch (fallbackCurrency.toUpperCase()) {
    case 'BRL':
      return 'R\$';
    case 'RUB':
      return '₽';
    case 'USD':
      return '\$';
    default:
      return fallbackCurrency;
  }
}
