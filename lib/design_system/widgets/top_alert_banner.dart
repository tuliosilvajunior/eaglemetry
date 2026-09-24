import 'package:flutter/material.dart';

import '../automotive_colors.dart';
import '../automotive_spacing.dart';
import '../automotive_typography.dart';
import 'technical_panel.dart';

class TopAlertBanner extends StatelessWidget {
  const TopAlertBanner({
    required this.title,
    required this.message,
    required this.dismissLabel,
    required this.onDismiss,
    this.icon = Icons.error_outline,
    super.key,
  });

  final String title;
  final String message;
  final String dismissLabel;
  final VoidCallback onDismiss;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      liveRegion: true,
      child: TechnicalPanel(
        padding: AutomotiveSpacing.panelPadding,
        color: AutomotiveColors.errorContainer.withValues(alpha: 0.96),
        borderColor: AutomotiveColors.error,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: AutomotiveColors.error, size: 20),
            const SizedBox(width: AutomotiveSpacing.x2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: AutomotiveTextStyles.labelCaps.copyWith(
                      color: AutomotiveColors.error,
                    ),
                  ),
                  const SizedBox(height: AutomotiveSpacing.x0_5),
                  Text(
                    message,
                    style: AutomotiveTextStyles.bodyMd.copyWith(
                      color: AutomotiveColors.onErrorContainer,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AutomotiveSpacing.x2),
            TextButton(
              onPressed: onDismiss,
              style: TextButton.styleFrom(
                foregroundColor: AutomotiveColors.error,
                minimumSize: const Size(96, 64),
                textStyle: AutomotiveTextStyles.labelCaps,
              ),
              child: Text(dismissLabel),
            ),
          ],
        ),
      ),
    );
  }
}
