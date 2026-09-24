import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

enum _MockCharge { idle, slow, medium, fast }

class LimitSliderGalleryPage extends StatefulWidget {
  const LimitSliderGalleryPage({super.key});

  @override
  State<LimitSliderGalleryPage> createState() => _LimitSliderGalleryPageState();
}

class _LimitSliderGalleryPageState extends State<LimitSliderGalleryPage> {
  double _chargeLimit = 85;
  double _currentCharge = 67;
  _MockCharge _mockCharge = _MockCharge.idle;
  bool _draggingChargeLimit = false;
  int _preset = 2;

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'LimitSlider',
      summary:
          'Charge-target slider. The pill is the full 0–100 % battery. '
          'The selectable range is 50–100 %.',
      note:
          'Light-gray 10 % guides appear only while dragging. At 100 % the '
          'knob stays inside the end cap. When the target is below the current '
          'charge, an 8 px cut marks it through the green fill.',
      child: GalleryStack(
        children: [
          AppCard(
            badge: const StatusBadge(icon: Icons.bolt),
            title: 'Live target',
            subtitle: '${_chargeLimit.round()} %',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TrackSegmentedControl<_MockCharge>(
                  items: const [
                    TabItem(value: _MockCharge.idle, label: 'Charge idle'),
                    TabItem(value: _MockCharge.slow, label: '7 kW'),
                    TabItem(value: _MockCharge.medium, label: '48 kW'),
                    TabItem(value: _MockCharge.fast, label: '80 kW'),
                  ],
                  selected: _mockCharge,
                  onSelected: (value) => setState(() => _mockCharge = value),
                ),
                const SizedBox(height: AppSpacing.x4),
                const GalleryCaption('Present charge'),
                const SizedBox(height: AppSpacing.x3),
                TrackSegmentedControl<double>(
                  items: const [
                    TabItem(value: 40, label: '40%'),
                    TabItem(value: 67, label: '67%'),
                    TabItem(value: 80, label: '80%'),
                    TabItem(value: 100, label: '100%'),
                  ],
                  selected: _currentCharge,
                  onSelected: (value) => setState(() => _currentCharge = value),
                ),
                const SizedBox(height: AppSpacing.x6),
                SizedBox(
                  height:
                      AppSizes.minTouchTarget +
                      AppSpacing.x2 +
                      AppSizes.limitSliderHeight,
                  child: LimitSlider(
                    value: _chargeLimit,
                    current: _currentCharge,
                    isCharging: _mockCharge != _MockCharge.idle,
                    chargingPowerKw: switch (_mockCharge) {
                      _MockCharge.idle => null,
                      _MockCharge.slow => 7,
                      _MockCharge.medium => 48,
                      _MockCharge.fast => 80,
                    },
                    currentLabel: _currentCharge.round().toString(),
                    currentUnit: '%',
                    valueLabel: _chargeLimit.round().toString(),
                    valueUnit: '%',
                    caption: _chargeLimit < _currentCharge
                        ? 'Target is below the present charge'
                        : '${(_chargeLimit * 3.13).round()} miles projected',
                    semanticsLabel: 'Charge limit',
                    semanticsValue: '${_chargeLimit.round()} percent',
                    increasedValue:
                        '${(_chargeLimit + 5).clamp(0, 100).round()} percent',
                    decreasedValue:
                        '${(_chargeLimit - 5).clamp(0, 100).round()} percent',
                    onChanged: _setChargeLimit,
                    onDraggingChanged: _onChargeLimitDragging,
                  ),
                ),
                const SizedBox(height: AppSpacing.x6),
                const GalleryCaption('Presets'),
                const SizedBox(height: AppSpacing.x3),
                Row(
                  children: [
                    for (var i = 0; i < 4; i++) ...[
                      if (i > 0) const SizedBox(width: AppSpacing.x3),
                      Expanded(
                        child: SelectableTile(
                          value: i == 0
                              ? (_preset == 0
                                    ? '${_chargeLimit.round()}%'
                                    : '--')
                              : const ['70%', '85%', '100%'][i - 1],
                          label: const [
                            'Custom',
                            'Daily',
                            'Extended',
                            'Max',
                          ][i],
                          selected: _preset == i,
                          onPressed: () => _selectPreset(i),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _setChargeLimit(double value) {
    setState(() {
      _chargeLimit = value;
      _preset = _draggingChargeLimit ? 0 : _presetFor(value);
    });
  }

  void _onChargeLimitDragging(bool dragging) {
    setState(() {
      _draggingChargeLimit = dragging;
      _preset = dragging ? 0 : _presetFor(_chargeLimit);
    });
  }

  int _presetFor(double value) => switch (value) {
    70 => 1,
    85 => 2,
    100 => 3,
    _ => 0,
  };

  void _selectPreset(int index) {
    if (index == 0) {
      setState(() => _preset = index);
      return;
    }
    _setChargeLimit(const [0.0, 70.0, 85.0, 100.0][index]);
  }
}
