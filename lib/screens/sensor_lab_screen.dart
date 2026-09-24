import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/sensor_lab_api.dart';
import '../design_system/design_system.dart';
import '../l10n/app_localizations.dart';

/// Vertical acceleration (m/s^2) above which a frame counts as a "bump".
const double _bumpThreshold = 2.5;

/// Full-scale for the g-force bars (m/s^2). ~1 g.
const double _accelFullScale = 10.0;

/// How many recent vertical-accel samples the road sparkline keeps.
const int _traceLength = 140;

class SensorLabScreen extends StatefulWidget {
  const SensorLabScreen({super.key});

  @override
  State<SensorLabScreen> createState() => _SensorLabScreenState();
}

class _SensorLabScreenState extends State<SensorLabScreen> {
  final _api = SensorLabApi();
  StreamSubscription<SensorLabFrame>? _subscription;
  final ListQueue<double> _trace = ListQueue<double>(_traceLength);

  SensorLabFrame? _frame;
  double _zeroPitch = 0;
  double _zeroRoll = 0;
  int _bumpCount = 0;
  double _sessionPeakVertical = 0;
  DateTime? _lastBumpAt;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _start() {
    _subscription?.cancel();
    setState(() => _error = null);
    _subscription = _api.stream().listen(
      _onFrame,
      onError: (Object error) {
        if (!mounted) return;
        setState(() => _error = error.toString());
      },
    );
  }

  void _onFrame(SensorLabFrame frame) {
    if (!mounted) return;
    setState(() {
      _frame = frame;
      _trace.addLast(frame.peakVertical);
      while (_trace.length > _traceLength) {
        _trace.removeFirst();
      }
      final absPeak = frame.peakVertical.abs();
      if (absPeak >= _bumpThreshold) {
        _bumpCount += 1;
        _lastBumpAt = DateTime.now();
      }
      if (absPeak > _sessionPeakVertical) _sessionPeakVertical = absPeak;
    });
  }

  void _calibrate() {
    final frame = _frame;
    if (frame == null) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _zeroPitch = frame.pitchDeg;
      _zeroRoll = frame.rollDeg;
    });
  }

  void _reset() {
    HapticFeedback.selectionClick();
    setState(() {
      _bumpCount = 0;
      _sessionPeakVertical = 0;
      _lastBumpAt = null;
      _trace.clear();
    });
  }

  bool get _bumpActive {
    final at = _lastBumpAt;
    return at != null &&
        DateTime.now().difference(at) < const Duration(milliseconds: 350);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final frame = _frame;
    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        title: Text(loc.sensorLabTitle),
        backgroundColor: colors.surface,
        foregroundColor: colors.onSurface,
        actions: [
          IconButton(
            onPressed: frame == null ? null : _calibrate,
            tooltip: loc.sensorLabCalibrate,
            icon: const Icon(Icons.center_focus_strong),
          ),
          IconButton(
            onPressed: _reset,
            tooltip: loc.sensorLabReset,
            icon: const Icon(Icons.restart_alt),
          ),
        ],
      ),
      body: _error != null
          ? _CenteredMessage(text: loc.sensorLabUnavailable)
          : frame == null
          ? _CenteredMessage(text: loc.sensorLabWaiting)
          : Padding(
              padding: AutomotiveSpacing.panelPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: _LevelPanel(
                            pitch: frame.pitchDeg - _zeroPitch,
                            roll: frame.rollDeg - _zeroRoll,
                          ),
                        ),
                        const SizedBox(width: AutomotiveSpacing.x2),
                        Expanded(
                          child: _ForcePanel(
                            vertical: frame.vertical,
                            horizontal: frame.horizontal,
                            peakVertical: frame.peakVertical,
                            peakHorizontal: frame.peakHorizontal,
                            bumpActive: _bumpActive,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AutomotiveSpacing.x2),
                  _RoadTracePanel(trace: _trace.toList(growable: false)),
                  const SizedBox(height: AutomotiveSpacing.x2),
                  _StatsRow(
                    bumpCount: _bumpCount,
                    sessionPeak: _sessionPeakVertical,
                    sampleRateHz: frame.sampleCount * (1000 / 100),
                  ),
                ],
              ),
            ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: AutomotiveRadii.baseRadius,
      ),
      padding: AutomotiveSpacing.panelPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: AutomotiveTextStyles.labelCaps.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AutomotiveSpacing.x1),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _LevelPanel extends StatelessWidget {
  const _LevelPanel({required this.pitch, required this.roll});
  final double pitch;
  final double roll;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    return _Panel(
      title: loc.sensorLabLevel,
      child: Column(
        children: [
          Expanded(
            child: CustomPaint(
              painter: _LevelPainter(
                pitch: pitch,
                roll: roll,
                lineColor: colors.outline,
                bubbleColor: colors.primary,
                ringColor: colors.outlineVariant,
              ),
              child: const SizedBox.expand(),
            ),
          ),
          const SizedBox(height: AutomotiveSpacing.x1),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _AngleReadout(label: loc.sensorLabPitch, value: pitch),
              _AngleReadout(label: loc.sensorLabRoll, value: roll),
            ],
          ),
        ],
      ),
    );
  }
}

