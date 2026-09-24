import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class CycleBarGalleryPage extends StatefulWidget {
  const CycleBarGalleryPage({super.key});

  @override
  State<CycleBarGalleryPage> createState() => _CycleBarGalleryPageState();
}

class _CycleBarGalleryPageState extends State<CycleBarGalleryPage> {
  double _fill = 41;

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'CycleBar',
      summary:
          'One battery cycle as a static pill. The scale is always the '
          'whole battery.',
      note:
          'A closed cycle fills the pill. An open one fills what it has '
          'reached. A partial one — collection joined in the middle — never '
          'reaches the end.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Live fill',
            subtitle: '${_fill.round()} %',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CycleBar(
                  fillPercent: _fill,
                  leadingLabel: '#6',
                  valueLabel: _fill.round().toString(),
                  valueUnit: '%',
                ),
                const SizedBox(height: AppSpacing.x6),
                TrackSegmentedControl<double>(
                  items: const [
                    TabItem(value: 0, label: '0'),
                    TabItem(value: 12, label: '12'),
                    TabItem(value: 41, label: '41'),
                    TabItem(value: 62, label: '62'),
                    TabItem(value: 100, label: '100'),
                  ],
                  selected: _nearest(_fill),
                  onSelected: (value) => setState(() => _fill = value),
                ),
              ],
            ),
          ),
          const AppCard(
            title: 'The three records',
            child: Column(
              children: [
                CycleBar(
                  fillPercent: 100,
                  leadingLabel: '#5',
                  valueLabel: '100',
                  valueUnit: '%',
                ),
                SizedBox(height: AppSpacing.x2),
                CycleBar(
                  fillPercent: 41,
                  leadingLabel: '#6',
                  valueLabel: '41',
                  valueUnit: '%',
                ),
                SizedBox(height: AppSpacing.x2),
                CycleBar(
                  fillPercent: 62,
                  leadingLabel: '#1',
                  valueLabel: '62',
                  valueUnit: '%',
                  isPartial: true,
                ),
                SizedBox(height: AppSpacing.x4),
                GalleryCaption(
                  'Closed, open, and partial. The last one never paints the '
                  'right end of the pill.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  double _nearest(double value) {
    const options = [0.0, 12.0, 41.0, 62.0, 100.0];
    return options.reduce(
      (best, next) => (next - value).abs() < (best - value).abs() ? next : best,
    );
  }
}
