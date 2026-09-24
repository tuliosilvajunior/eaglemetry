import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/image_cache_budget.dart';
import '../design_system/design_system.dart';
import '../l10n/app_localizations.dart';

class TelemetryMapPoint {
  const TelemetryMapPoint({
    required this.latitude,
    required this.longitude,
    this.altitudeM,
    this.accuracyM,
    this.speedKmh,
  });

  final double latitude;
  final double longitude;
  final double? altitudeM;
  final double? accuracyM;
  final double? speedKmh;

  LatLng get latLng => LatLng(latitude, longitude);
}

class TelemetryMapPanel extends StatefulWidget {
  const TelemetryMapPanel({
    super.key,
    required this.title,
    required this.emptyMessage,
    required this.points,
    this.compact = false,
    this.expanded = false,
    this.showRoute = true,
    this.follow = false,
    this.totalPointCount,
    this.onExpand,
    this.trailing,
  });

  final String title;
  final String emptyMessage;
  final List<TelemetryMapPoint> points;
  final bool compact;
  final bool expanded;
  final bool showRoute;

  /// Rota em andamento: a câmera acompanha o último ponto e ele ganha um marcador
  /// de posição atual em vez da bandeira de chegada.
  ///
  /// Sem isto o painel enquadra os limites da rota uma vez e o carro sai de vista
  /// assim que se afasta — o que numa tela ao vivo é o mesmo que não ter mapa.
  final bool follow;

  final int? totalPointCount;
  final VoidCallback? onExpand;

  /// Widget extra no cabeçalho, antes da contagem de pontos.
  final Widget? trailing;

  @override
  State<TelemetryMapPanel> createState() => _TelemetryMapPanelState();
}

class _TelemetryMapPanelState extends State<TelemetryMapPanel> {
  late List<TelemetryMapPoint> _validPoints;
  late _SpeedScale _speedScale;
  late List<Marker> _markerList;
  List<Polyline>? _routeLines;
  LatLngBounds? _bounds;

  /// Só existe no modo [TelemetryMapPanel.follow]: mover a câmera exige o
  /// controller, e criá-lo sem necessidade acopla o painel estático a ele.
  MapController? _controller;

  /// `move()` antes do mapa montar não tem para onde ir; `onMapReady` é o único
  /// aviso confiável de que a câmera existe.
  bool _mapReady = false;

  static const double _followZoom = 16;

  @override
  void initState() {
    super.initState();
    _controller = MapController();
    _rebuildDerived();
  }

