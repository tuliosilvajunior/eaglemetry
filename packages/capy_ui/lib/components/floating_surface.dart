import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';

/// Shared floating-panel route used by every overlay that appears above the
/// scrim with the 97% entry scale.
///
/// This is the one place that knows the four facts every floating surface
/// shares: [AppThemeColors.modalScrim], [AppMotion.base], the 0.97 → 1
/// scale + fade, and the reduced-motion branch. Callers supply only the
/// [pageBuilder]; the scrim, timing, and transition live here so a motion
/// change is one commit, not four.
Future<T?> showFloatingSurface<T>({
  required BuildContext context,
  required String barrierLabel,
  required Widget Function(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  )
  pageBuilder,
  bool barrierDismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: barrierLabel,
    barrierColor: AppThemeColors.of(context).modalScrim,
    transitionDuration: AppMotion.base,
    pageBuilder: pageBuilder,
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      if (MediaQuery.disableAnimationsOf(context)) return child;
      final curved = CurvedAnimation(parent: animation, curve: AppMotion.curve);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.97, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// The surface chrome every floating panel shares.
///
/// One place knows how a panel meets the screen: bounded width, bounded
/// height, and lifted above the keyboard ([MediaQuery.viewInsets]) so an
/// input inside it never hides behind the IME. The bounded height is what
/// lets the body's own scroll view actually scroll instead of growing past
/// the viewport.
class FloatingPanel extends StatelessWidget {
  const FloatingPanel({required this.child, this.maxWidth = 560, super.key});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final media = MediaQuery.of(context);
    final width = math.min(
      media.size.width - media.padding.horizontal - AppSpacing.x12,
      maxWidth,
    );
    final maxHeight = math.max(
      240.0,
      media.size.height -
          media.padding.vertical -
          media.viewInsets.bottom -
          AppSpacing.x12,
    );
    return Padding(
      // Lifts the whole panel above the keyboard while it is open.
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: SizedBox(
            key: floatingPanelKey,
            width: width,
            child: Material(
              color: colors.surface,
              borderRadius: AppRadii.xlRadius,
              clipBehavior: Clip.antiAlias,
              child: Padding(padding: AppSpacing.cardPadding, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// Test handle for the sized panel box.
const Key floatingPanelKey = Key('floating-panel');
