import 'package:flutter/foundation.dart';
import 'package:capy_ui/capy_ui.dart';

import 'efficiency_unit.dart';
import 'telemetry_api.dart';
import 'theme_controller.dart';

/// Syncs the account-scope preferences between the car and its phones.
///
/// The preference rows are the wire; the car's controllers are the truth a
/// person sees. This object is the hinge: when an annotation arrives that
/// names a theme or an efficiency unit, it applies it to the controllers,
/// and when the person changes either on the car, it writes the row so the
/// phone's next pull carries it.
///
/// A value this car does not know is skipped, never written back: the car
/// keeps its own choice and the row survives for the side that can draw it.
class PreferenceSyncController extends ChangeNotifier {
  PreferenceSyncController._();

  static final PreferenceSyncController instance = PreferenceSyncController._();

  TelemetryApi? _api;
  bool _started = false;

  /// True while [start]'s application loop is inside a row-apply, so the
  /// controller notifications it caused do not write the same value back.
  bool _applying = false;

  Future<void> start(TelemetryApi api) async {
    if (_started) return;
    _started = true;
    _api = api;
    await _applyPreferences();
    await _writeCurrentRows();
    api.annotationsChanged().listen((change) {
      if (change.preferences) _applyPreferences();
    });
    ThemeController.instance.addListener(_onThemeChanged);
    EfficiencyUnitController.instance.addListener(_onUnitChanged);
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    ThemeController.instance.removeListener(_onThemeChanged);
    EfficiencyUnitController.instance.removeListener(_onUnitChanged);
    _api = null;
  }

  void _onThemeChanged() {
    if (_applying) return;
    _writeThemeRow();
  }

  void _onUnitChanged() {
    if (_applying) return;
    _writeUnitRow();
  }

  Future<void> _applyPreferences() async {
    final api = _api;
    if (api == null) return;
    _applying = true;
    try {
      final rows = await api.getPreferenceRows();
      for (final row in rows) {
        if (row.scope != kPreferenceScopeAccount || row.deleted) continue;
        if (row.key == 'theme_id') {
          final id = appThemeIdFromName(row.value);
          if (id != null && id != ThemeController.instance.themeId) {
            await ThemeController.instance.setThemeId(id);
          }
        } else if (row.key == 'efficiency_unit') {
          EfficiencyUnit? unit;
          for (final candidate in EfficiencyUnit.values) {
            if (candidate.name == row.value) unit = candidate;
          }
          if (unit != null && unit != EfficiencyUnitController.instance.unit) {
            await EfficiencyUnitController.instance.setUnit(unit);
          }
        }
      }
    } on Exception {
      // A preference that cannot be read leaves the car on its own choice,
      // which is the standing rule: an unknown value renders as the default
      // and must not overwrite the stored one.
    } finally {
      _applying = false;
    }
  }

  Future<void> _writeCurrentRows() async {
    await _writeThemeRow();
    await _writeUnitRow();
  }

  Future<void> _writeThemeRow() async {
    final api = _api;
    if (api == null) return;
    try {
      await api.savePreferenceRow(
        scope: kPreferenceScopeAccount,
        key: 'theme_id',
        value: ThemeController.instance.themeId.name,
      );
    } on Exception {
      // The row is best-effort; the car's controller remains the truth.
    }
  }

  Future<void> _writeUnitRow() async {
    final api = _api;
    if (api == null) return;
    try {
      await api.savePreferenceRow(
        scope: kPreferenceScopeAccount,
        key: 'efficiency_unit',
        value: EfficiencyUnitController.instance.unit.name,
      );
    } on Exception {
      // Same as the theme row.
    }
  }
}
