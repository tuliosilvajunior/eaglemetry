import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// Recessed advisory block at the foot of a card (the eco-coach tip).
///
/// Uses the same [AppColors.control] fill as the interactive tiles but is not
/// tappable, so it reads as a note rather than an action. Keep it to one short
/// paragraph.
class TipBox extends StatelessWidget {
  const TipBox({required this.label, required this.message, super.key});

  /// Localized kicker (`Tip`).
  final String label;

  /// Localized body copy.
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.x4),
      decoration: BoxDecoration(
        color: colors.control,
        borderRadius: AppRadii.mdRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: AppText.caption),
          const SizedBox(height: AppSpacing.x2),
          Text(message, style: AppText.body),
        ],
      ),
    );
  }
}
