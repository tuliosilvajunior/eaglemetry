import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:capy_ui/capy_ui.dart';

import '../core/app_experience_controller.dart';
import '../l10n/app_localizations.dart';

/// Shows the Version 1.0 Experience announcement dialog.
///
/// Announced on first startup of version 1.0. Explains that this is a new app
/// experience undergoing continuous feedback & fixes, and that the legacy mode
/// remains accessible in Settings. Once dismissed or acted upon, it is marked
/// as seen and will never open again.
Future<void> showExperienceWelcomeDialog(BuildContext context) async {
  final controller = AppExperienceController.instance;
  if (controller.welcomeSeen) return;

  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: AppLocalizations.of(context)?.settingsCancel ?? 'Close',
    barrierColor: AppThemeColors.of(context).modalScrim,
    transitionDuration: AppMotion.base,
    pageBuilder: (context, animation, secondaryAnimation) =>
        const _ExperienceWelcomeDialog(),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      if (MediaQuery.disableAnimationsOf(context)) return child;
      final curved = CurvedAnimation(parent: animation, curve: AppMotion.curve);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );

  // Mark as seen so it never shows again, even if dismissed by tapping barrier.
  await controller.setWelcomeSeen(true);
}

class _ExperienceWelcomeDialog extends StatelessWidget {
  const _ExperienceWelcomeDialog();

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final loc = AppLocalizations.of(context)!;
    final safePadding = MediaQuery.paddingOf(context);
    final available =
        MediaQuery.sizeOf(context).width -
        safePadding.horizontal -
        AppSpacing.x12;

    return Center(
      child: SizedBox(
        key: const Key('experience-welcome-dialog'),
        width: math.min(available, AppSizes.confirmDialogWidth + 40),
        child: Material(
          color: colors.surface,
          borderRadius: AppRadii.xlRadius,
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            child: Padding(
              padding: AppSpacing.cardPadding,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: colors.selectionFill,
                          borderRadius: AppRadii.mdRadius,
                        ),
                        child: Icon(
                          Icons.auto_awesome,
                          color: colors.onSelection,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.x3),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              loc.v1WelcomeTitle,
                              style: AppText.cardTitle.copyWith(
                                color: colors.ink,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'v1.0',
                              style: AppText.caption.copyWith(
                                color: colors.inkMuted,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.x4),
                  Text(
                    loc.v1WelcomeBody,
                    style: AppText.body.copyWith(
                      color: colors.inkMuted,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.x6),
                  Column(
                    children: [
                      SoftActionTile(
                        label: loc.v1WelcomeConfirm,
                        selected: true,
                        centered: true,
                        onPressed: () {
                          Navigator.of(context).pop();
                        },
                      ),
                      const SizedBox(height: AppSpacing.x2),
                      SoftActionTile(
                        label: loc.v1WelcomeUseLegacy,
                        centered: true,
                        onPressed: () async {
                          await AppExperienceController.instance
                              .setNewUiEnabled(false);
                          if (context.mounted) {
                            Navigator.of(context).pop();
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
