import 'package:flutter/material.dart';

import '../capy_ui.dart';

/// Shared chrome for a single-component gallery page.
///
/// The back button appears only when this page was pushed from the catalog.
/// A standalone `*_main.dart` harness keeps its own scaffold and does not
/// go through here.
class GalleryDemoPage extends StatelessWidget {
  const GalleryDemoPage({
    required this.title,
    required this.summary,
    required this.child,
    this.note,
    this.scrollable = true,
    super.key,
  });

  final String title;
  final String summary;

  /// Optional "what to look for" line. Demo copy, not product copy.
  final String? note;

  final Widget child;

  /// False for a page whose body must fill the remaining viewport — a
  /// journey scaffold, a climate bar on its own ground.
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final header = _GalleryHeader(title: title, summary: summary, note: note);

    if (!scrollable) {
      return Scaffold(
        backgroundColor: colors.canvas,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              header,
              const SizedBox(height: AppSpacing.gridGutter),
              Expanded(child: child),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            header,
            Padding(padding: AppSpacing.screenPadding, child: child),
          ],
        ),
      ),
    );
  }
}

/// Thin back strip used when a pre-existing harness screen is pushed from
/// the catalog. Standalone `*_main.dart` entries see `canPop == false` and
/// paint the harness unchanged.
class GalleryHarnessShell extends StatelessWidget {
  const GalleryHarnessShell({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!Navigator.of(context).canPop()) return child;
    final colors = AppThemeColors.of(context);
    return Column(
      children: [
        Material(
          color: colors.canvas,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.x3,
                AppSpacing.x2,
                AppSpacing.x3,
                0,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: SquareIconButton(
                  icon: Icons.arrow_back,
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: 'Back to catalog',
                ),
              ),
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _GalleryHeader extends StatelessWidget {
  const _GalleryHeader({
    required this.title,
    required this.summary,
    required this.note,
  });

  final String title;
  final String summary;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final canPop = Navigator.of(context).canPop();
    return Padding(
      padding: AppSpacing.screenPadding.copyWith(bottom: 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (canPop) ...[
                SquareIconButton(
                  icon: Icons.arrow_back,
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: 'Back to catalog',
                ),
                const SizedBox(width: AppSpacing.x3),
              ],
              Expanded(
                child: Text(
                  title,
                  style: AppText.cardTitle.copyWith(color: colors.ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x2),
          Text(summary, style: AppText.body.copyWith(color: colors.inkMuted)),
          if (note != null) ...[
            const SizedBox(height: AppSpacing.x3),
            TipBox(label: 'Look for', message: note!),
          ],
        ],
      ),
    );
  }
}
