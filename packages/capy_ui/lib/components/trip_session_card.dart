import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../bodies/surface_capabilities.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import 'route_preview_map.dart';

/// An adaptive trip history card that renders an individual trip session.
///
/// Automatically switches between a vertical compact layout (phone / portrait)
/// and a horizontal expanded layout (head unit / landscape) based on
/// [SurfaceCapabilities.widthClass].
class TripSessionCard extends StatelessWidget {
  const TripSessionCard({
    required this.entry,
    required this.capabilities,
    this.onTap,
    this.selected = false,
    this.distanceUnit = 'km',
    this.energyUnit = 'kWh',
    this.speedUnit = 'km/h',
    super.key,
  });

  final TripSessionEntry entry;
  final SurfaceCapabilities capabilities;
  final VoidCallback? onTap;
  final bool selected;
  final String distanceUnit;
  final String energyUnit;
  final String speedUnit;

  bool get _isCompact => capabilities.widthClass == SurfaceWidthClass.compact;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final cardColor = selected ? colors.control : colors.surface;

    final content = _isCompact
        ? _CompactTripCard(
            entry: entry,
            distanceUnit: distanceUnit,
            energyUnit: energyUnit,
            speedUnit: speedUnit,
          )
        : _ExpandedTripCard(
            entry: entry,
            distanceUnit: distanceUnit,
            energyUnit: energyUnit,
            speedUnit: speedUnit,
          );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadii.xlRadius,
        child: Container(
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: AppRadii.xlRadius,
            border: selected
                ? Border.all(color: colors.energy.focus, width: 2)
                : null,
          ),
          child: content,
        ),
      ),
    );
  }
}

/// Mobile / compact portrait layout:
/// Top: Static map preview banner
/// Middle: Start/End timeline with timestamps
/// Bottom: 3-column metric row
class _CompactTripCard extends StatelessWidget {
  const _CompactTripCard({
    required this.entry,
    required this.distanceUnit,
    required this.energyUnit,
    required this.speedUnit,
  });

