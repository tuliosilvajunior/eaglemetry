import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import 'floating_surface.dart';
import 'soft_action_tile.dart';

/// Asks before an action that cannot be undone.
///
/// Centered like the category menu and on the same scrim, but deliberately
/// narrow: this surface exists to be read, not navigated, and a wide one
/// invites the eye to the buttons before the sentence.
///
/// Returns true only for the confirming action. A tap on the scrim, the cancel
/// action, and a back gesture all return null or false — a destructive action
/// must never be reachable by dismissing something.
Future<bool?> showConfirmDialog({
  required BuildContext context,
  required String title,
  required String message,
  required String confirmLabel,
  required String cancelLabel,
  required String barrierLabel,
  bool destructive = false,
}) {
  return showFloatingSurface<bool>(
    context: context,
    barrierLabel: barrierLabel,
    pageBuilder: (context, animation, secondaryAnimation) => _ConfirmDialog(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      destructive: destructive,
    ),
  );
}

class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.destructive,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final safePadding = MediaQuery.paddingOf(context);
    final available =
        MediaQuery.sizeOf(context).width -
        safePadding.horizontal -
        AppSpacing.x12;

    return Center(
      child: SizedBox(
        key: const Key('confirm-dialog'),
        width: math.min(available, AppSizes.confirmDialogWidth),
        child: Material(
          color: colors.surface,
          borderRadius: AppRadii.xlRadius,
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: AppSpacing.cardPadding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  style: AppText.cardTitle.copyWith(color: colors.ink),
                ),
                const SizedBox(height: AppSpacing.x3),
                Text(
                  message,
                  style: AppText.body.copyWith(color: colors.inkMuted),
                ),
                const SizedBox(height: AppSpacing.x6),
                Row(
                  children: [
                    Expanded(
                      child: SoftActionTile(
                        label: cancelLabel,
                        centered: true,
                        onPressed: () => Navigator.of(context).pop(false),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.x3),
                    Expanded(
                      child: SoftActionTile(
                        label: confirmLabel,
                        centered: true,
                        // Semantic colour goes on the glyph, never the row —
                        // see the iconography rule in `DESIGN.md`.
                        icon: destructive ? Icons.warning_amber : null,
                        iconColor: destructive
                            ? AppThemeColors.of(context).energy.critical
                            : null,
                        onPressed: () => Navigator.of(context).pop(true),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
