import 'package:capy_ui/capy_ui.dart';
import 'package:telemetry_core/telemetry_core.dart';

import 'companion_theme_controller.dart';

/// Phone adapter over [CompanionThemeController]/Archive.
///
/// Preserves the companion default `light` until issue 136 decides. The
/// `theme_id` row syncs both ways via [kPreferenceScopeAccount], so a choice
/// made here reaches the car by the annotation channel the companion already
/// has.
class CompanionSettingsSource extends SettingsSource {
  CompanionSettingsSource(this._controller) {
    _controller.addListener(_onChanged);
    _loadReduceMotion();
  }

  final CompanionThemeController _controller;

  static const String reduceMotionKey = 'reduce_motion';

  bool _reduceMotion = false;

  @override
  AppThemeId get themeId => _controller.themeId;

  @override
  bool get reduceMotion => _reduceMotion;

  @override
  Future<void> setThemeId(AppThemeId id) => _controller.select(id);

  @override
  Future<void> setReduceMotion(bool value) async {
    if (_reduceMotion == value) return;
    _reduceMotion = value;
    notifyListeners();

    final archive = _controller.archive;
    if (archive == null) return;
    final row = <String, Object?>{
      'scope': kPreferenceScopeAccount,
      'key': reduceMotionKey,
      'value': value.toString(),
      'updatedAtUtcMillis': DateTime.now().millisecondsSinceEpoch,
      'origin': kAnnotationOriginPhone,
      'deletedAtUtcMillis': null,
    };
    await archive.upsertPreference(row);
    await archive.database.enqueueAnnotationPush(
      SyncStreamType.preferences.name,
      row,
    );
  }

  Future<void> _loadReduceMotion() async {
    final archive = _controller.archive;
    if (archive == null) return;
    try {
      final rows = await archive.database.allPreferences();
      for (final row in rows) {
        if (row['scope'] != kPreferenceScopeAccount) continue;
        if (row['key'] != reduceMotionKey) continue;
        if (row['deletedAtUtcMillis'] != null) continue;
        final raw = row['value'] as String?;
        if (raw == null) return;
        final parsed = raw.toLowerCase() == 'true';
        if (parsed != _reduceMotion) {
          _reduceMotion = parsed;
          notifyListeners();
        }
        return;
      }
    } catch (_) {
      // Keep default; archive may not be ready yet.
    }
  }

  void _onChanged() => notifyListeners();

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    super.dispose();
  }
}
