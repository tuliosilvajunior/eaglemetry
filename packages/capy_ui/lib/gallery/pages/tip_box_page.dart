import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class TipBoxGalleryPage extends StatelessWidget {
  const TipBoxGalleryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const GalleryDemoPage(
      title: 'TipBox',
      summary:
          'Recessed advisory block at the foot of a card. Same fill as '
          'an action tile, but it is not tappable.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Coach',
            child: TipBox(
              label: 'Tip',
              message:
                  'Your average speed is very efficient. Way to go, and go.',
            ),
          ),
          AppCard(
            title: 'Warning tone',
            child: TipBox(
              label: 'Note',
              message:
                  'This charge sat below 10 °C. Energy added is still true; '
                  'the rate is not what a warm pack would have taken.',
            ),
          ),
          AppCard(
            title: 'Inside a denser card',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MetricValue(value: '6.2', unit: 'km/kWh', size: MetricSize.md),
                SizedBox(height: AppSpacing.x4),
                TipBox(
                  label: 'Tip',
                  message:
                      'Keep one short paragraph. A second one belongs on '
                      'another card.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
