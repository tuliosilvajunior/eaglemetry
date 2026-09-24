import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class CapyFaceGalleryPage extends StatelessWidget {
  const CapyFaceGalleryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'CapyFace',
      summary:
          'The mascot, one file per expression per direction. Full colour '
          'and never tinted, unlike every other image in this package. A '
          'mood reads the app state; it never carries that state alone.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'The nine moods',
            child: Wrap(
              spacing: AppSpacing.x4,
              runSpacing: AppSpacing.x4,
              children: [
                for (final mood in CapyMood.values)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CapyFace(mood: mood, size: 96),
                      const SizedBox(height: AppSpacing.x2),
                      GalleryCaption(mood.name),
                    ],
                  ),
              ],
            ),
          ),
          AppCard(
            title: 'The two directions',
            subtitle:
                'Both sets hold all nine moods and share one box, so the '
                'head keeps its centre and its scale either way.',
            child: Wrap(
              spacing: AppSpacing.x4,
              runSpacing: AppSpacing.x4,
              children: [
                for (final direction in CapyDirection.values)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CapyFace(
                        mood: CapyMood.happy,
                        direction: direction,
                        size: 96,
                      ),
                      const SizedBox(height: AppSpacing.x2),
                      GalleryCaption(direction.name),
                    ],
                  ),
              ],
            ),
          ),
          AppCard(
            title: 'CapyBadge',
            subtitle: 'The mark: a face on a surface disc.',
            child: Wrap(
              spacing: AppSpacing.x6,
              runSpacing: AppSpacing.x4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const CapyBadge(diameter: 120),
                const CapyBadge(
                  diameter: 120,
                  mood: CapyMood.delighted,
                  badge: Icons.check_circle,
                ),
                CapyBadge(
                  diameter: 120,
                  mood: CapyMood.worried,
                  badge: Icons.error_outline,
                  badgeColor: AppThemeColors.of(context).energy.warning,
                ),
                const CapyBadge(diameter: 52),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
