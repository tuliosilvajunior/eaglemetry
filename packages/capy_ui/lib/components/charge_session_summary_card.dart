import 'package:flutter/material.dart';

import '../capy_ui.dart';

/// Last-charge summary with a battery/climate energy breakdown.
///
/// [climateEnergy] is the one auxiliary load a charge session measures. It is
/// optional because the integral behind it can fail to cover the charge, and
/// the caller refuses a partial one. When it is absent, the climate stays in
/// the legend with the caller-supplied missing-value label and no arc is
/// invented for it.
class ChargeSessionSummaryCard extends StatelessWidget {
  const ChargeSessionSummaryCard({
    required this.title,
    required this.duration,
    required this.totalEnergy,
    required this.totalEnergyLabel,
    required this.batteryEnergy,
    required this.batteryEnergyLabel,
    required this.climateEnergy,
    required this.climateEnergyLabel,
    required this.energyUnit,
    required this.batterySemanticsLabel,
    required this.climateSemanticsLabel,
    required this.chartSemanticsLabel,
    super.key,
  });

  final String title;
  final String duration;

  /// Numeric values are used only for arc geometry.
  final double totalEnergy;
  final double batteryEnergy;
  final double? climateEnergy;

  /// Pre-formatted values keep formatting and localization with the caller.
  final String totalEnergyLabel;
  final String batteryEnergyLabel;
  final String climateEnergyLabel;
  final String energyUnit;
  final String batterySemanticsLabel;
  final String climateSemanticsLabel;
  final String chartSemanticsLabel;

  @override
  Widget build(BuildContext context) {
    final climate = climateEnergy;
    return AppCard(
      title: title,
      subtitle: duration,
      child: Column(
        children: [
          Expanded(
            child: SegmentedDonut(
              segments: [
                DonutSegment(
                  value: batteryEnergy,
                  color: AppThemeColors.of(context).energy.gain,
                  marker: Semantics(
                    label: batterySemanticsLabel,
                    child: const Icon(
                      Icons.battery_full,
                      size: AppSizes.iconMd,
                    ),
                  ),
                ),
                if (climate != null)
                  DonutSegment(
                    value: climate,
                    color: AppThemeColors.of(context).energy.gainSoft,
                    marker: Semantics(
                      label: climateSemanticsLabel,
                      child: const Icon(
                        Icons.thermostat,
                        size: AppSizes.iconMd,
                      ),
                    ),
                  ),
              ],
              total: totalEnergy,
              value: totalEnergyLabel,
              unit: energyUnit,
              semanticsLabel: chartSemanticsLabel,
            ),
          ),
          const SizedBox(height: AppSpacing.x5),
          IconValueGrid(
            entries: [
              IconValueEntry(
                icon: Icons.battery_full,
                value: batteryEnergyLabel,
                semanticLabel: batterySemanticsLabel,
              ),
              IconValueEntry(
                icon: Icons.thermostat,
                value: climateEnergyLabel,
                semanticLabel: climateSemanticsLabel,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
