import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class StatusBadgeGalleryPage extends StatelessWidget {
  const StatusBadgeGalleryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'StatusBadge',
      summary:
          'Circular filled glyph that prefixes a card title. The one '
          'place a series colour may fill a shape that is not data.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Healthy',
            badge: const StatusBadge(icon: Icons.bolt),
            child: const GalleryCaption(
              'Default colour is the theme gain hue.',
            ),
          ),
          AppCard(
            title: 'Warning',
            badge: const StatusBadge(
              icon: Icons.warning_amber_rounded,
              color: AppColors.warning,
            ),
            child: const GalleryCaption('Semantic warning.'),
          ),
          AppCard(
            title: 'Fault',
            badge: const StatusBadge(
              icon: Icons.error_outline,
              color: AppColors.critical,
            ),
            child: const GalleryCaption('Semantic critical.'),
          ),
          AppCard(
            title: 'Draw',
            badge: StatusBadge(
              icon: Icons.trending_down,
              color: AppThemeColors.of(context).energy.draw,
            ),
            child: const GalleryCaption(
              'Series draw hue, used as a status light.',
            ),
          ),
        ],
      ),
    );
  }
}
