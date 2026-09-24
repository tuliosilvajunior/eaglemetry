import 'recent_efficiency.dart';

/// Plausible span for measured trip efficiency, in km/kWh.
///
/// Below this a reading is a stalled-odometer artifact; above it the trip
/// distance or energy is wrong by an order of magnitude. The native range
/// estimate applies the same bounds to the closed-trip aggregate.
const _minEfficiencyKmPerKwh = 0.5;
const _maxEfficiencyKmPerKwh = 20.0;

/// Recent measured efficiency, or null when it is missing or implausible.
///
/// Every range figure on a screen must pass through this, so a reading that is
/// untrustworthy in one panel cannot appear as a confident number in another.
double? plausibleEfficiencyKmPerKwh(RecentTripEfficiency? history) {
  if (history == null || history.tripCount < 1) return null;
  final efficiency = history.averageEfficiencyKmPerKwh;
  if (efficiency == null ||
      !efficiency.isFinite ||
      efficiency < _minEfficiencyKmPerKwh ||
      efficiency > _maxEfficiencyKmPerKwh) {
    return null;
  }
  return efficiency;
}

/// Estimates the range a measured amount of delivered energy buys.
///
/// Shares [plausibleEfficiencyKmPerKwh] with the graph footer's range-gain
/// column, so a screen cannot show `--` for remaining range while presenting a
/// confident range gain derived from the same suspect efficiency.
double? estimateRangeGainKm({
  required RecentTripEfficiency? history,
  required double? energyKwh,
}) {
  final efficiency = plausibleEfficiencyKmPerKwh(history);
  if (efficiency == null ||
      energyKwh == null ||
      !energyKwh.isFinite ||
      energyKwh < 0) {
    return null;
  }
  return energyKwh * efficiency;
}
