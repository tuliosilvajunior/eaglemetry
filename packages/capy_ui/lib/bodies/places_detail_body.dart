import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import '../components/soft_action_tile.dart';

/// What a save from the detail returns.
@immutable
class PlaceDetailSave {
  const PlaceDetailSave({
    required this.name,
    required this.radiusM,
    this.autoName,
  });

  final String name;
  final double radiusM;

  /// Suggested name from companion, null when unchanged.
  final String? autoName;
}

/// Platform-agnostic detail body for a single [InsightPlace] or [CandidatePlace].
///
/// Shows a map with a live radius circle, a slider, an overlap warning,
/// a name field and save/cancel. Never calls Navigator or a store; the
/// wrapper provides [onSave]/[onCancel].
class PlacesDetailBody extends StatefulWidget {
  const PlacesDetailBody({
    required this.latitude,
    required this.longitude,
    this.placeId,
    this.initialName,
    this.initialAutoName,
    this.initialRadiusM = kInsightPlaceRadiusM,
    required this.otherPlaces,
    this.onSave,
    this.onCancel,
    this.title,
    this.hintText,
    this.saveLabel = 'Salvar',
    this.cancelLabel = 'Cancelar',
    this.enableSuggest = false,
    this.onSuggest,
    this.suggestManualPrompt =
        'Não foi possível obter o endereço. Digite manualmente.',
    super.key,
  });

  final double latitude;
  final double longitude;

  /// Null for a candidate (new place).
  final String? placeId;

  /// Raw user name, not displayName. Empty for candidate.
  final String? initialName;

  /// Existing suggested autoName, shown read-only when suggest disabled.
  final String? initialAutoName;

  final double initialRadiusM;

  /// Places to check for overlap. Caller must exclude self if editing.
  final List<InsightPlace> otherPlaces;

  final void Function(String name, double radiusM, String? autoName)? onSave;
  final VoidCallback? onCancel;

  final String? title;
  final String? hintText;
  final String saveLabel;
  final String cancelLabel;

  /// Companion-only: when true shows "Sugerir nome" button.
  final bool enableSuggest;

  /// Called when user taps Sugerir. Returns suggested displayName or null on failure/vague.
  final Future<String?> Function()? onSuggest;

  /// Message shown when suggest returns null.
  final String suggestManualPrompt;

  static const double minRadius = 50;
  static const double maxRadius = 2000;

  /// Helpers for tests and adapters.
  static List<InsightPlace> overlapping({
    required double latitude,
    required double longitude,
    required double radiusM,
    required List<InsightPlace> otherPlaces,
    String? placeId,
  }) {
    final result = <InsightPlace>[];
    for (final other in otherPlaces) {
      if (placeId != null && other.id == placeId) continue;
      final d = insightDistanceM(
        latitude,
        longitude,
        other.latitude,
        other.longitude,
      );
      if (d < (radiusM + other.radiusM)) {
        result.add(other);
      }
    }
    return result;
  }

  @override
  State<PlacesDetailBody> createState() => _PlacesDetailBodyState();
}

class _PlacesDetailBodyState extends State<PlacesDetailBody> {
  late double _radiusM;
  late final TextEditingController _nameController;
  String? _autoNameSuggestion;
  bool _isSuggesting = false;
  String? _suggestError;

  @override
  void initState() {
    super.initState();
    _radiusM = widget.initialRadiusM.clamp(
      PlacesDetailBody.minRadius,
      PlacesDetailBody.maxRadius,
    );
    _nameController = TextEditingController(
      text: (widget.initialName ?? '').trim(),
    );
    _autoNameSuggestion = widget.initialAutoName?.trim().isEmpty == true
        ? null
        : widget.initialAutoName;
  }

