import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';

/// A lightweight, static route preview map designed for list items.
///
/// Disables all gestures and user interaction (`InteractiveFlag.none`) to ensure
/// high performance 60fps scrolling in long trip lists.
class RoutePreviewMap extends StatefulWidget {
  const RoutePreviewMap({
    required this.points,
    this.borderRadius = AppRadii.lgRadius,
    this.routeColor,
    super.key,
  });

  final List<InsightPoint> points;
  final BorderRadius borderRadius;
  final Color? routeColor;

  @override
  State<RoutePreviewMap> createState() => _RoutePreviewMapState();
}

class _RoutePreviewMapState extends State<RoutePreviewMap> {
  final MapController _controller = MapController();
  bool _ready = false;

  List<InsightPoint> get _validPoints => widget.points
      .where(
        (p) =>
            p.latitude.isFinite &&
            p.longitude.isFinite &&
            p.latitude.abs() <= 90 &&
            p.longitude.abs() <= 180 &&
            !(p.latitude == 0 && p.longitude == 0),
      )
      .toList(growable: false);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _fit() {
    final valid = _validPoints;
    if (!_ready || valid.length < 2) return;
    _controller.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints([
          for (final p in valid) LatLng(p.latitude, p.longitude),
        ]),
        padding: const EdgeInsets.all(AppSpacing.x3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final valid = _validPoints;

    if (valid.isEmpty) {
      return ClipRRect(
        borderRadius: widget.borderRadius,
        child: Container(
          color: colors.control,
          alignment: Alignment.center,
          child: Icon(
            Icons.map_outlined,
            color: colors.inkMuted.withValues(alpha: 0.6),
            size: 28,
          ),
        ),
      );
    }

    final polylineColor = widget.routeColor ?? colors.energy.focus;
    final latLngs = [for (final p in valid) LatLng(p.latitude, p.longitude)];

    return ClipRRect(
      borderRadius: widget.borderRadius,
      child: ColoredBox(
        color: AppColors.inverseSurface,
        child: FlutterMap(
          mapController: _controller,
          options: MapOptions(
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.none,
            ),
            initialCenter: latLngs.first,
            initialZoom: latLngs.length == 1 ? 14 : 12,
            initialCameraFit: latLngs.length < 2
                ? null
                : CameraFit.bounds(
                    bounds: LatLngBounds.fromPoints(latLngs),
                    padding: const EdgeInsets.all(AppSpacing.x3),
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
              panBuffer: 0,
              keepBuffer: 1,
              tileBuilder: _mutedMapTile,
            ),
            if (latLngs.length >= 2)
              PolylineLayer(
                simplificationTolerance: 0,
                polylines: [
                  // Outer plate/contrast line
                  Polyline(
                    points: latLngs,
                    color: colors.surface.withValues(alpha: 0.7),
                    strokeWidth: 6.0,
                  ),
                  // Inner colored route line
                  Polyline(
                    points: latLngs,
                    color: polylineColor,
                    strokeWidth: 3.5,
                  ),
                ],
              ),
            MarkerLayer(
              markers: [
                // Start marker (hollow circle)
                Marker(
                  point: latLngs.first,
                  width: 14,
                  height: 14,
                  child: Container(
                    decoration: BoxDecoration(
                      color: colors.surface,
                      shape: BoxShape.circle,
                      border: Border.all(color: colors.ink, width: 2.5),
                    ),
                  ),
                ),
                if (latLngs.length >= 2)
                  // End marker (filled energy circle)
                  Marker(
                    point: latLngs.last,
                    width: 14,
                    height: 14,
                    child: Container(
                      decoration: BoxDecoration(
                        color: colors.energy.draw,
                        shape: BoxShape.circle,
                        border: Border.all(color: colors.surface, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Widget _mutedMapTile(BuildContext context, Widget tile, TileImage image) {
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
