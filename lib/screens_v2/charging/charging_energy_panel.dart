import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';
import 'package:telemetry_core/telemetry_core.dart';

/// Analytical energy and range panel: vehicle range, app range, and external charge controls.
class ChargingEnergyPanel extends StatelessWidget {
  const ChargingEnergyPanel({
    required this.vehicleRangeKm,
    required this.vehicleRangeAvailable,
    required this.appRangeKm,
    required this.appRangeCaption,
    this.externalChargeControlEnabled = false,
    this.chargeControlState = const ChargeControlState(),
    this.isActivelyCharging = false,
    this.onAmperageChanged,
    this.onForceChargingChanged,
    this.onStopCharging,
    super.key,
  });

  /// The distance-to-empty the car reports. Null while unavailable; zero is a
  /// valid reading, so availability is carried by [vehicleRangeAvailable].
  final double? vehicleRangeKm;
  final bool vehicleRangeAvailable;

  /// The app's SOC-based estimate, or null while unavailable.
  final double? appRangeKm;

  /// Label under the app estimate. The caption names the state: current,
  /// history-update delayed, or unavailable, so a degraded cached estimate is
  /// never presented as a fully current one.
  final String appRangeCaption;

  final bool externalChargeControlEnabled;
  final ChargeControlState chargeControlState;
  final bool isActivelyCharging;
  final ValueChanged<int>? onAmperageChanged;
  final ValueChanged<bool>? onForceChargingChanged;
  final VoidCallback? onStopCharging;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final minAmps = chargeControlState.minAmps;
    final maxAmps = chargeControlState.maxAmps;
    // Null means the car has not reported a current yet. The stepper has to
    // open on something, so it opens on the lowest the car allows, but the
    // tile says the reading is missing rather than showing that number as one.
    final reportedAmps = chargeControlState.amps;
    final currentAmps = reportedAmps ?? minAmps;
    final isForceCharging = chargeControlState.forceCharging;

    return AppCard(
      title: loc.v2ChargingEnergy,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final size = constraints.maxWidth < 220
                  ? MetricSize.md
                  : MetricSize.xl;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MetricWithCaption(
                    value: vehicleRangeAvailable
                        ? vehicleRangeKm!.round().toString()
                        : '--',
                    unit: vehicleRangeAvailable ? loc.unitKm : null,
                    caption: loc.v2RangeVehicleRange,
                    size: size,
                  ),
                  const SizedBox(height: AppSpacing.x3),
                  MetricWithCaption(
                    value: appRangeKm?.round().toString() ?? '--',
                    unit: appRangeKm == null ? null : loc.unitKm,
                    caption: appRangeCaption,
                    size: size,
                  ),
                ],
              );
            },
          ),
          const Spacer(),
          // Each control needs both the switch and its own callback. The
          // switch says the reader handed charge control to the other app;
          // the callback is the only path a command can take. Without either
          // the control is not drawn at all, so nothing on this screen can
          // write to the car.
          if (externalChargeControlEnabled) ...[
            if (isActivelyCharging && onStopCharging != null) ...[
              SoftActionTile(
                label: loc.v2ChargingStopButton,
                icon: Icons.stop_circle,
                iconColor: AppColors.critical,
                onPressed: onStopCharging,
              ),
              const SizedBox(height: AppSpacing.x3),
            ],
            // Force Charging Button
            if (onForceChargingChanged != null) ...[
              SoftActionTile(
                label: isForceCharging
                    ? loc.v2ChargingForceActive
                    : loc.v2ChargingForceButton,
                icon: isForceCharging ? Icons.bolt : Icons.bolt_outlined,
                iconColor: isForceCharging ? AppColors.energyGain : null,
                selected: isForceCharging,
                onPressed: () => onForceChargingChanged!(!isForceCharging),
              ),
              const SizedBox(height: AppSpacing.x3),
            ],
            // Amperage Stepper with Anchored Tooltip Dialog
            if (onAmperageChanged != null)
              AnchoredTooltipTrigger(
                side: AnchoredTooltipSide.right,
                caretAlignment: 0.85,
                barrierLabel: loc.v2ChargingAmperageClose,
                tooltipBuilder: (context) => ChargingAmperageDialog(
                  value: currentAmps,
                  min: minAmps,
                  max: maxAmps,
                  onChanged: (val) => onAmperageChanged!(val),
                  title: loc.v2ChargingAmperageTitle,
                  description: loc.v2ChargingAmperageDescription,
                  defaultLabel: loc.v2ChargingAmperageRange(minAmps, maxAmps),
                  unit: loc.v2ChargingAmperageUnit,
                  decreaseLabel: loc.v2ChargingAmperageDecrease,
                  increaseLabel: loc.v2ChargingAmperageIncrease,
                ),
                builder: (context, isOpen, open) => SoftActionTile(
                  icon: Icons.electrical_services,
                  label: reportedAmps == null
                      ? '-- ${loc.v2ChargingAmperageUnit}'
                      : loc.v2ChargingAmperageValue(reportedAmps),
                  centered: true,
                  selected: isOpen,
                  height: AppSizes.presetTileHeight,
                  onPressed: open,
                ),
              ),
          ],
        ],
      ),
    );
  }
}
