import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// Driving efficiency over a rolling window, with a level marker beside it.
///
/// Two lines and the band between them, one point per interval of
/// `EfficiencySeries`:
///
///  * the **cost** line — energy per kilometre after regeneration is credited
///    back. Green above [neutral] and grey below it, which is the whole
///    reading: green is range being earned, grey is range being lost.
///  * the **demand** line — energy per kilometre before that credit. Drawn in
///    a neutral colour, because the car publishes no expectation for demand
///    and colouring it would assert a judgement nothing measured.
///  * the band between them is what braking gave back.
///
/// The unit is Wh/km and the axis descends: zero at the top, [ceilingWhPerKm]
/// at the bottom. Two reasons. Wh/km is "lower is better", and flipping the
/// axis keeps *up is good* true for the driver and keeps the line agreeing
/// with the pill beside it. And in Wh/km the three quantities share a
/// denominator, so demand minus recovered is exactly cost and the band is a
/// real subtraction; in km/kWh they are reciprocals and do not subtract, which
/// is why only one of them could ever be drawn.
///
/// The axis is fixed. A live chart that rescales itself makes every reading
/// move when one changes, so a value past [ceilingWhPerKm] is clipped and the
/// bottom guide is labelled `300+` rather than allowed to stretch the axis.
/// The clip is display only — nothing clamped reaches the window average.
///
/// Intervals with no reading break the lines instead of being drawn through.
/// Joining across a gap would invent driving that was never measured.
class EfficiencyChart extends StatelessWidget {
  const EfficiencyChart({
    required this.series,
    this.smoothness,
    this.ceilingWhPerKm = 300,
    this.neutral,
    this.floorLabel,
    this.unitLabel,
    this.height = 148,
    super.key,
  });

  /// Alpha the recovered-energy band fades to at the demand edge, as a
  /// fraction of the band colour's own alpha. Never reaches zero: a band that
  /// vanished at the gross line would print as a gap, and the gross line is a
  /// real reading, not the edge of the chart.
  static const recoveredBandFloorAlpha = 0.2;

  final EfficiencySeries series;

  /// Live driving smoothness for the pill beside the line, or null to omit it.
  ///
  /// It is a separate reading on a separate scale, not the head of [series].
  /// See [DrivingSmoothness] for why the two answer different questions.
  final DrivingSmoothness? smoothness;

  /// Bottom of the fixed axis, in Wh/km. Readings past it clip.
  final double ceilingWhPerKm;

  /// Efficiency at which the cost line changes colour, in **km/kWh**.
  ///
  /// The unit is the caller's, not the axis's: every reference the app has is
  /// a km/kWh figure, so converting here keeps that arithmetic in one place
  /// instead of at each call site.
  ///
  /// Better than it, the stretch earned range; worse, it lost range. It
  /// defaults to the middle of the axis, which is a legible divider but not a
  /// measured one. On a shipping screen, pass the same reference the pill uses
  /// (`RangeEstimate.efficiencyKmPerKwh`), so the colour means *worse than this
  /// car actually manages* rather than *the middle of a chart*.
  final double? neutral;

  /// Localized caption above the clip line — the mock's `Less range`.
  final String? floorLabel;

  /// Localized axis unit, drawn at the top of the plot.
  ///
  /// Not decoration. The axis reads 0 to 300 and the numeral beside it reads
  /// km/kWh, so without the unit the two look like the same quantity
  /// disagreeing with itself.
  final String? unitLabel;

  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final smoothness = this.smoothness;
    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: CustomPaint(
              painter: _EfficiencyLinePainter(
                series: series,
                ceiling: ceilingWhPerKm,
                // A km/kWh reference is Wh/km through its reciprocal. A
                // reference of zero or less has no reciprocal, so it falls
                // back to the middle of the axis rather than to infinity.
                neutral: (neutral == null || neutral! <= 0)
                    ? ceilingWhPerKm / 2
                    : 1000 / neutral!,
                grid: colors.chartGrid,
                gainColor: AppThemeColors.of(context).energy.gain,
                lossColor: colors.chartHeld,
                demandColor: colors.chartHeld,
                recoveredColor: AppThemeColors.of(context).energy.gain,
                haloColor: colors.surface,
                floorLabel: floorLabel,
                unitLabel: unitLabel,
                labelStyle: AppText.caption.copyWith(
                  color: colors.chartAxisLabel,
                ),
              ),
            ),
          ),
          if (smoothness != null) ...[
            const SizedBox(width: AppSpacing.x4),
            SmoothnessLevel(smoothness: smoothness),
          ],
        ],
      ),
    );
  }
}

