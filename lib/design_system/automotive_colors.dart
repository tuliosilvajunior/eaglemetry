import 'package:flutter/material.dart';

import '../core/theme_controller.dart';

abstract final class AutomotiveColors {
  static bool get _light =>
      ThemeController.instance.themeMode == ThemeMode.light;

  static Color get surface =>
      _light ? AutomotiveLightColors.surface : _AutomotiveDarkColors.surface;
  static Color get surfaceDim => _light
      ? AutomotiveLightColors.surfaceDim
      : _AutomotiveDarkColors.surfaceDim;
  static Color get surfaceBright => _light
      ? AutomotiveLightColors.surfaceBright
      : _AutomotiveDarkColors.surfaceBright;
  static Color get surfaceContainerLowest => _light
      ? AutomotiveLightColors.surfaceContainerLowest
      : _AutomotiveDarkColors.surfaceContainerLowest;
  static Color get surfaceContainerLow => _light
      ? AutomotiveLightColors.surfaceContainerLow
      : _AutomotiveDarkColors.surfaceContainerLow;
  static Color get surfaceContainer => _light
      ? AutomotiveLightColors.surfaceContainer
      : _AutomotiveDarkColors.surfaceContainer;
  static Color get surfaceContainerHigh => _light
      ? AutomotiveLightColors.surfaceContainerHigh
      : _AutomotiveDarkColors.surfaceContainerHigh;
  static Color get surfaceContainerHighest => _light
      ? AutomotiveLightColors.surfaceContainerHighest
      : _AutomotiveDarkColors.surfaceContainerHighest;
  static Color get onSurface => _light
      ? AutomotiveLightColors.onSurface
      : _AutomotiveDarkColors.onSurface;
  static Color get onSurfaceVariant => _light
      ? AutomotiveLightColors.onSurfaceVariant
      : _AutomotiveDarkColors.onSurfaceVariant;
  static Color get inverseSurface => _light
      ? AutomotiveLightColors.inverseSurface
      : _AutomotiveDarkColors.inverseSurface;
  static Color get inverseOnSurface => _light
      ? AutomotiveLightColors.inverseOnSurface
      : _AutomotiveDarkColors.inverseOnSurface;
  static Color get outline =>
      _light ? AutomotiveLightColors.outline : _AutomotiveDarkColors.outline;
  static Color get outlineVariant => _light
      ? AutomotiveLightColors.outlineVariant
      : _AutomotiveDarkColors.outlineVariant;
  static Color get surfaceTint => _light
      ? AutomotiveLightColors.surfaceTint
      : _AutomotiveDarkColors.surfaceTint;
  static Color get primary =>
      _light ? AutomotiveLightColors.primary : _AutomotiveDarkColors.primary;
  static Color get onPrimary => _light
      ? AutomotiveLightColors.onPrimary
      : _AutomotiveDarkColors.onPrimary;
  static Color get primaryContainer => _light
      ? AutomotiveLightColors.primaryContainer
      : _AutomotiveDarkColors.primaryContainer;
  static Color get onPrimaryContainer => _light
      ? AutomotiveLightColors.onPrimaryContainer
      : _AutomotiveDarkColors.onPrimaryContainer;
  static Color get inversePrimary => _light
      ? AutomotiveLightColors.inversePrimary
      : _AutomotiveDarkColors.inversePrimary;
  static Color get secondary => _light
      ? AutomotiveLightColors.secondary
      : _AutomotiveDarkColors.secondary;
  static Color get onSecondary => _light
      ? AutomotiveLightColors.onSecondary
      : _AutomotiveDarkColors.onSecondary;
  static Color get secondaryContainer => _light
      ? AutomotiveLightColors.secondaryContainer
      : _AutomotiveDarkColors.secondaryContainer;
  static Color get onSecondaryContainer => _light
      ? AutomotiveLightColors.onSecondaryContainer
      : _AutomotiveDarkColors.onSecondaryContainer;
  static Color get tertiary =>
      _light ? AutomotiveLightColors.tertiary : _AutomotiveDarkColors.tertiary;
  static Color get onTertiary => _light
      ? AutomotiveLightColors.onTertiary
      : _AutomotiveDarkColors.onTertiary;
  static Color get tertiaryContainer => _light
      ? AutomotiveLightColors.tertiaryContainer
      : _AutomotiveDarkColors.tertiaryContainer;
  static Color get onTertiaryContainer => _light
      ? AutomotiveLightColors.onTertiaryContainer
      : _AutomotiveDarkColors.onTertiaryContainer;
  static Color get error =>
      _light ? AutomotiveLightColors.error : _AutomotiveDarkColors.error;
  static Color get onError =>
      _light ? AutomotiveLightColors.onError : _AutomotiveDarkColors.onError;
  static Color get errorContainer => _light
      ? AutomotiveLightColors.errorContainer
      : _AutomotiveDarkColors.errorContainer;
  static Color get onErrorContainer => _light
      ? AutomotiveLightColors.onErrorContainer
      : _AutomotiveDarkColors.onErrorContainer;
  static Color get background => _light
      ? AutomotiveLightColors.background
      : _AutomotiveDarkColors.background;
  static Color get onBackground => _light
      ? AutomotiveLightColors.onBackground
      : _AutomotiveDarkColors.onBackground;
  static Color get surfaceVariant => _light
      ? AutomotiveLightColors.surfaceVariant
      : _AutomotiveDarkColors.surfaceVariant;

