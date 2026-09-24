import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_palettes.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// Single-select grid of themes, one tile per [AppThemeId].
///
/// Each tile paints itself in the palette it offers, so the choice is made by
/// looking rather than by reading a name. The tile is a miniature of the
/// journey it produces: the page canvas, a card on it, and two ink weights.
/// The energy ramp is deliberately absent from the preview, because green and
/// amber are the same in every theme and a swatch that never changes tells the
/// reader nothing.
///
/// The grid reads [AppThemeId.values], so a theme added to the catalogue
/// appears here with no change to this widget. [nameOf] supplies the localized
/// label, which keeps `lib/ui/` free of the l10n import.
class ThemePicker extends StatelessWidget {
  const ThemePicker({
    required this.selected,
    required this.onSelected,
    required this.nameOf,
    super.key,
  });

  final AppThemeId selected;
  final ValueChanged<AppThemeId> onSelected;
  final String Function(AppThemeId id) nameOf;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.x3,
      runSpacing: AppSpacing.x3,
      children: [
        for (final id in AppThemeId.values)
          _ThemeTile(
            spec: appThemeSpec(id),
            label: nameOf(id),
            selected: id == selected,
            onPressed: () => onSelected(id),
          ),
      ],
    );
  }
}

class _ThemeTile extends StatelessWidget {
  const _ThemeTile({
    required this.spec,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  static const _width = 168.0;
  static const _previewHeight = 76.0;

  final AppThemeSpec spec;
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // The ring is drawn in the *current* theme, not in the offered one: it
    // states which tile the reader picked, and that answer has to read the
    // same across the whole grid.
    final current = AppThemeColors.of(context);
    final preview = spec.colors;

    return SizedBox(
      width: _width,
      child: Material(
        color: AppColors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: AppRadii.mdRadius,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedContainer(
                duration: AppMotion.fast,
                height: _previewHeight,
                decoration: BoxDecoration(
                  color: preview.canvas,
                  borderRadius: AppRadii.mdRadius,
                  border: Border.all(
                    color: selected ? current.selectionFill : preview.divider,
                    width: selected ? 3 : 1,
                  ),
                ),
                padding: const EdgeInsets.all(AppSpacing.x3),
                child: Container(
                  decoration: BoxDecoration(
                    color: preview.surface,
                    borderRadius: AppRadii.smRadius,
                  ),
                  padding: const EdgeInsets.all(AppSpacing.x2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _Rule(color: preview.ink, width: 54),
                      const SizedBox(height: AppSpacing.x2),
                      Row(
                        children: [
                          _Rule(color: preview.inkMuted, width: 26),
                          const SizedBox(width: AppSpacing.x2),
                          // The two data hues, in the order the charts use
                          // them. They are the whole point of an expressive
                          // theme, and on a restrained one they say that the
                          // charts do not change.
                          _Dot(color: preview.energy.draw),
                          const SizedBox(width: AppSpacing.x1),
                          _Dot(color: preview.energy.gain),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.x2),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: AppText.bodyStrong.copyWith(
                        color: selected ? current.ink : current.inkMuted,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (selected)
                    Icon(
                      Icons.check,
                      size: AppSizes.iconSm,
                      color: current.ink,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

class _Rule extends StatelessWidget {
  const _Rule({required this.color, required this.width});

  final Color color;
  final double width;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: 4,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(2),
    ),
  );
}