  @override
  void dispose() {
    evictMapImageCache();
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(TelemetryMapPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.points, widget.points) ||
        oldWidget.showRoute != widget.showRoute) {
      _rebuildDerived();
      if (widget.follow) _followLastPoint();
    }
  }

  void _followLastPoint() {
    final controller = _controller;
    if (!_mapReady || controller == null || _validPoints.isEmpty) return;
    // Mantém o zoom que o usuário deixou: só o centro acompanha o carro.
    controller.move(_validPoints.last.latLng, controller.camera.zoom);
  }

  // Recomputes the map's derived geometry (valid points, speed scale, route
  // polylines, markers, camera bounds) only when the inputs change, so
  // unrelated parent rebuilds don't re-run the O(n) passes over the points.
  void _rebuildDerived() {
    _validPoints = widget.points
        .where((point) => _validCoordinate(point.latitude, point.longitude))
        .toList(growable: false);
    _speedScale = _SpeedScale.fromPoints(_validPoints);
    _markerList = _validPoints.isEmpty
        ? const <Marker>[]
        : _markers(_validPoints);
    _routeLines = (widget.showRoute && _validPoints.length > 1)
        ? _routePolylines(_validPoints, _speedScale)
        : null;
    _bounds = _validPoints.length > 1
        ? LatLngBounds.fromPoints([
            for (final point in _validPoints) point.latLng,
          ])
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final validPoints = _validPoints;
    final speedScale = _speedScale;
    final height = widget.expanded ? null : (widget.compact ? 300.0 : 380.0);
    final totalPointCount = widget.totalPointCount;
    final pointLabel =
        totalPointCount != null && totalPointCount != validPoints.length
        ? '${validPoints.length}/$totalPointCount GPS'
        : '${validPoints.length} GPS';

    return Container(
      height: height,
      padding: AutomotiveSpacing.panelPadding,
      decoration: BoxDecoration(
        color: AutomotiveColors.surfaceContainer,
        border: Border.all(color: AutomotiveColors.outlineVariant),
        borderRadius: AutomotiveRadii.lgRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // O título cede espaço antes de qualquer outra coisa: numa coluna
          // estreita ele era o único filho sem limite, e a linha inteira
          // estourava em vez de truncá-lo.
          Row(
            children: [
              Flexible(
                child: Text(
                  widget.title,
                  overflow: TextOverflow.ellipsis,
                  style: AutomotiveTextStyles.headlineMd.copyWith(
                    color: AutomotiveColors.onSurface,
                  ),
                ),
              ),
              const Spacer(),
              if (widget.trailing != null) ...[
                widget.trailing!,
                const SizedBox(width: AutomotiveSpacing.x1),
              ],
              Text(
                pointLabel,
                overflow: TextOverflow.ellipsis,
                style: AutomotiveTextStyles.unitLabel.copyWith(
                  color: AutomotiveColors.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
              if (widget.onExpand != null) ...[
                const SizedBox(width: AutomotiveSpacing.x1),
                SizedBox(
                  width: 44,
                  height: 44,
                  child: IconButton(
                    tooltip: 'Expand map',
                    onPressed: widget.onExpand,
                    icon: Icon(Icons.open_in_full),
                    color: AutomotiveColors.secondary,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: AutomotiveSpacing.x2),
          Expanded(
            child: validPoints.isEmpty
                ? _MapEmptyState(message: widget.emptyMessage)
                : ClipRRect(
                    borderRadius: AutomotiveRadii.baseRadius,
                    child: Stack(
                      children: [
                        FlutterMap(
                          mapController: _controller,
                          options: MapOptions(
                            initialCenter: widget.follow
                                ? validPoints.last.latLng
                                : validPoints.first.latLng,
                            initialZoom: widget.follow
                                ? _followZoom
                                : validPoints.length == 1
                                ? 15
                                : 13,
                            // Enquadrar os limites no modo ao vivo brigaria com o
                            // acompanhamento: a cada ponto novo a câmera voltaria
                            // para a rota inteira.
                            initialCameraFit: _bounds != null && !widget.follow
                                ? CameraFit.bounds(
                                    bounds: _bounds!,
                                    padding: const EdgeInsets.all(36),
                                  )
                                : null,
                            onMapReady: () {
                              _mapReady = true;
                              if (widget.follow) {
                                _followLastPoint();
                              } else if (_bounds != null) {
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  if (mounted && _bounds != null) {
                                    _controller?.fitCamera(
                                      CameraFit.bounds(
                                        bounds: _bounds!,
                                        padding: const EdgeInsets.all(36),
                                      ),
                                    );
                                  }
                                });
                              }
                            },
                          ),
                          children: [
                            TileLayer(
                              urlTemplate:
                                  'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                              userAgentPackageName: 'com.timhss.capy',
                              panBuffer: 1,
                              keepBuffer: 2,
                              tileBuilder: _mutedTileBuilder,
                            ),
                            if (_routeLines != null)
                              PolylineLayer(
                                simplificationTolerance: 0,
                                cullingMargin: 24,
                                polylines: _routeLines!,
                              ),
                            MarkerLayer(markers: _markerList),
                          ],
                        ),
                        if (_routeLines != null && speedScale.hasSpeed)
                          Positioned(
                            right: 8,
                            bottom: 8,
                            child: _SpeedLegend(scale: speedScale),
                          ),
                        const Positioned(
                          left: 8,
                          bottom: 6,
                          child: _AttributionLabel(),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  List<Polyline> _routePolylines(
    List<TelemetryMapPoint> points,
    _SpeedScale speedScale,
  ) {
    final routePolylines = <Polyline>[];
    final latLngPoints = [for (final point in points) point.latLng];
    final haloPolyline = Polyline(
      points: latLngPoints,
      color: AutomotiveColors.surfaceContainerLowest.withValues(alpha: 0.88),
      strokeWidth: 8,
    );
    var bucketPoints = <LatLng>[latLngPoints.first];
    Color? bucketColor;

    void flushBucket() {
      if (bucketColor == null || bucketPoints.length < 2) return;
      routePolylines.add(
        Polyline(points: bucketPoints, color: bucketColor, strokeWidth: 5),
      );
    }

    for (var i = 1; i < points.length; i++) {
      final speed = _averageSegmentSpeed(points[i - 1], points[i]);
      final color = speedScale.colorFor(speed);
      if (bucketColor == null || color == bucketColor) {
        bucketColor = color;
        bucketPoints.add(latLngPoints[i]);
        continue;
      }
      flushBucket();
      bucketColor = color;
      bucketPoints = [latLngPoints[i - 1], latLngPoints[i]];
    }
    flushBucket();
    return [haloPolyline, ...routePolylines];
  }

  List<Marker> _markers(List<TelemetryMapPoint> points) {
    if (points.length == 1) {
      return [
        widget.follow
            ? _marker(
                point: points.first.latLng,
                icon: Icons.my_location,
                color: AutomotiveColors.secondary,
              )
            : _marker(
                point: points.first.latLng,
                icon: Icons.ev_station,
                color: AutomotiveColors.secondary,
              ),
      ];
    }
    return [
      _marker(
        point: points.first.latLng,
        icon: Icons.play_arrow,
        color: AutomotiveColors.secondary,
      ),
      // Numa rota em andamento o último ponto é onde o carro está, não onde a
      // viagem terminou: a bandeira de chegada mentiria.
      widget.follow
          ? _marker(
              point: points.last.latLng,
              icon: Icons.my_location,
              color: AutomotiveColors.secondary,
            )
          : _marker(
              point: points.last.latLng,
              icon: Icons.flag,
              color: AutomotiveColors.tertiary,
            ),
    ];
  }

  Marker _marker({
    required LatLng point,
    required IconData icon,
    required Color color,
  }) {
    return Marker(
      point: point,
      width: 44,
      height: 44,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AutomotiveColors.surfaceContainerLowest.withValues(alpha: 0.9),
          border: Border.all(color: color, width: 2),
          borderRadius: AutomotiveRadii.fullRadius,
        ),
        child: Icon(icon, color: color, size: 24),
      ),
    );
  }
}

class _SpeedScale {
  const _SpeedScale({required this.minSpeedKmh, required this.maxSpeedKmh});

  static const _slowColor = Color(0xFF3BB8FF);
  static const _cruiseColor = Color(0xFF30E3A2);
  static const _mediumColor = Color(0xFFFFD447);
  static const _fastColor = Color(0xFFFF4B55);

  final double? minSpeedKmh;
  final double? maxSpeedKmh;

  bool get hasSpeed => minSpeedKmh != null && maxSpeedKmh != null;

  static _SpeedScale fromPoints(List<TelemetryMapPoint> points) {
    double? min;
    double? max;
    for (var i = 1; i < points.length; i++) {
      final speed = _averageSegmentSpeed(points[i - 1], points[i]);
      if (speed == null || !speed.isFinite || speed < 0) continue;
      if (min == null || speed < min) min = speed;
      if (max == null || speed > max) max = speed;
    }
    return _SpeedScale(minSpeedKmh: min, maxSpeedKmh: max);
  }

  Color colorFor(double? speedKmh) {
    if (speedKmh == null || !speedKmh.isFinite || !hasSpeed) {
      return AutomotiveColors.outline;
    }
    final min = minSpeedKmh!;
    final max = maxSpeedKmh!;
    if ((max - min).abs() < 0.1) return _mediumColor;
    final t = ((speedKmh - min) / (max - min)).clamp(0.0, 1.0).toDouble();
    if (t < 0.25) return _slowColor;
    if (t < 0.5) return _cruiseColor;
    if (t < 0.75) return _mediumColor;
    return _fastColor;
  }
}

class _SpeedLegend extends StatelessWidget {
  const _SpeedLegend({required this.scale});

  final _SpeedScale scale;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AutomotiveColors.surfaceContainerLowest.withValues(alpha: 0.88),
        border: Border.all(color: AutomotiveColors.outlineVariant),
        borderRadius: AutomotiveRadii.baseRadius,
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: SizedBox(
          width: 190,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The two ends share the strip, and each truncates rather than
              // pushing the other out of it: the legend sits over the map at a
              // fixed width, and a long locale for "slow" must not take the
              // speed at the other end off the panel.
              Row(
                children: [
                  Flexible(
                    child: Text(
                      loc.mapSpeedSlow(_formatSpeed(scale.minSpeedKmh)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AutomotiveTextStyles.unitLabel.copyWith(
                        color: AutomotiveColors.onSurface,
                        fontSize: 10,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      loc.mapSpeedFast(_formatSpeed(scale.maxSpeedKmh)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: AutomotiveTextStyles.unitLabel.copyWith(
                        color: AutomotiveColors.onSurface,
                        fontSize: 10,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Container(
                height: 8,
                decoration: BoxDecoration(
                  borderRadius: AutomotiveRadii.fullRadius,
                  gradient: const LinearGradient(
                    colors: [
                      _SpeedScale._slowColor,
                      _SpeedScale._cruiseColor,
                      _SpeedScale._mediumColor,
                      _SpeedScale._fastColor,
                    ],
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

class _MapEmptyState extends StatelessWidget {
  const _MapEmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AutomotiveColors.surfaceContainerLow,
        border: Border.all(color: AutomotiveColors.outlineVariant),
        borderRadius: AutomotiveRadii.baseRadius,
      ),
      child: Center(
        child: Text(
          message,
          style: AutomotiveTextStyles.unitLabel.copyWith(
            color: AutomotiveColors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _AttributionLabel extends StatelessWidget {
  const _AttributionLabel();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AutomotiveColors.surfaceContainerLowest.withValues(alpha: 0.82),
        borderRadius: AutomotiveRadii.baseRadius,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Text(
          'OpenStreetMap',
          style: AutomotiveTextStyles.unitLabel.copyWith(
            color: AutomotiveColors.onSurfaceVariant,
            fontSize: 10,
          ),
        ),
      ),
    );
  }
}

double? _averageSegmentSpeed(
  TelemetryMapPoint previous,
  TelemetryMapPoint current,
) {
  final previousSpeed = previous.speedKmh;
  final currentSpeed = current.speedKmh;
  if (previousSpeed == null) return currentSpeed;
  if (currentSpeed == null) return previousSpeed;
  return (previousSpeed + currentSpeed) / 2;
}

String _formatSpeed(double? value) {
  if (value == null || !value.isFinite) return '--';
  return '${value.round()} km/h';
}

bool _validCoordinate(double latitude, double longitude) {
  return latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180 &&
      (latitude != 0 || longitude != 0);
}

Widget _mutedTileBuilder(
  BuildContext context,
  Widget tileWidget,
  TileImage tile,
) {
  return Stack(
    fit: StackFit.passthrough,
    children: [
      ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          0.12,
          0.36,
          0.04,
          0,
          12,
          0.12,
          0.36,
          0.04,
          0,
          12,
          0.12,
          0.36,
          0.04,
          0,
          12,
          0,
          0,
          0,
          1,
          0,
        ]),
        child: tileWidget,
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          color: AutomotiveColors.surfaceContainerLowest.withValues(
            alpha: 0.16,
          ),
        ),
      ),
    ],
  );
}