/// The vertical pill beside the chart: how steadily the car is being driven.
///
/// Not the head of the line. The line is fifteen minutes of closed intervals and
/// steps every ten seconds; this reads the last thirty. The two sit together on
/// purpose — what the driving cost, beside how it was driven.
///
/// ## Two marks, and the gap between them is the message
///
/// The **knob** is [DrivingSmoothness.standing], the last thirty seconds. It is
/// the reading, and it is the only thing the colour follows, so the colour
/// cannot flicker with the pedal.
///
/// The **tick** is [DrivingSmoothness.instant], the last five. It is the same
/// quantity over a shorter horizon, which is exactly why the two can be
/// compared: a tick above the knob means this moment is smoother than the
/// recent average, so the driving is improving. That comparison is the whole
/// coaching, and it needs no text to read.
///
/// The tick is absent whenever the short window covered too little distance to
/// divide by — every stop included. A car that is not moving has no "now" to
/// set against its standing, and placing the mark anyway would imply a
/// measurement.
///
/// ## Why the reading changed
///
/// This used to show `speed / drivePower` against a fixed km/kWh reference.
/// That reading ranked driving styles backwards, could not tell a coast from a
/// regeneration, and spent 45 % of its time pinned to the top. Its colour was
/// also a pure function of its position — `aboveNeutral` was exactly
/// `fraction >= 0.5` — so the pill carried one bit twice. See
/// `lib/core/driving_smoothness.dart` for the measurements behind the change.
class SmoothnessLevel extends StatelessWidget {
  const SmoothnessLevel({
    required this.smoothness,
    this.width = 26,
    this.chase = const Duration(milliseconds: 320),
    super.key,
  });

  final DrivingSmoothness smoothness;
  final double width;

  /// How long the marks take to reach a new reading.
  ///
  /// The reading is republished five times a second onto a fixed grid, so a
  /// direct binding steps visibly. Chasing it removes the step without adding
  /// lag a driver would notice.
  final Duration chase;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final standing = smoothness.standing;
    final instant = smoothness.instant;
    return SizedBox(
      width: width,
      // The marks travel; they do not reappear elsewhere. When the reading goes
      // away entirely the track empties instead of the knob sliding to zero,
      // which would claim a measured harshness.
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: standing ?? 0.5, end: standing ?? 0.5),
        duration: chase,
        curve: Curves.linear,
        builder: (context, value, _) => TweenAnimationBuilder<double>(
          tween: Tween(begin: instant ?? 0.5, end: instant ?? 0.5),
          duration: chase,
          curve: Curves.linear,
          builder: (context, instantValue, _) => CustomPaint(
            painter: _SmoothnessPainter(
              fraction: standing == null ? null : value,
              instant: instant == null ? null : instantValue,
              fillColor: smoothness.aboveNeutral
                  ? AppThemeColors.of(context).energy.gain
                  : AppThemeColors.of(context).energy.draw,
              // The empty part of the track carries the same hue as the fill,
              // one step paler, so the pill reads as one meter rather than as a
              // coloured bar sitting in a grey slot.
              trackColor: smoothness.aboveNeutral
                  ? AppThemeColors.of(context).energy.gainSubtle
                  : AppThemeColors.of(context).energy.drawSubtle,
              neutralColor: colors.chartGrid,
              knobColor: colors.surface,
              // The tick has to read against the fill on one side of it and the
              // pale track on the other, so it takes the card's own ink rather
              // than either of them.
              instantColor: colors.ink,
            ),
          ),
        ),
      ),
    );
  }
}

