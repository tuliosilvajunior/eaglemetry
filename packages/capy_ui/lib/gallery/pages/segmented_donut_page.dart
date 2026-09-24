import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class SegmentedDonutGalleryPage extends StatefulWidget {
  const SegmentedDonutGalleryPage({super.key});

  @override
  State<SegmentedDonutGalleryPage> createState() =>
      _SegmentedDonutGalleryPageState();
}

class _SegmentedDonutGalleryPageState extends State<SegmentedDonutGalleryPage> {
  double _scale = 1;

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'SegmentedDonut',
      summary:
          'Three jobs, one ring: a charge breakdown, a drive split with '
          'regen as an inner arc, and a meter with an empty shortfall.',
      note:
          'Animate to new values scales every segment at once so the '
          'implicit animation can be judged on all three rings together.',
      child: GalleryStack(
        children: [
          SoftActionTile(
            icon: Icons.refresh,
            label: 'Animate to new values',
            centered: true,
            onPressed: () => setState(() => _scale = _scale > 0.9 ? 0.55 : 1.0),
          ),
          GalleryRow(
            children: [
              Expanded(child: _chargeDonut()),
              Expanded(child: _driveDonut()),
              Expanded(child: _meterDonut()),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chargeDonut() {
    return AppCard(
      title: 'Last charge session',
      subtitle: '1 d 2 hr 13 min',
      trailing: InfoIconButton(onPressed: () {}, tooltip: 'About session'),
      child: SegmentedDonut(
        segments: [
          DonutSegment(
            value: 44.0 * _scale,
            color: AppColors.energyGain,
            marker: const Icon(Icons.battery_full, size: AppSizes.iconMd),
          ),
          DonutSegment(
            value: 2.2 * _scale,
            color: AppColors.energyGainSoft,
            marker: const Icon(Icons.air, size: AppSizes.iconMd),
          ),
          DonutSegment(
            value: 0.9 * _scale,
            color: AppColors.energyGainSubtle,
            marker: const Icon(Icons.directions_car, size: AppSizes.iconMd),
          ),
          DonutSegment(
            value: 0.9 * _scale,
            color: AppColors.energyGainSoft,
            marker: const Icon(Icons.power, size: AppSizes.iconMd),
          ),
        ],
        value: (48 * _scale).toStringAsFixed(1),
        unit: 'kWh',
      ),
    );
  }

  Widget _driveDonut() {
    return AppCard(
      title: 'Session details',
      subtitle: '1 hr 13 min',
      trailing: InfoIconButton(onPressed: () {}, tooltip: 'About session'),
      child: SegmentedDonut(
        segments: [
          DonutSegment(
            value: 55.6 * _scale,
            color: AppColors.energyDraw,
            marker: const Icon(Icons.grid_view, size: AppSizes.iconMd),
          ),
          DonutSegment(
            value: 5.0 * _scale,
            color: AppColors.energyDrawSoft,
            marker: const Icon(Icons.air, size: AppSizes.iconMd),
          ),
        ],
        innerArc: DonutInnerArc(
          value: 12.2 * _scale,
          color: AppColors.energyGain,
        ),
        value: (60.6 * _scale).toStringAsFixed(1),
        unit: 'kWh',
        delta: '+${(12.2 * _scale).toStringAsFixed(1)} kWh',
      ),
    );
  }

  Widget _meterDonut() {
    return AppCard(
      title: 'Charge limit',
      child: Column(
        children: [
          SegmentedDonut(
            segments: [
              DonutSegment(value: 67 * _scale, color: AppColors.energyGain),
            ],
            total: 100,
            showTrack: true,
            value: (67 * _scale).round().toString(),
            unit: '%',
          ),
          const SizedBox(height: AppSpacing.x4),
          const GalleryCaption(
            'total sits above the segment sum, so the shortfall stays empty '
            'and the ring reads as progress.',
          ),
        ],
      ),
    );
  }
}