class _AngleReadout extends StatelessWidget {
  const _AngleReadout({required this.label, required this.value});
  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        Text(
          '${value >= 0 ? '+' : ''}${value.toStringAsFixed(1)}°',
          style: AutomotiveTextStyles.bodyMd.copyWith(
            color: colors.onSurface,
            fontWeight: FontWeight.w700,
            fontSize: 22,
          ),
        ),
        Text(
          label,
          style: AutomotiveTextStyles.labelCaps.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _LevelPainter extends CustomPainter {
  _LevelPainter({
    required this.pitch,
    required this.roll,
    required this.lineColor,
    required this.bubbleColor,
    required this.ringColor,
  });
  final double pitch;
  final double roll;
  final Color lineColor;
  final Color bubbleColor;
  final Color ringColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2 - 8;

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = ringColor;
    canvas.drawCircle(center, radius, ring);
    canvas.drawCircle(center, radius / 2, ring);

    final cross = Paint()
      ..strokeWidth = 1
      ..color = lineColor;
    canvas.drawLine(
      Offset(center.dx - radius, center.dy),
      Offset(center.dx + radius, center.dy),
      cross,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - radius),
      Offset(center.dx, center.dy + radius),
      cross,
    );

    // Map +-15 degrees to full radius. Roll pushes the bubble sideways, pitch
    // up/down (nose up = bubble toward top).
    const maxDeg = 15.0;
    final dx = (roll / maxDeg).clamp(-1.0, 1.0) * radius;
    final dy = (pitch / maxDeg).clamp(-1.0, 1.0) * radius;
    final bubble = center + Offset(dx, -dy);

    final bubblePaint = Paint()..color = bubbleColor;
    canvas.drawCircle(bubble, 14, bubblePaint);
    canvas.drawCircle(
      bubble,
      14,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white.withValues(alpha: 0.6),
    );
  }

  @override
  bool shouldRepaint(_LevelPainter old) =>
      old.pitch != pitch || old.roll != roll;
}

