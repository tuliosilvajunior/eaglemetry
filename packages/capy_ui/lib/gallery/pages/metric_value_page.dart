import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class MetricValueGalleryPage extends StatefulWidget {
  const MetricValueGalleryPage({super.key});

  @override
  State<MetricValueGalleryPage> createState() => _MetricValueGalleryPageState();
}

class _MetricValueGalleryPageState extends State<MetricValueGalleryPage> {
  var _size = MetricSize.lg;
  var _unit = 'km';

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'MetricValue',
      summary:
          'Value and unit as separate runs sharing a baseline. Tabular '
          'figures so a live number does not jitter.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Energy',
            trailing: InfoIconButton(onPressed: () {}, tooltip: 'About range'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MetricWithCaption(
                  value: _unit == 'km' ? '325' : '202',
                  unit: _unit == 'km' ? 'km' : 'mi',
                  caption: 'Range based on All-Purpose',
                  trailing: SquareIconButton(
                    icon: Icons.swap_horiz,
                    onPressed: () =>
                        setState(() => _unit = _unit == 'km' ? 'mi' : 'km'),
                    tooltip: 'Swap unit',
                  ),
                ),
                const SizedBox(height: AppSpacing.x6),
                const GalleryCaption('Sizes'),
                const SizedBox(height: AppSpacing.x3),
                TrackSegmentedControl<MetricSize>(
                  items: const [
                    TabItem(value: MetricSize.xl, label: 'XL'),
                    TabItem(value: MetricSize.lg, label: 'LG'),
                    TabItem(value: MetricSize.md, label: 'MD'),
                    TabItem(value: MetricSize.sm, label: 'SM'),
                  ],
                  selected: _size,
                  onSelected: (value) => setState(() => _size = value),
                ),
                const SizedBox(height: AppSpacing.x4),
                MetricValue(value: '48', unit: 'kWh', size: _size),
                const SizedBox(height: AppSpacing.x6),
                const GalleryCaption('Fixed sizes'),
                const SizedBox(height: AppSpacing.x3),
                const MetricValue(
                  value: '48',
                  unit: 'kWh',
                  size: MetricSize.lg,
                ),
                const SizedBox(height: AppSpacing.x3),
                const MetricValue(
                  value: '60.6',
                  unit: 'kWh',
                  size: MetricSize.md,
                ),
                const SizedBox(height: AppSpacing.x3),
                const MetricValue(
                  value: '2.18',
                  unit: 'mi/kWh',
                  size: MetricSize.sm,
                ),
                const SizedBox(height: AppSpacing.x6),
                const GalleryCaption('Series colors'),
                const SizedBox(height: AppSpacing.x3),
                const GallerySwatches(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
