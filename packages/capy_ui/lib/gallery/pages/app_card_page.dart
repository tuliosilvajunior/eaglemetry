import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class AppCardGalleryPage extends StatelessWidget {
  const AppCardGalleryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const GalleryDemoPage(
      title: 'AppCard',
      summary:
          'The dashboard surface. Separation comes from the surface step, '
          'never from a border or a shadow.',
      note:
          'A card with no header is still a card. The badge is a status '
          'light, the trailing action is usually an info button.',
      child: GalleryStack(
        children: [
          GalleryRow(
            children: [
              Expanded(
                child: AppCard(
                  title: 'Title only',
                  child: Text(
                    'A card can carry just a title.',
                    style: AppText.body,
                  ),
                ),
              ),
              Expanded(
                child: AppCard(
                  title: 'With subtitle',
                  subtitle: '1 hr 13 min',
                  child: Text(
                    'The subtitle is supporting time or scope.',
                    style: AppText.body,
                  ),
                ),
              ),
              Expanded(
                child: AppCard(
                  badge: StatusBadge(icon: Icons.bolt),
                  title: 'With badge',
                  subtitle: 'Charging',
                  trailing: InfoIconButton(onPressed: null, tooltip: 'About'),
                  child: Text(
                    'Badge, title, subtitle and trailing together.',
                    style: AppText.body,
                  ),
                ),
              ),
            ],
          ),
          AppCard(
            child: Text(
              'No header. Use this when the content names itself — a chart, a mosaic, a control strip.',
              style: AppText.body,
            ),
          ),
        ],
      ),
    );
  }
}