class _EfficiencyLinePainter extends CustomPainter {
  const _EfficiencyLinePainter({
    required this.series,
    required this.ceiling,
    required this.neutral,
    required this.grid,
    required this.gainColor,
    required this.lossColor,
    required this.demandColor,
    required this.recoveredColor,
    required this.haloColor,
    required this.labelStyle,
    this.floorLabel,
    this.unitLabel,
  });

  final EfficiencySeries series;

  /// Bottom of the axis, in Wh/km. Readings past it clip.
  final double ceiling;

  /// Cost at which the line changes colour, in Wh/km.
  final double neutral;

  final Color grid;

  /// Cost line, on the better side of [neutral].
  final Color gainColor;

  /// Cost line, on the worse side.
  final Color lossColor;

  /// The demand line. Deliberately neutral: demand has no published
  /// expectation to be measured against, so colouring it would assert a
  /// judgement the car never made.
  final Color demandColor;

  /// Fill of the band between demand and cost — the energy braking gave back.
  ///
  /// Drawn at full strength on the cost edge (the net figure) and faded on
  /// the demand edge (the gross figure) — see [recoveredBandFloorColor] — so
  /// the eye reads the band as flowing *from* what was actually spent
  /// *toward* what would have been spent without regen, rather than as a
  /// flat wash that has to be labelled to be understood.
  final Color recoveredColor;

  /// Card background, used to open a gap in the grid where the line crosses it.
  final Color haloColor;

  final TextStyle labelStyle;
  final String? floorLabel;
  final String? unitLabel;

  /// Width reserved for the axis numerals at the left edge.
  static const _gutter = 34.0;

  /// Thickness of the cost line.
  ///
  /// Heavier than the guides by a wide margin. Ninety intervals across a narrow
  /// card put the points close together, and at a thin stroke the line reads as
  /// texture rather than as a trace the eye can follow from a driving seat.
  static const _stroke = 3.5;

  /// Thickness of the demand line. Under [_stroke], because demand is the
  /// context and cost is the reading.
  static const _demandStroke = 1.8;

  /// Thickness of the axis guides.
  static const _gridStroke = 2.0;

  /// Clearance the cost line keeps from the grid on each side.
  static const _halo = 2.5;

  /// How far above the zero line a net gain is drawn.
  ///
  /// The axis runs downward from zero, so an interval that gave back more than
  /// it took lands above the top of the scale. It has no cost per kilometre to
  /// plot, so it gets a fixed offset rather than a scaled one: the mark says
  /// *this stretch added range*, and inventing a height for it would imply a
  /// magnitude the maths never produced.
  static const _aboveZero = 14.0;

  @override
  void paint(Canvas canvas, Size size) {
    // Zero sits at the top and the axis counts downward, so that less energy
    // per kilometre is higher on the card. Wh/km is a "lower is better"
    // quantity; flipping the axis keeps "up is good" true for the driver, and
    // keeps the line agreeing with the pill beside it, which also fills upward
    // for a gain.
    //
    // The unit gets a row of its own above the gain strip, not a place on the
    // zero guide. It used to share that row, and on a long descent the whole
    // trace sits in the strip and goes straight through the text. The row is
    // measured rather than fixed, so it follows the system text scale.
    final plot = Rect.fromLTRB(
      _gutter,
      _unitRowHeight() + _aboveZero,
      size.width,
      // Room for half a stroke, so a run clipped at the ceiling keeps its full
      // thickness instead of being shaved by the bottom edge.
      size.height - _stroke / 2 - 2,
    );
    if (plot.width <= 0 || plot.height <= 0) return;

    _paintGuides(canvas, plot, size);
    _paintTrace(canvas, size, plot);
    // Last, so it stays legible over a run that the ceiling pinned into the
    // same corner.
    _paintFloorCaption(canvas, plot);
  }

