import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// Which edge of the bubble the caret sits on.
///
/// Named for the bubble's own geometry, not for the datum: a tooltip floating
/// *above* a bar carries its caret on [bottom].
enum ChartTooltipSide { top, bottom, left, right, none }

/// One supporting line inside a [ChartTooltip].
///
/// [color] draws the series swatch, which is what lets a tooltip explain a
/// stacked bar without repeating the legend. It is the series color itself —
/// the tooltip uses the inverse surface, and the swatches are
/// read against it directly.
@immutable
class ChartTooltipRow {
  const ChartTooltipRow({required this.label, this.value, this.color});

  /// Localized label.
  final String label;

  /// Pre-formatted value, right-aligned against the label.
  final String? value;

  /// Series swatch. Omit for a plain line.
  final Color? color;

  @override
  bool operator ==(Object other) =>
      other is ChartTooltipRow &&
      other.label == label &&
      other.value == value &&
      other.color == color;

  @override
  int get hashCode => Object.hash(label, value, color);
}

/// Floating dark callout naming the value under a chart's cursor.
///
/// The inverse surface is here for a reason: a tooltip travels across both a card and a
/// saturated bar, so it cannot borrow either of their contrasts.
///
/// The widget is purely presentational and sizes to its content. **Positioning
/// is the chart's job** — a tooltip that placed itself would have to know the
/// plot's bounds, and every chart clamps against those differently. Give it a
/// [side] and a [caretAlignment] and the caret lands on the datum even after
/// the chart has clamped the bubble away from a plot edge.
///
/// Show and hide it with [AppMotion.fast]; it deliberately has no entrance
/// animation of its own, because an opacity or offset tween fighting the
/// parent's positioning is what makes a scrubbing tooltip feel to lag.
///
/// ```dart
/// ChartTooltip(
///   title: loc.chartAt(label),
///   value: '10.8',
///   unit: loc.unitKw,
///   side: ChartTooltipSide.bottom,
///   caretAlignment: 0.4,
///   rows: [
///     ChartTooltipRow(
///       label: loc.energyConsumed,
///       value: '55.6 kWh',
///       color: AppThemeColors.of(context).energy.draw,
///     ),
///   ],
/// )
/// ```
class ChartTooltip extends StatelessWidget {
  const ChartTooltip({
    this.title,
    this.value,
    this.unit,
    this.rows = const [],
    this.side = ChartTooltipSide.bottom,
    this.caretAlignment = 0,
    this.maxWidth = 280,
    this.backgroundColor,
    this.semanticsLabel,
    super.key,
  });

  /// Localized line above the headline — usually the x-axis label the reading
  /// belongs to (`14:00`, `Tue`).
  final String? title;

  /// Pre-formatted headline value. Formatting stays with the caller.
  final String? value;

  /// Localized unit trailing [value].
  final String? unit;

  final List<ChartTooltipRow> rows;

  final ChartTooltipSide side;

  /// Where the caret sits along [side], from `-1` (start) to `1` (end).
  ///
  /// The travel is measured over the edge minus the corner radii and the
  /// caret's own width, so the caret cannot ride up onto a rounded corner no
  /// matter what the chart passes.
  final double caretAlignment;

  /// Wrapping width for long labels. The bubble is otherwise intrinsic.
  final double maxWidth;

  final Color? backgroundColor;

  /// Localized description for screen readers. Without it the tooltip is
  /// decorative, which is usually right: it repeats a value the chart already
  /// exposes.
  final String? semanticsLabel;

