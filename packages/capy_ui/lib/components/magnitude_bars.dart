import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// One measured quantity in a [MagnitudeBars] list.
class MagnitudeBar {
  const MagnitudeBar({
    required this.value,
    required this.label,
    required this.valueLabel,
    required this.color,
  });

  /// The magnitude, in whatever unit the caller is showing. The bar length
  /// comes from it against the longest bar in the list.
  final double value;

  /// What the quantity is, in the caller's words.
  final String label;

  /// The number itself, pre-formatted with its unit.
  final String valueLabel;

  final Color color;
}

/// Several measured quantities on one scale, each named and each with its
/// number.
///
/// The scale is the **largest** bar, not the sum. This is a comparison, not a
/// partition: the quantities here do not have to add up to anything, and the
/// full-length bar is simply the biggest of them. `ShareBar` is the partition,
/// and the two must not be swapped — a reader who takes this for a partition
/// would read the longest bar as "all of it".
///
/// That distinction is what this component is for. Energy drawn and energy
/// recovered are the case: recovery is measured against what was spent rather
/// than carved out of it, so it has no slice of a ring and no share of a pill,
/// but it does have a magnitude that can sit beside the others on one scale.
///
/// A quantity that measured zero keeps its row and its number, and draws no
/// bar. The row is the reading; the bar is only how long it is.
class MagnitudeBars extends StatelessWidget {
  const MagnitudeBars({required this.bars, this.footnote, super.key});

  final List<MagnitudeBar> bars;

  /// A localized line under the list, such as the total these compare against.
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final usable = [
      for (final bar in bars)
        if (bar.value.isFinite) bar,
    ];
    if (usable.isEmpty) return const SizedBox.shrink();
    final longest = usable
        .map((bar) => bar.value.abs())
        .reduce((a, b) => a > b ? a : b);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final bar in usable) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  bar.label,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.label.copyWith(color: colors.inkMuted),
                ),
              ),
              Text(
                bar.valueLabel,
                style: AppText.bodyStrong.copyWith(color: colors.ink),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x2),
          SizedBox(
            height: AppSizes.magnitudeBarHeight,
            child: ClipRRect(
              borderRadius: AppRadii.fullRadius,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: colors.track),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: longest <= 0
                          ? 0
                          : (bar.value.abs() / longest).clamp(0.0, 1.0),
                      heightFactor: 1,
                      child: ColoredBox(color: bar.color),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.x3),
        ],
        if (footnote case final footnote?)
          Text(footnote, style: AppText.label.copyWith(color: colors.inkMuted)),
      ],
    );
  }
}
