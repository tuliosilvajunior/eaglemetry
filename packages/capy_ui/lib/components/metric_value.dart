import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// Size steps for [MetricValue]. Each step pairs a numeral style with the unit
/// style that is proportioned for it.
enum MetricSize { xl, lg, md, sm }

/// A numeral with a small unit suffix (`202 mi`, `48 kWh`).
///
/// The two are separate text runs sharing a baseline, never one string: the
/// unit has to stay small and independently colored while the numeral scales.
/// The numeral styles carry tabular figures so a live-updating value does not
/// jitter as digits change.
class MetricValue extends StatelessWidget {
  const MetricValue({
    required this.value,
    this.unit,
    this.size = MetricSize.xl,
    this.valueColor,
    this.unitColor,
    super.key,
  });

  /// Pre-formatted numeral. Formatting and locale handling belong to the
  /// caller (`lib/core/telemetry_format.dart`), not to this widget.
  final String value;

  /// Localized unit suffix.
  final String? unit;

  final MetricSize size;
  final Color? valueColor;
  final Color? unitColor;

  TextStyle get _valueStyle => switch (size) {
    MetricSize.xl => AppText.metricXl,
    MetricSize.lg => AppText.metricLg,
    MetricSize.md => AppText.metricMd,
    MetricSize.sm => AppText.metricSm,
  };

  TextStyle get _unitStyle => switch (size) {
    MetricSize.xl || MetricSize.lg => AppText.unitLg,
    MetricSize.md || MetricSize.sm => AppText.unitMd,
  };

  double get _gap => switch (size) {
    MetricSize.xl || MetricSize.lg => AppSpacing.x2,
    MetricSize.md || MetricSize.sm => AppSpacing.x1,
  };

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          value,
          style: valueColor == null
              ? _valueStyle.copyWith(color: colors.ink)
              : _valueStyle.copyWith(color: valueColor),
        ),
        if (unit != null) ...[
          SizedBox(width: _gap),
          Text(
            unit!,
            style: _unitStyle.copyWith(color: unitColor ?? colors.ink),
          ),
        ],
      ],
    );
  }
}

/// A [MetricValue] with a supporting line beneath it and an optional trailing
/// action (`202 mi` / `Range based on All-Purpose`).
///
/// [captionWidget] takes precedence over [caption] and exists for captions that
/// contain an inline affordance, such as the underlined preset name.
class MetricWithCaption extends StatelessWidget {
  const MetricWithCaption({
    required this.value,
    this.unit,
    this.caption,
    this.captionWidget,
    this.size = MetricSize.xl,
    this.trailing,
    super.key,
  });

  final String value;
  final String? unit;

  /// Localized supporting line.
  final String? caption;
  final Widget? captionWidget;

  final MetricSize size;

  /// Right-aligned action beside the metric (a `SquareIconButton`).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        MetricValue(value: value, unit: unit, size: size),
        if (captionWidget != null) ...[
          const SizedBox(height: AppSpacing.x2),
          captionWidget!,
        ] else if (caption != null) ...[
          const SizedBox(height: AppSpacing.x2),
          Text(caption!, style: AppText.label.copyWith(color: colors.inkMuted)),
        ],
      ],
    );

    if (trailing == null) return column;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(child: column),
        const SizedBox(width: AppSpacing.x4),
        trailing!,
      ],
    );
  }
}
