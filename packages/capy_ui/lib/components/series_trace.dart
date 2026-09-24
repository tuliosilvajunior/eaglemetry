import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// One reading along a recorded session.
///
/// [value] is null for an interval the car reported nothing for. That is not
/// the same as a zero, and [SeriesTrace] breaks the line there rather than
/// drawing through it.
class SeriesTracePoint {
  const SeriesTracePoint({required this.position, required this.value});

  /// Where the reading sits along the session, 0 at the start and 1 at the end.
  ///
  /// A fraction rather than a timestamp, because the trace answers "what was
  /// happening across this drive" and never "at 14:32". A caller with stamps
  /// converts once; the component then needs no clock and no locale.
  final double position;

  final double? value;
}

/// One measured quantity across a session, drawn as a line over its own range.
///
/// This is the plain trace — altitude across a drive, outside temperature
/// across a charge. It is deliberately not `EfficiencyChart`, which is fixed to
/// Wh/km on a descending axis with a smoothness pill, because that chart
/// carries a judgement about what is good. Nothing here is good or bad: a hill
/// is a hill.
///
/// The vertical axis is the range of the data, not a fixed scale. A drive over
/// flat ground and a drive over a mountain are different questions, and a fixed
/// altitude axis would flatten the first into a straight line at the bottom.
/// The two labels state the range, so a flat trace cannot be misread as a
/// dramatic one — the numbers beside it say how much of a climb it was.
///
/// A gap breaks the line. Joining across an interval the car did not report
/// would invent a slope that nothing measured.
class SeriesTrace extends StatelessWidget {
  const SeriesTrace({
    required this.points,
    required this.minLabel,
    required this.maxLabel,
    this.color,
    this.height = AppSizes.seriesTraceHeight,
    this.semanticsLabel,
    super.key,
  });

  final List<SeriesTracePoint> points;

  /// The two ends of the range, pre-formatted and localized by the caller.
  final String minLabel;
  final String maxLabel;

  /// Null takes the theme's ordinary ink. Pass a colour when the reading has a
  /// series of its own on the same screen.
  final Color? color;

  final double height;

  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Semantics(
      label: semanticsLabel,
      readOnly: true,
      // The height is stated once, on the row, and the two children stretch
      // inside it. A stretching row with no height of its own is asked for an
      // infinite one by any column that scrolls, which is every screen this
      // sits on.
      child: SizedBox(
        height: height,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: CustomPaint(
                painter: _SeriesTracePainter(
                  points: points,
                  line: color ?? colors.ink,
                  guide: colors.divider,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.x3),
            // The range sits beside the line, high mark on top, so the two
            // labels read as the ends of the axis rather than as two more
            // readings.
            SizedBox(
              width: AppSizes.seriesTraceLabelWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    maxLabel,
                    style: AppText.caption.copyWith(color: colors.inkMuted),
                  ),
                  Text(
                    minLabel,
                    style: AppText.caption.copyWith(color: colors.inkSubtle),
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

class _SeriesTracePainter extends CustomPainter {
  const _SeriesTracePainter({
    required this.points,
    required this.line,
    required this.guide,
  });

  final List<SeriesTracePoint> points;
  final Color line;
  final Color guide;

  @override
  void paint(Canvas canvas, Size size) {
    final values = [
      for (final point in points)
        if (point.value case final value? when value.isFinite) value,
    ];
    if (values.isEmpty) return;

    var low = values.reduce(math.min);
    var high = values.reduce(math.max);
    // A reading that never changed is a real answer. Without a span it would
    // divide by zero, so it is drawn down the middle of its own range.
    if (high - low < _flatSpan) {
      final middle = (high + low) / 2;
      low = middle - _flatSpan / 2;
      high = middle + _flatSpan / 2;
    }

    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, size.height),
      Paint()
        ..color = guide
        ..strokeWidth = 1,
    );

    final stroke = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    var drawing = false;
    for (final point in points) {
      final value = point.value;
      if (value == null || !value.isFinite) {
        // The break is the whole point: a gap must not become a slope.
        drawing = false;
        continue;
      }
      final x = point.position.clamp(0.0, 1.0) * size.width;
      final y = size.height - ((value - low) / (high - low)) * size.height;
      if (drawing) {
        path.lineTo(x, y);
      } else {
        path.moveTo(x, y);
        drawing = true;
      }
    }
    canvas.drawPath(path, stroke);
  }

  /// The range a flat reading is given, in the unit of whatever is plotted.
  static const _flatSpan = 1.0;
  static const _strokeWidth = 2.0;

  @override
  bool shouldRepaint(_SeriesTracePainter old) =>
      old.points != points || old.line != line || old.guide != guide;
}
