import 'package:flutter/material.dart';

import '../../design_system/design_system.dart';
import '../../l10n/app_localizations.dart';
import '../session_event_card.dart';
import 'trip_session_display.dart';

class TripEventCard extends StatelessWidget {
  const TripEventCard({required this.row, required this.onTap, super.key});

  final TripSessionDisplay row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return SessionEventCard(
      statusColor: row.statusColor,
      badge: SessionEventBadge(
        label: loc.timelineTrip,
        icon: Icons.route,
        color: AutomotiveColors.tertiary,
      ),
      title: '${row.dateLabel} • ${row.windowLabel}',
      status: StatusBadge(label: row.status, color: row.statusColor),
      metrics: _TripEventMetrics(row: row),
      onTap: onTap,
    );
  }
}

class _TripEventMetrics extends StatelessWidget {
  const _TripEventMetrics({required this.row});

  final TripSessionDisplay row;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 780;
        if (narrow) {
          return Column(
            children: [
              _DistanceMetric(row: row),
              const SizedBox(height: AutomotiveSpacing.x2),
              _SocTrendMetric(row: row),
              const SizedBox(height: AutomotiveSpacing.x2),
              _AverageSpeedMetric(row: row),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(width: 180, child: _DistanceMetric(row: row)),
            const SizedBox(width: AutomotiveSpacing.x3),
            Expanded(child: _SocTrendMetric(row: row)),
            const SizedBox(width: AutomotiveSpacing.x3),
            SizedBox(width: 160, child: _AverageSpeedMetric(row: row)),
          ],
        );
      },
    );
  }
}

class _DistanceMetric extends StatelessWidget {
  const _DistanceMetric({required this.row});

  final TripSessionDisplay row;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return SessionMetricBlock(
      label: loc.tripMetricDistance,
      value: row.distanceLabel,
    );
  }
}

class _AverageSpeedMetric extends StatelessWidget {
  const _AverageSpeedMetric({required this.row});

  final TripSessionDisplay row;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Align(
      alignment: Alignment.centerRight,
      child: SessionMetricBlock(
        label: loc.tripMetricAvgSpeed,
        value: row.speedLabel,
        alignEnd: true,
      ),
    );
  }
}

class _SocTrendMetric extends StatelessWidget {
  const _SocTrendMetric({required this.row});

  final TripSessionDisplay row;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final trendColor = _isSocDrop
        ? AutomotiveColors.error
        : AutomotiveColors.secondary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                '${loc.tripMetricSocRange} (${row.socRange})',
                overflow: TextOverflow.ellipsis,
                style: AutomotiveTextStyles.labelCaps.copyWith(
                  color: AutomotiveColors.onSurfaceVariant,
                  fontSize: 10,
                ),
              ),
            ),
            const SizedBox(width: AutomotiveSpacing.x1),
            Text(
              row.socDelta,
              style: AutomotiveTextStyles.unitLabel.copyWith(
                color: trendColor,
                fontSize: 11,
              ),
            ),
          ],
        ),
        const SizedBox(height: AutomotiveSpacing.x1),
        SessionSocRangeBar(
          startSoc: row.startSoc,
          endSoc: row.endSoc,
          fillColor: trendColor,
          showLowerRangeFill: _isSocDrop,
        ),
      ],
    );
  }

  bool get _isSocDrop {
    final start = row.startSoc;
    final end = row.endSoc;
    return start != null && end != null && end < start;
  }
}
