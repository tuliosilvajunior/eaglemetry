import 'package:flutter/foundation.dart';

import '../tokens/app_palettes.dart';

/// Abstract source of the theme selection.
///
/// Implemented by a car adapter over [ThemeController]/SharedPreferences
/// and a phone adapter over [CompanionThemeController]/Archive.
/// The body never reads those stores directly.
abstract class SettingsSource extends ChangeNotifier {
  AppThemeId get themeId;

  bool get reduceMotion;

  Future<void> setThemeId(AppThemeId id);

  Future<void> setReduceMotion(bool value);
}
