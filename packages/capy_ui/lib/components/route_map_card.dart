import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import 'icon_buttons.dart';

/// Alpha for all translucent plates on the map (DESIGN.md: surface at 82%).
const double _routeMapPlateAlpha = 0.82;

/// One recorded position on a [RouteMapCard].
@immutable
class RouteMapPoint {
  const RouteMapPoint({
    required this.latitude,
    required this.longitude,
    this.speedKmh,
  });

  final double latitude;
  final double longitude;

  /// How fast the car was going here, when the frame recorded it.
  ///
  /// Null is an ordinary case, not a fault: a route is drawn from whatever the
  /// car reported, and a leg with no speed on either end is drawn in the
  /// unknown colour rather than being guessed at.
  final double? speedKmh;

  LatLng get latLng => LatLng(latitude, longitude);

  /// Whether the pair is a position at all. A frame with no fix stores zeroes,
  /// and `0, 0` is a real place in the Atlantic that no car in this fleet has
  /// driven to.
  bool get isValid =>
      latitude.abs() <= 90 &&
      longitude.abs() <= 180 &&
      !(latitude == 0 && longitude == 0);

  @override
  bool operator ==(Object other) =>
      other is RouteMapPoint &&
      other.latitude == latitude &&
      other.longitude == longitude &&
      other.speedKmh == speedKmh;

  @override
  int get hashCode => Object.hash(latitude, longitude, speedKmh);
}

/// The slowest and the fastest leg of a route, which is what the colour of the
/// line is measured against.
///
/// The scale is relative to the drive itself, not to an absolute speed: a lap
/// of a car park and a run down a motorway both use the whole ramp, because
/// what the line answers is "where on this drive was I moving well", and a
/// fixed scale would paint the whole car park one colour.
///
/// Public, and computed from the points alone, so the caller can name the two
/// ends of the legend without the card having to hand its internals over — see
/// [RouteMapCard.speedLegend].
@immutable
class RouteSpeedScale {
  const RouteSpeedScale({this.slowestKmh, this.fastestKmh});

  factory RouteSpeedScale.fromPoints(List<RouteMapPoint> points) {
    double? slowest;
    double? fastest;
    for (var i = 1; i < points.length; i++) {
      final speed = _legSpeed(points[i - 1], points[i]);
      if (speed == null || !speed.isFinite || speed < 0) continue;
      if (slowest == null || speed < slowest) slowest = speed;
      if (fastest == null || speed > fastest) fastest = speed;
    }
    return RouteSpeedScale(slowestKmh: slowest, fastestKmh: fastest);
  }

  final double? slowestKmh;
  final double? fastestKmh;

  /// Whether the route reported speed at all. False for a route the car
  /// recorded without it, and for a single position.
  bool get hasSpeed => slowestKmh != null && fastestKmh != null;

  /// The ramp, slowest to fastest. Every colour is an existing palette token:
  /// the map introduces no colour of its own, so an expressive theme colours
  /// the route in its own hues.
  static List<Color> rampOf(AppThemeColors colors) => <Color>[
    colors.energy.focus,
    colors.energy.gain,
    colors.energy.draw,
    colors.energy.critical,
  ];

  /// What a leg at [speedKmh] is drawn in.
  ///
  /// A leg with no speed is drawn in the neutral rather than in the slowest
  /// colour: "the car did not say" and "the car was crawling" are different
  /// facts, and the line must not turn one into the other.
  Color colorFor(double? speedKmh, AppThemeColors colors) {
    final ramp = rampOf(colors);
    if (speedKmh == null || !speedKmh.isFinite || !hasSpeed) {
      return AppColors.inkSubtle;
    }
    final slowest = slowestKmh!;
    final fastest = fastestKmh!;
    // A drive at one speed has no ramp to place anything on, so the whole line
    // takes the middle rather than an end that would read as a judgement.
    if ((fastest - slowest).abs() < 0.1) return ramp[2];
    final position = ((speedKmh - slowest) / (fastest - slowest))
        .clamp(0.0, 1.0)
        .toDouble();
    final step = (position * ramp.length).floor();
    return ramp[step.clamp(0, ramp.length - 1)];
  }
}

/// The two ends of the speed legend, already localized by the caller.
///
/// The card computes the scale and the caller names it — the component takes
/// its text as a parameter, as every component here does. Pass null and the
/// line is still coloured; only the legend goes away.
@immutable
class RouteSpeedLegend {
  const RouteSpeedLegend({required this.slowLabel, required this.fastLabel});

