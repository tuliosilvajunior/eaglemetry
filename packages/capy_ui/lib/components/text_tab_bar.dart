import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import 'pill_tab_bar.dart' show TabItem;

/// In-card tab bar: no fill at all. The selected tab is [AppColors.ink], the
/// rest are [AppColors.inkSubtle].
///
/// Sits in a card header where it replaces the title, so it uses the same
/// [AppText.tabLabel] size as the other tab components but stays completely
/// flat — a fill here would compete with the card's own controls.
class TextTabBar<T> extends StatelessWidget {
  const TextTabBar({
    required this.items,
    required this.selected,
    required this.onSelected,
    this.spacing = AppSpacing.x6,
    super.key,
  });

  final List<TabItem<T>> items;
  final T selected;
  final ValueChanged<T> onSelected;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final item in items) ...[
          if (item != items.first) SizedBox(width: spacing),
          _TextTab(
            label: item.label,
            selected: item.value == selected,
            onPressed: () => onSelected(item.value),
          ),
        ],
      ],
    );
  }
}

class _TextTab extends StatelessWidget {
  const _TextTab({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onPressed,
        borderRadius: AppRadii.smRadius,
        child: Container(
          constraints: const BoxConstraints(
            minWidth: AppSizes.minTouchTarget,
            minHeight: AppSizes.minTouchTarget,
          ),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x1),
          child: AnimatedDefaultTextStyle(
            duration: AppMotion.fast,
            curve: AppMotion.curve,
            style: AppText.tabLabel.copyWith(
              color: selected ? colors.ink : colors.inkSubtle,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            ),
            child: Text(label),
          ),
        ),
      ),
    );
  }
}
