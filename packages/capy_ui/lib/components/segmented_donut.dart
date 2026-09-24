import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// One arc of a [SegmentedDonut].
///
/// [marker] is the glyph that sits outside the ring at the arc's midpoint —
/// the legend key repeated by `IconValueGrid` below the chart. It rides the
/// arc, so it slides along as the values animate.
@immutable
class DonutSegment {
  const DonutSegment({required this.value, required this.color, this.marker});

  /// Magnitude of this arc, in whatever unit the caller is plotting. Sweep is
  /// derived from it, so callers never compute angles.
  final double value;

  final Color color;

  /// Optional widget pinned outside the ring at this arc's midpoint.
  final Widget? marker;

  @override
  bool operator ==(Object other) =>
      other is DonutSegment &&
      other.value == value &&
      other.color == color &&
      other.marker == marker;

  @override
  int get hashCode => Object.hash(value, color, marker);
}

/// Concentric arc drawn inside a [SegmentedDonut]'s ring.
///
/// Carries a second reading of the same total rather than another slice of the
/// breakdown: regeneration measured against the energy the session drew. It is
/// deliberately thinner than the ring ([AppSizes.donutInnerStroke]) and shares
/// the ring's denominator and start angle, so its sweep reads directly as
/// "this share of what was spent came back".
@immutable
class DonutInnerArc {
  const DonutInnerArc({required this.value, required this.color});

  /// In the same unit as the surrounding [DonutSegment] values.
  final double value;

  final Color color;
}

/// Thick multi-segment ring with a value at its center.
///
/// Carries the breakdown for a charge or drive session: each [DonutSegment] is
/// a consumer or contributor, drawn as a tint of the session's series color
/// (see `DESIGN.md` — parts of one series share a hue, they do not get
/// different hues).
///
/// Segments are separated by a real angular gap ([AppSizes.donutSegmentGap])
/// rather than a contrasting stroke, which is what keeps same-hue arcs legible.
///
/// Changes animate implicitly: sweeps and colors tween from their previous
/// values, and the first build sweeps up from zero. Markers are positioned off
/// the *animated* geometry, so they travel with their arc instead of snapping.
/// Animation is skipped when the platform asks for reduced motion.
///
/// ```dart
/// SegmentedDonut(
///   segments: [
///     DonutSegment(value: 55.6, color: AppThemeColors.of(context).energy.draw,
///         marker: Icon(Icons.grid_view)),
///     DonutSegment(value: 3.4, color: AppThemeColors.of(context).energy.drawSoft),
///   ],
///   innerArc: DonutInnerArc(value: 12.2, color: AppThemeColors.of(context).energy.gain),
///   value: '60.6',
///   unit: loc.unitKwh,
///   delta: '+12.2 kWh',
/// )
/// ```
class SegmentedDonut extends StatefulWidget {
  const SegmentedDonut({
    required this.segments,
    this.innerArc,
    this.value,
    this.unit,
    this.delta,
    this.deltaColor,
    this.center,
    this.total,
    this.strokeWidth = AppSizes.donutStroke,
    this.innerStrokeWidth = AppSizes.donutInnerStroke,
    this.innerGap = AppSizes.donutInnerGap,
    this.gap = AppSizes.donutSegmentGap,
    this.startAngle = -math.pi / 2,
    this.showTrack = false,
    this.trackColor,
    this.capRadius = AppSizes.donutCapRadius,
    this.innerCapRadius = 0,
    this.taper = true,
    this.markerSize = AppSizes.iconLg,
    this.markerExtent,
    this.duration = AppMotion.slow,
    this.animate = true,
    this.semanticsLabel,
    super.key,
  });

  final List<DonutSegment> segments;

  /// Optional concentric arc inside the ring. Null draws the ring alone.
  final DonutInnerArc? innerArc;

  /// Pre-formatted center value. Formatting stays with the caller.
  final String? value;

  /// Localized unit, rendered under [value].
  final String? unit;

  /// Optional signed change under the unit (`+12.2 kWh`).
  final String? delta;

  /// Defaults to [AppText.delta]'s gain color; pass a loss color when the
  /// change is negative.
  final Color? deltaColor;