  final String slowLabel;
  final String fastLabel;
}

/// Takes one map tile down to the dark, near-monochrome ground the route is
/// drawn on.
///
/// The matrix is the one the previous map shipped, kept to the digit. It reads
/// every tile through a green-weighted luminance and lifts the black point by
/// 12, which is what turns a street map into a ground rather than a picture:
/// the ramp is four saturated colours, and they need something that is not
/// competing with them underneath. The plate over it takes the last of the
/// remaining contrast out.
///
/// This is the one place in `capy_ui` that paints a dark surface in a
/// light-only system, and it is deliberate. The tiles are not the app's
/// surface — they are a photograph, the only image the app draws — so the rule
/// that keeps every panel light does not reach them. Everything the card puts
/// *on* the map stays light and gains contrast from the change.
Widget _mutedTile(BuildContext context, Widget tile, TileImage image) {
  return Stack(
    fit: StackFit.passthrough,
    children: [
      ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          0.12, 0.36, 0.04, 0, 12, //
          0.12, 0.36, 0.04, 0, 12, //
          0.12, 0.36, 0.04, 0, 12, //
          0, 0, 0, 1, 0, //
        ]),
        child: tile,
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.inverseSurface.withValues(alpha: 0.16),
        ),
      ),
    ],
  );
}

/// The speed of one leg: the mean of its two ends, or whichever end reported.
double? _legSpeed(RouteMapPoint from, RouteMapPoint to) {
  final start = from.speedKmh;
  final end = to.speedKmh;
  if (start == null) return end;
  if (end == null) return start;
  return (start + end) / 2;
}

/// A square map card whose map **is** the card: no padding, no header, no
/// border. The tiles run to the rounded corners and stop there.
///
/// [square] is enforced here rather than left to the caller. The card's whole
/// job is to be a window onto a route, and a window that changes shape with
/// its neighbour crops the route differently every time the layout moves —
/// so the caller supplies one dimension by constraining it, and this decides
/// the other. A caller that has decided the shape itself — one growing the
/// card into a box of its own choosing — passes `square: false` and gets a
/// card that fills what it is given.
///
/// The expand affordance is optional: pass [onToggleExpanded] to get the
/// button, leave it null and the card has none. Growing the card is the
/// caller's business, since only the caller knows what has to give the space
/// up. All this does is ask.
class RouteMapCard extends StatefulWidget {
  const RouteMapCard({
    required this.points,
    this.square = true,
    this.expanded = false,
    this.onToggleExpanded,
    this.expandLabel,
    this.collapseLabel,
    this.speedLegend,
    super.key,
  });

  /// Whether the card decides its own second dimension from the first. See
  /// the class doc.
  final bool square;

  /// The route, in order. One point draws a marker; two or more draw a line
  /// with a marker at each end.
  final List<RouteMapPoint> points;

  /// Whether the caller is currently giving this card its larger size. Only
  /// changes which label the button carries and which way its arrow points.
  final bool expanded;

  final VoidCallback? onToggleExpanded;

  /// Localized names for the two states of the button. Required in practice
  /// whenever [onToggleExpanded] is given — a button with no name is
  /// unreachable by assistive technology.
  final String? expandLabel;
  final String? collapseLabel;

  /// Names the two ends of the speed ramp. Omit it and the route is still
  /// coloured by speed but says nothing about what the colours mean, which is
  /// what a card too narrow to hold the legend falls back to.
  ///
  /// Build it from [RouteSpeedScale.fromPoints] over the same points.
  final RouteSpeedLegend? speedLegend;

  @override
  State<RouteMapCard> createState() => _RouteMapCardState();
}

class _RouteMapCardState extends State<RouteMapCard> {
  final MapController _controller = MapController();
  Animation<double>? _routeAnimation;

  /// `fitCamera` before the map is laid out has no camera to move, and
  /// `onMapReady` is the only reliable word that there is one.
  bool _ready = false;

  late List<RouteMapPoint> _valid = _validPoints;

