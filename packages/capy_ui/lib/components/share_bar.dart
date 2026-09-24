import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// One named part of a whole in a [ShareBar].
class ShareSegment {
  const ShareSegment({
    required this.value,
    required this.color,
    required this.label,
  });

  /// Magnitude of this part, in whatever the caller is counting. The width is
  /// derived from it against the total, so callers never compute a percentage
  /// for the bar — only for the words beside it.
  final double value;

  final Color color;

  /// Pre-formatted and localized, name and share together (`Eco 55%`). Nothing
  /// here may build a visible string.
  final String label;
}

/// How a whole divides, drawn as one pill and named underneath.
///
/// This is a partition, not a progress bar. The segments always fill the pill,
/// because what it answers is "of the whole, how much was each" — there is no
/// unfilled remainder to leave, and a track showing through would invent one.
/// `SocSpanBar` and `CycleBar` are the readings that do have a remainder; this
/// is not one of them.
///
/// A part that measured nothing is dropped rather than drawn as a hairline.
/// A sliver too thin to see but wide enough to shift its neighbours is a lie
/// about a part that was not there.
///
/// The widths and the words come from the same values, so the bar cannot
/// disagree with its own legend.
class ShareBar extends StatelessWidget {
  const ShareBar({required this.segments, this.semanticsLabel, super.key});

  final List<ShareSegment> segments;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final parts = [
      for (final segment in segments)
        if (segment.value > 0 && segment.value.isFinite) segment,
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    final total = parts.fold<double>(0, (sum, part) => sum + part.value);

    return Semantics(
      label: semanticsLabel,
      readOnly: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: AppSizes.shareBarHeight,
            child: ClipRRect(
              borderRadius: AppRadii.fullRadius,
              child: Row(
                children: [
                  for (final part in parts)
                    Expanded(
                      // Integer flex would round every share to the same step.
                      // The counts are whole numbers but the shares are not,
                      // and the pill has to hold the exact division.
                      flex: (part.value / total * _flexScale).round().clamp(
                        1,
                        _flexScale,
                      ),
                      child: ColoredBox(color: part.color),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.x3),
          Wrap(
            spacing: AppSpacing.x4,
            runSpacing: AppSpacing.x2,
            children: [
              for (final part in parts)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: AppSizes.shareBarDot,
                      height: AppSizes.shareBarDot,
                      decoration: BoxDecoration(
                        color: part.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.x2),
                    Text(
                      part.label,
                      style: AppText.caption.copyWith(color: colors.inkMuted),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Resolution the shares are held at. A flex is an integer, so this is what
  /// keeps a 5.5 % part from rounding to the same width as a 6.4 % one.
  static const _flexScale = 10000;
}