  EdgeInsets get _padding {
    const base = EdgeInsets.symmetric(
      horizontal: AppSpacing.x4,
      vertical: AppSpacing.x3,
    );
    const caret = AppSizes.tooltipCaret;
    return switch (side) {
      ChartTooltipSide.top => base + const EdgeInsets.only(top: caret),
      ChartTooltipSide.bottom => base + const EdgeInsets.only(bottom: caret),
      ChartTooltipSide.left => base + const EdgeInsets.only(left: caret),
      ChartTooltipSide.right => base + const EdgeInsets.only(right: caret),
      ChartTooltipSide.none => base,
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Semantics(
      label: semanticsLabel,
      container: semanticsLabel != null,
      child: CustomPaint(
        painter: _BubblePainter(
          side: side,
          alignment: caretAlignment.clamp(-1.0, 1.0),
          color: backgroundColor ?? colors.inverseSurface,
        ),
        // Intrinsic width so the row values right-align against a shared edge;
        // without it each row would size independently and the numbers would
        // stagger.
        child: IntrinsicWidth(
          child: _MaxWidthBox(
            maxWidth: maxWidth,
            child: Padding(
              padding: _padding,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (title != null) Text(title!, style: AppText.tooltipLine),
                  if (value != null) ...[
                    if (title != null) const SizedBox(height: AppSpacing.x1),
                    _Headline(value: value!, unit: unit),
                  ],
                  for (final row in rows) ...[
                    const SizedBox(height: AppSpacing.x2),
                    _Row(row: row),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Caps the width, *including* in intrinsic queries.
///
/// A `ConstrainedBox` cannot do this job. Its height intrinsics forward the
/// incoming width to the child untouched, so a parent measuring the tooltip is
/// told the height of unwrapped text and then wraps it at layout time — the
/// tooltip ends up laid out shorter than it draws, and whatever measured it
/// overflows. That is not hypothetical here: labels arrive from three locales,
/// and `pt`/`ru` run long enough to wrap where `en` does not.
class _MaxWidthBox extends SingleChildRenderObjectWidget {
  const _MaxWidthBox({required this.maxWidth, required Widget super.child});

  final double maxWidth;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMaxWidthBox(maxWidth);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderMaxWidthBox renderObject,
  ) {
    renderObject.maxWidth = maxWidth;
  }
}

class _RenderMaxWidthBox extends RenderProxyBox {
  _RenderMaxWidthBox(this._maxWidth);

  double _maxWidth;

  double get maxWidth => _maxWidth;

  set maxWidth(double value) {
    if (value == _maxWidth) return;
    _maxWidth = value;
    markNeedsLayout();
  }

  BoxConstraints _constrain(BoxConstraints constraints) =>
      constraints.enforce(BoxConstraints(maxWidth: _maxWidth));

  @override
  double computeMinIntrinsicWidth(double height) =>
      math.min(super.computeMinIntrinsicWidth(height), _maxWidth);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      math.min(super.computeMaxIntrinsicWidth(height), _maxWidth);

  @override
  double computeMinIntrinsicHeight(double width) =>
      super.computeMinIntrinsicHeight(math.min(width, _maxWidth));

  @override
  double computeMaxIntrinsicHeight(double width) =>
      super.computeMaxIntrinsicHeight(math.min(width, _maxWidth));

  @override
  Size computeDryLayout(BoxConstraints constraints) => child == null
      ? constraints.smallest
      : child!.getDryLayout(_constrain(constraints));

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(_constrain(constraints), parentUsesSize: true);
    size = child.size;
  }
}

class _Headline extends StatelessWidget {
  const _Headline({required this.value, this.unit});

  final String value;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(value, style: AppText.tooltipValue),
        if (unit != null) ...[
          const SizedBox(width: AppSpacing.x1),
          Text(unit!, style: AppText.tooltipLine),
        ],
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.row});

  final ChartTooltipRow row;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (row.color != null) ...[
          Container(
            width: AppSizes.tooltipSwatch,
            height: AppSizes.tooltipSwatch,
            decoration: BoxDecoration(color: row.color, shape: BoxShape.circle),
          ),
          const SizedBox(width: AppSpacing.x2),
        ],
        Expanded(child: Text(row.label, style: AppText.tooltipLine)),
        if (row.value != null) ...[
          const SizedBox(width: AppSpacing.x4),
          Text(
            row.value!,
            style: AppText.tooltipLine.copyWith(
              color: AppThemeColors.of(context).onInverseSurface,
            ),
          ),
        ],
      ],
    );
  }
}

/// Rounded body plus caret, drawn as one shape.
///
/// The two parts are unioned rather than painted one over the other: they are
/// the same opaque color, so overlapping them would leave a faint antialiasing
/// seam exactly along the edge the caret is meant to grow out of.
class _BubblePainter extends CustomPainter {
  const _BubblePainter({
    required this.side,
    required this.alignment,
    required this.color,
  });

  static const radius = AppRadii.md;
  static const caretExtent = AppSizes.tooltipCaret;
  static const caretWidth = AppSizes.tooltipCaretWidth;

  final ChartTooltipSide side;
  final double alignment;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final body = switch (side) {
      ChartTooltipSide.top => Rect.fromLTRB(
        0,
        caretExtent,
        size.width,
        size.height,
      ),
      ChartTooltipSide.bottom => Rect.fromLTRB(
        0,
        0,
        size.width,
        size.height - caretExtent,
      ),
      ChartTooltipSide.left => Rect.fromLTRB(
        caretExtent,
        0,
        size.width,
        size.height,
      ),
      ChartTooltipSide.right => Rect.fromLTRB(
        0,
        0,
        size.width - caretExtent,
        size.height,
      ),
      ChartTooltipSide.none => Offset.zero & size,
    };
    if (body.isEmpty) return;

    final bubble = Path()
      ..addRRect(RRect.fromRectAndRadius(body, Radius.circular(radius)));
    final caret = _caretPath(body);

    canvas.drawPath(
      caret == null ? bubble : Path.combine(PathOperation.union, bubble, caret),
      Paint()..color = color,
    );
  }

  Path? _caretPath(Rect body) {
    if (side == ChartTooltipSide.none || caretExtent <= 0 || caretWidth <= 0) {
      return null;
    }
    final vertical =
        side == ChartTooltipSide.top || side == ChartTooltipSide.bottom;

    // Travel excludes the corners and the caret's own half-width, so the caret
    // stays on the flat part of the edge whatever alignment it is handed.
    final span =
        (vertical ? body.width : body.height) - 2 * radius - caretWidth;
    if (span < 0) return null;
    final offset = alignment * span / 2;
    final mid = (vertical ? body.center.dx : body.center.dy) + offset;
    final half = caretWidth / 2;

    return switch (side) {
      ChartTooltipSide.top =>
        Path()
          ..moveTo(mid - half, body.top)
          ..lineTo(mid, body.top - caretExtent)
          ..lineTo(mid + half, body.top),
      ChartTooltipSide.bottom =>
        Path()
          ..moveTo(mid - half, body.bottom)
          ..lineTo(mid, body.bottom + caretExtent)
          ..lineTo(mid + half, body.bottom),
      ChartTooltipSide.left =>
        Path()
          ..moveTo(body.left, mid - half)
          ..lineTo(body.left - caretExtent, mid)
          ..lineTo(body.left, mid + half),
      ChartTooltipSide.right =>
        Path()
          ..moveTo(body.right, mid - half)
          ..lineTo(body.right + caretExtent, mid)
          ..lineTo(body.right, mid + half),
      ChartTooltipSide.none => Path(),
    }..close();
  }

  @override
  bool shouldRepaint(_BubblePainter old) =>
      old.side != side || old.alignment != alignment || old.color != color;
}
