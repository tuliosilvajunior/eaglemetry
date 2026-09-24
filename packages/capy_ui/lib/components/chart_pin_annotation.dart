import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import 'chart_tooltip.dart';

/// Vertical rule through a plot with a dot marking the pinned reading.
///
/// This is the marker half of a chart callout: the rule ties a reading to its
/// column, and the dot sits on the value itself. Pair it with a [ChartTooltip]
/// placed above the dot — they are separate components because the rule spans
/// the plot while the bubble has to be clamped inside it, so they are almost
/// never positioned by the same rectangle.
///
/// The dot carries a [ringColor] halo. Without it the marker disappears the
/// moment it lands on a dark bar or crosses the ink overlay curve, which is
/// exactly where a reading is most likely to be pinned.
///
/// **Nothing here animates.** The rule follows a finger or a rotary control,
/// and a tween between samples reads as the marker lagging behind the input.
/// The chart moves it every frame instead.
///
/// ```dart
/// Positioned(
///   left: x - ChartPinAnnotation.width / 2,
///   top: plot.top,
///   child: ChartPinAnnotation(height: plot.height, dotOffset: 0.35),
/// )
/// ```
class ChartPinAnnotation extends StatelessWidget {
  const ChartPinAnnotation({
    required this.height,
    this.dotOffset = 0,
    this.color,
    this.ruleColor,
    this.ringColor,
    this.showDot = true,
    this.extendAboveDot = true,
    this.dotSize = AppSizes.chartPinDot,
    this.ringWidth = AppSizes.chartPinRing,
    this.ruleWidth = AppSizes.chartPinRule,
    this.semanticsLabel,
    super.key,
  });

  /// Default horizontal footprint. A larger [dotSize] expands the footprint so
  /// the painter does not clip the marker.
  static const width = AppSizes.chartPinDot;

  /// Plot height the rule spans.
  final double height;

  /// Where the dot sits on the rule, `0` at the top of the plot and `1` at the
  /// bottom. A fraction rather than a pixel offset, so the caller converts from
  /// its value axis once and does not also have to know the dot's geometry.
  final double dotOffset;

  /// Dot fill. Defaults to the light center of the reference ring marker.
  final Color? color;

  final Color? ruleColor;

  /// Ring outline separating the dot from whatever it lands on.
  final Color? ringColor;

  /// Set false for a bare rule — a "now" divider with no reading attached.
  final bool showDot;

  /// Whether the rule continues above the dot. False draws it only from the
  /// dot down to the axis, which reads as a stem hanging off the value.
  final bool extendAboveDot;

  final double dotSize;
  final double ringWidth;
  final double ruleWidth;

  /// Localized description for screen readers. Usually null: the pinned value
  /// is announced by the tooltip beside it.
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Semantics(
      label: semanticsLabel,
      container: semanticsLabel != null,
      child: SizedBox(
        width: math.max(width, math.max(dotSize, ruleWidth)),
        height: height,
        child: CustomPaint(
          painter: _PinPainter(
            dotOffset: dotOffset.clamp(0.0, 1.0),
            color: color ?? colors.surface,
            ruleColor: ruleColor ?? colors.chartNowMarker,
            ringColor: ringColor ?? colors.ink,
            showDot: showDot,
            extendAboveDot: extendAboveDot,
            dotSize: dotSize,
            ringWidth: ringWidth,
            ruleWidth: ruleWidth,
          ),
        ),
      ),
    );
  }
}

class _PinPainter extends CustomPainter {
  const _PinPainter({
    required this.dotOffset,
    required this.color,
    required this.ruleColor,
    required this.ringColor,
    required this.showDot,
    required this.extendAboveDot,
    required this.dotSize,
    required this.ringWidth,
    required this.ruleWidth,
  });

  final double dotOffset;
  final Color color;
  final Color ruleColor;
  final Color ringColor;
  final bool showDot;
  final bool extendAboveDot;
  final double dotSize;
  final double ringWidth;
  final double ruleWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.height <= 0) return;

    final x = size.width / 2;
    final dotY = dotOffset * size.height;
    // The rule runs under the dot rather than stopping at it, so the ring
    // reads as a hole punched in the line instead of two segments meeting.
    final top = extendAboveDot || !showDot ? 0.0 : dotY;

    if (ruleWidth > 0 && top < size.height) {
      canvas.drawLine(
        Offset(x, top),
        Offset(x, size.height),
        Paint()
          ..color = ruleColor
          ..strokeWidth = ruleWidth
          ..strokeCap = StrokeCap.round,
      );
    }

    if (!showDot || dotSize <= 0) return;

    final center = Offset(x, dotY);
    final outer = dotSize / 2;
    final inner = math.max(0.0, outer - ringWidth);
    canvas
      ..drawCircle(center, outer, Paint()..color = ringColor)
      ..drawCircle(center, inner, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_PinPainter old) =>
      old.dotOffset != dotOffset ||
      old.color != color ||
      old.ruleColor != ruleColor ||
      old.ringColor != ringColor ||
      old.showDot != showDot ||
      old.extendAboveDot != extendAboveDot ||
      old.dotSize != dotSize ||
      old.ringWidth != ringWidth ||
      old.ruleWidth != ruleWidth;
}
