import 'package:flutter/material.dart';

import '../automotive_colors.dart';
import '../automotive_spacing.dart';
import '../automotive_typography.dart';
import 'technical_panel.dart';

/// Centered loading placeholder used while telemetry data loads.
class LoadingPanel extends StatelessWidget {
  const LoadingPanel({this.height = 180, super.key});

  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: const Center(child: CircularProgressIndicator()),
    );
  }
}

/// Error surface that keeps the native bridge error visible instead of
/// hiding it behind optimistic UI.
class ErrorPanel extends StatelessWidget {
  const ErrorPanel({
    required this.message,
    this.icon,
    this.padding = AutomotiveSpacing.panelPadding,
    super.key,
  });

  final String message;
  final IconData? icon;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      message,
      style: AutomotiveTextStyles.unitLabel.copyWith(
        color: AutomotiveColors.onErrorContainer,
      ),
    );
    return TechnicalPanel(
      padding: padding,
      color: AutomotiveColors.errorContainer.withValues(alpha: 0.22),
      borderColor: AutomotiveColors.error,
      child: icon == null
          ? text
          : Row(
              children: [
                Icon(icon, color: AutomotiveColors.onErrorContainer),
                const SizedBox(width: AutomotiveSpacing.x2),
                Expanded(child: text),
              ],
            ),
    );
  }
}

/// Empty/placeholder surface for lists and detail panels.
class EmptyStatePanel extends StatelessWidget {
  const EmptyStatePanel({
    required this.message,
    this.icon,
    this.padding = AutomotiveSpacing.panelPadding,
    super.key,
  });

  final String message;
  final Widget? icon;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final content = <Widget>[
      if (icon != null) ...[
        IconTheme(
          data: IconThemeData(
            color: AutomotiveColors.onSurfaceVariant,
            size: 32,
          ),
          child: icon!,
        ),
        const SizedBox(width: AutomotiveSpacing.x2),
      ],
      Flexible(
        child: Text(
          message,
          overflow: TextOverflow.ellipsis,
          style: AutomotiveTextStyles.bodyMd.copyWith(
            color: AutomotiveColors.onSurfaceVariant,
          ),
        ),
      ),
    ];

    return TechnicalPanel(
      padding: padding,
      child: icon != null
          ? Row(mainAxisAlignment: MainAxisAlignment.center, children: content)
          : Text(
              message,
              style: AutomotiveTextStyles.unitLabel.copyWith(
                color: AutomotiveColors.onSurfaceVariant,
              ),
            ),
    );
  }
}
