// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'capy_ui_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class CapyUiL10nEn extends CapyUiL10n {
  CapyUiL10nEn([String locale = 'en']) : super(locale);

  @override
  String get settingsAppearance => 'Appearance';

  @override
  String get settingsAppTheme => 'App theme';

  @override
  String get settingsThemeDesc =>
      'Choose the palette the app wears. Each tile shows the page, a card, and its text.';

  @override
  String get settingsThemeNameLight => 'Light';

  @override
  String get settingsThemeNameDark => 'Petrol';

  @override
  String get settingsThemeNameMidnight => 'Midnight';

  @override
  String get settingsThemeNameSepia => 'Sepia';

  @override
  String get settingsThemeNameNordic => 'Nordic';

  @override
  String get settingsThemeNameDaylight => 'Daylight';

  @override
  String get settingsThemeNameTokyoNeon => 'Tokyo Neon';

  @override
  String get settingsThemeNameSunsetDrive => 'Sunset Drive';

  @override
  String get settingsThemeNameBubblegum => 'Bubblegum';

  @override
  String get settingsThemeReadOnlyLabel => 'Tip';

  @override
  String get settingsThemeReadOnlyMessage =>
      'Theme selection is unavailable while keyboard input is blocked.';

  @override
  String get settingsTogglesTitle => 'Toggles';

  @override
  String get settingsTogglesDesc =>
      'Switches that respect driving mode. When input is blocked they are read-only.';

  @override
  String get settingsReduceMotionLabel => 'Reduce motion';

  @override
  String get settingsReduceMotionDesc =>
      'Limit animations and transitions for a still interface.';

  @override
  String get settingsTogglesReadOnlyLabel => 'Tip';

  @override
  String get settingsTogglesReadOnlyMessage =>
      'Toggles are unavailable while input is blocked.';
}