  @override
  void didUpdateWidget(covariant PlacesDetailBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialRadiusM != widget.initialRadiusM) {
      _radiusM = widget.initialRadiusM.clamp(
        PlacesDetailBody.minRadius,
        PlacesDetailBody.maxRadius,
      );
    }
    if (oldWidget.initialName != widget.initialName) {
      _nameController.text = (widget.initialName ?? '').trim();
    }
    if (oldWidget.initialAutoName != widget.initialAutoName) {
      _autoNameSuggestion = widget.initialAutoName?.trim().isEmpty == true
          ? null
          : widget.initialAutoName;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  List<InsightPlace> get _overlapping => PlacesDetailBody.overlapping(
    latitude: widget.latitude,
    longitude: widget.longitude,
    radiusM: _radiusM,
    otherPlaces: widget.otherPlaces,
    placeId: widget.placeId,
  );

  String? get _effectiveAutoName => _autoNameSuggestion;

  bool get _canSave {
    final trimmed = _nameController.text.trim();
    if (trimmed.isNotEmpty) return true;
    final auto = _effectiveAutoName?.trim();
    if (auto != null && auto.isNotEmpty) return true;
    return false;
  }

  void _handleSave() {
    final name = _nameController.text.trim();
    final effectiveAuto = _effectiveAutoName;
    if (name.isEmpty &&
        (effectiveAuto == null || effectiveAuto.trim().isEmpty)) {
      return;
    }
    widget.onSave?.call(name, _radiusM, effectiveAuto);
  }

  Future<void> _handleSuggest() async {
    final fetcher = widget.onSuggest;
    if (fetcher == null) return;
    setState(() {
      _isSuggesting = true;
      _suggestError = null;
    });
    String? result;
    try {
      result = await fetcher();
    } catch (_) {
      result = null;
    }
    if (!mounted) return;
    if (result == null || result.trim().isEmpty) {
      setState(() {
        _isSuggesting = false;
        _suggestError = widget.suggestManualPrompt;
      });
      return;
    }
    final trimmed = result.trim();
    setState(() {
      _isSuggesting = false;
      _autoNameSuggestion = trimmed;
      // Fill name field if empty or if user has not typed a custom name different from previous auto?
      // Spec: fill name field editable with displayName.
      // If field is empty, fill. If already has a name (editing), keep user name but still store autoName.
      if (_nameController.text.trim().isEmpty) {
        _nameController.text = trimmed;
      } else if (widget.initialName?.trim().isEmpty == true) {
        // Candidate case: field was empty initially, now fill.
        _nameController.text = trimmed;
      } else {
        // For existing named place, do not overwrite user name, just store autoName.
        // But if spec says always fill, we would overwrite. Preserve user name to avoid loss.
      }
      _suggestError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final overlapping = _overlapping;

    return SingleChildScrollView(
      key: const Key('places-detail-body'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.title != null) ...[
            Text(
              widget.title!,
              key: const Key('places-detail-title'),
              style: AppText.cardTitle.copyWith(color: colors.ink),
            ),
            const SizedBox(height: AppSpacing.x4),
          ],
          _PlaceRadiusMap(
            key: const Key('places-detail-map'),
            latitude: widget.latitude,
            longitude: widget.longitude,
            radiusM: _radiusM,
          ),
          const SizedBox(height: AppSpacing.x4),
          Row(
            children: [
              const Icon(Icons.radio_button_checked, size: 14),
              const SizedBox(width: AppSpacing.x1),
              Text(
                '${_radiusM.round()} m',
                key: const Key('places-detail-radius-label'),
                style: AppText.bodyStrong.copyWith(color: colors.ink),
              ),
              const Spacer(),
            ],
          ),
          const SizedBox(height: AppSpacing.x2),
          Slider(
            key: const Key('places-detail-slider'),
            min: PlacesDetailBody.minRadius,
            max: PlacesDetailBody.maxRadius,
            divisions: 39,
            label: '${_radiusM.round()} m',
            value: _radiusM,
            onChanged: (v) => setState(() => _radiusM = v),
          ),
          if (overlapping.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.x1),
            Row(
              key: const Key('places-detail-overlap-row'),
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: colors.energy.warning,
                ),
                const SizedBox(width: AppSpacing.x1),
                Expanded(
                  child: Text(
                    'Sobrepoe com ${overlapping.map((p) => p.displayName.trim().isEmpty ? p.id : p.displayName).join(', ')}',
                    key: const Key('places-detail-overlap-warning'),
                    style: AppText.caption.copyWith(
                      color: colors.energy.warning,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.x4),
          TextField(
            key: const Key('places-detail-name-field'),
            controller: _nameController,
            autofocus: false,
            style: AppText.body.copyWith(color: colors.ink),
            decoration: InputDecoration(
              hintText: widget.hintText ?? 'Nome',
              hintStyle: AppText.body.copyWith(color: colors.inkSubtle),
              border: const OutlineInputBorder(),
              suffixIcon: _nameController.text.isNotEmpty
                  ? IconButton(
                      key: const Key('places-detail-clear'),
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _nameController.clear();
                        setState(() {});
                      },
                    )
                  : null,
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _handleSave(),
          ),
          if (widget.enableSuggest) ...[
            const SizedBox(height: AppSpacing.x2),
            _SuggestControl(
              isLoading: _isSuggesting,
              error: _suggestError,
              onPressed: _isSuggesting ? null : _handleSuggest,
            ),
          ] else if (widget.initialAutoName != null &&
              widget.initialAutoName!.trim().isNotEmpty) ...[
            const SizedBox(height: AppSpacing.x2),
            Row(
              key: const Key('places-detail-autoname-readonly'),
              children: [
                Icon(Icons.place, size: 14, color: colors.inkSubtle),
                const SizedBox(width: AppSpacing.x1),
                Expanded(
                  child: Text(
                    widget.initialAutoName!.trim(),
                    style: AppText.caption.copyWith(color: colors.inkSubtle),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.x6),
          Row(
            children: [
              Expanded(
                child: SoftActionTile(
                  key: const Key('places-detail-cancel'),
                  label: widget.cancelLabel,
                  centered: true,
                  onPressed: widget.onCancel,
                ),
              ),
              const SizedBox(width: AppSpacing.x3),
              Expanded(
                child: SoftActionTile(
                  key: const Key('places-detail-save'),
                  label: widget.saveLabel,
                  centered: true,
                  onPressed: _canSave ? _handleSave : null,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SuggestControl extends StatelessWidget {
  const _SuggestControl({required this.isLoading, this.error, this.onPressed});

  final bool isLoading;
  final String? error;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SoftActionTile(
          key: const Key('places-detail-suggest'),
          label: 'Sugerir nome',
          icon: Icons.auto_awesome,
          centered: false,
          onPressed: onPressed,
        ),
        if (isLoading) ...[
          const SizedBox(height: AppSpacing.x2),
          Row(
            key: const Key('places-detail-suggest-loading'),
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: AppSpacing.x2),
              Text(
                'Buscando...',
                style: AppText.caption.copyWith(color: colors.inkSubtle),
              ),
            ],
          ),
        ],
        if (error != null) ...[
          const SizedBox(height: AppSpacing.x1),
          Text(
            error!,
            key: const Key('places-detail-suggest-error'),
            style: AppText.caption.copyWith(color: colors.energy.warning),
          ),
        ],
      ],
    );
  }
}

class _PlaceRadiusMap extends StatelessWidget {
  const _PlaceRadiusMap({
    required this.latitude,
    required this.longitude,
    required this.radiusM,
    super.key,
  });

  final double latitude;
  final double longitude;
  final double radiusM;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final center = LatLng(latitude, longitude);

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
              key: const Key('places-detail-circle-layer'),
              circles: [
                CircleMarker(
                  point: center,
                  radius: radiusM,
                  useRadiusInMeter: true,
                  color: colors.energy.gain.withValues(alpha: 0.18),
                  borderColor: colors.energy.gain,
                  borderStrokeWidth: 2,
                ),
              ],
            ),
            MarkerLayer(
              markers: [
                Marker(
                  point: center,
                  width: AppSizes.iconLg,
                  height: AppSizes.iconLg,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.surface.withValues(alpha: 0.82),
                      border: Border.all(color: colors.energy.gain, width: 2),
                      borderRadius: AppRadii.fullRadius,
                    ),
                    child: Icon(
                      Icons.place,
                      size: AppSizes.iconSm,
                      color: colors.energy.gain,
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

/// The muted tile treatment every places map shares, so the previews read as
/// one surface.
Widget placesMutedTileBuilder(
  BuildContext context,
  Widget tile,
  TileImage image,
) {
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
