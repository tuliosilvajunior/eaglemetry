import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import '../components/soft_action_tile.dart';
import 'places_detail_body.dart';

/// What a confirmed merge returns.
///
/// [keepId] is the older row (id tie-break when creation stamps are
/// missing); [deleteId] becomes the tombstone. The center and radius are
/// the proposed geometry the preview showed.
@immutable
class PlaceMergeSave {
  const PlaceMergeSave({
    required this.keepId,
    required this.deleteId,
    required this.latitude,
    required this.longitude,
    required this.radiusM,
  });

  final String keepId;
  final String deleteId;
  final double latitude;
  final double longitude;
  final double radiusM;
}

/// Platform-agnostic merge body for one [PlaceDuplicatePair].
///
/// Shows both source circles thin and the proposed merged circle thick,
/// with a live radius slider over the proposal. Never calls Navigator or a
/// store; the wrapper provides [onSave]/[onCancel].
class PlacesMergeBody extends StatefulWidget {
  const PlacesMergeBody({
    required this.pair,
    this.onSave,
    this.onCancel,
    this.title = 'Mesclar locais',
    this.saveLabel = 'Confirmar mescla',
    this.cancelLabel = 'Cancelar',
    super.key,
  });

  final PlaceDuplicatePair pair;
  final void Function(PlaceMergeSave save)? onSave;
  final VoidCallback? onCancel;

  final String title;
  final String saveLabel;
  final String cancelLabel;

  @override
  State<PlacesMergeBody> createState() => _PlacesMergeBodyState();
}

class _PlacesMergeBodyState extends State<PlacesMergeBody> {
  late double _radiusM = proposeMergeRadiusM(
    widget.pair.placeA,
    widget.pair.placeB,
  );

  InsightPoint get _center =>
      proposeMergeCenter(widget.pair.placeA, widget.pair.placeB);

  void _handleSave() {
    final keeper = resolveMergeKeep(widget.pair.placeA, widget.pair.placeB);
    final loser = keeper == widget.pair.placeA
        ? widget.pair.placeB
        : widget.pair.placeA;
    widget.onSave?.call(
      PlaceMergeSave(
        keepId: keeper.id,
        deleteId: loser.id,
        latitude: _center.latitude,
        longitude: _center.longitude,
        radiusM: _radiusM,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);

    return SingleChildScrollView(
      key: const Key('places-merge-body'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.title,
            key: const Key('places-merge-title'),
            style: AppText.cardTitle.copyWith(color: colors.ink),
          ),
          const SizedBox(height: AppSpacing.x2),
          Text(
            '${_label(widget.pair.placeA)} + ${_label(widget.pair.placeB)}'
            ' — ${widget.pair.distanceM.round()} m',
            key: const Key('places-merge-pair-label'),
            style: AppText.body.copyWith(color: colors.inkMuted),
          ),
          const SizedBox(height: AppSpacing.x4),
          _PlaceMergeMap(
            key: const Key('places-merge-map'),
            placeA: widget.pair.placeA,
            placeB: widget.pair.placeB,
            centerLatitude: _center.latitude,
            centerLongitude: _center.longitude,
            radiusM: _radiusM,
          ),
          const SizedBox(height: AppSpacing.x4),
          Row(
            children: [
              const Icon(Icons.radio_button_checked, size: 14),
              const SizedBox(width: AppSpacing.x1),
              Text(
                '${_radiusM.round()} m',
                key: const Key('places-merge-radius-label'),
                style: AppText.bodyStrong.copyWith(color: colors.ink),
              ),
              const Spacer(),
            ],
          ),
          const SizedBox(height: AppSpacing.x2),
          Slider(
            key: const Key('places-merge-slider'),
            min: kInsightPlaceMinRadiusM,
            max: kInsightPlaceMaxRadiusM,
            divisions: 39,
            label: '${_radiusM.round()} m',
            value: _radiusM,
            onChanged: (v) => setState(() => _radiusM = v),
          ),
          const SizedBox(height: AppSpacing.x6),
          Row(
            children: [
              Expanded(
                child: SoftActionTile(
                  key: const Key('places-merge-cancel'),
                  label: widget.cancelLabel,
                  centered: true,
                  onPressed: widget.onCancel,
                ),
              ),
              const SizedBox(width: AppSpacing.x3),
              Expanded(
                child: SoftActionTile(
                  key: const Key('places-merge-confirm'),
                  label: widget.saveLabel,
                  centered: true,
                  onPressed: _handleSave,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _label(InsightPlace place) {
    final display = place.displayName.trim();
    return display.isEmpty ? place.id : display;
  }
}

class _PlaceMergeMap extends StatelessWidget {
  const _PlaceMergeMap({
    required this.placeA,
    required this.placeB,
    required this.centerLatitude,
    required this.centerLongitude,
    required this.radiusM,
    super.key,
  });

  final InsightPlace placeA;
  final InsightPlace placeB;
  final double centerLatitude;
  final double centerLongitude;
  final double radiusM;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final center = LatLng(centerLatitude, centerLongitude);

    return ClipRRect(
      borderRadius: AppRadii.xlRadius,
      child: SizedBox(
        height: 220,
        child: FlutterMap(
          options: MapOptions(initialCenter: center, initialZoom: 15),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.timhss.capy',
              panBuffer: 1,
              keepBuffer: 2,
              tileBuilder: placesMutedTileBuilder,
            ),
            CircleLayer(
              key: const Key('places-merge-circle-layer'),
              circles: [
                CircleMarker(
                  point: LatLng(placeA.latitude, placeA.longitude),
                  radius: placeA.radiusM,
                  useRadiusInMeter: true,
                  color: colors.energy.focus.withValues(alpha: 0.08),
                  borderColor: colors.energy.focus,
                  borderStrokeWidth: 1.5,
                ),
                CircleMarker(
                  point: LatLng(placeB.latitude, placeB.longitude),
                  radius: placeB.radiusM,
                  useRadiusInMeter: true,
                  color: colors.energy.warning.withValues(alpha: 0.08),
                  borderColor: colors.energy.warning,
                  borderStrokeWidth: 1.5,
                ),
                CircleMarker(
                  point: center,
                  radius: radiusM,
                  useRadiusInMeter: true,
                  color: colors.energy.gain.withValues(alpha: 0.18),
                  borderColor: colors.energy.gain,
                  borderStrokeWidth: 3,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
