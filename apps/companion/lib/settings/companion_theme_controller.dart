import 'dart:async';

import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../sync/companion_archive.dart';

/// The theme this phone draws with, and the row that carries it to the car.
///
/// It is stored as the account-scope `theme_id` preference rather than in a
/// store of its own. That key already syncs both ways — `kSyncedPreferenceKeys`
/// names it — so a choice made here reaches the car by the route the
/// annotation channel already has, and a choice made on the car reaches the
/// phone the same way. A second local store would be a second answer to one
/// question, and the two would disagree the first time one of them was
/// written alone.
///
/// The mode is **not** a second choice. `packages/capy_ui/DESIGN.md` derives
/// it from the chosen theme's brightness: picking `midnight` is picking dark.
class CompanionThemeController extends ChangeNotifier {
  CompanionThemeController(this.archive);

  /// Absent in a test that draws the screen without a database. The picker
  /// then still works for the session and persists nothing.
  final CompanionArchive? archive;

  static const String preferenceKey = 'theme_id';
  static const String launchBgColorKey = 'launch_bg_color';

  AppThemeId _themeId = AppThemeId.light;

  AppThemeId get themeId => _themeId;

  /// The brightness Material builds against, taken from the theme itself.
  ThemeMode get themeMode =>
      appThemeSpec(_themeId).isDark ? ThemeMode.dark : ThemeMode.light;

  void _syncNativeLaunchColor(AppThemeId id) {
    unawaited(
      SharedPreferences.getInstance()
          .then((prefs) {
            prefs.setString(launchBgColorKey, appThemeCanvasHex(id));
          })
          .catchError((_) {
            // Ignored in tests or platforms where SharedPreferences is unavailable.
          }),
    );
  }

  /// Reads the stored row. An unknown id renders as the default and keeps the
  /// stored value, which is the standing rule for this channel: a phone that
  /// does not know a theme the car chose must not overwrite the car's choice.
  Future<void> load() async {
    final store = archive;
    if (store == null) return;
    final rows = await store.database.allPreferences();
    for (final row in rows) {
      if (row['scope'] != kPreferenceScopeAccount) continue;
      if (row['key'] != preferenceKey) continue;
      if (row['deletedAtUtcMillis'] != null) continue;
      final id = appThemeIdFromName(row['value'] as String?);
      if (id != null && id != _themeId) {
        _themeId = id;
        notifyListeners();
      }
      _syncNativeLaunchColor(_themeId);
      return;
    }
    _syncNativeLaunchColor(_themeId);
  }

  /// Applies a row that arrived from the car. It does not write one back: the
  /// pull already merged it, and answering a pull with a push would send the
  /// car its own row.
  void applyStoredValue(String? value) {
    final id = appThemeIdFromName(value);
    if (id == null || id == _themeId) return;
    _themeId = id;
    notifyListeners();
    _syncNativeLaunchColor(_themeId);
  }

  /// The reader chose. The row is merged locally with the same last-writer-wins
  /// rule the pull uses, then queued for the car.
  Future<void> select(AppThemeId id) async {
    if (id == _themeId) return;
    _themeId = id;
    notifyListeners();
    _syncNativeLaunchColor(id);

    final store = archive;
    if (store == null) return;
    final row = <String, Object?>{
      'scope': kPreferenceScopeAccount,
      'key': preferenceKey,
      'value': id.name,
      'updatedAtUtcMillis': DateTime.now().millisecondsSinceEpoch,
      'origin': kAnnotationOriginPhone,
      'deletedAtUtcMillis': null,
    };
    await store.upsertPreference(row);
    await store.database.enqueueAnnotationPush(
      SyncStreamType.preferences.name,
      row,
    );
  }
}