  /// Replaces the whole default center block. Takes precedence over [value],
  /// [unit] and [delta].
  final Widget? center;

  /// Denominator for the ring. When null the segments fill the full circle
  /// proportionally; when set, any shortfall is left empty (or drawn in
  /// [trackColor] if [showTrack]), which turns the ring into a meter.
  final double? total;

  final double strokeWidth;

  /// Stroke of [innerArc]. Ignored when there is no inner arc.
  final double innerStrokeWidth;

  /// Clear space between the ring's inner edge and [innerArc]'s outer edge.
  final double innerGap;

  /// Angular separation between adjacent arcs, in radians.
  final double gap;

  /// Where the first arc begins. Defaults to twelve o'clock.
  final double startAngle;

  /// Draws the unfilled remainder when [total] exceeds the segment sum. Off by
  /// default because a session breakdown always sums to its own total.
  final bool showTrack;

  final Color? trackColor;

  /// Corner radius applied to each end of an arc.
  ///
  /// `0` gives square ends. Anything between that and half [strokeWidth]
  /// softens the four corners of the arc while its end stays flat — which is
  /// what the reference dashboards show, and what `StrokeCap.round` cannot
  /// express, since its radius is always half the stroke. At exactly half
  /// [strokeWidth] the end becomes a full semicircle; values above are
  /// clamped there.
  ///
  /// The swept angle is compensated for the rounding either way, so [gap]
  /// stays the gap you see regardless of [strokeWidth] or this value.
  final double capRadius;

  /// Corner radius on the ends of [innerArc].
  ///
  /// Zero, and separate from [capRadius], because the inner arc is a different
  /// reading and must not be mistaken for one more slice of the ring. Square
  /// ends are what tell the two apart at a glance.
  final double innerCapRadius;

  /// Whether the gap between two arcs keeps one width at every radius.
  ///
  /// A gap held at a constant *angle* opens wider the further out it is drawn,
  /// which leaves the arc ends parallel and the ring reading as a cut cylinder.
  /// Held at a constant *width* the ends slant instead: each arc is a little
  /// wider at the ring's outer edge than at its inner one. [gap] still states
  /// the gap on the stroke centerline, so the mean separation is unchanged
  /// either way.
  ///
  /// Set false when the exact swept angle at both radii must be identical —
  /// tests that read the emitted arcs, mainly.
  final bool taper;

  /// Layout box reserved for each marker, and the basis for the ring inset
  /// that keeps markers inside the widget's bounds.
  final double markerSize;

  /// Overrides the square [markerSize] box for a marker that is not an icon —
  /// a glyph with its reading beside or beneath it, say.
  ///
  /// The ring insets by the **larger** of the two dimensions: a marker at three
  /// o'clock needs its width in clearance and one at twelve needs its height,
  /// and the ring has no way to reserve different amounts per direction.
  final Size? markerExtent;

  final Duration duration;

  /// Set false to render the final state immediately (tests, static exports).
  final bool animate;

  /// Localized description for screen readers. The ring is decorative without
  /// it, since the same numbers appear in the adjacent legend.
  final String? semanticsLabel;

  @override
  State<SegmentedDonut> createState() => _SegmentedDonutState();
}

