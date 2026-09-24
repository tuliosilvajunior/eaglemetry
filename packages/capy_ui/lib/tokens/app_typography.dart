import 'package:flutter/widgets.dart';

import 'app_colors.dart';

/// Typography for the `capy_ui` design system.
///
/// One family (Inter, bundled via `pubspec.yaml`) at varying weights — no
/// separate monospace face. Numeric styles carry
/// [FontFeature.tabularFigures], which matters here more than it would in a
/// typical app: these readouts update live, and proportional digits make the
/// value visibly jitter as it counts.
abstract final class AppFonts {
  static const family = 'Inter';

  static const _tabular = [FontFeature.tabularFigures()];
}

abstract final class AppText {
  // --- Metrics -------------------------------------------------------------
  // The hero number on a card. Pair with a `unit*` style via `MetricValue`
  // rather than baking the unit into the same run.

  static const metricXl = TextStyle(
    fontFamily: AppFonts.family,
    fontSize: 72,
    fontWeight: FontWeight.w800,
    height: 1,
    letterSpacing: -2,
    fontFeatures: AppFonts._tabular,
  );

  static const metricLg = TextStyle(
    fontFamily: AppFonts.family,
    fontSize: 48,
    fontWeight: FontWeight.w800,
    height: 1,
    letterSpacing: -1.4,
    fontFeatures: AppFonts._tabular,
  );

  static const metricMd = TextStyle(
    fontFamily: AppFonts.family,
    fontSize: 32,
    fontWeight: FontWeight.w700,
    height: 1.05,
    letterSpacing: -0.8,
    fontFeatures: AppFonts._tabular,
  );

  static const metricSm = TextStyle(
    fontFamily: AppFonts.family,
    fontSize: 22,
    fontWeight: FontWeight.w700,
    height: 1.1,
    letterSpacing: -0.3,
    fontFeatures: AppFonts._tabular,
  );

  // --- Units ---------------------------------------------------------------
  // The small suffix trailing a metric (`mi`, `%`, `kWh`).

  static const unitLg = TextStyle(
    fontFamily: AppFonts.family,
    fontSize: 24,
    fontWeight: FontWeight.w600,
    height: 1,
  );

  static const unitMd = TextStyle(
    fontFamily: AppFonts.family,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 1,
  );

  // --- Structure -----------------------------------------------------------

  /// Card title (`Energy`, `Last charge session`).
  static const cardTitle = TextStyle(
    fontFamily: AppFonts.family,
    fontSize: 22,
    fontWeight: FontWeight.w700,
    height: 1.2,
    letterSpacing: -0.2,
  );

  /// Page-level pill tab label, and in-card text tab label.
  static const tabLabel = TextStyle(
    fontFamily: AppFonts.family,
    fontSize: 20,
    fontWeight: FontWeight.w600,
    height: 1.2,
    letterSpacing: -0.2,
  );

  // --- Content -------------------------------------------------------------

  static const body = TextStyle(
    fontFamily: AppFonts.family,
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 1.4,
  );

  /// Body weight used for the label of an action row or preset tile.
  static const bodyStrong = TextStyle(
    fontFamily: AppFonts.family,
    fontSize: 16,
    fontWeight: FontWeight.w500,
    height: 1.4,
  );

  /// Supporting line under a metric (`Range based on All-Purpose`), preset
  /// tile sublabel.
  static const label = TextStyle(
    fontFamily: AppFonts.family,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.3,
  );

  static const caption = TextStyle(
    fontFamily: AppFonts.family,
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.3,
  );

  /// A cardinal point on the compass tape (`NE`, `E`).
  ///
  /// Heavier and larger than any other label in the system on purpose: the
  /// tape is read at a glance while driving, and the eight letters are the
  /// only thing on it that carries meaning by itself.
  static const compassCardinal = TextStyle(
    fontFamily: AppFonts.family,
    fontSize: 32,
    fontWeight: FontWeight.w800,
    height: 1.1,
    letterSpacing: -0.6,
  );

  /// Value in a chart footer stat column (`10.8 kW`, `2.18`).
  static const statValue = TextStyle(
    fontFamily: AppFonts.family,
    fontSize: 26,
    fontWeight: FontWeight.w700,
    height: 1.1,
    letterSpacing: -0.5,
    fontFeatures: AppFonts._tabular,
  );

  /// Signed change shown next to a total (`+12.2 kWh` under a donut center).
  /// Colored as a gain by default; recolor for a loss at the call site.
  static const delta = TextStyle(
    fontFamily: AppFonts.family,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 1.2,
    fontFeatures: AppFonts._tabular,
    color: AppColors.energyGain,
  );

  // --- Tooltip -------------------------------------------------------------
  // Rendered on [AppColors.inverseSurface], so these carry light colors.

  static const tooltipValue = TextStyle(
    fontFamily: AppFonts.family,
    fontSize: 20,
    fontWeight: FontWeight.w700,
    height: 1.2,
    fontFeatures: AppFonts._tabular,
    color: AppColors.onInverseSurface,
  );

  static const tooltipLine = TextStyle(
    fontFamily: AppFonts.family,
    fontSize: 15,
    fontWeight: FontWeight.w500,
    height: 1.35,
    fontFeatures: AppFonts._tabular,
    color: AppColors.onInverseSurfaceMuted,
  );

  /// Numeric value in a compact legend row (the `44.0 kWh` grid).
  static const legendValue = TextStyle(
    fontFamily: AppFonts.family,
    fontSize: 18,
    fontWeight: FontWeight.w600,
    height: 1.2,
    fontFeatures: AppFonts._tabular,
  );
}
