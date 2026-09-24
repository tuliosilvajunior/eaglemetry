import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// The battery of one cycle, drawn as a static pill.
///
/// The scale is always the whole battery: zero to 100 % of state of charge
/// removed by driving. A closed cycle fills the pill, which is what makes it a
/// cycle. An open one fills the part it has reached, and a partial one — a
/// battery that collection joined in the middle of — never reaches the end.
///
/// This is a sibling of `LimitSlider`, not a use of it. A charge target has a
/// knob, a selectable range and guides, and none of those describe a battery
/// that is already spent. Reusing the control would put a knob and the word
/// "target" on a reading nobody can change.
///
/// It draws no animation. The rows repeat down a list, and a list that breathes
/// is a distraction in a moving car.
class CycleBar extends StatelessWidget {
  const CycleBar({
    required this.fillPercent,
    required this.leadingLabel,
    required this.valueLabel,
    this.valueUnit,
    this.isPartial = false,
    this.semanticsLabel,
    this.fillColor,
    super.key,
  });

  /// How much of the battery this cycle has spent, 0 to 100. Values outside
  /// that range are clamped: the pill is the whole battery and cannot overflow.
  final double fillPercent;

  /// The identity of the cycle, drawn inside the filled end. The bar is a
  /// constant 100 % for every closed cycle, so it carries the ordinal to earn
  /// its width.
  final String leadingLabel;

  /// The pre-formatted numeral and its localized unit. Both come from the
  /// caller, because nothing here may build a visible string.
  final String valueLabel;
  final String? valueUnit;

  /// Collection began in the middle of this battery. The unfilled zone then
  /// keeps an outline, so the reader sees a battery that was never whole
  /// rather than one that stopped early.
  final bool isPartial;

  final String? semanticsLabel;

  /// The fill is green, and this is the one place the green does not mean
  /// energy recovered. It reads as a battery that is filling up towards a whole
  /// one, which is what the row counts. A complete cycle is therefore a
  /// completely green pill.
  /// Null takes the theme's gain hue, which is what a cycle is measured in.
  final Color? fillColor;

  @override
  Widget build(BuildContext context) {
    final fill = fillPercent.isFinite
        ? fillPercent.clamp(0.0, 100.0).toDouble()
        : 0.0;
    final colors = AppThemeColors.of(context);
    final fillPaint = fillColor ?? colors.energy.gain;

    return Semantics(
      label: semanticsLabel,
      readOnly: true,
      child: SizedBox(
        height: AppSizes.cycleBarHeight,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: AppRadii.fullRadius,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: colors.track),
                  if (fill > 0)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: fill / 100,
                        // Both factors, always. A `ColoredBox` with no child
                        // takes the smallest height it is offered, so without
                        // this the fill is nothing and the pill stays the
                        // colour of the empty track.
                        heightFactor: 1,
                        child: ColoredBox(color: fillPaint),
                      ),
                    ),
                ],
              ),
            ),
            if (isPartial)
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: AppRadii.fullRadius,
                  border: Border.all(
                    color: colors.divider,
                    width: AppSizes.limitSliderOutline,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x3),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    leadingLabel,
                    style: AppText.metricSm.copyWith(
                      // The label sits over the filled end, which is amber in
                      // both themes, so its ink is the constant one.
                      color: fill > 0 ? AppColors.ink : colors.inkMuted,
                    ),
                  ),
                  _Value(
                    label: valueLabel,
                    unit: valueUnit,
                    // The numeral sits over the empty end of an open bar, so it
                    // takes the surface colour, not the colour of the fill.
                    color: fill >= 100 ? AppColors.ink : colors.ink,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Value extends StatelessWidget {
  const _Value({required this.label, required this.unit, required this.color});

  final String label;
  final String? unit;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final unitLabel = unit;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(label, style: AppText.metricMd.copyWith(color: color)),
        if (unitLabel != null) ...[
          const SizedBox(width: AppSpacing.x1),
          Text(unitLabel, style: AppText.unitMd.copyWith(color: color)),
        ],
      ],
    );
  }
}
