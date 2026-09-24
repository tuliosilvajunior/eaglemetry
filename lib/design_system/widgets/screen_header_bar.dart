import 'package:flutter/material.dart';

import '../automotive_colors.dart';
import '../automotive_spacing.dart';
import '../automotive_typography.dart';

/// 64px screen-top chrome bar with the app title, an optional subtitle after
/// a vertical divider, and right-aligned trailing widgets.
///
/// Replaces the `_TopBar` / `_HistoryHeader` / `_TripHeader` /
/// `_ChargingHeader` containers previously duplicated per screen. Trailing
/// widgets are rendered as-is, so callers control the gaps between them
/// (chips usually sit `x1` apart, with `x2` before a [RefreshIconButton]).
class ScreenHeaderBar extends StatelessWidget {
  const ScreenHeaderBar({
    required this.title,
    this.subtitle,
    this.subtitleWidget,
    this.trailing = const <Widget>[],
    super.key,
  }) : assert(
         subtitle == null || subtitleWidget == null,
         'Provide subtitle or subtitleWidget, not both.',
       );

  final String title;

  /// Plain-text subtitle shown after the divider.
  final String? subtitle;

  /// Custom subtitle content (e.g. a connection badge) shown after the
  /// divider. Mutually exclusive with [subtitle].
  final Widget? subtitleWidget;

  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final hasSubtitle = subtitle != null || subtitleWidget != null;
    return Container(
      height: AutomotiveDimensions.minTouchTarget,
      padding: const EdgeInsets.symmetric(
        horizontal: AutomotiveSpacing.marginScreen,
      ),
      decoration: BoxDecoration(
        color: AutomotiveColors.surface,
        border: Border(
          bottom: BorderSide(color: AutomotiveColors.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Flexible(
            flex: 0,
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AutomotiveTextStyles.labelCaps.copyWith(
                color: AutomotiveColors.onSurface,
                letterSpacing: 2,
              ),
            ),
          ),
          if (hasSubtitle) ...[
            const SizedBox(width: AutomotiveSpacing.x2),
            Container(
              width: 1,
              height: 18,
              color: AutomotiveColors.outlineVariant,
            ),
            const SizedBox(width: AutomotiveSpacing.x2),
            Flexible(
              child: subtitleWidget != null
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: subtitleWidget,
                    )
                  : Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AutomotiveTextStyles.bodyMd.copyWith(
                        color: AutomotiveColors.onSurfaceVariant,
                      ),
                    ),
            ),
          ],
          const Spacer(),
          ...trailing,
        ],
      ),
    );
  }
}

/// Timer icon + mono clock readout for [ScreenHeaderBar.trailing].
class HeaderClock extends StatelessWidget {
  const HeaderClock({required this.value, super.key});

  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.timer, color: AutomotiveColors.onSurfaceVariant, size: 18),
        const SizedBox(width: AutomotiveSpacing.x1),
        Text(
          value,
          style: AutomotiveTextStyles.unitLabel.copyWith(
            color: AutomotiveColors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// 64px touch-target refresh action with a built-in loading spinner state.
class RefreshIconButton extends StatelessWidget {
  const RefreshIconButton({
    required this.onPressed,
    this.loading = false,
    this.tooltip,
    super.key,
  });

  final VoidCallback? onPressed;
  final bool loading;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: AutomotiveDimensions.minTouchTarget,
      height: AutomotiveDimensions.minTouchTarget,
      child: IconButton(
        tooltip: tooltip,
        onPressed: loading ? null : onPressed,
        color: AutomotiveColors.secondary,
        icon: loading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.refresh),
      ),
    );
  }
}
