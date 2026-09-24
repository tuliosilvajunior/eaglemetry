import 'package:flutter/material.dart';

import '../capy_ui.dart';

/// Caption used inside a demo card. Gallery copy only.
class GalleryCaption extends StatelessWidget {
  const GalleryCaption(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: AppText.caption.copyWith(
        color: AppThemeColors.of(context).inkMuted,
      ),
    );
  }
}

/// Stretches children to a common height, the same grid row the old gallery
/// used. A child that measures itself with a `LayoutBuilder` still needs its
/// height pinned outside this row.
class GalleryRow extends StatelessWidget {
  const GalleryRow({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: AppSpacing.gridGutter),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// The two energy ramps, side by side. Used on the metric page so the tokens
/// can be judged next to the numbers they colour.
class GallerySwatches extends StatelessWidget {
  const GallerySwatches({super.key});

  static const _ramps = [
    [
      AppColors.energyGain,
      AppColors.energyGainSoft,
      AppColors.energyGainSubtle,
    ],
    [
      AppColors.energyDraw,
      AppColors.energyDrawSoft,
      AppColors.energyDrawSubtle,
    ],
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final ramp in _ramps)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.x2),
            child: Row(
              children: [
                for (final color in ramp)
                  Expanded(
                    child: Container(
                      height: AppSpacing.x8,
                      margin: const EdgeInsets.only(right: AppSpacing.x1),
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: AppRadii.xsRadius,
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Vertical stack of demo cards with the gallery gutter between them.
class GalleryStack extends StatelessWidget {
  const GalleryStack({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.gridGutter),
          children[i],
        ],
      ],
    );
  }
}
