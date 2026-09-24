import 'dart:math' as math;

/// The three ways this app can print a driving-efficiency number.
///
/// All three describe the same ratio. [kmPerKwh] is distance per energy,
/// which is the question a driver asks at the end of a drive; the other two
/// are energy per a fixed distance, the consumption framing familiar from
/// fuel-economy labels. The reader picks one with the host's controller;
/// nothing in the app assumes a fixed choice any more.
enum EfficiencyUnit { kmPerKwh, kwhPer50km, kwhPer100km }

/// Formats a km/kWh reading in whichever [unit] the reader chose.
///
/// km/kWh is the canonical base because that is what the efficiency series
/// and the range estimate already carry. A negative ratio is clamped to zero
/// the same way [EfficiencyPoint] treats it — a car cannot travel a negative
/// distance on the energy it drew — and zero or null both print as `--` for
/// the two consumption units, since dividing a fixed distance by zero
/// distance-per-energy is not a reading, it is an asymptote.
String formatEfficiencyForUnit(double? kmPerKwh, EfficiencyUnit unit) {
  if (kmPerKwh == null || !kmPerKwh.isFinite) return '--';
  final value = math.max(0.0, kmPerKwh);
  switch (unit) {
    case EfficiencyUnit.kmPerKwh:
      return _roundedForDisplay(value);
    case EfficiencyUnit.kwhPer50km:
      if (value <= 0) return '--';
      return _roundedForDisplay(50 / value);
    case EfficiencyUnit.kwhPer100km:
      if (value <= 0) return '--';
      return _roundedForDisplay(100 / value);
  }
}

/// Same conversion, starting from Wh/km — the base the session, trip and
/// history rows already carry — instead of km/kWh.
String formatEfficiencyWhPerKmForUnit(double? whPerKm, EfficiencyUnit unit) {
  if (whPerKm == null || !whPerKm.isFinite || whPerKm <= 0) return '--';
  return formatEfficiencyForUnit(1000 / whPerKm, unit);
}

/// Two decimals below ten, one above: matches `formatEfficiency` in
/// `efficiency_chart.dart`, so a value does not change its own precision
/// convention when the reader switches unit.
String _roundedForDisplay(double value) {
  return value < 10 ? value.toStringAsFixed(2) : value.toStringAsFixed(1);
}