  /// The line, already cut into runs of one colour.
  ///
  /// Held rather than built in `build`, because it is an O(n) pass over the
  /// route and nothing about a parent rebuild — a card resizing, the expand
  /// button being pressed — changes what it draws. The theme does change it,
  /// so [didChangeDependencies] rebuilds it too.
  List<Polyline> _lines = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _lines = _speedLines(_valid, AppThemeColors.of(context));
    final animation = ModalRoute.of(context)?.animation;
    if (animation != _routeAnimation) {
      _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
      _routeAnimation = animation;
      _routeAnimation?.addStatusListener(_onRouteAnimationStatus);
    }
  }

  void _onRouteAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _fit();
    }
  }

  List<RouteMapPoint> get _validPoints =>
      widget.points.where((point) => point.isValid).toList(growable: false);

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
    // History is keep-alive. Without this the OSM tiles stay in the
    // process-wide image cache after the card leaves the tree.
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant RouteMapCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.points, widget.points)) return;
    final next = _validPoints;
    if (listEquals(next, _valid)) return;
    _valid = next;
    _lines = _speedLines(next, AppThemeColors.of(context));
    // The expanded card is handed a denser version of the same route, so the
    // camera has to be re-fitted: `initialCameraFit` fires once and would
    // leave the finer route framed by the coarser one's bounds.
    _fit();
  }

  void _fit() {
    if (!_ready || _valid.length < 2) return;
    _controller.fitCamera(
      CameraFit.bounds(bounds: _bounds(_valid), padding: _fitPadding),
    );
  }

  static const _fitPadding = EdgeInsets.all(AppSpacing.x6);

  static LatLngBounds _bounds(List<RouteMapPoint> points) {
    return LatLngBounds.fromPoints([for (final point in points) point.latLng]);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final points = _valid;
    final toggle = widget.onToggleExpanded;

    final card = ClipRRect(
      borderRadius: AppRadii.xlRadius,
      child: ColoredBox(
        // The ground the tiles land on, so a tile still loading is the dark
        // the map is about to be rather than a light square that flashes and
        // goes out. A card with no position to show has no tiles coming and
        // stays an ordinary empty surface.
        color: points.isEmpty ? colors.control : AppColors.inverseSurface,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // A legend wider than the card it explains would cover the route
            // it is explaining. The small square beside a wall of readings is
            // below that width; the drive's own column is well above it.
            final legend = constraints.maxWidth >= _legendMinCardWidth
                ? widget.speedLegend
                : null;
            return _mapStack(context, colors, points, toggle, legend);
          },
        ),
      ),
    );
    return widget.square ? AspectRatio(aspectRatio: 1, child: card) : card;
  }

  /// How wide the card has to be before the legend earns its corner.
  static const _legendMinCardWidth = 320.0;

  Widget _mapStack(
    BuildContext context,
    AppThemeColors colors,
    List<RouteMapPoint> points,
    VoidCallback? toggle,
    RouteSpeedLegend? legend,
  ) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (points.isNotEmpty)
          FlutterMap(
            mapController: _controller,
            options: MapOptions(
              initialCenter: points.first.latLng,
              initialZoom: points.length == 1 ? 15 : 13,
              initialCameraFit: points.length < 2
                  ? null
                  : CameraFit.bounds(
                      bounds: _bounds(points),
                      padding: _fitPadding,
                    ),
              onMapReady: () {
                _ready = true;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _fit();
                });
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.timhss.capy',
                panBuffer: 1,
                keepBuffer: 2,
                tileBuilder: _mutedTile,
              ),
              if (_lines.isNotEmpty)
                PolylineLayer(
                  // The route is already decimated by the time it gets
                  // here, and the runs are short: simplifying again would
                  // drop the very corners that separate one colour from
                  // the next.
                  simplificationTolerance: 0,
                  polylines: _lines,
                ),
              MarkerLayer(markers: _markers(points)),
            ],
          ),
        if (toggle != null)
          Positioned(
            top: AppSpacing.x2,
            right: AppSpacing.x2,
            child: _FloatingControl(
              child: SquareIconButton(
                icon: widget.expanded
                    ? Icons.close_fullscreen
                    : Icons.open_in_full,
                tooltip: widget.expanded
                    ? widget.collapseLabel
                    : widget.expandLabel,
                onPressed: toggle,
              ),
            ),
          ),
        if (legend != null)
          Positioned(
            right: AppSpacing.x2,
            bottom: AppSpacing.x2,
            child: _SpeedLegendPlate(legend: legend),
          ),
        // Required by the tile provider's terms. It is an attribution,
        // not product copy, which is why it is not an ARB key.
        Positioned(
          left: AppSpacing.x2,
          bottom: AppSpacing.x1,
          child: _FloatingControl(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.x2,
                vertical: AppSpacing.x1,
              ),
              child: Text(
                'OpenStreetMap',
                style: AppText.caption.copyWith(color: colors.inkMuted),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// The route as runs of one colour, over a plate of the card's own surface.
  ///
  /// The plate is not decoration. These tiles are a photograph of a city and
  /// the ramp has to stay readable over every part of it, so the line is laid
  /// on a wider stroke of the surface colour first — the same reason the
  /// controls on this card ride translucent plates.
  List<Polyline> _speedLines(
    List<RouteMapPoint> points,
    AppThemeColors colors,
  ) {
    if (points.length < 2) return const [];
    final scale = RouteSpeedScale.fromPoints(points);
    final plate = Polyline(
      points: [for (final point in points) point.latLng],
      color: AppColors.surface.withValues(alpha: _routeMapPlateAlpha),
      strokeWidth: 8,
    );

    final runs = <Polyline>[];
    var run = <LatLng>[points.first.latLng];
    Color? color;

    void closeRun() {
      final runColor = color;
      if (runColor == null || run.length < 2) return;
      runs.add(Polyline(points: run, color: runColor, strokeWidth: 5));
    }

    for (var i = 1; i < points.length; i++) {
      final legColor = scale.colorFor(
        _legSpeed(points[i - 1], points[i]),
        colors,
      );
      if (color == null || legColor == color) {
        color = legColor;
        run.add(points[i].latLng);
        continue;
      }
      closeRun();
      color = legColor;
      // The new run starts at the leg's own first point, or the line would
      // show a gap wherever the colour changes.
      run = [points[i - 1].latLng, points[i].latLng];
    }
    closeRun();
    return [plate, ...runs];
  }

  List<Marker> _markers(List<RouteMapPoint> points) {
    if (points.length == 1) {
      return [
        _marker(
          points.first,
          Icons.place,
          AppThemeColors.of(context).energy.draw,
        ),
      ];
    }
    return [
      _marker(
        points.first,
        Icons.play_arrow,
        AppThemeColors.of(context).energy.gain,
      ),
      _marker(points.last, Icons.flag, AppThemeColors.of(context).energy.draw),
    ];
  }

  /// A plated marker, for the same reason the line is plated: an icon alone
  /// over map tiles is legible only where the tiles happen to be pale.
  Marker _marker(RouteMapPoint point, IconData icon, Color color) {
    return Marker(
      point: point.latLng,
      width: AppSizes.iconLg,
      height: AppSizes.iconLg,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: _routeMapPlateAlpha),
          border: Border.all(color: color, width: 2),
          borderRadius: AppRadii.fullRadius,
        ),
        child: Icon(icon, size: AppSizes.iconSm, color: color),
      ),
    );
  }
}

