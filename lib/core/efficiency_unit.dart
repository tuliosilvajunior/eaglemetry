import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../l10n/app_localizations.dart';

export 'package:telemetry_core/telemetry_core.dart'
    show
        EfficiencyUnit,
        formatEfficiencyForUnit,
        formatEfficiencyWhPerKmForUnit;

/// Persisted, app-wide choice of [EfficiencyUnit].
///
/// Same shape as `ThemeController`: a singleton `ChangeNotifier` loaded once
/// at startup and written back to `SharedPreferences` on every change, so a
/// widget depends on it the same way it depends on the theme.
class EfficiencyUnitController extends ChangeNotifier {
  EfficiencyUnitController._();

  static final EfficiencyUnitController instance = EfficiencyUnitController._();

  static const _unitKey = 'efficiency_unit';

  EfficiencyUnit _unit = EfficiencyUnit.kmPerKwh;

  EfficiencyUnit get unit => _unit;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _unit = _unitFromName(prefs.getString(_unitKey));
  }

  /// Steps to the next unit in declaration order, wrapping around. This is
  /// the whole of the "press of a button" toggle — every tap target in the
  /// app calls this one method rather than picking a unit itself.
  Future<void> cycle() => setUnit(
    EfficiencyUnit.values[(_unit.index + 1) % EfficiencyUnit.values.length],
  );

  Future<void> setUnit(EfficiencyUnit unit) async {
    if (_unit == unit) return;
    _unit = unit;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_unitKey, unit.name);
  }

  static EfficiencyUnit _unitFromName(String? name) {
    for (final candidate in EfficiencyUnit.values) {
      if (candidate.name == name) return candidate;
    }
    return EfficiencyUnit.kmPerKwh;
  }
}

/// The localized unit suffix a reading in [unit] is printed with.
///
/// Goes through [loc] rather than a fixed string: `km/kWh` is spelled the
/// same across the three shipped locales, but its two consumption siblings
/// are not — Russian abbreviates kWh as `кВт·ч`, the same way
/// `loc.unitKmPerKwh` already did for the single unit this app offered
/// before.
String efficiencyUnitSuffix(EfficiencyUnit unit, AppLocalizations loc) {
  switch (unit) {
    case EfficiencyUnit.kmPerKwh:
      return loc.unitKmPerKwh;
    case EfficiencyUnit.kwhPer50km:
      return loc.unitKwhPer50km;
    case EfficiencyUnit.kwhPer100km:
      return loc.unitKwhPer100km;
  }
}