  /// Height reserved above the gain strip for the axis unit, or zero when there
  /// is no unit to draw.
  double _unitRowHeight() {
    final unit = unitLabel;
    if (unit == null) return 0;
    return (TextPainter(
      text: TextSpan(text: unit, style: labelStyle),
      textDirection: TextDirection.ltr,
    )..layout()).height;
  }

  void _paintTrace(Canvas canvas, Size size, Rect plot) {
    if (series.points.isEmpty) return;

    final step = series.points.length > 1
        ? plot.width / (series.points.length - 1)
        : 0.0;

    // The divider in screen coordinates. Colour is decided here, by where the
    // stroke actually is, not by which reading a run started from: a run that
    // crosses the divider has to change colour at the crossing, and a rule
    // applied per reading cannot cut a curve in the middle.
    final neutralY = _yOf(neutral, plot);

    // One run per unbroken stretch. A point with no plottable cost ends the
    // current run, so the stroke stops rather than spanning what was not read.
    var cost = <Offset>[];
    var demand = <Offset>[];

    void flush() {
      if (cost.length >= 2) {
        // The band first, so both lines sit on top of it.
        if (demand.length == cost.length) {
          _paintRecoveredBand(canvas, cost, demand);

          canvas.drawPath(
            _through(demand),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = _demandStroke
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round
              ..color = demandColor,
          );
        }

        final path = _through(cost);
        // The grid is already down. Stroking the same path in the card colour
        // first, wider than the line, opens a gap in every guide the line
        // crosses. The result reads as the grid running behind the trace and
        // stopping short of it, which keeps a crossing legible instead of
        // letting a guide cut the data in half.
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = _stroke + _halo * 2
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..color = haloColor,
        );
        // Above the divider is the better side, because the axis descends.
        _band(canvas, size, path, top: 0, bottom: neutralY, color: gainColor);
        _band(
          canvas,
          size,
          path,
          top: neutralY,
          bottom: size.height,
          color: lossColor,
        );
      } else if (cost.length == 1) {
        canvas.drawCircle(
          cost.first,
          _stroke / 2 + _halo,
          Paint()..color = haloColor,
        );
        canvas.drawCircle(
          cost.first,
          _stroke / 2,
          Paint()..color = cost.first.dy <= neutralY ? gainColor : lossColor,
        );
      }
      cost = <Offset>[];
      demand = <Offset>[];
    }

