import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import 'app_card.dart';
import 'metric_value.dart';

/// The vehicle drawing a [TiltGauge] stands on its ground line.
///
/// One gauge serves both tilt axes, and the axis is carried entirely by this
/// value: pitch is the side view, roll is the front view. Nothing else in the
/// component knows which reading it is showing.
///
/// [aspectRatio] must be the asset's own ratio. The gauge sizes the drawing
/// from the dial and would distort it otherwise.
///
/// Every view is drawn to the same **height**, and the width follows from the
/// ratio. This is the one scale that is true: the views are the same vehicle,
/// so its height is the same in all of them, while a side view is over twice
/// as long as a front view is wide. Sizing by width instead makes the front
/// view tower over the side view at the same nominal size, and the two tiles
/// then read as two different cars.
///
/// Assets are ink in the alpha channel over black RGB, produced by
/// `scripts/extract_line_art.py` and then `scripts/thicken_line_art.py` from
/// the masters in `art/`. The gauge tints them with the theme ink through
/// [BlendMode.srcIn], so the colour planes are never shown and the art follows
/// the theme instead of shipping a second dark-mode copy.
///
/// The line weight is chosen for the size the gauge draws at, not for the
/// master. A line thin enough to fall below one pixel does not thin out — it
/// goes translucent, because the line is alpha — and the vehicle then reads as
/// a grey ghost beside the solid ground line. Re-run the thickening script if
/// this component starts drawing at a very different size.
@immutable
class CarSilhouette {
  const CarSilhouette({
    required this.asset,
    required this.aspectRatio,
    required this.sourceWidth,
    required this.rotationSign,
    this.mirrored = false,
  });

  /// The side view: front of the car at the right edge, tyres on the bottom
  /// edge.
  ///
  /// The file itself faces left. It is drawn [mirrored], because a reader who
  /// takes the drawing to face the other way reads every angle backwards, and
  /// the project owner reported exactly that on the car: a climb looked like a
  /// descent. Nothing measured changed — only which end of the drawing is the
  /// nose.
  ///
  /// It carries pitch. A nose-up pitch is positive, and with the front at the
  /// right that must raise the **right** edge. On a y-down canvas a positive
  /// rotation is clockwise, and clockwise lowers the right edge — so the turn
  /// wanted here is counter-clockwise, and [rotationSign] is -1.
  ///
  /// Get that backwards and a climb is drawn as a descent. It happened twice on
  /// this component (2026-08-11), the second time because the mirror was added
  /// and the sign was inverted with it, when only one of the two flips was the
  /// fix. Reason it out from the drawing, not from the previous value.
  static const side = CarSilhouette(
    asset: 'assets/images/car_side.webp',
    aspectRatio: 2.4691,
    sourceWidth: 600,
    rotationSign: -1,
    mirrored: true,
  );

  /// The front view: the car seen head-on, tyres on the bottom edge.
  ///
  /// It carries roll. Positive roll is the vehicle's **right** side down, which
  /// is the body-frame convention, and a front view mirrors the vehicle — the
  /// right side of the car is at the left of the drawing. So a positive roll
  /// lowers the left of the drawing, which is a counter-clockwise turn and a
  /// [rotationSign] of -1.
  ///
  /// Read that mirror before you wire a source to it. A roll signal in the
  /// driver's own frame has the opposite sense on this drawing, and the sign
  /// belongs to whoever knows which frame the signal is in.
  static const front = CarSilhouette(
    asset: 'assets/images/car_front.webp',
    aspectRatio: 1.2780,
    sourceWidth: 400,
    rotationSign: -1,
  );

  /// Every view. The layout resolves one dial that suits all of them, so two
  /// tilt tiles side by side share a ground line of the same length.
  static const values = [side, front];

  final String asset;

  /// Width divided by height of [asset].
  final double aspectRatio;

  /// Pixel width of [asset]. The gauge decodes at the size it draws, and this
  /// is the ceiling for that: asking the codec for more than the file holds
  /// upscales during decode, which costs memory and returns nothing.
  final int sourceWidth;

  /// Which way a positive angle turns this drawing: -1 for a view whose
  /// positive direction is counter-clockwise on screen, +1 for clockwise.
  ///
  /// This belongs to the artwork, not to the caller. A drawing that faces the
  /// other way inverts the sense of every reading fed to it, and a screen has
  /// no way to know which way the file happens to face.
  final double rotationSign;

  /// Whether the file is drawn flipped left to right.
  ///
  /// This belongs to the artwork with [rotationSign], and the two must move
  /// together: a mirror turns the nose to the other end of the drawing, which
  /// reverses which way a positive angle must turn.
  final bool mirrored;

  /// Width of the drawing, in dial diameters.
  double get widthUnits => _carHeightUnits * aspectRatio;

