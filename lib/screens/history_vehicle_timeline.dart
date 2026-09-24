import 'package:flutter/material.dart';

import '../core/telemetry_api.dart';
import '../design_system/design_system.dart';
import '../l10n/app_localizations.dart';

class HistoryVehicleTimeline extends StatelessWidget {
  const HistoryVehicleTimeline({
    required this.sessions,
    required this.rangeStartUtcMillis,
    required this.rangeEndUtcMillis,
    super.key,
  });

  static const _nodeSpacing = 82.0;
  static const _axisX = 22.0;
  static const _shortTransitionMillis = 5 * 60 * 1000;

  final List<HistorySessionRow> sessions;
  final int rangeStartUtcMillis;
  final int rangeEndUtcMillis;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final nodes = _buildNodes(loc);
    if (nodes.isEmpty) {
      return TechnicalPanel(
        child: SizedBox(
          height: 360,
          child: Center(
            child: Text(
              loc.timelineEmpty,
              style: AutomotiveTextStyles.bodyMd.copyWith(
                color: AutomotiveColors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    final height = (nodes.length - 1) * _nodeSpacing + 72;
    return TechnicalPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.timeline, color: AutomotiveColors.secondary, size: 22),
              const SizedBox(width: AutomotiveSpacing.x1),
              Text(
                loc.timelineTitle,
                style: AutomotiveTextStyles.labelCaps.copyWith(
                  color: AutomotiveColors.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: AutomotiveSpacing.x2),
          SizedBox(
            height: height,
            child: CustomPaint(
              painter: _TimelinePainter(nodes: nodes),
              child: Stack(
                children: [
                  for (int i = 0; i < nodes.length; i++)
                    Positioned(
                      left: 56,
                      right: 0,
                      top: i * _nodeSpacing - 18,
                      child: _TimelineNodeContent(node: nodes[i]),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<_TimelineNode> _buildNodes(AppLocalizations loc) {
    final sorted = [...sessions]
      ..sort((a, b) => a.startUtcMillis.compareTo(b.startUtcMillis));
    final nodes = <_TimelineNode>[];
    var cursor = rangeStartUtcMillis;
    String? previousType;

    for (final session in sorted) {
      if (!_isSupported(session)) continue;
      final start = session.startUtcMillis;
      final end = session.endUtcMillis > start
          ? session.endUtcMillis
          : start + session.durationMillis;
      final gap = start - cursor;
      final type = session.type.toUpperCase();

      if (nodes.isEmpty && gap > _shortTransitionMillis) {
        nodes.add(_parkedNode(loc, gap));
      } else if (nodes.isNotEmpty && gap > _shortTransitionMillis) {
        nodes.add(_parkedNode(loc, gap, connector: _TimelineConnector.grey()));
      }

      final sessionColor = _sessionColor(type);
      final startConnector = nodes.isEmpty
          ? null
          : gap <= _shortTransitionMillis &&
                previousType != null &&
                previousType != type
          ? _TimelineConnector.gradient(
              from: _sessionColor(previousType),
              to: sessionColor,
            )
          : _TimelineConnector.grey();

      nodes.add(
        _TimelineNode(
          color: sessionColor,
          marker: _markerFor(type, start: true),
          connectorFromPrevious: startConnector,
        ),
      );
      nodes.add(
        _TimelineNode(
          color: sessionColor,
          marker: _markerFor(type, start: false),
          connectorFromPrevious: _TimelineConnector.solid(sessionColor),
          card: _TimelineSessionCardData.fromSession(session, loc),
        ),
      );

      cursor = end;
      previousType = type;
    }

    final trailingGap = rangeEndUtcMillis - cursor;
    if (nodes.isNotEmpty && trailingGap > _shortTransitionMillis) {
      nodes.add(
        _parkedNode(loc, trailingGap, connector: _TimelineConnector.grey()),
      );
    }
    return nodes;
  }

  static bool _isSupported(HistorySessionRow session) {
    final type = session.type.toUpperCase();
    return type == 'TRIP' || type == 'CHARGE';
  }

  static Color _sessionColor(String? type) {
    return type == 'CHARGE'
        ? AutomotiveColors.secondary
        : AutomotiveColors.tertiary;
  }

  static IconData _markerFor(String type, {required bool start}) {
    if (type == 'CHARGE') {
      return start ? Icons.power : Icons.battery_charging_full;
    }
    return start ? Icons.play_arrow : Icons.flag;
  }

  static _TimelineNode _parkedNode(
    AppLocalizations loc,
    int durationMillis, {
    _TimelineConnector? connector,
  }) {
    return _TimelineNode(
      color: AutomotiveColors.outline,
      marker: Icons.local_parking,
      connectorFromPrevious: connector,
      parkedLabel: loc.timelineParkedFor(_formatDuration(durationMillis)),
    );
  }

  static String _formatDuration(int millis) {
    final duration = Duration(milliseconds: millis);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    if (hours <= 0) return '${minutes}M';
    return '${hours}H ${minutes.toString().padLeft(2, '0')}M';
  }
}

class _TimelineNodeContent extends StatelessWidget {
  const _TimelineNodeContent({required this.node});

  final _TimelineNode node;

  @override
  Widget build(BuildContext context) {
    final card = node.card;
    if (card != null) return _SessionBlock(data: card);
    final parkedLabel = node.parkedLabel;
    if (parkedLabel == null) return const SizedBox.shrink();
    return SizedBox(
      height: 40,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          parkedLabel,
          overflow: TextOverflow.ellipsis,
          style: AutomotiveTextStyles.unitLabel.copyWith(
            color: AutomotiveColors.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

class _SessionBlock extends StatelessWidget {
  const _SessionBlock({required this.data});

  final _TimelineSessionCardData data;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 54),
      padding: const EdgeInsets.symmetric(
        horizontal: AutomotiveSpacing.x2,
        vertical: AutomotiveSpacing.x1,
      ),
      decoration: BoxDecoration(
        color: data.color.withValues(alpha: 0.12),
        border: Border.all(color: data.color.withValues(alpha: 0.42)),
        borderRadius: AutomotiveRadii.baseRadius,
      ),
      child: Row(
        children: [
          Icon(data.icon, color: data.color, size: 20),
          const SizedBox(width: AutomotiveSpacing.x1),
          Expanded(
            child: Text(
              data.primary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AutomotiveTextStyles.headlineMd.copyWith(
                color: AutomotiveColors.onSurface,
                fontFamily: AutomotiveFonts.mono,
                fontSize: 20,
              ),
            ),
          ),
          const SizedBox(width: AutomotiveSpacing.x2),
          Text(
            data.secondary,
            overflow: TextOverflow.ellipsis,
            style: AutomotiveTextStyles.unitLabel.copyWith(
              color: data.color,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _TimelinePainter extends CustomPainter {
  const _TimelinePainter({required this.nodes});

  final List<_TimelineNode> nodes;

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = HistoryVehicleTimeline._axisX;
    for (var i = 1; i < nodes.length; i++) {
      final fromY = (i - 1) * HistoryVehicleTimeline._nodeSpacing + 18;
      final toY = i * HistoryVehicleTimeline._nodeSpacing + 18;
      final connector = nodes[i].connectorFromPrevious;
      if (connector == null) continue;
      final paint = Paint()
        ..strokeCap = StrokeCap.round
        ..strokeWidth = connector.width;
      if (connector.toColor == null) {
        paint.color = connector.fromColor;
      } else {
        paint.shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [connector.fromColor, connector.toColor!],
        ).createShader(Rect.fromLTRB(centerX, fromY, centerX, toY));
      }
      canvas.drawLine(Offset(centerX, fromY), Offset(centerX, toY), paint);
    }

    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      final center = Offset(
        centerX,
        i * HistoryVehicleTimeline._nodeSpacing + 18,
      );
      final fill = Paint()..color = node.color;
      final ring = Paint()
        ..color = AutomotiveColors.surface
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;
      canvas.drawCircle(
        center,
        node.color == AutomotiveColors.outline ? 8 : 11,
        fill,
      );
      canvas.drawCircle(
        center,
        node.color == AutomotiveColors.outline ? 8 : 11,
        ring,
      );
    }
  }

  @override
  bool shouldRepaint(_TimelinePainter oldDelegate) {
    return oldDelegate.nodes != nodes;
  }
}

class _TimelineNode {
  const _TimelineNode({
    required this.color,
    required this.marker,
    this.connectorFromPrevious,
    this.parkedLabel,
    this.card,
  });

  final Color color;
  final IconData marker;
  final _TimelineConnector? connectorFromPrevious;
  final String? parkedLabel;
  final _TimelineSessionCardData? card;
}

class _TimelineConnector {
  const _TimelineConnector._({
    required this.fromColor,
    required this.toColor,
    required this.width,
  });

  _TimelineConnector.grey()
    : this._(fromColor: AutomotiveColors.outline, toColor: null, width: 2);

  const _TimelineConnector.solid(Color color)
    : this._(fromColor: color, toColor: null, width: 5);

  const _TimelineConnector.gradient({required Color from, required Color to})
    : this._(fromColor: from, toColor: to, width: 5);

  final Color fromColor;
  final Color? toColor;
  final double width;
}

class _TimelineSessionCardData {
  const _TimelineSessionCardData({
    required this.color,
    required this.icon,
    required this.primary,
    required this.secondary,
  });

  factory _TimelineSessionCardData.fromSession(
    HistorySessionRow session,
    AppLocalizations loc,
  ) {
    final type = session.type.toUpperCase();
    if (type == 'CHARGE') {
      return _TimelineSessionCardData(
        color: AutomotiveColors.secondary,
        icon: Icons.ev_station,
        primary: loc.sessionTypeCharging,
        secondary: _formatSocDelta(session.socDeltaPercent),
      );
    }
    return _TimelineSessionCardData(
      color: AutomotiveColors.tertiary,
      icon: Icons.route,
      primary: _formatDistance(session.distanceKm),
      secondary: _formatSocDelta(session.socDeltaPercent),
    );
  }

  final Color color;
  final IconData icon;
  final String primary;
  final String secondary;
}

String _formatDistance(double? value) {
  if (value == null) return '-- km';
  return '${value.toStringAsFixed(1)} km';
}

String _formatSocDelta(double? value) {
  if (value == null) return '--%';
  final prefix = value > 0 ? '+' : '';
  return '$prefix${value.toStringAsFixed(1)}% SOC';
}
