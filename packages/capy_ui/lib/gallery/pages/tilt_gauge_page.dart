import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class TiltGaugeGalleryPage extends StatefulWidget {
  const TiltGaugeGalleryPage({super.key});

  @override
  State<TiltGaugeGalleryPage> createState() => _TiltGaugeGalleryPageState();
}

class _TiltGaugeGalleryPageState extends State<TiltGaugeGalleryPage> {
  double? _tiltDeg = 3;

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'TiltGauge',
      summary:
          'One component, two axes. The only difference between the '
          'tiles is the silhouette.',
      note:
          'A small angle looks small. The level dashes stay put while the '
          'ground turns. Pitch is positive nose up; roll is positive right '
          'side down.',
      child: GalleryStack(
        children: [
          GalleryRow(
            children: [
              Expanded(
                child: TiltCard(
                  label: 'Pitch',
                  value: _tiltAngleLabel(_tiltDeg),
                  angleDeg: _tiltDeg,
                ),
              ),
              Expanded(
                child: TiltCard(
                  label: 'Roll',
                  value: _tiltAngleLabel(_tiltDeg),
                  angleDeg: _tiltDeg,
                  silhouette: CarSilhouette.front,
                ),
              ),
            ],
          ),
          AppCard(
            title: 'Tilt input',
            subtitle: 'Both tiles read the same value',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TrackSegmentedControl<double?>(
                  items: const [
                    TabItem(value: -12, label: '-12°'),
                    TabItem(value: -3, label: '-3°'),
                    TabItem(value: 0, label: '0°'),
                    TabItem(value: 3, label: '3°'),
                    TabItem(value: 12, label: '12°'),
                    TabItem(value: null, label: '--'),
                  ],
                  selected: _tiltDeg,
                  onSelected: (value) => setState(() => _tiltDeg = value),
                ),
                const SizedBox(height: AppSpacing.x4),
                const GalleryCaption(
                  'Pitch turns the side art counter-clockwise for a positive '
                  'angle. Roll lowers the left of the front drawing. Pick `--` '
                  'to see a tile with no reading.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _tiltAngleLabel(double? degrees) {
  if (degrees == null || !degrees.isFinite) return '--';
  final rounded = degrees.roundToDouble();
  return '${rounded == 0 ? 0 : rounded.toInt()}°';
}