  /// Vertical room the drawing needs above the pivot, in dial diameters, at
  /// the worst angle rather than at rest.
  ///
  /// The group turns about the middle of the ground line, so a corner of the
  /// drawing travels on a circle of that radius and the tallest the drawing
  /// ever stands is the distance from the pivot to its far top corner. Reserve
  /// only the resting height and a large angle swings the roof out of the box,
  /// where the gauge's own `ClipRect` cuts it off.
  double get envelopeUnits =>
      _carHeightUnits * math.sqrt(aspectRatio * aspectRatio / 4 + 1);
}

/// The turning group: the vehicle, its ground line and the disc. A test reads
/// the measured angle back from this widget's transform.
const Key tiltGroupKey = Key('tilt_gauge_group');

/// Fractions of the dial diameter. The gauge has no fixed size of its own: it
/// resolves one diameter from the box it is given and lays everything out
/// against that, so the drawing keeps its proportions at any card size.
/// Height of the vehicle, shared by every view. Widths follow from the aspect
/// ratio, so all views are drawn at one scale.
const double _carHeightUnits = 0.313;

/// The half-disc below the ground line. It is a semicircle about the pivot, so
/// it reaches exactly the dial radius downwards at any angle.
const double _discUnits = 0.5;

const double _dashGapUnits = 0.06;
const double _dashLengthUnits = 0.13;
const double _widthUnits = 1 + 2 * (_dashGapUnits + _dashLengthUnits);

/// Height of the whole gauge, in dial diameters.
///
/// The widest view sets it, so every view resolves the same dial from the same
/// box. A front view then carries some unused headroom, which costs nothing —
/// two tilt tiles beside each other with ground lines of different lengths
/// would read as two different instruments.
final double _heightUnits =
    CarSilhouette.values
        .map((silhouette) => silhouette.envelopeUnits)
        .reduce(math.max) +
    _discUnits;

/// A vehicle standing on a ground line that turns with the measured angle.
///
/// The car, the ground line and the half-disc under it are one group and turn
/// together. The two short dashes at the sides do not: they are the level
/// reference, and the whole reading is the angle between them and the line.
/// A gauge whose reference turned with the car would show nothing at all.
///
/// The angle is drawn as measured. It is not exaggerated for legibility, so a
/// 1° pitch looks very nearly level — which is what 1° is. The numeral beside
/// the dial (see [TiltCard]) is what carries a small reading.
///
/// A null [angleDeg] means the tilt is not known. The gauge then draws level in
/// the muted ink rather than showing a confident level car, and the caller
/// shows `--` for the value.
///
/// The gauge fills the box it is given. Inside a `Column` or any other
/// unbounded height it takes the height its own proportions ask for.
class TiltGauge extends StatelessWidget {
  const TiltGauge({
    required this.angleDeg,
    this.silhouette = CarSilhouette.side,
    this.animate = true,
    super.key,
  });

  /// Measured tilt in degrees, or null when the vehicle does not report it.
  final double? angleDeg;

  final CarSilhouette silhouette;

  /// Whether a new reading travels to its angle instead of jumping. Reduced
  /// motion turns it off regardless.
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final known = angleDeg != null;
    final ink = known ? colors.ink : colors.inkSubtle;
    final radians = (angleDeg ?? 0) * silhouette.rotationSign * math.pi / 180;
    final still = !animate || MediaQuery.disableAnimationsOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : _widthUnits * AppSizes.tiltFallbackDiameter;
        final height = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : width / _widthUnits * _heightUnits;
        final layout = _TiltLayout.resolve(Size(width, height), silhouette);

