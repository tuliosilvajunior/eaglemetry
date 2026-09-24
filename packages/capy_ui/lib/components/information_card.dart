import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import 'anchored_tooltip.dart';

/// One muted information block inside an explanatory tooltip.
class InformationCard extends StatelessWidget {
  const InformationCard({
    required this.value,
    required this.description,
    this.icon,
    this.iconColor,
    this.linkLabel,
    this.onLinkPressed,
    super.key,
  }) : assert(
         (linkLabel == null) == (onLinkPressed == null),
         'A link needs both a label and a destination.',
       );

  /// Localized or pre-formatted lead value, such as `70%`.
  final String value;

  /// Localized supporting explanation.
  final String description;

  /// Optional glyph shown before [value].
  ///
  /// Exists so a legend can be explained with the same icon the chart draws:
  /// naming the color in words would not survive a palette change, and the
  /// reader is looking for the shape they just saw.
  final IconData? icon;

  /// Series color for [icon]. Defaults to the card's muted ink.
  final Color? iconColor;

  /// Optional tappable line under [description], such as a URL the reader has
  /// to open. It is its own line rather than a span inside the paragraph: a
  /// link buried in running text is hard to hit with a thumb, and it survives
  /// translation, where the sentence around it moves.
  final String? linkLabel;

  /// Runs when [linkLabel] is tapped. The card opens nothing itself, so the
  /// design system stays free of a URL launcher.
  final VoidCallback? onLinkPressed;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final icon = this.icon;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.x4),
      decoration: BoxDecoration(
        color: colors.control,
        borderRadius: AppRadii.xsRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: AppSizes.iconSm,
                  color: iconColor ?? colors.inkMuted,
                ),
                const SizedBox(width: AppSpacing.x2),
              ],
              Flexible(
                child: Text(
                  value,
                  style: AppText.cardTitle.copyWith(color: colors.inkMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x1),
          Text(
            description,
            style: AppText.body.copyWith(color: colors.inkMuted),
          ),
          if (linkLabel != null) ...[
            const SizedBox(height: AppSpacing.x2),
            InkWell(
              onTap: onLinkPressed,
              borderRadius: AppRadii.xsRadius,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: AppSizes.minTouchTarget,
                ),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    linkLabel!,
                    style: AppText.body.copyWith(
                      color: colors.energy.draw,
                      decoration: TextDecoration.underline,
                      decorationColor: colors.energy.draw,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// White tooltip panel with a heading and stacked [InformationCard] children.
class InformationTooltipPanel extends StatelessWidget {
  const InformationTooltipPanel({
    required this.title,
    required this.children,
    super.key,
  });

  final String title;
  final List<InformationCard> children;

  @override
  Widget build(BuildContext context) {
    return AnchoredTooltipSurface(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.x6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: AppText.tabLabel, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.x5),
            // The panel is capped at the viewport, and how tall the cards come
            // out is a property of the translation. Scrolling the stack keeps a
            // long locale readable instead of overflowing the surface.
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var index = 0; index < children.length; index++) ...[
                      if (index > 0) const SizedBox(height: AppSpacing.x2),
                      children[index],
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
