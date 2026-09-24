import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class ClimateControlCardGalleryPage extends StatefulWidget {
  const ClimateControlCardGalleryPage({super.key});

  @override
  State<ClimateControlCardGalleryPage> createState() =>
      _ClimateControlCardGalleryPageState();
}

class _ClimateControlCardGalleryPageState
    extends State<ClimateControlCardGalleryPage> {
  double _tempC = 21.5;
  bool _auto = false;
  int _fan = 3;
  bool _ac = true;
  bool _sync = false;
  bool _defrost = false;
  bool _seatHeat = false;
  bool _wheelHeat = false;
  bool _petMode = false;

  static const _minTempC = 15.5;
  static const _maxTempC = 33.0;
  static const _maxFan = 9;

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'ClimateControlCard',
      summary:
          'Front-row HVAC card. Stepper buttons disable at the range the '
          'car declared.',
      note:
          'A real caller owns these values from TelemetryApi and supplies '
          'the bounds it read. The gallery stands in for both. A rejected '
          'write would show the read-back, not the request.',
      child: GalleryStack(
        children: [
          ClimateControlCard(
            title: 'Climate control',
            subtitle: 'Front row',
            temperatureValue: _tempC.toStringAsFixed(1),
            temperatureUnit: '°C',
            decreaseTemperatureLabel: 'Decrease temperature',
            increaseTemperatureLabel: 'Increase temperature',
            onDecreaseTemperature: _tempC <= _minTempC
                ? null
                : () => setState(() => _tempC -= 0.5),
            onIncreaseTemperature: _tempC >= _maxTempC
                ? null
                : () => setState(() => _tempC += 0.5),
            autoLabel: 'Auto',
            autoEnabled: _auto,
            onAutoChanged: (v) => setState(() => _auto = v),
            fanSpeedLevel: _fan,
            fanSpeedMaxLevel: _maxFan,
            fanSpeedCaption: _fan <= 2 ? 'Low' : null,
            decreaseFanSpeedLabel: 'Decrease fan speed',
            increaseFanSpeedLabel: 'Increase fan speed',
            onDecreaseFanSpeed: _fan <= 0
                ? null
                : () => setState(() => _fan -= 1),
            onIncreaseFanSpeed: _fan >= _maxFan
                ? null
                : () => setState(() => _fan += 1),
            acLabel: 'A/C',
            acEnabled: _ac,
            onAcChanged: (v) => setState(() => _ac = v),
            syncLabel: 'Sync',
            syncEnabled: _sync,
            onSyncChanged: (v) => setState(() => _sync = v),
            defrostLabel: 'Front defrost',
            defrostEnabled: _defrost,
            onDefrostChanged: (v) => setState(() => _defrost = v),
            seatHeatLabel: 'Seat heat',
            seatHeatEnabled: _seatHeat,
            onSeatHeatChanged: (v) => setState(() => _seatHeat = v),
            steeringWheelHeatLabel: 'Wheel heat',
            steeringWheelHeatEnabled: _wheelHeat,
            onSteeringWheelHeatChanged: (v) => setState(() => _wheelHeat = v),
            petModeLabel: 'Pet mode',
            petModeEnabled: _petMode,
            onPetModeChanged: (v) => setState(() => _petMode = v),
            climateScheduleLabel: 'Climate schedule',
            onClimateSchedulePressed: () {},
          ),
          AppCard(
            title: 'Jump to a bound',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TrackSegmentedControl<double>(
                  items: const [
                    TabItem(value: 15.5, label: 'Floor'),
                    TabItem(value: 21.5, label: '21.5'),
                    TabItem(value: 33.0, label: 'Ceiling'),
                  ],
                  selected: _nearestTemp(_tempC),
                  onSelected: (value) => setState(() => _tempC = value),
                ),
                const SizedBox(height: AppSpacing.x4),
                TrackSegmentedControl<int>(
                  items: const [
                    TabItem(value: 0, label: 'Fan 0'),
                    TabItem(value: 3, label: 'Fan 3'),
                    TabItem(value: 9, label: 'Fan 9'),
                  ],
                  selected: _nearestFan(_fan),
                  onSelected: (value) => setState(() => _fan = value),
                ),
                const SizedBox(height: AppSpacing.x4),
                const GalleryCaption(
                  'At the floor or ceiling the matching chevron disables. '
                  'That is what a vehicle limit looks like.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  double _nearestTemp(double value) {
    const options = [15.5, 21.5, 33.0];
    return options.reduce(
      (best, next) => (next - value).abs() < (best - value).abs() ? next : best,
    );
  }

  int _nearestFan(int value) {
    if (value <= 0) return 0;
    if (value >= 9) return 9;
    return 3;
  }
}