        return SizedBox(
          width: width,
          height: height,
          child: ClipRect(
            child: Stack(
              children: [
                _ReferenceDashes(layout: layout, color: colors.inkSubtle),
                if (still)
                  _Group(
                    layout: layout,
                    silhouette: silhouette,
                    radians: radians,
                    ink: ink,
                    disc: colors.control,
                  )
                else
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: radians),
                    duration: AppMotion.base,
                    curve: AppMotion.curve,
                    builder: (context, value, _) => _Group(
                      layout: layout,
                      silhouette: silhouette,
                      radians: value,
                      ink: ink,
                      disc: colors.control,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Everything that turns with the reading: the ground, the disc under it, and
/// the vehicle standing on it.
class _Group extends StatelessWidget {
  const _Group({
    required this.layout,
    required this.silhouette,
    required this.radians,
    required this.ink,
    required this.disc,
  });

  final _TiltLayout layout;
  final CarSilhouette silhouette;
  final double radians;
  final Color ink;
  final Color disc;

  @override
  Widget build(BuildContext context) {
    final pivot = layout.pivot;
    final radius = layout.radius;
    // Decode at the size the art is actually drawn, but never above the file's
    // own width.
    final decodeWidth = math.min(
      (layout.carSize.width * MediaQuery.devicePixelRatioOf(context)).round(),
      silhouette.sourceWidth,
    );

    return Transform.rotate(
      // Named, because the drawing now sits under a second [Transform] for the
      // mirror and a test that reads "the transform above the image" would
      // otherwise read the flip.
      key: tiltGroupKey,
      angle: radians,
      origin: pivot - layout.size.center(Offset.zero),
      child: Stack(
        children: [
          Positioned(
            left: pivot.dx - radius,
            top: pivot.dy,
            width: layout.diameter,
            height: radius,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(radius),
                ),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [disc, disc.withValues(alpha: 0)],
                ),
              ),
            ),
          ),
          Positioned(
            left: pivot.dx - radius,
            top: pivot.dy - AppSizes.tiltGroundLine / 2,
            width: layout.diameter,
            height: AppSizes.tiltGroundLine,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: ink,
                borderRadius: AppRadii.fullRadius,
              ),
            ),
          ),
          Positioned(
            left: pivot.dx - layout.carSize.width / 2,
            // The tyres rest on the middle of the ground line, so the line
            // reads as the surface the car stands on rather than a rail it
            // hovers over.
            top: pivot.dy - layout.carSize.height,
            width: layout.carSize.width,
            height: layout.carSize.height,
            child: Transform.flip(
              flipX: silhouette.mirrored,
              child: Image.asset(
                silhouette.asset,
                package: 'capy_ui',
                color: ink,
                colorBlendMode: BlendMode.srcIn,
                filterQuality: FilterQuality.medium,
                cacheWidth: decodeWidth > 0 ? decodeWidth : null,
                fit: BoxFit.fill,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The level reference. Fixed to the horizontal, outside the dial on both
/// sides, so the tilt is readable as the angle between them and the ground
/// line.
class _ReferenceDashes extends StatelessWidget {
  const _ReferenceDashes({required this.layout, required this.color});

  final _TiltLayout layout;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final dash = DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: AppRadii.fullRadius,
      ),
    );
    final length = layout.diameter * _dashLengthUnits;
    final outer = layout.radius + layout.diameter * _dashGapUnits;
    final top = layout.pivot.dy - AppSizes.tiltReferenceDash / 2;

    return Stack(
      children: [
        Positioned(
          left: layout.pivot.dx - outer - length,
          top: top,
          width: length,
          height: AppSizes.tiltReferenceDash,
          child: dash,
        ),
        Positioned(
          left: layout.pivot.dx + outer,
          top: top,
          width: length,
          height: AppSizes.tiltReferenceDash,
          child: dash,
        ),
      ],
    );
  }
}

/// The one dial diameter every part of the gauge is measured from, and where
/// the drawing turns.
@immutable
class _TiltLayout {
  const _TiltLayout({
    required this.size,
    required this.diameter,
    required this.pivot,
    required this.carSize,
  });

  factory _TiltLayout.resolve(Size size, CarSilhouette silhouette) {
    final diameter = math.max(
      0.0,
      math.min(size.width / _widthUnits, size.height / _heightUnits),
    );
    final carSize = Size(
      diameter * silhouette.widthUnits,
      diameter * _carHeightUnits,
    );
    return _TiltLayout(
      size: size,
      diameter: diameter,
      // The ground line sits at the same place in every view: the headroom
      // above it is the largest envelope of any of them, and the disc hangs
      // below. Centring each view on its own drawing instead would put the two
      // tiles' ground lines at different heights.
      pivot: Offset(
        size.width / 2,
        (size.height - diameter * _heightUnits) / 2 +
            diameter * (_heightUnits - _discUnits),
      ),
      carSize: carSize,
    );
  }

  final Size size;
  final double diameter;

  /// Centre of the ground line. Everything that moves turns about this point.
  final Offset pivot;

  final Size carSize;

  double get radius => diameter / 2;
}

/// The reference tile: a title, the angle as a numeral, and the dial beneath.
///
/// Both tilt readings use this — pass the localized [label] and the matching
/// [silhouette]. It takes [value] pre-formatted, like every other metric in
/// this system; `tiltAngleLabel` in `lib/core/telemetry_format.dart` produces
/// it, including the `--` that goes with a null [angleDeg].
class TiltCard extends StatelessWidget {
  const TiltCard({
    required this.label,
    required this.value,
    required this.angleDeg,
    this.silhouette = CarSilhouette.side,
    this.height = AppSizes.tiltGaugeHeight,
    this.animate = true,
    super.key,
  });

  /// Localized title (`Pitch`, `Roll`).
  final String label;

  /// Pre-formatted angle (`1°`), or the `--` placeholder.
  final String value;

  final double? angleDeg;
  final CarSilhouette silhouette;
  final double height;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      title: label,
      trailing: MetricValue(value: value, size: MetricSize.lg),
      child: SizedBox(
        height: height,
        child: TiltGauge(
          angleDeg: angleDeg,
          silhouette: silhouette,
          animate: animate,
        ),
      ),
    );
  }
}
