import 'package:flutter/material.dart';

import '../automotive_colors.dart';
import '../automotive_spacing.dart';
import '../automotive_typography.dart';

/// One selectable value inside a [SegmentedFilter].
class FilterOption<T> {
  const FilterOption(this.value, this.label);

  final T value;
  final String label;
}

/// Bordered single-select segmented control for filters (signal groups,
/// diagnostic statuses, history ranges).
///
/// Replaces the `_FilterSegment` / `_GroupSegment` / `_RangeSelector`
/// widgets previously duplicated per screen. Labels are rendered as given;
/// pass caps strings for the standard look.
class SegmentedFilter<T> extends StatelessWidget {
  const SegmentedFilter({
    required this.options,
    required this.selected,
    required this.onSelected,
    this.segmentHeight = 32,
    this.color,
    super.key,
  });

  final List<FilterOption<T>> options;
  final T selected;
  final ValueChanged<T> onSelected;

  /// Height of each segment button; use 40 for page-level filters.
  final double segmentHeight;

  /// Track color behind the segments. Defaults to the recessed
  /// primary-container surface used by the control bars.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AutomotiveSpacing.x0_5),
      decoration: BoxDecoration(
        color: color ?? AutomotiveColors.primaryContainer,
        border: Border.all(color: AutomotiveColors.technicalBorder),
        borderRadius: AutomotiveRadii.lgRadius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final option in options)
            SizedBox(
              height: segmentHeight,
              child: TextButton(
                onPressed: () => onSelected(option.value),
                style: TextButton.styleFrom(
                  foregroundColor: option.value == selected
                      ? AutomotiveColors.onSurface
                      : AutomotiveColors.onSurfaceVariant,
                  backgroundColor: option.value == selected
                      ? AutomotiveColors.surfaceContainerHighest
                      : Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: AutomotiveRadii.baseRadius,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AutomotiveSpacing.x2,
                  ),
                  textStyle: AutomotiveTextStyles.labelCaps.copyWith(
                    fontSize: 11,
                  ),
                ),
                child: Text(option.label),
              ),
            ),
        ],
      ),
    );
  }
}