class _SegmentedDonutState extends State<SegmentedDonut>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  late List<DonutSegment> _from;

  /// Inner arc to animate from. Held separately from [_from] because it is not
  /// part of the ring's series and must not shift the segments' angles.
  DonutInnerArc? _fromInner;

  /// Denominator to animate from. Tracked apart from the segment values
  /// because they must not move together: if the ring were always divided by
  /// its own animated sum, a growing set of segments would render a full ring
  /// on the first frame and no sweep would ever be visible.
  late double _fromDenominator;

  /// Whether the ring is still performing its introductory sweep.
  ///
  /// Only that first one fades the center in. A live caller updates this widget
  /// every second, and re-running the fade on each update reads as the value
  /// blinking rather than as the ring settling.
  bool _firstSweep = true;

  double get _denominator => widget.total ?? _sumOf(widget.segments);

  static double _sumOf(List<DonutSegment> segments) =>
      segments.fold<double>(0, (acc, s) => acc + s.value);

  @override
  void initState() {
    super.initState();
    // Sweep up from nothing on first paint, against the final denominator.
    _from = _zeroed(widget.segments);
    _fromInner = _zeroedArc(widget.innerArc);
    _fromDenominator = _denominator;
    _controller.value = 1;
    if (widget.animate) _controller.forward(from: 0);
  }

  @override
  void didUpdateWidget(SegmentedDonut oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.duration;
    if (!_sameGeometry(oldWidget.segments, widget.segments) ||
        !_sameArc(oldWidget.innerArc, widget.innerArc) ||
        oldWidget.total != widget.total) {
      // Restart from wherever the previous animation had reached, so rapid
      // updates from live telemetry stay continuous instead of jumping back.
      _from = _lerp(_from, oldWidget.segments, _controller.value);
      _fromInner = _lerpArc(_fromInner, oldWidget.innerArc, _controller.value);
      _fromDenominator = lerpDouble(
        _fromDenominator,
        oldWidget.total ?? _sumOf(oldWidget.segments),
        _controller.value,
      )!;
      _firstSweep = false;
      if (widget.animate) {
        _controller.forward(from: 0);
      } else {
        _from = widget.segments;
        _fromInner = widget.innerArc;
        _fromDenominator = _denominator;
        _controller.value = 1;
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static List<DonutSegment> _zeroed(List<DonutSegment> segments) => [
    for (final s in segments)
      DonutSegment(value: 0, color: s.color, marker: s.marker),
  ];

  static DonutInnerArc? _zeroedArc(DonutInnerArc? arc) =>
      arc == null ? null : DonutInnerArc(value: 0, color: arc.color);

  /// Whether two inner arcs describe the same geometry to animate. An arc
  /// appearing or disappearing counts as a change, so it sweeps rather than
  /// popping.
  static bool _sameArc(DonutInnerArc? a, DonutInnerArc? b) {
    if (a == null || b == null) return a == null && b == null;
    return a.value == b.value && a.color == b.color;
  }

  /// Tweens through zero when an arc is added or removed, so the sweep grows
  /// out of — or retreats into — the ring's start angle.
  static DonutInnerArc? _lerpArc(DonutInnerArc? a, DonutInnerArc? b, double t) {
    if (t >= 1) return b;
    if (t <= 0) return a;
    if (a == null && b == null) return null;
    final color = Color.lerp(a?.color ?? b!.color, b?.color ?? a!.color, t)!;
    return DonutInnerArc(
      value: lerpDouble(a?.value ?? 0, b?.value ?? 0, t)!,
      color: color,
    );
  }

  /// Whether two segment lists describe the same ring to animate.
  ///
  /// Only the animated properties count. [DonutSegment.marker] is deliberately
  /// excluded: it is a widget, so it compares by identity, and a caller that
  /// builds one inline (`Semantics(label: ..., child: Icon(...))`) produces a
  /// fresh instance on every rebuild. Including it restarted the sweep on each
  /// parent rebuild — with a live telemetry parent, that reads as a permanent
  /// flicker in the ring and its center value. Markers are positioned from the
  /// animated geometry, so a rebuilt marker needs no animation of its own.
  static bool _sameGeometry(List<DonutSegment> a, List<DonutSegment> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].value != b[i].value || a[i].color != b[i].color) return false;
    }
    return true;
  }

  /// Pads the shorter list so a changed segment count still tweens: a new arc
  /// grows from zero, a removed one shrinks into its neighbour's gap.
  static List<DonutSegment> _lerp(
    List<DonutSegment> a,
    List<DonutSegment> b,
    double t,
  ) {
    // Short-circuit the endpoints: the settled ring should hold the exact
    // token colors it was given, not lerp-reconstructed equivalents.
    if (t >= 1) return b;
    if (t <= 0) return a;
    final length = math.max(a.length, b.length);
    return [
      for (var i = 0; i < length; i++)
        () {
          final from = i < a.length ? a[i] : null;
          final to = i < b.length ? b[i] : null;
          final color = Color.lerp(
            from?.color ?? to!.color,
            to?.color ?? from!.color,
            t,
          )!;
          return DonutSegment(
            value: lerpDouble(from?.value ?? 0, to?.value ?? 0, t)!,
            color: color,
            marker: (to ?? from)!.marker,
          );
        }(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final animate = widget.animate && !reduceMotion;

    return Semantics(
      label: widget.semanticsLabel,
      container: widget.semanticsLabel != null,
      child: AspectRatio(
        aspectRatio: 1,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final side = math.min(constraints.maxWidth, constraints.maxHeight);
            return AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final t = animate ? _controller.value : 1.0;
                final segments = _lerp(_from, widget.segments, t);
                final innerArc = _lerpArc(_fromInner, widget.innerArc, t);
                final denominator = lerpDouble(
                  _fromDenominator,
                  _denominator,
                  t,
                )!;
                final geometry = _DonutGeometry(
                  side: side,
                  strokeWidth: widget.strokeWidth,
                  innerStrokeWidth: widget.innerStrokeWidth,
                  innerGap: widget.innerGap,
                  markerBand: _hasMarkers
                      ? math.max(_markerBox.width, _markerBox.height) +
                            AppSpacing.x2
                      : 0,
                );
                // The ring and its markers must be measured against the same
                // box. `AspectRatio` cannot square a tight constraint — a
                // parent that stretches this widget and gives it a fixed height
                // gets those dimensions straight back — so the square is
                // established here instead. Without it the painter centered the
                // ring on the full box while the markers were placed against
                // `side`, and the icons drifted off their arcs and onto the
                // ring by exactly half the difference.
                return Center(
                  child: SizedBox.square(
                    dimension: side,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _DonutPainter(
                              segments: segments,
                              innerArc: innerArc,
                              denominator: denominator,
                              geometry: geometry,
                              gap: widget.gap,
                              startAngle: widget.startAngle,
                              showTrack: widget.showTrack,
                              trackColor: widget.trackColor ?? colors.track,
                              capRadius: widget.capRadius,
                              innerCapRadius: widget.innerCapRadius,
                              taper: widget.taper,
                            ),
                          ),
                        ),
                        ..._markers(segments, denominator, geometry),
                        Positioned.fill(
                          child: Center(child: _centerBlock(geometry, t)),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  bool get _hasMarkers => widget.segments.any((s) => s.marker != null);

  Size get _markerBox => widget.markerExtent ?? Size.square(widget.markerSize);

  /// The center block, held inside the ring's hole.
  ///
  /// Without the bound the block is laid out against the whole box and simply
  /// centered, so a ring in a short card draws straight through its own
  /// headline — which is what a squeezed session card did. `BoxFit.scaleDown`
  /// leaves the type at its designed size whenever it fits and only shrinks it
  /// when the ring has closed in, so the common case is unchanged.
  Widget? _centerBlock(_DonutGeometry geometry, double t) {
    final child = _center(t);
    if (child == null) return null;
    return SizedBox.square(
      dimension: geometry.holeSquare,
      child: FittedBox(fit: BoxFit.scaleDown, child: child),
    );
  }

  Widget? _center(double t) {
    final child =
        widget.center ??
        (widget.value == null
            ? null
            : _DonutCenter(
                value: widget.value!,
                unit: widget.unit,
                delta: widget.delta,
                deltaColor: widget.deltaColor,
              ));
    if (child == null) return null;
    // The center resolves as the ring lands rather than competing with it —
    // once, on the way in. Every later update leaves it at full opacity: the
    // number is being read while the ring moves under it.
    if (!_firstSweep) return child;
    return Opacity(opacity: Curves.easeIn.transform(t), child: child);
  }

  List<Widget> _markers(
    List<DonutSegment> segments,
    double denominator,
    _DonutGeometry geometry,
  ) {
    if (!_hasMarkers || denominator <= 0) return const [];

    final markers = <Widget>[];
    var angle = widget.startAngle;
    for (final segment in segments) {
      final sweep = segment.value / denominator * 2 * math.pi;
      if (segment.marker != null && sweep > 0) {
        final mid = angle + sweep / 2;
        markers.add(
          Positioned(
            left:
                geometry.center +
                geometry.markerRadius * math.cos(mid) -
                _markerBox.width / 2,
            top:
                geometry.center +
                geometry.markerRadius * math.sin(mid) -
                _markerBox.height / 2,
            width: _markerBox.width,
            height: _markerBox.height,
            child: Center(child: segment.marker),
          ),
        );
      }
      angle += sweep;
    }
    return markers;
  }
}

/// Resolved ring measurements for a given box.
@immutable
class _DonutGeometry {
  const _DonutGeometry({
    required this.side,
    required this.strokeWidth,
    required this.markerBand,
    this.innerStrokeWidth = 0,
    this.innerGap = 0,
  });

  final double side;
  final double strokeWidth;
  final double innerStrokeWidth;
  final double innerGap;

  /// Ring space reserved outside the stroke for perimeter markers.
  final double markerBand;

  double get center => side / 2;

  double get outerRadius => math.max(0, side / 2 - markerBand);

  /// Centerline the stroke is drawn on.
  double get radius => math.max(0, outerRadius - strokeWidth / 2);

  /// Centerline of the inner arc, one gap in from the ring's inner edge.
  ///
  /// Clamped at zero so a box too small to hold both rings drops the inner arc
  /// rather than drawing it inside-out through the center.
  double get innerRadius =>
      math.max(0, radius - strokeWidth / 2 - innerGap - innerStrokeWidth / 2);

  double get markerRadius => outerRadius + markerBand / 2;

  /// Free radius at the middle, inside everything the ring draws.
  ///
  /// The inner arc is subtracted whether or not one is shown: the center block
  /// must not change size when a session happens to have regenerated nothing,
  /// or the same card would print its headline at two sizes.
  double get holeRadius =>
      math.max(0, innerRadius - innerStrokeWidth / 2 - innerGap);

  /// The largest square that fits in [holeRadius] — a circle of radius `r`
  /// inscribes a square of side `r * sqrt(2)`.
  double get holeSquare => holeRadius * math.sqrt2;
}

class _DonutPainter extends CustomPainter {
  const _DonutPainter({
    required this.segments,
    required this.innerArc,
    required this.denominator,
    required this.geometry,
    required this.gap,
    required this.startAngle,
    required this.showTrack,
    required this.trackColor,
    required this.capRadius,
    required this.innerCapRadius,
    required this.taper,
  });

  final List<DonutSegment> segments;
  final DonutInnerArc? innerArc;

  /// Value that maps to a full turn. Already resolved and animated by the
  /// widget, so the painter never has to decide between `total` and the sum.
  final double denominator;

  final _DonutGeometry geometry;
  final double gap;
  final double startAngle;
  final bool showTrack;
  final Color trackColor;
  final double capRadius;
  final double innerCapRadius;
  final bool taper;

  /// Half the stroke is the largest rounding an arc end can take; past that
  /// the corners meet and the end is a semicircle.
  static double _capFor(double corner, double strokeWidth) =>
      math.min(corner, strokeWidth / 2);

  /// Sweep shortfall still treated as a closed ring. A denominator built from
  /// summed doubles rarely divides back to exactly `2π`, and a sub-milliradian
  /// wedge is a seam artifact, not a gap the caller asked for.
  static const _fullTurnEpsilon = 1e-6;

  @override
  void paint(Canvas canvas, Size size) {
    if (geometry.radius <= 0 || denominator <= 0) return;

    final sum = segments.fold<double>(0, (acc, s) => acc + s.value);
    final center = Offset(size.width / 2, size.height / 2);

    // A gap is only meaningful between two arcs; a lone full ring keeps its
    // ends closed.
    final drawnCount = segments.where((s) => s.value > 0).length;
    final effectiveGap = drawnCount > 1 ? gap : 0.0;

    // The gap the arc ends are cut against, as a width rather than an angle.
    // Taken on the centerline, where `gap` is defined, so the two forms agree
    // there and differ only in how the cut slants across the stroke.
    final gapWidth = taper ? effectiveGap * geometry.radius : 0.0;

    void draw(double start, double extent, Color color) {
      if (extent <= 0) return;
      _drawSegment(
        canvas,
        center,
        start,
        extent,
        color,
        geometry.radius,
        geometry.strokeWidth,
        corner: capRadius,
        gapWidth: gapWidth,
      );
    }

    // The track is the ring the segments rest on, not another arc in the
    // series, so it is one continuous circle drawn underneath — no gap, no cap
    // rounding. Filling only the shortfall would give the empty remainder its
    // own rounded ends and its own gap, which reads as a second gray category
    // instead of the unfilled part of one ring.
    if (showTrack && sum < denominator) {
      _drawRing(
        canvas,
        center,
        startAngle,
        2 * math.pi,
        trackColor,
        geometry.radius,
        geometry.strokeWidth,
      );
    }

    var angle = startAngle;
    for (final segment in segments) {
      final sweep = segment.value / denominator * 2 * math.pi;
      draw(angle + effectiveGap / 2, sweep - effectiveGap, segment.color);
      angle += sweep;
    }

    // The inner arc shares the ring's denominator and start angle, so its
    // sweep is directly comparable to the segments above it. It takes no
    // segment gap: it is a lone arc, and a gap only separates neighbours.
    final arc = innerArc;
    if (arc != null && arc.value > 0 && geometry.innerRadius > 0) {
      _drawSegment(
        canvas,
        center,
        startAngle,
        math.min(arc.value / denominator * 2 * math.pi, 2 * math.pi),
        arc.color,
        geometry.innerRadius,
        geometry.innerStrokeWidth,
        corner: innerCapRadius,
      );
    }
  }

  /// Butt-capped arc with no cap compensation, for shapes that have no ends to
  /// round: the full background track and a segment that closes the circle.
  void _drawRing(
    Canvas canvas,
    Offset center,
    double start,
    double extent,
    Color color,
    double ringRadius,
    double strokeWidth,
  ) {
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: ringRadius),
      start,
      extent,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.butt
        ..color = color,
    );
  }

  void _drawSegment(
    Canvas canvas,
    Offset center,
    double start,
    double extent,
    Color color,
    double ringRadius,
    double strokeWidth, {
    required double corner,
    double gapWidth = 0,
  }) {
    final radius = _capFor(corner, strokeWidth);

    // A closed ring has no ends. Rounding is compensation for caps that push
    // past the arc, so applying it here would shorten a full turn by two cap
    // angles and leave a notch where the ends should have met.
    if (extent >= 2 * math.pi - _fullTurnEpsilon) {
      _drawRing(
        canvas,
        center,
        start,
        2 * math.pi,
        color,
        ringRadius,
        strokeWidth,
      );
      return;
    }

    // Square, radial ends: a plain butt-capped stroke is exactly the shape
    // wanted. A tapered end is not radial, so it cannot take this route.
    if (radius <= 0 && gapWidth <= 0) {
      _drawRing(canvas, center, start, extent, color, ringRadius, strokeWidth);
      return;
    }

    // Rounding pushes past the geometry it is applied to, so the swept angle
    // gives that back on both ends and the arc is nudged forward by the same
    // amount. Without it the rounding eats the neighbouring gap, and the size
    // of that gap would silently depend on the stroke width.
    final capAngle = radius / ringRadius;
    final inner = math.max(0.0, extent - 2 * capAngle);

    // Fully round: the corners have met, and a round stroke cap draws that
    // directly and more cheaply than a path. A semicircular end has no wall to
    // slant, so the taper drops out here rather than being ignored.
    if (radius >= strokeWidth / 2) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: ringRadius),
        start + capAngle,
        inner,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round
          ..color = color,
      );
      return;
    }

    // Partial rounding: draw the sector shrunk by the corner radius on all
    // four sides, then grow it back by stroking the same path with a round
    // join. Dilating a shape by `radius` is exactly the shape with its corners
    // rounded to `radius` — and for an annular sector the dilation lands back
    // on the original radii, so the ring keeps its thickness.
    //
    // A segment too small to host its own corners collapses to a zero-sweep
    // core, which this still renders as a rounded radial pill. That keeps a
    // tiny reading visible instead of dropping it.
    final path = _sectorPath(
      center: center,
      start: start,
      sweep: extent,
      ringRadius: ringRadius,
      innerRadius: ringRadius - strokeWidth / 2 + radius,
      outerRadius: ringRadius + strokeWidth / 2 - radius,
      corner: radius,
      gapWidth: gapWidth,
    );

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.fill
        ..color = color,
    );
    if (radius > 0) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = radius * 2
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..color = color,
      );
    }
  }

  /// Closed annular sector: out along the outer radius, back along the inner.
  ///
  /// [start] and [sweep] describe the arc on the stroke centerline, before any
  /// end is cut. Each radius is then shortened by two allowances:
  ///
  /// - [corner], the rounding the caller grows back by stroking this path. It
  ///   costs the same *distance* at every radius, so it costs a larger angle at
  ///   the inner one;
  /// - [gapWidth], the separation from the neighbouring arc, held as a width.
  ///   Measured on the centerline, so the inner radius gives up a little more
  ///   angle than the centerline and the outer a little less — which is the
  ///   slant. Zero leaves the ends radial.
  static Path _sectorPath({
    required Offset center,
    required double start,
    required double sweep,
    required double ringRadius,
    required double innerRadius,
    required double outerRadius,
    required double corner,
    required double gapWidth,
  }) {
    // Half of it, because the arc gives up an end to each of its neighbours.
    final half = gapWidth / 2;

    (double, double) endsAt(double radius) {
      if (radius <= 0) return (start + sweep / 2, 0);
      final cut = corner / radius + half * (1 / radius - 1 / ringRadius);
      return (start + cut, math.max(0, sweep - 2 * cut));
    }

    final (outerStart, outerSweep) = endsAt(outerRadius);
    final (innerStart, innerSweep) = endsAt(innerRadius);

    return Path()
      ..arcTo(
        Rect.fromCircle(center: center, radius: outerRadius),
        outerStart,
        outerSweep,
        true,
      )
      ..arcTo(
        Rect.fromCircle(center: center, radius: innerRadius),
        innerStart + innerSweep,
        -innerSweep,
        false,
      )
      ..close();
  }

  @override
  bool shouldRepaint(_DonutPainter old) =>
      // `old.segments != segments` compared two Lists by identity, so it was
      // always true and the ring repainted on every frame of every rebuild.
      // Markers are widgets in the Stack, not painted here, so the painted
      // state is exactly the arc geometry.
      !_SegmentedDonutState._sameGeometry(old.segments, segments) ||
      !_SegmentedDonutState._sameArc(old.innerArc, innerArc) ||
      old.denominator != denominator ||
      old.geometry.side != geometry.side ||
      old.geometry.strokeWidth != geometry.strokeWidth ||
      old.geometry.innerStrokeWidth != geometry.innerStrokeWidth ||
      old.geometry.innerGap != geometry.innerGap ||
      old.gap != gap ||
      old.startAngle != startAngle ||
      old.showTrack != showTrack ||
      old.trackColor != trackColor ||
      old.capRadius != capRadius ||
      old.innerCapRadius != innerCapRadius ||
      old.taper != taper;
}

/// Stacked value/unit/delta block at the ring's center.
///
/// Stacked rather than the inline `MetricValue` row, because the ring's
/// interior is taller than it is wide once the stroke is accounted for.
class _DonutCenter extends StatelessWidget {
  const _DonutCenter({
    required this.value,
    this.unit,
    this.delta,
    this.deltaColor,
  });

  final String value;
  final String? unit;
  final String? delta;
  final Color? deltaColor;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: AppText.metricLg),
        if (unit != null) ...[
          const SizedBox(height: AppSpacing.x1),
          Text(unit!, style: AppText.unitMd),
        ],
        if (delta != null) ...[
          const SizedBox(height: AppSpacing.x1),
          Text(
            delta!,
            style: deltaColor == null
                ? AppText.delta
                : AppText.delta.copyWith(color: deltaColor),
          ),
        ],
      ],
    );
  }
}