  static Color get technicalBase => _light
      ? AutomotiveLightColors.technicalBase
      : _AutomotiveDarkColors.technicalBase;
  static Color get technicalPanel => _light
      ? AutomotiveLightColors.technicalPanel
      : _AutomotiveDarkColors.technicalPanel;
  static Color get technicalBorder => _light
      ? AutomotiveLightColors.technicalBorder
      : _AutomotiveDarkColors.technicalBorder;

  static Color get batteryPositive => _light
      ? AutomotiveLightColors.batteryPositive
      : _AutomotiveDarkColors.batteryPositive;
  static Color get kinetic =>
      _light ? AutomotiveLightColors.kinetic : _AutomotiveDarkColors.kinetic;
  static Color get warning =>
      _light ? AutomotiveLightColors.warning : _AutomotiveDarkColors.warning;
  static Color get critical =>
      _light ? AutomotiveLightColors.critical : _AutomotiveDarkColors.critical;

  static ColorScheme get colorScheme => ColorScheme.dark(
    brightness: Brightness.dark,
    primary: primary,
    onPrimary: onPrimary,
    primaryContainer: primaryContainer,
    onPrimaryContainer: onPrimaryContainer,
    secondary: secondary,
    onSecondary: onSecondary,
    secondaryContainer: secondaryContainer,
    onSecondaryContainer: onSecondaryContainer,
    tertiary: tertiary,
    onTertiary: onTertiary,
    tertiaryContainer: tertiaryContainer,
    onTertiaryContainer: onTertiaryContainer,
    error: error,
    onError: onError,
    errorContainer: errorContainer,
    onErrorContainer: onErrorContainer,
    surface: surface,
    onSurface: onSurface,
    onSurfaceVariant: onSurfaceVariant,
    outline: outline,
    outlineVariant: outlineVariant,
    inverseSurface: inverseSurface,
    onInverseSurface: inverseOnSurface,
    inversePrimary: inversePrimary,
    surfaceTint: surfaceTint,
  );
}

abstract final class _AutomotiveDarkColors {
  static const surface = Color(0xFF131313);
  static const surfaceDim = Color(0xFF131313);
  static const surfaceBright = Color(0xFF393939);
  static const surfaceContainerLowest = Color(0xFF0E0E0E);
  static const surfaceContainerLow = Color(0xFF1C1B1B);
  static const surfaceContainer = Color(0xFF20201F);
  static const surfaceContainerHigh = Color(0xFF2A2A2A);
  static const surfaceContainerHighest = Color(0xFF353535);
  static const onSurface = Color(0xFFE5E2E1);
  static const onSurfaceVariant = Color(0xFFC4C7C7);
  static const inverseSurface = Color(0xFFE5E2E1);
  static const inverseOnSurface = Color(0xFF313030);
  static const outline = Color(0xFF8E9192);
  static const outlineVariant = Color(0xFF444748);
  static const surfaceTint = Color(0xFFC9C6C5);
  static const primary = Color(0xFFC9C6C5);
  static const onPrimary = Color(0xFF313030);
  static const primaryContainer = Color(0xFF0A0A0A);
  static const onPrimaryContainer = Color(0xFF7B7979);
  static const inversePrimary = Color(0xFF5F5E5E);
  static const secondary = Color(0xFF4AE183);
  static const onSecondary = Color(0xFF003919);
  static const secondaryContainer = Color(0xFF06BB63);
  static const onSecondaryContainer = Color(0xFF00431F);
  static const tertiary = Color(0xFF92CCFF);
  static const onTertiary = Color(0xFF003351);
  static const tertiaryContainer = Color(0xFF000B16);
  static const onTertiaryContainer = Color(0xFF0080C0);
  static const error = Color(0xFFFFB4AB);
  static const onError = Color(0xFF690005);
  static const errorContainer = Color(0xFF93000A);
  static const onErrorContainer = Color(0xFFFFDAD6);
  static const background = Color(0xFF131313);
  static const onBackground = Color(0xFFE5E2E1);
  static const surfaceVariant = Color(0xFF353535);
  static const technicalBase = Color(0xFF0A0A0A);
  static const technicalPanel = Color(0xFF1A1A1A);
  static const technicalBorder = Color(0xFF2A2A2A);
  static const batteryPositive = Color(0xFF2ECC71);
  static const kinetic = Color(0xFF3498DB);
  static const warning = Color(0xFFF39C12);
  static const critical = Color(0xFFE74C3C);
}

