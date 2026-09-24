import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;

import '../../core/telemetry_api.dart';
import '../../core/telemetry_scope.dart';
import '../../l10n/app_localizations.dart';

/// Car surface wrapper for the shared [PlacesBody].
///
/// Data-reactive via [TelemetryQuery] over [HistoricalTelemetrySource].
/// Viewport/input-reactive via [SurfaceCapabilities].
class PlacesScreen extends StatefulWidget {
  const PlacesScreen({this.telemetryApi, super.key});

  final TelemetryApi? telemetryApi;

  @override
  State<PlacesScreen> createState() => _PlacesScreenState();
}

class _PlacesScreenState extends State<PlacesScreen> {
  late final TelemetryApi _api =
      widget.telemetryApi ?? TelemetryScope.of(context);

  late final TelemetryQuery<PlacesData> _query = TelemetryQuery(
    read: () async {
      final placesResult = await _api.getInsightPlaces();
      final tripsResult = await _api.getInsightTrips();
      return buildPlacesData(
        places: placesResult.places,
        trips: tripsResult.trips,
      );
    },
    interval: const Duration(seconds: 30),
    refreshOn: _api.annotationsChanged().where((c) => c.places),
    debugLabel: 'PlacesScreen',
  );

  @override
  void initState() {
    super.initState();
    _query.addListener(_onChanged);
    _query.refresh();
  }

  @override
  void dispose() {
    _query.removeListener(_onChanged);
    _query.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// The line a refused write shows. A near duplicate travels as its own
  /// message; other bridge failures keep their code.
  String _saveErrorMessage(Object error) => switch (error) {
    DuplicatePlaceException() => error.toString(),
    PlatformException(:final message) when message != null => message,
    ArgumentError(:final message) => message.toString(),
    _ => error.toString(),
  };

  void _showSaveError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        key: const Key('places-save-error-snackbar'),
        content: Text(_saveErrorMessage(error)),
      ),
    );
  }

  Future<void> _openNamed(NamedPlaceEntry entry) async {
    final loc = AppLocalizations.of(context)!;
    final data = _query.state.value;
    final allPlaces = data?.named.map((e) => e.place).toList() ?? [];
    final otherPlaces = allPlaces.where((p) => p.id != entry.place.id).toList();
    final result = await showPlaceDetailDialog(
      context: context,
      latitude: entry.place.latitude,
      longitude: entry.place.longitude,
      placeId: entry.place.id,
      initialName: entry.place.name,
      initialAutoName: entry.place.autoName,
      initialRadiusM: entry.place.radiusM,
      otherPlaces: otherPlaces,
      title: loc.insightPlaceTitle,
      hintText: loc.insightPlaceHint,
      saveLabel: loc.insightPlaceSave,
      cancelLabel: loc.insightPlaceCancel,
      barrierLabel: loc.insightPlaceCancel,
      enableSuggest: false,
    );
    if (result == null || !mounted) return;
    try {
      await _api.saveInsightPlace(
        id: entry.place.id,
        name: result.name,
        latitude: entry.place.latitude,
        longitude: entry.place.longitude,
        radiusM: result.radiusM,
        autoName: result.autoName ?? entry.place.autoName,
        autoNameUpdatedAtUtcMillis: result.autoName != null
            ? DateTime.now().millisecondsSinceEpoch
            : null,
        autoNameSource: result.autoName != null ? 'nominatim' : null,
      );
    } catch (error) {
      _showSaveError(error);
      return;
    }
    _query.refresh();
  }

  Future<void> _openCandidate(CandidatePlace candidate) async {
    final loc = AppLocalizations.of(context)!;
    final data = _query.state.value;
    final allPlaces = data?.named.map((e) => e.place).toList() ?? [];
    final result = await showPlaceDetailDialog(
      context: context,
      latitude: candidate.latitude,
      longitude: candidate.longitude,
      placeId: null,
      initialName: null,
      initialAutoName: null,
      initialRadiusM: kInsightPlaceRadiusM,
      otherPlaces: allPlaces,
      title: loc.insightPlaceTitle,
      hintText: loc.insightPlaceHint,
      saveLabel: loc.insightPlaceSave,
      cancelLabel: loc.insightPlaceCancel,
      barrierLabel: loc.insightPlaceCancel,
      enableSuggest: false,
    );
    if (result == null || !mounted) return;
    try {
      await _api.saveInsightPlace(
        name: result.name,
        latitude: candidate.latitude,
        longitude: candidate.longitude,
        radiusM: result.radiusM,
        autoName: result.autoName,
        autoNameUpdatedAtUtcMillis: result.autoName != null
            ? DateTime.now().millisecondsSinceEpoch
            : null,
        autoNameSource: result.autoName != null ? 'nominatim' : null,
      );
    } catch (error) {
      _showSaveError(error);
      return;
    }
    _query.refresh();
  }

  Future<void> _openMerge(PlaceDuplicatePair pair) async {
    final result = await showPlacesMergeDialog(
      context: context,
      pair: pair,
      barrierLabel: PlacesBody.duplicatesMergeLabel,
    );
    if (result == null || !mounted) return;
    final keeper = resolveMergeKeep(pair.placeA, pair.placeB);
    try {
      // Tombstone first: the blocker counts live rows, so the keeper update
      // only passes once the other duplicate is gone. Sync carries both
      // writes to the other side.
      await _api.deleteInsightPlace(id: result.deleteId);
      await _api.saveInsightPlace(
        id: result.keepId,
        name: keeper.name,
        latitude: result.latitude,
        longitude: result.longitude,
        radiusM: result.radiusM,
        autoName: keeper.autoName,
        autoNameSource: keeper.autoNameSource,
      );
    } catch (error) {
      _showSaveError(error);
      return;
    }
    _query.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final capabilities = SurfaceCapabilities.of(context);
    final state = _query.state;
    return Scaffold(
      backgroundColor: AppThemeColors.of(context).canvas,
      appBar: AppBar(title: const Text('Consultar locais')),
      body: PlacesBody(
        state: state,
        capabilities: capabilities,
        isOptIn: true,
        onRetry: _query.refresh,
        onSelectNamed: _openNamed,
        onSelectCandidate: _openCandidate,
        onMergePlaces: _openMerge,
        enableSuggest: false,
      ),
    );
  }
}
