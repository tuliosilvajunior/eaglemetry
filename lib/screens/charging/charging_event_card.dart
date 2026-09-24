import 'package:flutter/material.dart';

import '../../design_system/design_system.dart';
import '../../l10n/app_localizations.dart';
import '../session_event_card.dart';
import 'charging_session_display.dart';

class ChargingEventCard extends StatelessWidget {
  const ChargingEventCard({required this.row, required this.onTap, super.key});

  final ChargingSessionDisplay row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final session = row.session;
    return SessionEventCard(
      statusColor: row.statusColor,
      badge: _PlugBadge(label: row.plugLabel),
      title: '${row.startedLabel} • ${row.windowLabel}',
      status: StatusBadge(label: row.status, color: row.statusColor),
      metrics: _EventMetrics(
        row: row,
        startSoc: session?.startSoc.displayValue,
        endSoc: session?.endSoc.displayValue,
      ),
      onTap: onTap,
    );
  }
}

class _EventMetrics extends StatelessWidget {
  const _EventMetrics({
    required this.row,
    required this.startSoc,
    required this.endSoc,
  });

  final ChargingSessionDisplay row;
  final double? startSoc;
  final double? endSoc;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 780;
        if (narrow) {
          return Column(
            children: [
              _EnergyMetric(row: row),
              const SizedBox(height: AutomotiveSpacing.x2),
              _SocMetric(row: row, startSoc: startSoc, endSoc: endSoc),
              const SizedBox(height: AutomotiveSpacing.x2),
              _CostMetric(row: row),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(width: 180, child: _EnergyMetric(row: row)),
            const SizedBox(width: AutomotiveSpacing.x3),
            Expanded(
              child: _SocMetric(row: row, startSoc: startSoc, endSoc: endSoc),
            ),
            const SizedBox(width: AutomotiveSpacing.x3),
            SizedBox(width: 160, child: _CostMetric(row: row)),
          ],
        );
      },
    );
  }
}

class _PlugBadge extends StatelessWidget {
  const _PlugBadge({required this.label});

  final String label;

  bool get _dc => label.toUpperCase().contains('DC');
  bool get _ac => label.toUpperCase().contains('AC');

  @override
  Widget build(BuildContext context) {
    final color = _dc
        ? AutomotiveColors.secondary
        : _ac
        ? AutomotiveColors.tertiary
        : AutomotiveColors.warning;
    final icon = _dc
        ? Icons.bolt
        : _ac
        ? Icons.power
        : Icons.cable;
    return SessionEventBadge(label: label, icon: icon, color: color);
  }
}

class _EnergyMetric extends StatelessWidget {
  const _EnergyMetric({required this.row});

  final ChargingSessionDisplay row;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return SessionMetricBlock(
      label: loc.detailEnergyEst,
      value: row.energyLabel,
      unit: loc.detailEnergyUnit,
    );
  }
}

class _CostMetric extends StatelessWidget {
  const _CostMetric({required this.row});

  final ChargingSessionDisplay row;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Align(
      alignment: Alignment.centerRight,
      child: SessionMetricBlock(
        label: loc.chargeCostLabel,
        value: row.costLabel,
        alignEnd: true,
      ),
    );
  }
}

class _SocMetric extends StatelessWidget {
  const _SocMetric({
    required this.row,
    required this.startSoc,
    required this.endSoc,
  });

  final ChargingSessionDisplay row;
  final double? startSoc;
  final double? endSoc;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                '${loc.historyHeadersSoc} (${row.socRange})',
                overflow: TextOverflow.ellipsis,
                style: AutomotiveTextStyles.labelCaps.copyWith(
                  color: AutomotiveColors.onSurfaceVariant,
                  fontSize: 10,
                ),
              ),
            ),
            const SizedBox(width: AutomotiveSpacing.x1),
            Text(
              row.durationLabel,
              style: AutomotiveTextStyles.unitLabel.copyWith(
                color: AutomotiveColors.onSurfaceVariant,
                fontSize: 11,
              ),
            ),
          ],
        ),
        const SizedBox(height: AutomotiveSpacing.x1),
        SessionSocRangeBar(
          startSoc: startSoc,
          endSoc: endSoc,
          fillColor: AutomotiveColors.secondary,
        ),
      ],
    );
  }
}
