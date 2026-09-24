import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class StatColumnGalleryPage extends StatefulWidget {
  const StatColumnGalleryPage({super.key});

  @override
  State<StatColumnGalleryPage> createState() => _StatColumnGalleryPageState();
}

class _StatColumnGalleryPageState extends State<StatColumnGalleryPage> {
  double _power = 10.8;
  String? _lastEdit;

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'StatColumn',
      summary:
          'Value, unit and supporting line. A stepper marks a setting. '
          'onPressed steps the column onto a control surface and adds a pencil.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Strip',
            subtitle: _lastEdit == null
                ? 'No editor opened'
                : 'Opened $_lastEdit',
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: StatColumn(
                    value: _power.toStringAsFixed(1),
                    unit: 'kW',
                    caption: '22 mi/hr',
                    onIncrement: () => setState(() => _power += 0.2),
                    onDecrement: () => setState(() => _power -= 0.2),
                  ),
                ),
                Expanded(
                  child: StatColumn(
                    value: r'$7.68',
                    caption: r'$0.32 / kWh',
                    onPressed: () => setState(() => _lastEdit = 'cost'),
                    editLabel: 'Edit charge cost',
                  ),
                ),
                const Expanded(
                  child: StatColumn(
                    value: '75.3',
                    unit: 'mi',
                    caption: 'Distance',
                  ),
                ),
              ],
            ),
          ),
          const AppCard(
            title: 'Reading only',
            child: Row(
              children: [
                Expanded(
                  child: StatColumn(value: '--', caption: 'No power yet'),
                ),
                Expanded(
                  child: StatColumn(value: '0.0', unit: 'kW', caption: 'Idle'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
