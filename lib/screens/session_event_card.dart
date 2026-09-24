import 'package:flutter/material.dart';

import '../design_system/design_system.dart';

class SessionEventCard extends StatelessWidget {
  const SessionEventCard({
    required this.statusColor,
    required this.badge,
    required this.title,
    required this.status,
    required this.metrics,
    required this.onTap,
    super.key,
  });

  final Color statusColor;
  final Widget badge;
  final String title;
  final Widget status;
  final Widget metrics;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AutomotiveColors.surfaceContainerLow,
      borderRadius: AutomotiveRadii.lgRadius,
      child: InkWell(
        onTap: onTap,
        borderRadius: AutomotiveRadii.lgRadius,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: AutomotiveColors.technicalBorder),
            borderRadius: AutomotiveRadii.lgRadius,
          ),
          child: ClipRRect(
            borderRadius: AutomotiveRadii.lgRadius,
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: 4,
                  child: ColoredBox(color: statusColor),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AutomotiveSpacing.x3,
                    AutomotiveSpacing.x2,
                    AutomotiveSpacing.x2,
                    AutomotiveSpacing.x2,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SessionEventHeader(
                        badge: badge,
                        title: title,
                        status: status,
                      ),
                      const SizedBox(height: AutomotiveSpacing.x2),
                      metrics,
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SessionEventHeader extends StatelessWidget {
  const SessionEventHeader({
    required this.badge,
    required this.title,
    required this.status,
    super.key,
  });

  final Widget badge;
  final String title;
  final Widget status;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        badge,
        const SizedBox(width: AutomotiveSpacing.x2),
        Expanded(
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            style: AutomotiveTextStyles.unitLabel.copyWith(
              color: AutomotiveColors.onSurface,
            ),
          ),
        ),
        const SizedBox(width: AutomotiveSpacing.x2),
        status,
      ],
    );
  }
}

class SessionEventBadge extends StatelessWidget {
  const SessionEventBadge({
    required this.label,
    required this.icon,
    required this.color,
    super.key,
  });

  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 32),
      padding: const EdgeInsets.symmetric(
        horizontal: AutomotiveSpacing.x1,
        vertical: AutomotiveSpacing.x0_5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        border: Border.all(color: color.withValues(alpha: 0.55)),
        borderRadius: AutomotiveRadii.baseRadius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: AutomotiveSpacing.x0_5),
          Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: AutomotiveTextStyles.labelCaps.copyWith(
              color: color,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}

class SessionMetricBlock extends StatelessWidget {
  const SessionMetricBlock({
    required this.label,
    required this.value,
    this.unit,
    this.alignEnd = false,
    super.key,
  });

  final String label;
  final String value;
  final String? unit;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: alignEnd
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          overflow: TextOverflow.ellipsis,
          style: AutomotiveTextStyles.labelCaps.copyWith(
            color: AutomotiveColors.onSurfaceVariant,
            fontSize: 10,
          ),
        ),
        const SizedBox(height: AutomotiveSpacing.x0_5),
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: Text(
                value,
                overflow: TextOverflow.ellipsis,
                style: AutomotiveTextStyles.headlineMd.copyWith(
                  color: AutomotiveColors.onSurface,
                  fontFamily: AutomotiveFonts.mono,
                ),
              ),
            ),
            if (unit != null) ...[
              const SizedBox(width: AutomotiveSpacing.x0_5),
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  unit!,
                  style: AutomotiveTextStyles.unitLabel.copyWith(
                    color: AutomotiveColors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class SessionSocRangeBar extends StatelessWidget {
  const SessionSocRangeBar({
    required this.startSoc,
    required this.endSoc,
    required this.fillColor,
    this.showLowerRangeFill = false,
    super.key,
  });

  final double? startSoc;
  final double? endSoc;
  final Color fillColor;
  final bool showLowerRangeFill;

  @override
  Widget build(BuildContext context) {
    final start = startSoc?.clamp(0, 100).toDouble();
    final end = endSoc?.clamp(0, 100).toDouble();
    final hasRange = start != null && end != null;
    final lower = hasRange
        ? start < end
              ? start
              : end
        : 0.0;
    final higher = hasRange
        ? start > end
              ? start
              : end
        : 0.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final left = width * (lower / 100);
        final fillWidth = width * ((higher - lower) / 100);
        return ClipRRect(
          borderRadius: AutomotiveRadii.baseRadius,
          child: SizedBox(
            height: 8,
            child: Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(color: AutomotiveColors.surfaceVariant),
                ),
                if (hasRange && showLowerRangeFill)
                  Positioned(
                    left: 0,
                    width: left,
                    top: 0,
                    bottom: 0,
                    child: ColoredBox(
                      color: AutomotiveColors.secondary.withValues(alpha: 0.3),
                    ),
                  ),
                if (hasRange)
                  Positioned(
                    left: left,
                    width: fillWidth.clamp(2.0, width),
                    top: 0,
                    bottom: 0,
                    child: ColoredBox(color: fillColor),
                  ),
                if (hasRange) ...[
                  Positioned(
                    left: left.clamp(0.0, width - 1),
                    top: 0,
                    bottom: 0,
                    child: ColoredBox(color: AutomotiveColors.surface),
                  ),
                  Positioned(
                    left: (left + fillWidth).clamp(0.0, width - 1),
                    top: 0,
                    bottom: 0,
                    child: ColoredBox(color: AutomotiveColors.surface),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