    for (var index = 0; index < series.points.length; index++) {
      final point = series.points[index];
      final y = _costY(point, plot);
      if (y == null) {
        flush();
        continue;
      }
      final x = plot.left + index * step;
      cost.add(Offset(x, y));
      demand.add(Offset(x, _demandY(point, plot) ?? y));
    }
    flush();
  }

  /// Paints the band as a Gouraud-shaded strip: full-strength [recoveredColor]
  /// on every cost vertex, [recoveredBandFloorColor] of it on the demand
  /// vertex directly below. A flat fill can only answer with one colour, and
  /// the gap between the two lines is not constant — it opens on a stretch of
  /// hard regen and closes to nothing where none was given back. A single
  /// top-to-bottom gradient over the run's bounding box would shade by
  /// absolute height instead, so a column where the band is thin would still
  /// show whatever shade the box's other columns put at that height. Per-vertex
  /// colour follows each column's own span instead, which is what makes the
  /// fade always start at the cost line and always end at the demand line.
  ///
  /// The strip is built from straight segments between the plotted points
  /// rather than the smoothed curves [_through] draws for the strokes on top.
  /// At ninety points across a narrow card the deviation is under a pixel,
  /// and the strokes redraw both edges anyway, so the seam never shows.
  void _paintRecoveredBand(
    Canvas canvas,
    List<Offset> cost,
    List<Offset> demand,
  ) {
    final floor = recoveredBandFloorColor(recoveredColor);
    final positions = <Offset>[];
    final colors = <Color>[];
    for (var index = 0; index < cost.length; index++) {
      positions
        ..add(cost[index])
        ..add(demand[index]);
      colors
        ..add(recoveredColor)
        ..add(floor);
    }
    canvas.drawVertices(
      ui.Vertices(ui.VertexMode.triangleStrip, positions, colors: colors),
      BlendMode.srcOver,
      Paint(),
    );
  }

  /// Strokes [path] in [color], but only inside a horizontal band.
  ///
  /// The whole line is drawn twice, clipped above and below the divider. That
  /// is what makes the colour change land exactly on the crossing instead of at
  /// the nearest reading, and it needs no root-finding on the curve.
  void _band(
    Canvas canvas,
    Size size,
    Path path, {
    required double top,
    required double bottom,
    required Color color,
  }) {
    if (bottom <= top) return;
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, top, size.width, bottom));
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
    canvas.restore();
  }

  /// Screen position of a cost in Wh/km. Clipping here is display only; the
  /// value that reached the window average was never clamped.
  double _yOf(double whPerKm, Rect plot) =>
      plot.top + plot.height * (whPerKm / ceiling).clamp(0.0, 1.0);

  /// Where the cost line goes for [point], or null when it cannot be plotted.
  double? _costY(EfficiencyPoint point, Rect plot) {
    switch (point.state) {
      case EfficiencyState.unreported:
      case EfficiencyState.still:
        // Both break the line, for different reasons that arrive at the same
        // answer: one has no measurement and the other has a measurement with
        // no ratio in it. Neither may be joined across, because a segment drawn
        // through either would claim driving that did not happen. They are
        // listed apart so a future reading of the card can tell them apart
        // without changing the reducer.
        return null;
      case EfficiencyState.regenerating:
        // A net gain has no cost per kilometre. It sits in the strip above
        // zero, which is the only place on this axis that means "gave back".
        return plot.top - _aboveZero / 2;
      case EfficiencyState.idle:
        // Energy spent without moving. The ratio is unbounded rather than
        // missing, so it pins to the worst end of the axis — the same place
        // the previous chart put it, at the opposite end of the same scale.
        return plot.bottom;
      case EfficiencyState.consuming:
      case EfficiencyState.coasting:
        final value = point.netWhPerKm;
        return value == null ? null : _yOf(math.max(0, value), plot);
    }
  }

  /// Where the demand line goes, or null when it has no ratio either.
  double? _demandY(EfficiencyPoint point, Rect plot) {
    final value = point.drawnWhPerKm;
    return value == null ? null : _yOf(value, plot);
  }

  /// Smooths the run without letting a curve leave the data.
  ///
  /// Control points are horizontal only, so an interpolated segment can never
  /// rise above the higher of its two readings or dip below the lower one. A
  /// free spline would overshoot, and on this chart an overshoot is a claim
  /// about efficiency the car never reported.
  Path _through(List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var index = 1; index < points.length; index++) {
      final from = points[index - 1];
      final to = points[index];
      final midX = (from.dx + to.dx) / 2;
      path.cubicTo(midX, from.dy, midX, to.dy, to.dx, to.dy);
    }
    return path;
  }

  void _paintGuides(Canvas canvas, Rect plot, Size size) {
    final paint = Paint()
      ..color = grid
      ..strokeWidth = _gridStroke;
    for (final level in [0.0, ceiling / 3, ceiling * 2 / 3, ceiling]) {
      final y = _yOf(level, plot);
      canvas.drawLine(Offset(plot.left, y), Offset(size.width, y), paint);
      _label(
        canvas,
        // The bottom guide is the clip line, so it is labelled as a ceiling of
        // a range rather than as a value the reading reached.
        level == ceiling ? '${_trim(ceiling)}+' : _trim(level),
        Offset(0, y - labelStyle.fontSize! / 2 - 2),
        // The last guide sits close enough to the bottom edge that a centred
        // numeral hangs off it, and `CustomPaint` does not clip. It gives up
        // being centred rather than being cut in half.
        within: size.height,
      );
    }
    // The colour divider, drawn as a dashed guide.
    //
    // Without it the reader has to infer where green becomes grey from the
    // colours themselves, and a divider that sits off the end of the axis —
    // a reference past the ceiling — looks like a chart that simply refuses
    // to go green.
    if (neutral > 0 && neutral < ceiling) {
      final y = _yOf(neutral, plot);
      const dash = 5.0;
      for (var x = plot.left; x < size.width; x += dash * 2) {
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(x + dash, size.width), y),
          paint,
        );
      }
    }

    // The unit sits at the trailing edge of its own row, clear of the strip a
    // net gain is drawn in.
    final unit = unitLabel;
    if (unit != null) {
      _label(canvas, unit, const Offset(0, 0), alignRight: size.width);
    }
  }

  /// The clip-line caption, drawn after the trace.
  ///
  /// It is anchored by its bottom edge and sits *above* the line it names. A
  /// top-anchored caption on `plot.bottom` grew downward off the canvas, and
  /// `CustomPaint` does not clip, so most of the text left the chart.
  ///
  /// The bottom-left corner is reachable by the data — an `idle` interval and a
  /// clipped one both pin to `plot.bottom` — so the caption takes a patch of
  /// card colour with it. That corner holds the oldest readings, and a run
  /// already pinned against the scale carries no magnitude a caption can hide.
  void _paintFloorCaption(Canvas canvas, Rect plot) {
    final floor = floorLabel;
    if (floor == null) return;
    _label(
      canvas,
      floor,
      Offset(_gutter + 8, plot.bottom - _stroke / 2 - 1),
      alignBottom: true,
      background: haloColor,
    );
  }

  void _label(
    Canvas canvas,
    String text,
    Offset at, {
    double? alignRight,
    bool alignBottom = false,
    Color? background,
    double? within,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    var top = alignBottom ? at.dy - painter.height : at.dy;
    if (within != null) {
      top = top.clamp(0.0, math.max(0.0, within - painter.height));
    }
    final origin = Offset(
      alignRight == null ? at.dx : alignRight - painter.width,
      top,
    );
    if (background != null) {
      canvas.drawRect(
        Rect.fromLTWH(
          origin.dx - 3,
          origin.dy,
          painter.width + 6,
          painter.height,
        ),
        Paint()..color = background,
      );
    }
    painter.paint(canvas, origin);
  }

  static String _trim(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);

  @override
  bool shouldRepaint(_EfficiencyLinePainter old) =>
      old.series != series ||
      old.ceiling != ceiling ||
      old.neutral != neutral ||
      old.grid != grid ||
      // The style carries the system text scale, and the plot geometry is
      // measured from it. A card that kept the old one would keep the old
      // layout until something else forced a repaint.
      old.labelStyle != labelStyle ||
      old.gainColor != gainColor ||
      old.lossColor != lossColor ||
      old.demandColor != demandColor ||
      old.recoveredColor != recoveredColor ||
      old.haloColor != haloColor ||
      old.floorLabel != floorLabel ||
      old.unitLabel != unitLabel;
}

