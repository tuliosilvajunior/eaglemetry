import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class TrackSegmentedControlGalleryPage extends StatefulWidget {
  const TrackSegmentedControlGalleryPage({super.key});

  @override
  State<TrackSegmentedControlGalleryPage> createState() =>
      _TrackSegmentedControlGalleryPageState();
}

enum _Mode { drive, parked }

enum _Charge { idle, slow, medium, fast }

class _TrackSegmentedControlGalleryPageState
    extends State<TrackSegmentedControlGalleryPage> {
  _Mode _mode = _Mode.drive;
  _Charge _charge = _Charge.idle;

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'TrackSegmentedControl',
      summary:
          'In-card filter. Selected segment is white on the grey track — '
          'the visual inverse of the page-level pill.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Two options',
            subtitle: _mode == _Mode.drive ? 'Drive' : 'Parked',
            child: TrackSegmentedControl<_Mode>(
              items: const [
                TabItem(value: _Mode.drive, label: 'Drive'),
                TabItem(value: _Mode.parked, label: 'Parked'),
              ],
              selected: _mode,
              onSelected: (value) => setState(() => _mode = value),
            ),
          ),
          AppCard(
            title: 'Four options',
            subtitle: switch (_charge) {
              _Charge.idle => 'Charge idle',
              _Charge.slow => '7 kW',
              _Charge.medium => '48 kW',
              _Charge.fast => '80 kW',
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TrackSegmentedControl<_Charge>(
                  items: const [
                    TabItem(value: _Charge.idle, label: 'Charge idle'),
                    TabItem(value: _Charge.slow, label: '7 kW'),
                    TabItem(value: _Charge.medium, label: '48 kW'),
                    TabItem(value: _Charge.fast, label: '80 kW'),
                  ],
                  selected: _charge,
                  onSelected: (value) => setState(() => _charge = value),
                ),
                const SizedBox(height: AppSpacing.x4),
                const GalleryCaption(
                  'The selected segment is a surface step, never a series hue.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
