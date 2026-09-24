import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:telemetry_core/telemetry_core.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import 'app_card.dart';
import 'metric_value.dart';

/// A strip of the compass dial, running under a fixed centre bar.
///
/// The tape moves and the bar does not. That is the opposite of a needle
/// sweeping a fixed dial, and it is the right way round for a car: the reader's
/// question is "which way am I pointed", the answer sits always in the same
/// place, and the dial slides behind it.
///
/// This widget draws a direction. It does not decide whether there is one to
/// draw — [CompassTracker] does that, and [state] is its answer.
class CompassTape extends StatefulWidget {
  const CompassTape({
    required this.bearingDeg,
    required this.cardinalLabels,
    this.state = CompassState.live,
    this.animate = true,
    super.key,
  });

  /// The course to centre under the bar, or null when there is none.
  final double? bearingDeg;

  /// The eight labels, starting at north and running clockwise: N, NE, E, SE,
  /// S, SW, W, NW. Localized by the caller — this component holds no text of
  /// its own.
  final List<String> cardinalLabels;

  /// What the reading is. [CompassState.held] draws the whole tape muted,
  /// because a remembered course must not look like a measured one.
  final CompassState state;

  final bool animate;

  @override
  State<CompassTape> createState() => _CompassTapeState();
}

class _CompassTapeState extends State<CompassTape>
    with SingleTickerProviderStateMixin {
  final CompassNeedle _needle = CompassNeedle();
  Ticker? _ticker;
  Duration _lastTick = Duration.zero;

  @override
  void initState() {
    super.initState();
    final start = widget.bearingDeg;
    if (start != null) _needle.snapTo(start);
  }

  @override
  void didUpdateWidget(CompassTape old) {
    super.didUpdateWidget(old);
    final target = widget.bearingDeg;
    if (target == null) {
      _stop();
      return;
    }
    // A course arriving after there was none starts where it is rather than
    // swinging in from whatever the needle last held: the two are unrelated
    // readings, and animating between them would draw a turn that never
    // happened.
    if (old.bearingDeg == null || !_animating) {
      _needle.snapTo(target);
      setState(() {});
      return;
    }
    _needle.target = target;
    _start();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  bool get _animating =>
      widget.animate && !MediaQuery.of(context).disableAnimations;

  void _start() {
    if (_ticker?.isActive ?? false) return;
    _lastTick = Duration.zero;
    (_ticker ??= createTicker(_onTick)).start();
  }

  void _stop() {
    if (_ticker?.isActive ?? false) _ticker!.stop();
  }

  void _onTick(Duration elapsed) {
    final dt = _lastTick == Duration.zero
        ? 1 / 60
        : (elapsed - _lastTick).inMicroseconds / Duration.microsecondsPerSecond;
    _lastTick = elapsed;
    final moving = _needle.step(dt);
    setState(() {});
    if (!moving) _stop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final target = widget.bearingDeg;
    // Without animation the needle is simply the reading. It is read here
    // rather than held, so a rebuild from a theme change cannot leave the tape
    // pointing at an older course.
    final angle = target == null ? null : (_animating ? _needle.angle : target);
    // A maximum, not a fixed height. The tape is a painter and reads correctly
    // at any height, so in a short card it is the part that gives way — before
    // the letters or the numeral, which cannot be shrunk without becoming
    // harder to read at exactly the moment they are glanced at.
    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxHeight: AppSizes.compassTapeHeight,
        minHeight: AppSizes.compassTapeMinHeight,
      ),
      child: CustomPaint(
        size: Size.infinite,
        painter: _CompassTapePainter(
          bearingDeg: angle,
          cardinalLabels: widget.cardinalLabels,
          state: widget.state,
          colors: colors,
          textDirection: Directionality.of(context),
        ),
      ),
    );
  }
}

/// The needle's motion: a chase, built as a critically damped spring.
///
/// It was underdamped at first, so that a fast turn overshot and swung back the
/// way a real needle in fluid does. On the car that was wrong, and the reason
/// is the clock rather than the physics: the course arrives once a second, so
/// every reading is a step, and an underdamped needle answered each step with a
/// swing. The card was never still. A needle that rings once per reading is
/// reporting the update rate, not the road.
///
/// So the damping is critical — the needle chases the course and stops on it,
/// at any turn rate, and one arrival is finished before the next reading lands.
/// The simulation is kept because it is what makes the chase indifferent to the
/// size of the step: a curve applies the same shape to a 5 degree correction
/// and a 180 degree spin.
class CompassNeedle {
  /// Spring constant, in inverse seconds squared. Sets how hard the needle is
  /// pulled to the course, and so how much of the second between readings it
  /// spends moving: a 90 degree step lands in about 0.8 s at this value, which
  /// is motion the eye follows and an arrival that is over before the next
  /// course comes in.
  static const stiffness = 100.0;

  /// Damping ratio. Below 1 the needle overshoots; at 1 it never does.
  ///
  /// Exactly 1. See the class comment: the overshoot was asked for and then
  /// measured against a once-a-second reading, where it turned every step into
  /// a swing.
  static const dampingRatio = 1.0;