class _SmoothnessPainter extends CustomPainter {
  const _SmoothnessPainter({
    required this.fraction,
    required this.instant,
    required this.fillColor,
    required this.trackColor,
    required this.neutralColor,
    required this.knobColor,
    required this.instantColor,
  });

  /// Null when there is no reading to place a knob at.
  final double? fraction;

  /// Null when the short window has no reading. The tick is then not drawn.
  final double? instant;

  final Color fillColor;
  final Color trackColor;
  final Color neutralColor;
  final Color knobColor;
  final Color instantColor;

  /// Thickness of the instant tick.
  static const _tickStroke = 4.5;

  /// The knob's clearance from either end of the pill.
  static const _knobInset = 5.0;

  /// Track the fill leaves visible around the knob.
  ///
  /// The fill does not stop at the knob's centre with a flat edge. It runs past
  /// the knob and ends in a round cap of its own, so the reading's end wraps
  /// the knob with this much track showing between the two — the same shape
  /// `LimitSlider` gives its charge fill.
  static const _knobMargin = 3.0;

  @override
  void paint(Canvas canvas, Size size) {
    final track = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(size.width / 2),
    );
    canvas.drawRRect(track, Paint()..color = trackColor);

    final value = fraction;
    if (value == null) {
      _paintNeutral(canvas, size);
      return;
    }

