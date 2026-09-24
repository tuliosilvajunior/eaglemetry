import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class ClimateTemperatureBarGalleryPage extends StatefulWidget {
  const ClimateTemperatureBarGalleryPage({super.key});

  @override
  State<ClimateTemperatureBarGalleryPage> createState() =>
      _ClimateTemperatureBarGalleryPageState();
}

class _ClimateTemperatureBarGalleryPageState
    extends State<ClimateTemperatureBarGalleryPage> {
  double _driverTempC = 21.5;
  double _passengerTempC = 22.0;
  int _volume = 12;

  static const _minTempC = 15.5;
  static const _maxTempC = 33.0;

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'ClimateTemperatureBar',
      summary:
          'Always-dark climate strip. Two zone pills float on the bezel, '
          'not the two ends of one long bar.',
      note:
          'This component ignores the theme on purpose. It reads the same '
          'in every cabin theme, the way the reference strip does.',
      scrollable: true,
      child: GalleryStack(
        children: [
          ColoredBox(
            color: AppColors.climateBarSurface,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.x2),
              child: ClimateTemperatureBar(
                driverValue: _driverTempC.toStringAsFixed(1),
                driverDecreaseLabel: 'Decrease driver temperature',
                driverIncreaseLabel: 'Increase driver temperature',
                onDriverDecrease: _driverTempC <= _minTempC
                    ? null
                    : () => setState(() => _driverTempC -= 0.5),
                onDriverIncrease: _driverTempC >= _maxTempC
                    ? null
                    : () => setState(() => _driverTempC += 0.5),
                passengerValue: _passengerTempC.toStringAsFixed(1),
                passengerDecreaseLabel: 'Decrease passenger temperature',
                passengerIncreaseLabel: 'Increase passenger temperature',
                onPassengerDecrease: _passengerTempC <= _minTempC
                    ? null
                    : () => setState(() => _passengerTempC -= 0.5),
                onPassengerIncrease: _passengerTempC >= _maxTempC
                    ? null
                    : () => setState(() => _passengerTempC += 0.5),
                centerChild: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.gridGutter,
                  ),
                  child: NowPlayingBar(
                    title: 'Night Drive',
                    artist: 'Low Tide',
                    isPlaying: true,
                    idleLabel: 'Nothing playing',
                    volume: _volume,
                    volumeMin: 0,
                    volumeMax: 30,
                    onVolumeChanged: (next) => setState(() => _volume = next),
                  ),
                ),
              ),
            ),
          ),
          AppCard(
            title: 'Driver temperature',
            subtitle: '${_driverTempC.toStringAsFixed(1)} °C',
            child: TrackSegmentedControl<double>(
              items: const [
                TabItem(value: 15.5, label: 'LO'),
                TabItem(value: 18.5, label: '18.5'),
                TabItem(value: 21.5, label: '21.5'),
                TabItem(value: 26.0, label: '26'),
                TabItem(value: 33.0, label: 'HI'),
              ],
              selected: _nearest(_driverTempC),
              onSelected: (value) => setState(() => _driverTempC = value),
            ),
          ),
          AppCard(
            title: 'Passenger temperature',
            subtitle: '${_passengerTempC.toStringAsFixed(1)} °C',
            child: TrackSegmentedControl<double>(
              items: const [
                TabItem(value: 15.5, label: 'LO'),
                TabItem(value: 18.5, label: '18.5'),
                TabItem(value: 22.0, label: '22'),
                TabItem(value: 26.0, label: '26'),
                TabItem(value: 33.0, label: 'HI'),
              ],
              selected: _nearest(_passengerTempC),
              onSelected: (value) => setState(() => _passengerTempC = value),
            ),
          ),
          ColoredBox(
            color: AppColors.climateBarSurface,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.x2),
              child: Row(
                children: const [
                  ClimateZonePill(
                    zoneKeyPrefix: 'demo-auto',
                    value: '18.5',
                    caption: 'AUTO',
                    decreaseLabel: 'Cooler',
                    increaseLabel: 'Warmer',
                  ),
                  SizedBox(width: AppSpacing.gridGutter),
                  ClimateZonePill(
                    zoneKeyPrefix: 'demo-off',
                    value: 'LO',
                    caption: 'OFF',
                    fanActive: false,
                    decreaseLabel: 'Cooler',
                    increaseLabel: 'Warmer',
                  ),
                  SizedBox(width: AppSpacing.gridGutter),
                  ClimateZonePill(
                    zoneKeyPrefix: 'demo-plain',
                    value: '21.0',
                    decreaseLabel: 'Cooler',
                    increaseLabel: 'Warmer',
                  ),
                  SizedBox(width: AppSpacing.gridGutter),
                  ClimateZonePill(
                    zoneKeyPrefix: 'demo-limit',
                    value: '33.0',
                    caption: 'HI',
                    decreaseLabel: 'Cooler',
                    increaseLabel: 'Warmer',
                  ),
                ],
              ),
            ),
          ),
          const GalleryCaption(
            'The four pill states the reference unit draws: AUTO with a '
            'running fan, OFF with a stopped fan, a plain value with no mode '
            'line, and a ceiling with both chevrons disabled.',
          ),
        ],
      ),
    );
  }

  double _nearest(double value) {
    const options = [15.5, 18.5, 21.5, 22.0, 26.0, 33.0];
    return options.reduce(
      (best, next) => (next - value).abs() < (best - value).abs() ? next : best,
    );
  }
}
