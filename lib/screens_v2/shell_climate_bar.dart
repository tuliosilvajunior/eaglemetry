import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';

/// Preview climate strip for [AppShellV2].
///
/// Holds the two zone readings in its own [State] so a chevron tap rebuilds
/// this strip only. Putting those numbers on the shell would rebuild every
/// mounted destination — the same reason the instant readout bar feeds itself
/// instead of taking values from [AppShellV2].
///
/// The numbers are local. `getHvacControlStatus` publishes one zone, and this
/// bar has two, so nothing here may state a cabin temperature until the
/// passenger zone exists natively and a stepper reports the read-back.
class ShellClimateBar extends StatefulWidget {
  const ShellClimateBar({super.key});

  @override
  State<ShellClimateBar> createState() => _ShellClimateBarState();
}

class _ShellClimateBarState extends State<ShellClimateBar> {
  // Same span `HvacClimateController` and `MockTelemetryData` clamp to.
  // Preview only: a live caller must read the range from the car.
  static const _minTempC = 15.5;
  static const _maxTempC = 33.0;
  static const _stepC = 0.5;

  double _driverTempC = 21.5;
  double _passengerTempC = 21.5;

  // Preview only. Nothing here reads a media session.
  static const _volumeMin = 0;
  static const _volumeMax = 30;
  int _volume = 12;

  VoidCallback? _stepper({
    required double value,
    required bool increase,
    required ValueChanged<double> apply,
  }) {
    if (increase && value >= _maxTempC) return null;
    if (!increase && value <= _minTempC) return null;
    return () {
      setState(() {
        apply(increase ? value + _stepC : value - _stepC);
      });
    };
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return ClimateTemperatureBar(
      driverValue: _driverTempC.toStringAsFixed(1),
      driverDecreaseLabel: loc.climateBarDriverDecrease,
      driverIncreaseLabel: loc.climateBarDriverIncrease,
      onDriverDecrease: _stepper(
        value: _driverTempC,
        increase: false,
        apply: (next) => _driverTempC = next,
      ),
      onDriverIncrease: _stepper(
        value: _driverTempC,
        increase: true,
        apply: (next) => _driverTempC = next,
      ),
      passengerValue: _passengerTempC.toStringAsFixed(1),
      passengerDecreaseLabel: loc.climateBarPassengerDecrease,
      passengerIncreaseLabel: loc.climateBarPassengerIncrease,
      onPassengerDecrease: _stepper(
        value: _passengerTempC,
        increase: false,
        apply: (next) => _passengerTempC = next,
      ),
      onPassengerIncrease: _stepper(
        value: _passengerTempC,
        increase: true,
        apply: (next) => _passengerTempC = next,
      ),
      centerChild: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gridGutter),
        child: NowPlayingBar(
          idleLabel: loc.nowPlayingIdle,
          volume: _volume,
          volumeMin: _volumeMin,
          volumeMax: _volumeMax,
          onVolumeChanged: (next) => setState(() => _volume = next),
        ),
      ),
    );
  }
}