    // The knob first, because the fill is drawn around it: its end cap is
    // placed from the knob's centre, not from the raw reading.
    final knobRadius = size.width / 2 - _knobInset;
    final centerY = (size.height * (1 - value)).clamp(
      knobRadius + _knobInset,
      size.height - knobRadius - _knobInset,
    );

    canvas.save();
    canvas.clipRRect(track);
    // The fill's own round end, at the pill's radius, centred on the knob. It
    // therefore covers the knob and leaves [_knobMargin] of colour around it,
    // instead of ending flat across the knob's middle.
    final capRadius = size.width / 2;
    final fillTop = centerY - knobRadius - _knobMargin;
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTRB(0, fillTop, size.width, size.height),
        topLeft: Radius.circular(capRadius),
        topRight: Radius.circular(capRadius),
      ),
      Paint()..color = fillColor,
    );
    canvas.restore();
    // The neutral line is drawn over the fill, so the reading can always be
    // read as above or below it without comparing against a remembered
    // position.
    _paintNeutral(canvas, size);

    // The tick goes under the knob, so that when the two readings agree the
    // knob covers the tick instead of the tick cutting the knob in half. The
    // pair is only worth reading when they differ.
    _paintInstant(canvas, size, track);

    // The knob stays inside the pill at both ends, the way LimitSlider's does,
    // so a reading at the ceiling does not look like it left the control.
    canvas.drawCircle(
      Offset(size.width / 2, centerY),
      knobRadius,
      Paint()..color = knobColor,
    );
  }

  /// The fast mark: the same reading over five seconds instead of thirty.
  void _paintInstant(Canvas canvas, Size size, RRect track) {
    final value = instant;
    if (value == null) return;
    // Clipped to the pill for the same reason the knob is clamped: a reading at
    // either end must stay part of the control.
    canvas.save();
    canvas.clipRRect(track);
    final y = (size.height * (1 - value)).clamp(
      _tickStroke / 2,
      size.height - _tickStroke / 2,
    );
    // A rectangle across the full width, cut by the pill's own edges. A bar
    // with round ends would read as a second knob. The ink carries itself over
    // both the fill and the pale track, so it needs no rim under it.
    canvas.drawRect(
      Rect.fromCenter(
        center: Offset(size.width / 2, y),
        width: size.width,
        height: _tickStroke,
      ),
      Paint()..color = instantColor,
    );
    canvas.restore();
  }

  /// The midpoint mark: driving at exactly the reference ramp.
  void _paintNeutral(Canvas canvas, Size size) {
    final y = size.height / 2;
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..color = neutralColor
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_SmoothnessPainter old) =>
      old.fraction != fraction ||
      old.instant != instant ||
      old.fillColor != fillColor ||
      old.trackColor != trackColor ||
      old.neutralColor != neutralColor ||
      old.knobColor != knobColor ||
      old.instantColor != instantColor;
}

/// Rounds a window average for display.
///
/// Two decimals below ten, one above: `3.11` is the mock's precision, and a
/// value that reaches double digits does not need the same resolution to be
/// read at a glance.
String formatEfficiency(double? kmPerKwh) {
  if (kmPerKwh == null) return '--';
  final value = math.max(0.0, kmPerKwh);
  return value < 10 ? value.toStringAsFixed(2) : value.toStringAsFixed(1);
}

/// [color] faded to [EfficiencyChart.recoveredBandFloorAlpha] of its own
/// alpha — the recovered-energy band's colour at the demand edge.
///
/// A top-level function rather than logic inlined at the `drawVertices` call,
/// because `Vertices` does not expose its colours back out once built: the
/// fade has to be checked here, before it reaches the canvas, or it cannot be
/// checked at all.
Color recoveredBandFloorColor(Color color) =>
    color.withValues(alpha: color.a * EfficiencyChart.recoveredBandFloorAlpha);