class _ForcePanel extends StatelessWidget {
  const _ForcePanel({
    required this.vertical,
    required this.horizontal,
    required this.peakVertical,
    required this.peakHorizontal,
    required this.bumpActive,
  });
  final double vertical;
  final double horizontal;
  final double peakVertical;
  final double peakHorizontal;
  final bool bumpActive;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    return _Panel(
      title: loc.sensorLabForces,
      child: Column(
        children: [
          Expanded(
            child: _BarMeter(
              label: loc.sensorLabVertical,
              value: vertical.abs(),
              peak: peakVertical.abs(),
              fullScale: _accelFullScale,
              color: bumpActive ? colors.error : colors.tertiary,
              trackColor: colors.surfaceContainerHighest,
              textColor: colors.onSurface,
              subTextColor: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AutomotiveSpacing.x1),
          Expanded(
            child: _BarMeter(
              label: loc.sensorLabHorizontal,
              value: horizontal,
              peak: peakHorizontal,
              fullScale: _accelFullScale,
              color: colors.primary,
              trackColor: colors.surfaceContainerHighest,
              textColor: colors.onSurface,
              subTextColor: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _BarMeter extends StatelessWidget {
  const _BarMeter({
    required this.label,
    required this.value,
    required this.peak,
    required this.fullScale,
    required this.color,
    required this.trackColor,
    required this.textColor,
    required this.subTextColor,
  });
  final String label;
  final double value;
  final double peak;
  final double fullScale;
  final Color color;
  final Color trackColor;
  final Color textColor;
  final Color subTextColor;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final fraction = (value / fullScale).clamp(0.0, 1.0);
    final peakFraction = (peak / fullScale).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: AutomotiveTextStyles.bodyMd.copyWith(
                color: subTextColor,
                fontSize: 13,
              ),
            ),
            Text(
              '${value.toStringAsFixed(1)}  ·  ${loc.sensorLabPeak} ${peak.toStringAsFixed(1)}',
              style: AutomotiveTextStyles.bodyMd.copyWith(
                color: textColor,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              return Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: trackColor,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: fraction,
                    child: Container(
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
                  Positioned(
                    left: (peakFraction * w).clamp(0.0, w - 2),
                    top: 0,
                    bottom: 0,
                    child: Container(width: 2, color: textColor),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _RoadTracePanel extends StatelessWidget {
  const _RoadTracePanel({required this.trace});
  final List<double> trace;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    return Container(
      height: 110,
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: AutomotiveRadii.baseRadius,
      ),
      padding: AutomotiveSpacing.panelPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            loc.sensorLabRoadTrace,
            style: AutomotiveTextStyles.labelCaps.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: CustomPaint(
              painter: _TracePainter(
                trace: trace,
                lineColor: colors.tertiary,
                zeroColor: colors.outlineVariant,
                fullScale: _accelFullScale,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ),
    );
  }
}

class _TracePainter extends CustomPainter {
  _TracePainter({
    required this.trace,
    required this.lineColor,
    required this.zeroColor,
    required this.fullScale,
  });
  final List<double> trace;
  final Color lineColor;
  final Color zeroColor;
  final double fullScale;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    canvas.drawLine(
      Offset(0, mid),
      Offset(size.width, mid),
      Paint()
        ..strokeWidth = 1
        ..color = zeroColor,
    );
    if (trace.length < 2) return;
    final path = Path();
    final dx = size.width / (_traceLength - 1);
    for (var i = 0; i < trace.length; i++) {
      final norm = (trace[i] / fullScale).clamp(-1.0, 1.0);
      final x = i * dx;
      final y = mid - norm * mid;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = lineColor,
    );
  }

  @override
  bool shouldRepaint(_TracePainter old) => true;
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({
    required this.bumpCount,
    required this.sessionPeak,
    required this.sampleRateHz,
  });
  final int bumpCount;
  final double sessionPeak;
  final double sampleRateHz;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Row(
      children: [
        Expanded(
          child: _Stat(label: loc.sensorLabBumps, value: '$bumpCount'),
        ),
        const SizedBox(width: AutomotiveSpacing.x2),
        Expanded(
          child: _Stat(
            label: loc.sensorLabSessionPeak,
            value: '${sessionPeak.toStringAsFixed(1)} m/s²',
          ),
        ),
        const SizedBox(width: AutomotiveSpacing.x2),
        Expanded(
          child: _Stat(
            label: loc.sensorLabRate,
            value: '${sampleRateHz.round()} Hz',
          ),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: AutomotiveRadii.baseRadius,
      ),
      padding: const EdgeInsets.symmetric(
        vertical: AutomotiveSpacing.x1,
        horizontal: AutomotiveSpacing.x2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: AutomotiveTextStyles.bodyMd.copyWith(
              color: colors.onSurface,
              fontWeight: FontWeight.w700,
              fontSize: 18,
            ),
          ),
          Text(
            label,
            style: AutomotiveTextStyles.labelCaps.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Text(
        text,
        style: AutomotiveTextStyles.bodyMd.copyWith(
          color: colors.onSurfaceVariant,
        ),
      ),
    );
  }
}
