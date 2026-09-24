import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class InformationCardGalleryPage extends StatelessWidget {
  const InformationCardGalleryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'InformationCard',
      summary:
          'Muted information block inside an explanatory tooltip. An '
          'optional icon carries the series colour the chart already uses.',
      child: GalleryStack(
        children: [
          const AppCard(
            title: 'Plain values',
            child: Column(
              children: [
                InformationCard(
                  value: '70%',
                  description: 'For daily driving and shorter charging times.',
                ),
                SizedBox(height: AppSpacing.x3),
                InformationCard(
                  value: '85%',
                  description: 'Travel an extended distance on one charge.',
                ),
                SizedBox(height: AppSpacing.x3),
                InformationCard(
                  value: '100%',
                  description: 'For max range and longer charging times.',
                ),
              ],
            ),
          ),
          AppCard(
            title: 'With series icons',
            child: Column(
              children: [
                InformationCard(
                  value: '55.6 kWh',
                  description: 'Traction. The same glyph the donut draws.',
                  icon: Icons.trending_down,
                  iconColor: AppThemeColors.of(context).energy.draw,
                ),
                const SizedBox(height: AppSpacing.x3),
                InformationCard(
                  value: '12.2 kWh',
                  description: 'Regeneration returned to the pack.',
                  icon: Icons.trending_up,
                  iconColor: AppThemeColors.of(context).energy.gain,
                ),
              ],
            ),
          ),
          const AppCard(
            title: 'As a panel',
            child: InformationTooltipPanel(
              title: 'Which charge limit should I pick?',
              children: [
                InformationCard(
                  value: '70%',
                  description: 'For daily driving and shorter charging times.',
                ),
                InformationCard(
                  value: '85%',
                  description: 'Travel an extended distance on one charge.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
