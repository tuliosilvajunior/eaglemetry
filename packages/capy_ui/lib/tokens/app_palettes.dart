import 'package:flutter/material.dart';

import 'app_colors.dart';

/// The themes the v2 journey can open with.
///
/// A theme is one [AppThemeColors] value plus the [Brightness] that Material
/// needs for its own defaults. Nothing else varies: the energy ramp (green and
/// amber) stays in [AppColors] and is the same in every theme, because the
/// bars mean *spent* and *recovered* and that meaning must not move with a
/// preference.
///
/// To add a theme, add one value to [AppThemeId] and one case to [palettes].
/// The picker in the settings Displays pane reads [AppThemeId.values], so it
/// grows on its own. The only other obligation is the localized name, which
/// [appThemeName] resolves — a theme with no key falls back to its id, so a new
/// theme is visible before its translations land instead of crashing.
enum AppThemeId {
  /// The off-white service view. The reference light direction.
  light,

  /// Blue-petrol cabin view, taken from the in-vehicle reference.
  dark,

  /// Near-black cabin view for night driving on an OLED panel.
  midnight,

  /// Warm paper. A light view with the blue taken out for long daylight use.
  sepia,

  /// Cool slate. A dark view that reads colder than [dark].
  nordic,

  /// Maximum separation between content and background, for direct sunlight.
  daylight,

  // The expressive themes. They state their own energy ramp, so the charts
  // change hue with them; the six above all keep the reference green and
  // amber. `gain` and `draw` never swap roles, whatever the hues are.

  /// Cyan and magenta on near-black violet.
  tokyoNeon,

  /// Mint and coral on deep plum.
  sunsetDrive,

  /// Turquoise and raspberry on pink paper.
  bubblegum,
}

/// One theme: its neutral palette and the brightness Material builds against.
@immutable
class AppThemeSpec {
  const AppThemeSpec({
    required this.id,
    required this.brightness,
    required this.colors,
  });

  final AppThemeId id;
  final Brightness brightness;
  final AppThemeColors colors;

  bool get isDark => brightness == Brightness.dark;
}

/// Every theme, keyed by id. Iteration order follows [AppThemeId].
const Map<AppThemeId, AppThemeSpec> palettes = <AppThemeId, AppThemeSpec>{
  AppThemeId.light: AppThemeSpec(
    id: AppThemeId.light,
    brightness: Brightness.light,
    colors: AppThemeColors.light,
  ),
  AppThemeId.dark: AppThemeSpec(
    id: AppThemeId.dark,
    brightness: Brightness.dark,
    colors: AppThemeColors.dark,
  ),
  AppThemeId.midnight: AppThemeSpec(
    id: AppThemeId.midnight,
    brightness: Brightness.dark,
    colors: AppThemeColors.midnight,
  ),
  AppThemeId.sepia: AppThemeSpec(
    id: AppThemeId.sepia,
    brightness: Brightness.light,
    colors: AppThemeColors.sepia,
  ),
  AppThemeId.nordic: AppThemeSpec(
    id: AppThemeId.nordic,
    brightness: Brightness.dark,
    colors: AppThemeColors.nordic,
  ),
  AppThemeId.daylight: AppThemeSpec(
    id: AppThemeId.daylight,
    brightness: Brightness.light,
    colors: AppThemeColors.daylight,
  ),
  AppThemeId.tokyoNeon: AppThemeSpec(
    id: AppThemeId.tokyoNeon,
    brightness: Brightness.dark,
    colors: AppThemeColors.tokyoNeon,
  ),
  AppThemeId.sunsetDrive: AppThemeSpec(
    id: AppThemeId.sunsetDrive,
    brightness: Brightness.dark,
    colors: AppThemeColors.sunsetDrive,
  ),
  AppThemeId.bubblegum: AppThemeSpec(
    id: AppThemeId.bubblegum,
    brightness: Brightness.light,
    colors: AppThemeColors.bubblegum,
  ),
};

/// The spec for [id]. Falls back to the light reference, which is the one
/// palette every component was drawn against.
AppThemeSpec appThemeSpec(AppThemeId id) =>
    palettes[id] ?? palettes[AppThemeId.light]!;

/// Parses a persisted id. An unknown or absent name is not an error: it is an
/// older install, or a theme that a later build removed.
AppThemeId? appThemeIdFromName(String? name) {
  if (name == null) return null;
  for (final id in AppThemeId.values) {
    if (id.name == name) return id;
  }
  return null;
}

/// Resolves the canvas background color of a theme as a 6-digit hex string
/// (e.g. `#EFEFED` or `#060606`) for native window background synchronization.
String appThemeCanvasHex(AppThemeId id) {
  final color = appThemeSpec(id).colors.canvas;
  final rgb = color.toARGB32() & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}