  final TripSessionEntry entry;
  final String distanceUnit;
  final String energyUnit;
  final String speedUnit;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final distStr = entry.distanceKm != null
        ? entry.distanceKm!.toStringAsFixed(entry.distanceKm! >= 100 ? 0 : 1)
        : '--';
    final energyStr = entry.netEnergyKwh != null
        ? entry.netEnergyKwh!.toStringAsFixed(2)
        : '--';
    final speedStr = entry.avgSpeedKmh != null
        ? entry.avgSpeedKmh!.round().toString()
        : '--';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Map banner
        SizedBox(
          height: 130,
          child: RoutePreviewMap(
            points: entry.routePoints,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppRadii.xl),
            ),
          ),
        ),
        // Timeline content
        Padding(
          padding: AppSpacing.cardPadding,
          child: _TripTimeline(entry: entry),
        ),
        // Divider
        Divider(height: 1, color: colors.divider),
        // 3-column stats bar
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.x4,
            vertical: AppSpacing.x3,
          ),
          child: Row(
            children: [
              Expanded(
                child: _StatColumn(
                  label: 'DIST.',
                  value: distStr,
                  unit: distanceUnit,
                ),
              ),
              Expanded(
                child: _StatColumn(
                  label: 'ENERGIA LÍQ.',
                  value: energyStr,
                  unit: energyUnit,
                ),
              ),
              Expanded(
                child: _StatColumn(
                  label: 'MÉDIA',
                  value: speedStr,
                  unit: speedUnit,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Head unit / landscape expanded layout:
/// Left: Square map thumbnail
/// Center: Time range and Start/End timeline
/// Right: 4-metric icon column
class _ExpandedTripCard extends StatelessWidget {
  const _ExpandedTripCard({
    required this.entry,
    required this.distanceUnit,
    required this.energyUnit,
    required this.speedUnit,
  });

  final TripSessionEntry entry;
  final String distanceUnit;
  final String energyUnit;
  final String speedUnit;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final distStr = entry.distanceKm != null
        ? entry.distanceKm!.toStringAsFixed(entry.distanceKm! >= 100 ? 0 : 1)
        : '--';
    final energyStr = entry.netEnergyKwh != null
        ? entry.netEnergyKwh!.toStringAsFixed(2)
        : '--';
    final speedStr = entry.avgSpeedKmh != null
        ? entry.avgSpeedKmh!.round().toString()
        : '--';
    final durationStr = entry.durationMillis != null
        ? _formatDurationMinutes(entry.durationMillis!)
        : '--';

    final startTimeStr = _formatClock(entry.startedAtUtcMillis, context);
    final endTimeStr = _formatClock(entry.endedAtUtcMillis, context);
    final timeRangeStr = '$startTimeStr — $endTimeStr';

    return Padding(
      padding: AppSpacing.cardPadding,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Left map thumbnail
            SizedBox(
              width: 140,
              height: 140,
              child: RoutePreviewMap(
                points: entry.routePoints,
                borderRadius: AppRadii.lgRadius,
              ),
            ),
            const SizedBox(width: AppSpacing.x5),
            // Center timeline & time header
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    timeRangeStr,
                    style: AppText.caption.copyWith(color: colors.inkMuted),
                  ),
                  const SizedBox(height: AppSpacing.x3),
                  _TripTimeline(entry: entry),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.x5),
            // Vertical divider
            VerticalDivider(width: 1, thickness: 1, color: colors.divider),
            const SizedBox(width: AppSpacing.x5),
            // Right metric column
            SizedBox(
              width: 155,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _MetricRow(
                    icon: Icons.straighten,
                    value: distStr,
                    unit: distanceUnit,
                    label: 'DISTÂNCIA',
                  ),
                  _MetricRow(
                    icon: Icons.bolt,
                    value: energyStr,
                    unit: energyUnit,
                    label: 'ENERGIA LÍQ.',
                  ),
                  _MetricRow(
                    icon: Icons.speed,
                    value: speedStr,
                    unit: speedUnit,
                    label: 'MÉDIA',
                  ),
                  _MetricRow(
                    icon: Icons.timer_outlined,
                    value: durationStr,
                    unit: '',
                    label: 'DURAÇÃO',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Origin and destination vertical timeline with connector line and timestamps.
class _TripTimeline extends StatelessWidget {
  const _TripTimeline({required this.entry});

  final TripSessionEntry entry;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final startTimeStr = _formatClock(entry.startedAtUtcMillis, context);
    final endTimeStr = _formatClock(entry.endedAtUtcMillis, context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Origin row
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 3),
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: colors.ink, width: 2.5),
              ),
            ),
            const SizedBox(width: AppSpacing.x3),
            Expanded(
              child: Text(
                entry.displayStartLocation.isNotEmpty
                    ? entry.displayStartLocation
                    : 'Ponto de partida',
                style: AppText.bodyStrong.copyWith(color: colors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: AppSpacing.x2),
            Text(
              startTimeStr,
              style: AppText.caption.copyWith(color: colors.inkMuted),
            ),
          ],
        ),
        // Connector line
        Container(
          margin: const EdgeInsets.only(left: 5),
          width: 2,
          height: 16,
          color: colors.inkMuted.withValues(alpha: 0.3),
        ),
        // Destination row
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 3),
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.energy.draw,
              ),
            ),
            const SizedBox(width: AppSpacing.x3),
            Expanded(
              child: Text(
                entry.displayEndLocation.isNotEmpty
                    ? entry.displayEndLocation
                    : 'Destino',
                style: AppText.bodyStrong.copyWith(color: colors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: AppSpacing.x2),
            Text(
              endTimeStr,
              style: AppText.caption.copyWith(color: colors.inkMuted),
            ),
          ],
        ),
      ],
    );
  }
}

class _StatColumn extends StatelessWidget {
  const _StatColumn({
    required this.label,
    required this.value,
    required this.unit,
  });

  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: AppText.bodyStrong.copyWith(color: colors.ink),
              ),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 2),
                Text(
                  unit,
                  style: AppText.caption.copyWith(
                    color: colors.inkMuted,
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.x1),
        Text(
          label,
          style: AppText.caption.copyWith(
            color: colors.inkMuted,
            fontWeight: FontWeight.w600,
            fontSize: 10,
          ),
        ),
      ],
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({
    required this.icon,
    required this.value,
    required this.unit,
    required this.label,
  });

  final IconData icon;
  final String value;
  final String unit;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Row(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: colors.control,
            borderRadius: AppRadii.smRadius,
          ),
          child: Icon(icon, size: 16, color: colors.ink),
        ),
        const SizedBox(width: AppSpacing.x2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      value,
                      style: AppText.bodyStrong.copyWith(color: colors.ink),
                    ),
                    if (unit.isNotEmpty) ...[
                      const SizedBox(width: 2),
                      Text(
                        unit,
                        style: AppText.caption.copyWith(color: colors.inkMuted),
                      ),
                    ],
                  ],
                ),
              ),
              Text(
                label,
                style: AppText.caption.copyWith(
                  color: colors.inkMuted,
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _formatClock(int? millis, BuildContext context) {
  if (millis == null || millis <= 0) return '--';
  final at = DateTime.fromMillisecondsSinceEpoch(millis);
  final locale =
      Localizations.maybeLocaleOf(context)?.toString() ??
      Intl.getCurrentLocale();
  return DateFormat.jm(locale).format(at);
}

String _formatDurationMinutes(int millis) {
  final totalMin = (millis / 60000).round();
  if (totalMin < 60) return '$totalMin min';
  final h = totalMin ~/ 60;
  final m = totalMin % 60;
  return '$h h $m min';
}