/// What the colours of the route mean: the ramp itself, with the slowest and
/// the fastest leg of this drive named at its ends.
///
/// It prints the two speeds and nothing between them, because the ramp is
/// relative to the drive — see [RouteSpeedScale]. A tick in the middle would
/// claim a reading the scale does not make.
class _SpeedLegendPlate extends StatelessWidget {
  const _SpeedLegendPlate({required this.legend});

  final RouteSpeedLegend legend;

  static const _width = 180.0;
  static const _rampHeight = 8.0;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return _FloatingControl(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.x2),
        child: SizedBox(
          width: _width,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      legend.slowLabel,
                      style: AppText.caption.copyWith(color: colors.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.x2),
                  Flexible(
                    child: Text(
                      legend.fastLabel,
                      style: AppText.caption.copyWith(color: colors.ink),
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.x1),
              Container(
                height: _rampHeight,
                decoration: BoxDecoration(
                  borderRadius: AppRadii.fullRadius,
                  gradient: LinearGradient(
                    colors: RouteSpeedScale.rampOf(AppThemeColors.of(context)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A control resting on top of the map.
///
/// The map is the only surface in this system a control can sit *on*, and a
/// bare icon over aerial tiles is unreadable half the time, so this is the one
/// place a translucent plate is right.
class _FloatingControl extends StatelessWidget {
  const _FloatingControl({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: _routeMapPlateAlpha),
        borderRadius: AppRadii.mdRadius,
      ),
      child: child,
    );
  }
}
