import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// The dashboard card: a themed surface one step above the canvas.
///
/// Borderless and shadowless by design — separation comes from the surface
/// step alone (see `DESIGN.md`). Do not add a border or elevation to a card.
///
/// The header is optional. When present it is a title row that can carry a
/// leading [badge] (a `StatusBadge`), a [subtitle] beneath, and a [trailing]
/// action (usually an `InfoIconButton`).
class AppCard extends StatelessWidget {
  const AppCard({
    required this.child,
    this.title,
    this.subtitle,
    this.badge,
    this.trailing,
    this.padding = AppSpacing.cardPadding,
    super.key,
  });

  final Widget child;

  /// Localized title. Omit for a card that is all content.
  final String? title;

  /// Localized supporting line under the title (`1 hr 13 min`).
  final String? subtitle;

  /// Leading status glyph, rendered before the title.
  final Widget? badge;

  /// Trailing header action, right-aligned.
  final Widget? trailing;

  final EdgeInsetsGeometry padding;

  bool get _hasHeader =>
      title != null || subtitle != null || badge != null || trailing != null;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: AppRadii.xlRadius,
      ),
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_hasHeader) ...[
            _Header(
              title: title,
              subtitle: subtitle,
              badge: badge,
              trailing: trailing,
            ),
            const SizedBox(height: AppSpacing.x5),
          ],
          Flexible(child: child),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({this.title, this.subtitle, this.badge, this.trailing});

  final String? title;
  final String? subtitle;
  final Widget? badge;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (title != null)
                Row(
                  children: [
                    if (badge != null) ...[
                      badge!,
                      const SizedBox(width: AppSpacing.x3),
                    ],
                    Flexible(
                      child: Text(
                        title!,
                        style: AppText.cardTitle.copyWith(
                          color: AppThemeColors.of(context).ink,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              if (subtitle != null) ...[
                const SizedBox(height: AppSpacing.x1),
                Text(
                  subtitle!,
                  style: AppText.label.copyWith(
                    color: AppThemeColors.of(context).inkMuted,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}
