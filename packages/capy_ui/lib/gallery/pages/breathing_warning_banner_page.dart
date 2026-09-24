import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class BreathingWarningBannerGalleryPage extends StatefulWidget {
  const BreathingWarningBannerGalleryPage({super.key});

  @override
  State<BreathingWarningBannerGalleryPage> createState() =>
      _BreathingWarningBannerGalleryPageState();
}

enum _BannerKind { warming, fault, still }

class _BreathingWarningBannerGalleryPageState
    extends State<BreathingWarningBannerGalleryPage> {
  _BannerKind _kind = _BannerKind.warming;
  bool _animate = true;

  @override
  Widget build(BuildContext context) {
    final spec = switch (_kind) {
      _BannerKind.warming => (
        icon: Icons.battery_charging_full,
        title: 'Warming battery for faster charging',
        message: 'Ready for up to 50 kW',
        color: AppColors.warning,
      ),
      _BannerKind.fault => (
        icon: Icons.error_outline,
        title: 'Charge paused',
        message: 'The station reported a fault. Unplug and retry.',
        color: AppColors.critical,
      ),
      _BannerKind.still => (
        icon: Icons.info_outline,
        title: 'Collection is idle',
        message: 'The car is parked and nothing is being written.',
        color: AppColors.energyGain,
      ),
    };

    return GalleryDemoPage(
      title: 'BreathingWarningBanner',
      summary:
          'Fixed-height status warning. One 2× pulse and one more-'
          'transparent 3× pulse. Text truncates on a narrow panel.',
      note:
          'animate: false freezes both rings at their initial size, which '
          'is also what reduced motion does.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Kind',
            child: TrackSegmentedControl<_BannerKind>(
              items: const [
                TabItem(value: _BannerKind.warming, label: 'Warming'),
                TabItem(value: _BannerKind.fault, label: 'Fault'),
                TabItem(value: _BannerKind.still, label: 'Idle'),
              ],
              selected: _kind,
              onSelected: (value) => setState(() => _kind = value),
            ),
          ),
          SettingToggleRow(
            label: 'Breathe',
            description: 'Turn off to judge the resting rings.',
            value: _animate,
            onChanged: (value) => setState(() => _animate = value),
          ),
          BreathingWarningBanner(
            icon: spec.icon,
            title: spec.title,
            message: spec.message,
            color: spec.color,
            animate: _animate,
          ),
        ],
      ),
    );
  }
}
