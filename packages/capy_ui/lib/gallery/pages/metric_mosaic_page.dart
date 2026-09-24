import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class MetricMosaicGalleryPage extends StatefulWidget {
  const MetricMosaicGalleryPage({super.key});

  @override
  State<MetricMosaicGalleryPage> createState() =>
      _MetricMosaicGalleryPageState();
}

enum _MosaicSet { trip, charge, sparse }

class _MetricMosaicGalleryPageState extends State<MetricMosaicGalleryPage> {
  _MosaicSet _set = _MosaicSet.trip;

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'MetricMosaic',
      summary: 'One hero, the rest packed around it. First fit, in order.',
      note:
          'Four spans only: small, wide, tall, hero. A mosaic whose tiles '
          'can be any size stops reading as a grid.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Set',
            child: TrackSegmentedControl<_MosaicSet>(
              items: const [
                TabItem(value: _MosaicSet.trip, label: 'Trip'),
                TabItem(value: _MosaicSet.charge, label: 'Charge'),
                TabItem(value: _MosaicSet.sparse, label: 'Sparse'),
              ],
              selected: _set,
              onSelected: (value) => setState(() => _set = value),
            ),
          ),
          AppCard(
            title: 'Mosaic',
            subtitle: switch (_set) {
              _MosaicSet.trip => 'A closed drive',
              _MosaicSet.charge => 'A closed charge',
              _MosaicSet.sparse => 'Few tiles, still first-fit',
            },
            child: SizedBox(height: 360, child: MetricMosaic(tiles: _tiles)),
          ),
        ],
      ),
    );
  }

  List<MosaicTile> get _tiles => switch (_set) {
    _MosaicSet.trip => const [
      MosaicTile(
        caption: 'Efficiency',
        value: '6.2',
        unit: 'km/kWh',
        icon: Icons.eco,
        accent: AppColors.energyGain,
        span: MosaicTileSpan.hero,
      ),
      MosaicTile(
        caption: 'Distance',
        value: '42.8',
        unit: 'km',
        icon: Icons.route,
        span: MosaicTileSpan.wide,
      ),
      MosaicTile(
        caption: 'Consumed',
        value: '6.91',
        unit: 'kWh',
        icon: Icons.bolt,
        accent: AppColors.energyDraw,
      ),
      MosaicTile(
        caption: 'Regenerated',
        value: '2.84',
        unit: 'kWh',
        icon: Icons.refresh,
        accent: AppColors.energyGain,
      ),
      MosaicTile(caption: 'Start', value: '08:14', icon: Icons.play_arrow),
      MosaicTile(caption: 'End', value: '09:02', icon: Icons.stop),
      MosaicTile(
        caption: 'Duration',
        value: '48 min',
        icon: Icons.schedule,
        span: MosaicTileSpan.wide,
      ),
      MosaicTile(
        caption: 'SOC',
        value: '82.0% -> 64.5%',
        icon: Icons.battery_full,
        span: MosaicTileSpan.wide,
      ),
      MosaicTile(
        caption: 'Temperature',
        value: '18.5°C -> 21.0°C',
        icon: Icons.thermostat,
        span: MosaicTileSpan.wide,
      ),
      MosaicTile(caption: 'Est. cost', value: '--', icon: Icons.payments),
    ],
    _MosaicSet.charge => const [
      MosaicTile(
        caption: 'Added',
        value: '18.4',
        unit: 'kWh',
        icon: Icons.battery_charging_full,
        accent: AppColors.energyGain,
        span: MosaicTileSpan.hero,
      ),
      MosaicTile(
        caption: 'Duration',
        value: '1 hr 12 min',
        icon: Icons.schedule,
        span: MosaicTileSpan.wide,
      ),
      MosaicTile(caption: 'Peak', value: '48', unit: 'kW', icon: Icons.bolt),
      MosaicTile(caption: 'Cost', value: r'$6.20', icon: Icons.payments),
    ],
    _MosaicSet.sparse => const [
      MosaicTile(
        caption: 'Range',
        value: '325',
        unit: 'km',
        icon: Icons.flag,
        span: MosaicTileSpan.hero,
      ),
      MosaicTile(caption: 'SOC', value: '82 %', icon: Icons.battery_full),
      MosaicTile(caption: 'Outside', value: '18.5 °C', icon: Icons.thermostat),
    ],
  };
}
