import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class SocSpanBarGalleryPage extends StatelessWidget {
  const SocSpanBarGalleryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'SocSpanBar',
      summary:
          'What one recorded session did to the battery, drawn as the '
          'stretch between its two ends.',
      note:
          'The scale is always the whole battery, so two sessions can be '
          'compared by looking at them. The direction is read from the two '
          'ends alone.',
      child: GalleryStack(
        children: [
          const AppCard(
            title: 'A drive',
            child: SocSpanBar(
              startPercent: 82,
              endPercent: 63,
              startLabel: '82%',
              endLabel: '63%',
            ),
          ),
          const AppCard(
            title: 'A charge',
            child: Column(
              children: [
                SocSpanBar(
                  startPercent: 34,
                  endPercent: 80,
                  startLabel: '34%',
                  endLabel: '80%',
                ),
                SizedBox(height: AppSpacing.x4),
                GalleryCaption(
                  'The same component. A session that gained takes the gain '
                  'hue; one that lost takes the critical hue. Nothing else '
                  'decides which.',
                ),
              ],
            ),
          ),
          const AppCard(
            title: 'The edges',
            child: Column(
              children: [
                SocSpanBar(
                  startPercent: 100,
                  endPercent: 0,
                  startLabel: '100%',
                  endLabel: '0%',
                ),
                SizedBox(height: AppSpacing.x4),
                SocSpanBar(
                  startPercent: 55,
                  endPercent: 55,
                  startLabel: '55%',
                  endLabel: '55%',
                ),
                SizedBox(height: AppSpacing.x4),
                GalleryCaption(
                  'A whole battery spent, and a session that moved it by '
                  'nothing. The second draws no span rather than dividing by '
                  'a zero one.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
