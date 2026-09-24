import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import 'pill_tab_bar.dart';

/// Local filter inside a card (`Drive | Parked`): a [AppColors.control] track
/// holding a white [AppColors.surface] pill on the selected segment.
///
/// Its selected state is the visual inverse of [PillTabBar]'s, and that is
/// deliberate — a page-level switch reads as dark-on-light, a filter within a
/// card reads as light-on-grey. Swapping the two is the easiest way to make a
/// screen look almost right and be wrong.
class TrackSegmentedControl<T> extends StatelessWidget {
  const TrackSegmentedControl({
    required this.items,
    required this.selected,
    required this.onSelected,
    this.segmentWidth,
    super.key,
  });

  final List<TabItem<T>> items;
  final T selected;
  final ValueChanged<T> onSelected;

  /// Fixed width per segment. Leave null to size each segment to its label.
  final double? segmentWidth;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.x1),
      decoration: BoxDecoration(
        color: colors.control,
        borderRadius: AppRadii.mdRadius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in items)
            _Segment(
              label: item.label,
              selected: item.value == selected,
              width: segmentWidth,
              onPressed: () => onSelected(item.value),
            ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.onPressed,
    this.width,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return AnimatedContainer(
      duration: AppMotion.fast,
      curve: AppMotion.curve,
      decoration: BoxDecoration(
        color: selected ? colors.surface : null,
        borderRadius: AppRadii.smRadius,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onPressed,
          borderRadius: AppRadii.smRadius,
          child: Container(
            width: width,
            height: AppSizes.segmentedHeight - AppSpacing.x2,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x6),
            child: Text(
              label,
              style: AppText.bodyStrong.copyWith(
                color: selected ? colors.ink : colors.inkMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
