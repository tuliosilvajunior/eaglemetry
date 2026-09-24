import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class IconValueGridGalleryPage extends StatefulWidget {
  const IconValueGridGalleryPage({super.key});

  @override
  State<IconValueGridGalleryPage> createState() =>
      _IconValueGridGalleryPageState();
}

class _IconValueGridGalleryPageState extends State<IconValueGridGalleryPage> {
  int _columns = 2;

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'IconValueGrid',
      summary:
          'Compact legend under a donut. The glyph is the key — it '
          'repeats the icon shown on the ring.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Session details',
            subtitle: '1 hr 13 min',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TrackSegmentedControl<int>(
                  items: const [
                    TabItem(value: 1, label: '1 col'),
                    TabItem(value: 2, label: '2 col'),
                    TabItem(value: 4, label: '4 col'),
                  ],
                  selected: _columns,
                  onSelected: (value) => setState(() => _columns = value),
                ),
                const SizedBox(height: AppSpacing.x6),
                IconValueGrid(
                  columns: _columns,
                  entries: const [
                    IconValueEntry(icon: Icons.grid_view, value: '55.6 kWh'),
                    IconValueEntry(icon: Icons.air, value: '3.4 kWh'),
                    IconValueEntry(icon: Icons.power, value: '1.2 kWh'),
                    IconValueEntry(
                      icon: Icons.directions_car,
                      value: '0.3 kWh',
                    ),
                  ],
                ),
              ],
            ),
          ),
          const AppCard(
            title: 'Tinted to match segments',
            child: IconValueGrid(
              columns: 1,
              entries: [
                IconValueEntry(
                  icon: Icons.trending_down,
                  value: '55.6 kWh',
                  color: AppColors.energyDraw,
                ),
                IconValueEntry(
                  icon: Icons.trending_up,
                  value: '12.2 kWh',
                  color: AppColors.energyGain,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