  /// Below these the needle has arrived, and the ticker can stop. Degrees, and
  /// degrees per second.
  ///
  /// A quarter of a degree is under a pixel on the tape. A critically damped
  /// approach has a long tail, so a tighter figure would hold the ticker open
  /// for half a second of motion that cannot be drawn.
  static const restAngle = 0.25;
  static const restVelocity = 1.0;

  /// The longest step the simulation integrates at once. A dropped frame must
  /// not be integrated as one large step, which an underdamped spring turns
  /// into a wild swing instead of the motion the reader missed.
  static const maxStep = 1 / 60;

  /// Where the needle points, in degrees, folded into one turn.
  double get angle => _angle;
  double _angle = 0;

  /// Degrees per second. Positive is clockwise.
  double get velocity => _velocity;
  double _velocity = 0;

  /// The course the needle is pulled towards.
  double target = 0;

  /// Places the needle with no motion. Used when a reading is not the
  /// continuation of the one before it.
  void snapTo(double bearing) {
    _angle = bearing;
    target = bearing;
    _velocity = 0;
  }

  /// Advances the simulation by [seconds]. Returns false once the needle has
  /// come to rest, which is what lets the caller stop its ticker.
  bool step(double seconds) {
    var remaining = seconds.clamp(0.0, 1.0);
    final damping = 2 * dampingRatio * math.sqrt(stiffness);
    while (remaining > 0) {
      final dt = remaining < maxStep ? remaining : maxStep;
      remaining -= dt;
      // The error is the short way round: a needle at 359 pulled to 1 turns two
      // degrees clockwise, not 358 the other way.
      final error = compassDelta(_angle, target);
      _velocity += (stiffness * error - damping * _velocity) * dt;
      _angle = compassNormalize(_angle + _velocity * dt);
    }
    if (compassDelta(_angle, target).abs() < restAngle &&
        _velocity.abs() < restVelocity) {
      _angle = target;
      _velocity = 0;
      return false;
    }
    return true;
  }
}

class _CompassTapePainter extends CustomPainter {
  _CompassTapePainter({
    required this.bearingDeg,
    required this.cardinalLabels,
    required this.state,
    required this.colors,
    required this.textDirection,
  });

  /// Ticks every fifteen degrees, labels every forty-five.
  ///
  /// Two ticks between one letter and the next. At five degrees the card
  /// carried seventeen of them and the letters had to compete with a grid for
  /// the reader's eye; the tick is a subdivision of the letters, so there are
  /// as few as still divide the gap.
  static const _tickStepDeg = 15.0;
  static const _labelStepDeg = 45.0;

  /// How far the fade at each end reaches, as a share of the width. The tape
  /// has no ends — it is a circle — so a hard edge would read as one.
  static const _fadeShare = 0.16;

  final double? bearingDeg;
  final List<String> cardinalLabels;
  final CompassState state;
  final AppThemeColors colors;
  final TextDirection textDirection;

