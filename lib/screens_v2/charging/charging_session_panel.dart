import 'package:flutter/material.dart';

import '../../core/telemetry_api.dart';
import '../../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';
import 'charging_format.dart';

/// What the last charge put into the pack, and what climate took.
class ChargingSessionPanel extends StatelessWidget {
  const ChargingSessionPanel({
    required this.session,
    required this.detail,
    required this.loading,
    required this.failed,
    super.key,
  });

  final SessionRecord? session;
  final ChargeDetailReading? detail;
  final bool loading;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    if (loading) {
      return const AppCard(child: Center(child: CircularProgressIndicator()));
    }
    if (failed) {
      return AppCard(
        child: ChargeGraphMessage(message: loc.v2ChargeGraphLoadFailed),
      );
    }
    final session = this.session;
    final detail = this.detail;
    if (session == null || detail == null) {
      return AppCard(
        child: ChargeGraphMessage(message: loc.v2ChargeGraphEmpty),
      );
    }
    final duration = chargeSessionDuration(session);
    final batteryEnergy = usableChargeEnergy(
      detail.estimatedEnergyKwh ??
          sessionReadingDeliveredKwh(session).displayValue,
    );
    if (batteryEnergy == null) {
      return AppCard(
        title: loc.v2LastChargeSession,
        subtitle: chargeDurationLabel(loc, duration),
        child: ChargeGraphMessage(message: loc.v2ChargeSummaryNoEnergy),
      );
    }
    // The climate load, and only it. During a charge the pack term is the
    // charging current, so the `pack - traction` remainder that names the
    // system load on a trip does not exist here, and nothing else on this bus
    // measures it. An integral that missed part of the charge is a floor, not
    // a refusal — see `ChargeSessionDetailResult.climateEnergyKwhOver`.
    final climate = detail.climateEnergyKwhOver(duration);
    final climateEnergy = usableChargeEnergy(climate?.kwh);
    final totalEnergy = batteryEnergy + (climateEnergy ?? 0);
    return ChargeSessionSummaryCard(
      title: loc.v2LastChargeSession,
      duration: chargeDurationLabel(loc, duration),
      totalEnergy: totalEnergy,
      totalEnergyLabel: totalEnergy.toStringAsFixed(1),
      batteryEnergy: batteryEnergy,
      batteryEnergyLabel: '${batteryEnergy.toStringAsFixed(1)} ${loc.unitKwh}',
      climateEnergy: climateEnergy,
      // An incomplete cover makes the figure a floor, and it is marked as one:
      // the quiet seconds can only have added climate energy.
      climateEnergyLabel: climateEnergy == null
          ? '-- ${loc.unitKwh}'
          : climate!.complete
          ? '${climateEnergy.toStringAsFixed(1)} ${loc.unitKwh}'
          : '\u2265 ${climateEnergy.toStringAsFixed(1)} ${loc.unitKwh}',
      energyUnit: loc.unitKwh,
      batterySemanticsLabel: loc.v2ChargeSummaryBatteryEnergy,
      climateSemanticsLabel: loc.v2ChargeSummaryClimateEnergy,
      chartSemanticsLabel: loc.v2ChargeSummarySemantics,
    );
  }
}
