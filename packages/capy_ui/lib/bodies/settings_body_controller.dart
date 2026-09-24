import 'package:flutter/foundation.dart';

import '../tokens/app_palettes.dart';
import 'settings_source.dart';

/// View model beside [SettingsBody].
///
/// Depends on an injected [SettingsSource] and exposes theme state plus
/// [onThemeChanged] as pure intents. The body reads [themeId] and calls
/// [setThemeId]; the controller persists via the source and notifies
/// listeners when the source changes.
class SettingsBodyController extends ChangeNotifier {
  SettingsBodyController({required this.source}) {
    source.addListener(_onSourceChanged);
  }

  final SettingsSource source;

  AppThemeId get themeId => source.themeId;

  bool get reduceMotion => source.reduceMotion;

  Future<void> setThemeId(AppThemeId id) => source.setThemeId(id);

  Future<void> setReduceMotion(bool value) => source.setReduceMotion(value);

  /// Alias for the body to pass as `onThemeChanged`.
  Future<void> onThemeChanged(AppThemeId id) => setThemeId(id);

  /// Alias for the body to pass as `onReduceMotionChanged`.
  Future<void> onReduceMotionChanged(bool value) => setReduceMotion(value);

  void _onSourceChanged() => notifyListeners();

  @override
  void dispose() {
    source.removeListener(_onSourceChanged);
    super.dispose();
  }
}