  bool get _muted => state != CompassState.live;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final centreX = size.width / 2;
    final centreY = size.height / 2;
    // The bar keeps clear of the top and bottom edges, so a squeezed tape
    // shortens it rather than letting it run edge to edge and read as a rule
    // across the card.
    final barHeight = size.height - AppSpacing.x4 < AppSizes.compassMarkerHeight
        ? size.height - AppSpacing.x4
        : AppSizes.compassMarkerHeight;
    final barRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(centreX, centreY),
        width: AppSizes.compassMarker,
        height: barHeight,
      ),
      const Radius.circular(AppSizes.compassMarker / 2),
    );

    // 1. The dial, in its own colours, faded at both ends.
    canvas.saveLayer(Offset.zero & size, Paint());
    _paintDial(canvas, size, inverted: false);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: const [
            AppColors.transparent,
            AppColors.ink,
            AppColors.ink,
            AppColors.transparent,
          ],
          stops: const [0.0, _fadeShare, 1 - _fadeShare, 1.0],
        ).createShader(Offset.zero & size),
    );
    canvas.restore();

    // 2. The bar, over the dial. It is where the reading is taken, so it is
    // outside the fade and is the one accent on the card.
    canvas.drawRRect(
      barRect,
      Paint()..color = _muted ? colors.inkSubtle : colors.energy.draw,
    );

    // 3. The dial again, clipped to the bar and drawn in the opposite ink. A
    // letter crossing the bar would otherwise be dark on amber and unreadable
    // for the moment it matters most — it is the letter being read.
    canvas.save();
    canvas.clipRRect(barRect);
    _paintDial(canvas, size, inverted: true);
    canvas.restore();
  }

  /// Draws the ticks and the letters once.
  ///
  /// [inverted] swaps the ink for the surface colour, which is the opposite in
  /// either theme: near-black on white becomes white, and light on a dark card
  /// becomes dark.
  void _paintDial(Canvas canvas, Size size, {required bool inverted}) {
    final bearing = bearingDeg;
    if (bearing == null) return;
    final pxPerDeg = size.width / AppSizes.compassTapeSpanDeg;
    final centreX = size.width / 2;
    final centreY = size.height / 2;

    final tickColor = inverted
        ? colors.surface
        : (_muted ? colors.inkSubtle : colors.inkMuted);
    final labelColor = inverted
        ? colors.surface
        : (_muted ? colors.inkSubtle : colors.ink);
    final tickPaint = Paint()
      ..color = tickColor
      ..strokeWidth = AppSizes.compassTick
      ..strokeCap = StrokeCap.round;

    // Half a span each side, plus a step of margin so an element entering the
    // fade is already drawn rather than appearing inside it.
    final halfSpan = AppSizes.compassTapeSpanDeg / 2 + _labelStepDeg;
    final first = ((bearing - halfSpan) / _tickStepDeg).ceil() * _tickStepDeg;
    for (var deg = first; deg <= bearing + halfSpan; deg += _tickStepDeg) {
      final x = centreX + (deg - bearing) * pxPerDeg;
      if ((deg % _labelStepDeg).abs() < 0.001) {
        _paintLabel(canvas, deg, x, centreY, labelColor);
        continue;
      }
      canvas.drawLine(
        Offset(x, centreY - AppSizes.compassTickLength / 2),
        Offset(x, centreY + AppSizes.compassTickLength / 2),
        tickPaint,
      );
    }
  }

  void _paintLabel(
    Canvas canvas,
    double deg,
    double x,
    double centreY,
    Color color,
  ) {
    if (cardinalLabels.length != compassCardinalCount) return;
    final painter = TextPainter(
      text: TextSpan(
        text: cardinalLabels[compassIndexOf(deg)],
        style: AppText.compassCardinal.copyWith(color: color),
      ),
      textDirection: textDirection,
    )..layout();
    painter.paint(
      canvas,
      Offset(x - painter.width / 2, centreY - painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(_CompassTapePainter old) =>
      old.bearingDeg != bearingDeg ||
      old.state != state ||
      old.colors != colors ||
      !identical(old.cardinalLabels, cardinalLabels);
}

/// The eight points of the dial: N, NE, E, SE, S, SW, W, NW.
const compassCardinalCount = 8;

/// Which of the eight cardinal labels sits at [deg]. North is 0 and the index
/// runs clockwise. The tape walks into negative degrees when the course is near
/// north, so the modulo is folded rather than left signed.
int compassIndexOf(double deg) {
  final index = (deg / 45.0).round() % compassCardinalCount;
  return index < 0 ? index + compassCardinalCount : index;
}

/// The compass card for the instant-readout strip.
class CompassCard extends StatelessWidget {
  const CompassCard({
    required this.label,
    required this.value,
    required this.bearingDeg,
    required this.cardinalLabels,
    this.state = CompassState.live,
    this.caption,
    this.animate = true,
    super.key,
  });

  /// Localized card title.
  final String label;

  /// Pre-formatted course (`75°`), or the `--` placeholder. Formatting belongs
  /// to the caller.
  final String value;

  final double? bearingDeg;
  final List<String> cardinalLabels;
  final CompassState state;

  /// Localized line under the title, naming why the course is held or absent.
  /// Null while the reading is live — a state that needs no explanation must
  /// not be given one.
  final String? caption;

  final bool animate;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return AppCard(
      title: label,
      subtitle: caption,
      // Centred rather than hugging the top: the card's home is a square in
      // the readout strip, so there is height to spare, and content pinned to
      // the top of a square reads as a card that failed to fill.
      //
      // A `Center` rather than a stretched column, because the height it is
      // given is not always bounded — in an intrinsic-height row it is, on a
      // page that scrolls it is not, and `Center` shrink-wraps in the second
      // case instead of asking for infinity.
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Both parts give way, in proportion, so the card fits a strip that
            // is a quarter of whatever screen it is on. A `LayoutBuilder` would
            // read the height and step the sizes, but it reports no intrinsic
            // dimensions, and the card sits in rows that measure themselves.
            Flexible(
              flex: 5,
              child: CompassTape(
                bearingDeg: bearingDeg,
                cardinalLabels: cardinalLabels,
                state: state,
                animate: animate,
              ),
            ),
            // Set apart from the tape, not tucked under it. They are two
            // readings of one course — the letters name it, the number measures
            // it — and at a small gap the numeral read as a caption on the
            // dial. The gap is the widest part that gives way, because it is
            // the only one that carries nothing.
            const Flexible(child: SizedBox(height: AppSpacing.x6)),
            // Under the tape and centred on it: the number is the same reading
            // the bar is pointing at, so it belongs on the bar's own axis rather
            // than in the header opposite the title. It scales down rather than
            // clipping — a course with its top sheared off is a misreading, not
            // a small one.
            Flexible(
              flex: 2,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: MetricValue(
                  value: value,
                  size: MetricSize.lg,
                  // A held course is a real reading of an earlier moment, so it
                  // is shown rather than hidden — muted, so it cannot be
                  // mistaken for a live one.
                  valueColor: state == CompassState.live
                      ? colors.ink
                      : colors.inkSubtle,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
