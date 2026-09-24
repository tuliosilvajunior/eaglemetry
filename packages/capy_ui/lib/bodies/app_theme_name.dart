import '../l10n/capy_ui_localizations.dart';
import '../tokens/app_palettes.dart';

/// Localized name for [id] via the shared `CapyUiL10n` ARB.
///
/// Single package-side resolver for the 9-case `_themeName` switch that was
/// duplicated in `DisplaysPane` and the companion `SettingsScreen`. Bodies and
/// gallery call this instead of copying the switch.
String appThemeName(AppThemeId id, CapyUiL10n l10n) => switch (id) {
  AppThemeId.light => l10n.settingsThemeNameLight,
  AppThemeId.dark => l10n.settingsThemeNameDark,
  AppThemeId.midnight => l10n.settingsThemeNameMidnight,
  AppThemeId.sepia => l10n.settingsThemeNameSepia,
  AppThemeId.nordic => l10n.settingsThemeNameNordic,
  AppThemeId.daylight => l10n.settingsThemeNameDaylight,
  AppThemeId.tokyoNeon => l10n.settingsThemeNameTokyoNeon,
  AppThemeId.sunsetDrive => l10n.settingsThemeNameSunsetDrive,
  AppThemeId.bubblegum => l10n.settingsThemeNameBubblegum,
};
