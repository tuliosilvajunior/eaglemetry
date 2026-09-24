import 'package:capy_ui/capy_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme_controller.dart';

/// Car adapter over [ThemeController]/SharedPreferences.
///
/// Preserves the car default `dark` until issue 136 decides. The body stays
/// agnostic; this adapter is the only place that knows about
/// `SharedPreferences` and the legacy `theme_mode` key.
class CarSettingsSource extends SettingsSource {
  CarSettingsSource({ThemeController? controller})
    : _controller = controller ?? ThemeController.instance {
    _controller.addListener(_onChanged);
    _loadReduceMotion();
  }

  final ThemeController _controller;

  static const _reduceMotionKey = 'reduce_motion';

  bool _reduceMotion = false;

  @override
  AppThemeId get themeId => _controller.themeId;

  @override
  bool get reduceMotion => _reduceMotion;

  @override
  Future<void> setThemeId(AppThemeId id) => _controller.setThemeId(id);

  @override
  Future<void> setReduceMotion(bool value) async {
    if (_reduceMotion == value) return;
    _reduceMotion = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_reduceMotionKey, value);
  }

  Future<void> _loadReduceMotion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getBool(_reduceMotionKey);
      if (stored != null && stored != _reduceMotion) {
        _reduceMotion = stored;
        notifyListeners();
      }
    } catch (_) {
      // Keep default; persistence is best-effort on head unit.
    }
  }

  void _onChanged() => notifyListeners();

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    super.dispose();
  }
}