abstract final class AutomotiveLightColors {
  static const surface = Color(0xFFFCF9F8);
  static const surfaceDim = Color(0xFFDCD9D9);
  static const surfaceBright = Color(0xFFFCF9F8);
  static const surfaceContainerLowest = Color(0xFFFFFFFF);
  static const surfaceContainerLow = Color(0xFFF6F3F2);
  static const surfaceContainer = Color(0xFFF0EDED);
  static const surfaceContainerHigh = Color(0xFFEAE7E7);
  static const surfaceContainerHighest = Color(0xFFE5E2E1);
  static const onSurface = Color(0xFF1C1B1B);
  static const onSurfaceVariant = Color(0xFF444748);
  static const inverseSurface = Color(0xFF313030);
  static const inverseOnSurface = Color(0xFFF3F0EF);
  static const outline = Color(0xFF747878);
  static const outlineVariant = Color(0xFFC4C7C7);
  static const surfaceTint = Color(0xFF5F5E5E);
  static const primary = Color(0xFF000000);
  static const onPrimary = Color(0xFFFFFFFF);
  static const primaryContainer = Color(0xFFEAE7E7);
  static const onPrimaryContainer = Color(0xFF444748);
  static const inversePrimary = Color(0xFFC9C6C5);
  static const secondary = Color(0xFF006D37);
  static const onSecondary = Color(0xFFFFFFFF);
  static const secondaryContainer = Color(0xFF6BFE9C);
  static const onSecondaryContainer = Color(0xFF00743A);
  static const tertiary = Color(0xFF006493);
  static const onTertiary = Color(0xFFFFFFFF);
  static const tertiaryContainer = Color(0xFFCCE5FF);
  static const onTertiaryContainer = Color(0xFF1D8ACD);
  static const error = Color(0xFFBA1A1A);
  static const onError = Color(0xFFFFFFFF);
  static const errorContainer = Color(0xFFFFDAD6);
  static const onErrorContainer = Color(0xFF93000A);
  static const background = Color(0xFFFCF9F8);
  static const onBackground = Color(0xFF1C1B1B);
  static const surfaceVariant = Color(0xFFE5E2E1);

  static const technicalBase = surfaceContainerLowest;
  static const technicalPanel = surfaceContainerLow;
  static const technicalBorder = outlineVariant;

  static const batteryPositive = Color(0xFF006D37);
  static const kinetic = Color(0xFF1D8ACD);
  static const warning = Color(0xFFF39C12);
  static const critical = Color(0xFFBA1A1A);

  static const colorScheme = ColorScheme.light(
    brightness: Brightness.light,
    primary: primary,
    onPrimary: onPrimary,
    primaryContainer: primaryContainer,
    onPrimaryContainer: onPrimaryContainer,
    secondary: secondary,
    onSecondary: onSecondary,
    secondaryContainer: secondaryContainer,
    onSecondaryContainer: onSecondaryContainer,
    tertiary: tertiary,
    onTertiary: onTertiary,
    tertiaryContainer: tertiaryContainer,
    onTertiaryContainer: onTertiaryContainer,
    error: error,
    onError: onError,
    errorContainer: errorContainer,
    onErrorContainer: onErrorContainer,
    surface: surface,
    onSurface: onSurface,
    onSurfaceVariant: onSurfaceVariant,
    outline: outline,
    outlineVariant: outlineVariant,
    inverseSurface: inverseSurface,
    onInverseSurface: inverseOnSurface,
    inversePrimary: inversePrimary,
    surfaceTint: surfaceTint,
  );
}
