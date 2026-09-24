import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:capy_ui/capy_ui.dart';

/// The one place that decides which theme the app wears.
///
/// The v2 journey picks from the whole [AppThemeId] catalogue. [themeMode] is
/// derived from the chosen theme's brightness, so callers that only need to
/// know "dark or light" — `MaterialApp.themeMode`, the settings backup — keep
/// working without knowing the catalogue exists.
class ThemeController extends ChangeNotifier {
  ThemeController._();

  static final ThemeController instance = ThemeController._();

  /// The pre-catalogue key. Still read, so an existing install keeps the
  /// theme it was left on, and still written, so a downgrade finds it.
  static const _themeModeKey = 'theme_mode';

  static const _themeIdKey = 'theme_id';

  static const _launchBgColorKey = 'launch_bg_color';

  AppThemeId _themeId = AppThemeId.dark;

  AppThemeId get themeId => _themeId;

  AppThemeSpec get spec => appThemeSpec(_themeId);

  ThemeMode get themeMode => spec.isDark ? ThemeMode.dark : ThemeMode.light;

  bool get isDark => spec.isDark;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = appThemeIdFromName(prefs.getString(_themeIdKey));
    _themeId = stored ?? _themeIdFromMode(prefs.getString(_themeModeKey));
    await prefs.setString(_launchBgColorKey, appThemeCanvasHex(_themeId));
  }

  Future<void> setThemeId(AppThemeId id) async {
    if (_themeId == id) return;
    _themeId = id;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeIdKey, id.name);
    await prefs.setString(_themeModeKey, themeMode.name);
    await prefs.setString(_launchBgColorKey, appThemeCanvasHex(id));
  }

  /// Sets the theme by brightness alone. Kept for the settings restore path,
  /// which carries a mode rather than an id.
  Future<void> setThemeMode(ThemeMode mode) =>
      setThemeId(mode == ThemeMode.light ? AppThemeId.light : AppThemeId.dark);

  static AppThemeId _themeIdFromMode(String? name) =>
      name == 'light' ? AppThemeId.light : AppThemeId.dark;
}
