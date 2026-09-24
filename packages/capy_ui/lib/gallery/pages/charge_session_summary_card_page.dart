import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class ChargeSessionSummaryCardGalleryPage extends StatefulWidget {
  const ChargeSessionSummaryCardGalleryPage({super.key});

  @override
  State<ChargeSessionSummaryCardGalleryPage> createState() =>
      _ChargeSessionSummaryCardGalleryPageState();
}

enum _Climate { present, missing }

class _ChargeSessionSummaryCardGalleryPageState
    extends State<ChargeSessionSummaryCardGalleryPage> {
  _Climate _climate = _Climate.present;

  @override
  Widget build(BuildContext context) {
    final climate = _climate == _Climate.present ? 1.4 : null;
    return GalleryDemoPage(
      title: 'ChargeSessionSummaryCard',
      summary:
          'Last-charge summary with a battery and climate breakdown. '
          'Climate is optional because the integral behind it can fail.',
      note:
          'When climate is absent the legend still names it and prints '
          '`--`. No arc is invented for a number the car did not give.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Climate integral',
            child: TrackSegmentedControl<_Climate>(
              items: const [
                TabItem(value: _Climate.present, label: 'Measured'),
                TabItem(value: _Climate.missing, label: 'Missing'),
              ],
              selected: _climate,
              onSelected: (value) => setState(() => _climate = value),
            ),
          ),
          SizedBox(
            height: 360,
            child: ChargeSessionSummaryCard(
              title: 'Last charge',
              duration: '1 hr 12 min',
              totalEnergy: 18.4,
              totalEnergyLabel: '18.4',
              batteryEnergy: 17.0,
              batteryEnergyLabel: '17.0 kWh',
              climateEnergy: climate,
              climateEnergyLabel: climate == null ? '-- kWh' : '1.4 kWh',
              energyUnit: 'kWh',
              batterySemanticsLabel: 'Battery energy',
              climateSemanticsLabel: 'Climate energy',
              chartSemanticsLabel: 'Charge energy breakdown',
            ),
          ),
        ],
      ),
    );
  }
}
