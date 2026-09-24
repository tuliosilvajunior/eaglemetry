import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class InstantReadoutBarGalleryPage extends StatefulWidget {
  const InstantReadoutBarGalleryPage({super.key});

  @override
  State<InstantReadoutBarGalleryPage> createState() =>
      _InstantReadoutBarGalleryPageState();
}

enum _ReadoutSet { three, one, empty }

class _InstantReadoutBarGalleryPageState
    extends State<InstantReadoutBarGalleryPage> {
  _ReadoutSet _set = _ReadoutSet.three;

  @override
  Widget build(BuildContext context) {
    final readings = switch (_set) {
      _ReadoutSet.three => const [
        SizedBox(
          width: 280,
          child: _DemoReading(label: 'Outside', value: '18.5', unit: '°C'),
        ),
        SizedBox(
          width: 280,
          child: _DemoReading(label: 'Compass', value: '75', unit: '°'),
        ),
        SizedBox(
          width: 280,
          child: _DemoReading(label: 'Pitch', value: '3', unit: '°'),
        ),
      ],
      _ReadoutSet.one => const [
        SizedBox(
          width: 280,
          child: _DemoReading(label: 'Outside', value: '18.5', unit: '°C'),
        ),
      ],
      _ReadoutSet.empty => const <Widget>[],
    };

    return GalleryDemoPage(
      title: 'InstantReadoutBar',
      summary:
          'Journey footer. One live reading at a time, cycling on tap. '
          'Which reading is showing is this widget\'s own state.',
      note:
          'An empty list renders nothing. A single reading is not a button. '
          'Tap the strip when there are two or more.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'How many readings',
            child: TrackSegmentedControl<_ReadoutSet>(
              items: const [
                TabItem(value: _ReadoutSet.three, label: 'Three'),
                TabItem(value: _ReadoutSet.one, label: 'One'),
                TabItem(value: _ReadoutSet.empty, label: 'None'),
              ],
              selected: _set,
              onSelected: (value) => setState(() => _set = value),
            ),
          ),
          SizedBox(height: 120, child: InstantReadoutBar(readings: readings)),
        ],
      ),
    );
  }
}

class _DemoReading extends StatelessWidget {
  const _DemoReading({
    required this.label,
    required this.value,
    required this.unit,
  });

  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      title: label,
      child: MetricValue(value: value, unit: unit, size: MetricSize.md),
    );
  }
}
