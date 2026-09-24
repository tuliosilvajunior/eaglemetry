import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class EntranceGateGalleryPage extends StatefulWidget {
  const EntranceGateGalleryPage({super.key});

  @override
  State<EntranceGateGalleryPage> createState() =>
      _EntranceGateGalleryPageState();
}

class _EntranceGateGalleryPageState extends State<EntranceGateGalleryPage> {
  bool _open = false;
  int _generation = 0;

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'EntranceGate',
      summary:
          'Decides whether the subtree may mount yet, so an entrance '
          'plays on arrival instead of behind a transition.',
      note:
          'Closed, the placeholder holds the footprint. Open, the donut '
          'mounts and animates from zero. Remount replays it. The gate has '
          'no visual of its own.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Gate',
            child: Column(
              children: [
                SettingToggleRow(
                  label: 'Open',
                  description: 'Mount the donut and let it enter.',
                  value: _open,
                  onChanged: (value) => setState(() => _open = value),
                ),
                const SizedBox(height: AppSpacing.x3),
                SoftActionTile(
                  icon: Icons.replay,
                  label: 'Remount the subtree',
                  onPressed: () => setState(() {
                    _open = true;
                    _generation++;
                  }),
                ),
              ],
            ),
          ),
          AppCard(
            title: 'Gated donut',
            child: SizedBox(
              height: 220,
              child: EntranceGate(
                key: ValueKey(_generation),
                open: _open,
                child: Builder(
                  builder: (context) => EntranceGate.guard(
                    context,
                    () => const SegmentedDonut(
                      segments: [
                        DonutSegment(value: 44, color: AppColors.energyGain),
                        DonutSegment(value: 4, color: AppColors.energyGainSoft),
                      ],
                      value: '48',
                      unit: 'kWh',
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
