import 'package:flutter/material.dart';

import 'automotive_colors.dart';
import 'automotive_spacing.dart';
import 'automotive_typography.dart';

abstract final class AutomotiveTheme {
  static ThemeData dark() {
    return _build(
      brightness: Brightness.dark,
      colorScheme: AutomotiveColors.colorScheme,
      scaffoldBackground: AutomotiveColors.technicalBase,
      surface: AutomotiveColors.surface,
      panel: AutomotiveColors.technicalPanel,
      panelHigh: AutomotiveColors.surfaceContainerHighest,
      panelDisabled: AutomotiveColors.surfaceContainer,
      panelBorder: AutomotiveColors.technicalBorder,
      onSurface: AutomotiveColors.onSurface,
      onSurfaceVariant: AutomotiveColors.onSurfaceVariant,
      outline: AutomotiveColors.outline,
      outlineVariant: AutomotiveColors.outlineVariant,
      active: AutomotiveColors.secondary,
      onActive: AutomotiveColors.onSecondary,
      error: AutomotiveColors.error,
    );
  }

  static ThemeData light() {
    return _build(
      brightness: Brightness.light,
      colorScheme: AutomotiveLightColors.colorScheme,
      scaffoldBackground: AutomotiveLightColors.technicalBase,
      surface: AutomotiveLightColors.surface,
      panel: AutomotiveLightColors.technicalPanel,
      panelHigh: AutomotiveLightColors.surfaceContainerHighest,
      panelDisabled: AutomotiveLightColors.surfaceContainer,
      panelBorder: AutomotiveLightColors.technicalBorder,
      onSurface: AutomotiveLightColors.onSurface,
      onSurfaceVariant: AutomotiveLightColors.onSurfaceVariant,
      outline: AutomotiveLightColors.outline,
      outlineVariant: AutomotiveLightColors.outlineVariant,
      active: AutomotiveLightColors.secondary,
      onActive: AutomotiveLightColors.onSecondary,
      error: AutomotiveLightColors.error,
    );
  }

  static ThemeData _build({
    required Brightness brightness,
    required ColorScheme colorScheme,
    required Color scaffoldBackground,
    required Color surface,
    required Color panel,
    required Color panelHigh,
    required Color panelDisabled,
    required Color panelBorder,
    required Color onSurface,
    required Color onSurfaceVariant,
    required Color outline,
    required Color outlineVariant,
    required Color active,
    required Color onActive,
    required Color error,
  }) {
    final textTheme = _textTheme(onSurface);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: scaffoldBackground,
      fontFamily: AutomotiveFonts.ui,
      textTheme: textTheme,
      extensions: [AutomotiveTypography.standard()],
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: surface,
        foregroundColor: onSurface,
        centerTitle: false,
        titleTextStyle: AutomotiveTextStyles.headlineMd.copyWith(
          color: onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: panel,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: AutomotiveRadii.lgRadius,
          side: BorderSide(color: panelBorder),
        ),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(
            AutomotiveDimensions.minTouchTarget,
            AutomotiveDimensions.minTouchTarget,
          ),
          backgroundColor: active,
          foregroundColor: onActive,
          shape: RoundedRectangleBorder(borderRadius: AutomotiveRadii.lgRadius),
          textStyle: AutomotiveTextStyles.labelCaps,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(
            AutomotiveDimensions.minTouchTarget,
            AutomotiveDimensions.minTouchTarget,
          ),
          foregroundColor: onSurface,
          side: BorderSide(color: outline),
          shape: RoundedRectangleBorder(borderRadius: AutomotiveRadii.lgRadius),
          textStyle: AutomotiveTextStyles.labelCaps,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size.square(AutomotiveDimensions.minTouchTarget),
          foregroundColor: onSurface,
          shape: RoundedRectangleBorder(borderRadius: AutomotiveRadii.lgRadius),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: panel,
        selectedColor: panelHigh,
        disabledColor: panelDisabled,
        labelStyle: AutomotiveTextStyles.bodyMd.copyWith(color: onSurface),
        secondaryLabelStyle: AutomotiveTextStyles.bodyMd.copyWith(
          color: onSurface,
        ),
        side: BorderSide(color: outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: AutomotiveRadii.lgRadius),
        padding: const EdgeInsets.symmetric(
          horizontal: AutomotiveSpacing.x1,
          vertical: AutomotiveSpacing.x1,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return panelHigh;
            return panel;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return onSurface;
            return onSurfaceVariant;
          }),
          side: WidgetStateProperty.all(BorderSide(color: outlineVariant)),
          minimumSize: WidgetStateProperty.all(
            const Size(AutomotiveSpacing.touchTargetMin, 48),
          ),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: AutomotiveRadii.lgRadius),
          ),
          textStyle: WidgetStateProperty.all(AutomotiveTextStyles.labelCaps),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return onActive;
          return onSurfaceVariant;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return active;
          return panelHigh;
        }),
      ),
      dividerTheme: DividerThemeData(
        color: outlineVariant,
        thickness: 1,
        space: 1,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: active,
        linearTrackColor: panelHigh,
        circularTrackColor: panelHigh,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: panel,
        border: OutlineInputBorder(
          borderRadius: AutomotiveRadii.lgRadius,
          borderSide: BorderSide(color: outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AutomotiveRadii.lgRadius,
          borderSide: BorderSide(color: outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AutomotiveRadii.lgRadius,
          borderSide: BorderSide(
            color: active,
            width: AutomotiveDimensions.activeBorderWidth,
          ),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: AutomotiveRadii.lgRadius,
          borderSide: BorderSide(color: error),
        ),
        labelStyle: AutomotiveTextStyles.bodyMd.copyWith(
          color: onSurfaceVariant,
        ),
      ),
    );
  }

  static TextTheme _textTheme(Color onSurface) {
    return TextTheme(
      displayLarge: AutomotiveTextStyles.metricDisplay,
      displayMedium: AutomotiveTextStyles.metricDisplayMobile,
      headlineLarge: AutomotiveTextStyles.headlineLg,
      headlineMedium: AutomotiveTextStyles.headlineMd,
      bodyLarge: AutomotiveTextStyles.bodyLg,
      bodyMedium: AutomotiveTextStyles.bodyMd,
      labelLarge: AutomotiveTextStyles.labelCaps,
      labelMedium: AutomotiveTextStyles.labelCaps,
      labelSmall: AutomotiveTextStyles.labelCaps,
    ).apply(bodyColor: onSurface, displayColor: onSurface);
  }
}
