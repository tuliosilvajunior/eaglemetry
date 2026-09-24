import 'package:flutter/material.dart';

import 'tokens/app_colors.dart';
import 'tokens/app_palettes.dart';
import 'tokens/app_spacing.dart';
import 'tokens/app_typography.dart';

/// [ThemeData] projection of the `capy_ui` tokens.
///
/// `main.dart` applies this theme only to the temporary V2 preview. The shipped
/// journey continues to use `AutomotiveTheme.light()`/`.dark()`, so the two
/// visual systems stay in separate widget trees.
abstract final class AppTheme {
  static ThemeData light() => forId(AppThemeId.light);

  static ThemeData dark() => forId(AppThemeId.dark);

  /// The theme for one catalogue entry. Assembling a [ThemeData] is not cheap
  /// and a theme never changes for a given id, so each one is built once and
  /// kept.
  static ThemeData forId(AppThemeId id) =>
      _cache.putIfAbsent(id, () => build(appThemeSpec(id)));

  static ThemeData build(AppThemeSpec spec) =>
      _build(spec.brightness, spec.colors);

  static final Map<AppThemeId, ThemeData> _cache = <AppThemeId, ThemeData>{};

  static ThemeData _build(Brightness brightness, AppThemeColors colors) {
    final colorScheme = ColorScheme.fromSeed(
      brightness: brightness,
      seedColor: colors.energy.gain,
      primary: colors.selectionFill,
      onPrimary: colors.onSelection,
      secondary: colors.energy.gain,
      onSecondary: colors.ink,
      error: colors.energy.critical,
      onError: colors.onSelection,
      surface: colors.surface,
      onSurface: colors.ink,
      onSurfaceVariant: colors.inkMuted,
      outline: colors.inkSubtle,
      outlineVariant: colors.divider,
      inverseSurface: colors.inverseSurface,
      onInverseSurface: colors.onInverseSurface,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colors.canvas,
      extensions: [colors],
      fontFamily: AppFonts.family,
      textTheme: _textTheme,
      splashFactory: InkSparkle.splashFactory,
      // The reference language separates surfaces by contrast, never by
      // elevation or hairlines, so shadows are off by default everywhere.
      cardTheme: CardThemeData(
        elevation: 0,
        color: colors.surface,
        surfaceTintColor: AppColors.transparent,
        shadowColor: AppColors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.xlRadius),
        margin: EdgeInsets.zero,
      ),
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: colors.canvas,
        foregroundColor: colors.ink,
        centerTitle: false,
        titleTextStyle: AppText.cardTitle,
      ),
      iconTheme: IconThemeData(color: colors.ink, size: AppSizes.iconMd),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.square(AppSizes.minTouchTarget),
          backgroundColor: colors.selectionFill,
          foregroundColor: colors.onSelection,
          elevation: 0,
          shape: const RoundedRectangleBorder(borderRadius: AppRadii.mdRadius),
          textStyle: AppText.bodyStrong,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size.square(AppSizes.minTouchTarget),
          foregroundColor: colors.ink,
          shape: const RoundedRectangleBorder(borderRadius: AppRadii.mdRadius),
          textStyle: AppText.bodyStrong,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size.square(AppSizes.minTouchTarget),
          foregroundColor: colors.ink,
          shape: const CircleBorder(),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colors.divider,
        thickness: 1,
        space: 1,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colors.energy.gain,
        linearTrackColor: colors.track,
        circularTrackColor: colors.track,
      ),
    );
  }

  static const _textTheme = TextTheme(
    displayLarge: AppText.metricXl,
    displayMedium: AppText.metricLg,
    displaySmall: AppText.metricMd,
    headlineMedium: AppText.cardTitle,
    headlineSmall: AppText.tabLabel,
    titleMedium: AppText.bodyStrong,
    bodyLarge: AppText.body,
    bodyMedium: AppText.body,
    bodySmall: AppText.caption,
    labelLarge: AppText.bodyStrong,
    labelMedium: AppText.label,
    labelSmall: AppText.caption,
  );
}
