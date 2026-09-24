import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../settings/nominatim_opt_in_store.dart';
import '../sync/companion_database.dart';
import '../sync/local_telemetry_source.dart';
import '../sync/nominatim_auto_namer.dart';
import '../sync/nominatim_gateway.dart';

/// Companion wrapper for the shared [PlacesBody].
///
/// Mounts the same platform-agnostic body into the phone scaffold.
/// Handles data-reactive query, banner CTA to Settings, and navigation.
class PlacesScreen extends StatefulWidget {
  const PlacesScreen({
    required this.source,
    this.nominatimOptIn,
    this.onOpenSettings,
    super.key,
  });

  final HistoricalTelemetrySource source;
  final NominatimOptInStore? nominatimOptIn;
  final VoidCallback? onOpenSettings;

  @override
  State<PlacesScreen> createState() => _PlacesScreenState();
}

class _PlacesScreenState extends State<PlacesScreen> {
  late final TelemetryQuery<PlacesData> _query = TelemetryQuery(
    read: () async {
      final placesResult = await widget.source.insightPlaces();
      final tripsResult = await widget.source.insightTrips(null);
      return buildPlacesData(
        places: placesResult.places,
        trips: tripsResult.trips,
      );
    },
    interval: const Duration(seconds: 30),
    refreshOn: widget.source.annotationsChanged().where((c) => c.places),
    debugLabel: 'PlacesScreen.companion',
  );

  NominatimGateway? _gateway;
  bool _autoScheduled = false;
  final Set<String> _autoLoadingNamedIds = {};
  final Set<String> _autoLoadingCandidateIds = {};

  CompanionDatabase? get _companionDb {
    final src = widget.source;
    if (src is LocalTelemetrySource) return src.archive.database;
    return null;
  }

  NominatimGateway? get gateway {
    final db = _companionDb;
    if (db == null) return null;
    return _gateway ??= NominatimGateway(database: db);
  }

  Future<String?> _suggestFor(double lat, double lon) async {
    final isOptIn = widget.nominatimOptIn?.enabled ?? false;
    if (!isOptIn) return null;
    final g = gateway;
    if (g == null) return null;
    final result = await g.reverse(lat: lat, lon: lon, optIn: true);
    return result?.displayName;
  }

  @override
  void initState() {
    super.initState();
    _query.addListener(_onChanged);
    widget.nominatimOptIn?.addListener(_onChanged);
    _query.refresh();
  }

  @override
  void dispose() {
    _query.removeListener(_onChanged);
    widget.nominatimOptIn?.removeListener(_onChanged);
    _query.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
    _scheduleAutoName();
  }

  void _scheduleAutoName() {
    if (_autoScheduled) return;
    if (widget.nominatimOptIn?.enabled != true) return;
    final data = _query.state.value;
    if (data == null) return;
    final pendingNamed = data.named
        .where(
          (e) =>
              e.place.name.trim().isEmpty &&
              (e.place.autoName == null || e.place.autoName!.trim().isEmpty),
        )
        .toList();
    final pendingCandidates = data.candidates.toList();
    if (pendingNamed.isEmpty && pendingCandidates.isEmpty) return;
    final src = widget.source;
    if (src is! LocalTelemetrySource) return;
    if (gateway == null) return;
    // Already auto-loading these ids? Avoid re-queue.
    final alreadyLoading =
        _autoLoadingNamedIds.isNotEmpty || _autoLoadingCandidateIds.isNotEmpty;
    if (alreadyLoading) return;
    _autoScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _autoScheduled = false;
      if (!mounted) return;
      final src2 = widget.source;
      if (src2 is! LocalTelemetrySource) return;
      final g = gateway;
      final optIn = widget.nominatimOptIn;
      if (g == null || optIn == null || !optIn.enabled) return;
      // Clean historical same-cell twins first (e.g. an unnamed auto twin
      // left behind when the user named the other row).
      final cleaner = NominatimAutoNamer(
        source: src2,
        gateway: g,
        optInStore: optIn,
      );
      final deduped = await cleaner.dedupeSameCell(
        (await src2.insightPlaces()).places,
      );
      if (!mounted) return;
      var didWork = deduped > 0;
      if (deduped > 0) await _query.refresh();

      final data2 = _query.state.value;
      if (data2 == null) return;
      // Recompute pending to avoid race
      final stillPendingNamed = data2.named
          .where(
            (e) =>
                e.place.name.trim().isEmpty &&
                (e.place.autoName == null || e.place.autoName!.trim().isEmpty),
          )
          .toList();
      final stillPendingCandidates = data2.candidates.toList();
      if (stillPendingNamed.isEmpty && stillPendingCandidates.isEmpty) return;

      setState(() {
        _autoLoadingNamedIds
          ..clear()
          ..addAll(stillPendingNamed.map((e) => e.place.id));
        _autoLoadingCandidateIds
          ..clear()
          ..addAll(stillPendingCandidates.map((c) => c.id));
      });

      // Fill existing empty-name places
      for (final entry in stillPendingNamed) {
        if (!mounted || !(widget.nominatimOptIn?.enabled ?? false)) break;
        final result = await g.reverse(
          lat: entry.place.latitude,
          lon: entry.place.longitude,
          optIn: true,
        );
        if (!mounted) break;
        setState(() => _autoLoadingNamedIds.remove(entry.place.id));
        if (result == null || result.displayName.trim().isEmpty) continue;
        try {
          await src2.saveInsightPlace(
            id: entry.place.id,
            name: entry.place.name,
            latitude: entry.place.latitude,
            longitude: entry.place.longitude,
            radiusM: entry.place.radiusM,
            autoName: result.displayName,
            autoNameUpdatedAtUtcMillis: DateTime.now().millisecondsSinceEpoch,
            autoNameSource: 'nominatim',
          );
          didWork = true;
        } catch (_) {}
      }

      // Create from candidates, respecting radius exclusion
      var currentPlaces = (await src2.insightPlaces()).places;
      for (final cand in stillPendingCandidates) {
        if (!mounted || !(widget.nominatimOptIn?.enabled ?? false)) break;
        if (!_autoLoadingCandidateIds.contains(cand.id)) continue;
        final autoId = 'auto-${cand.id}';
        if (currentPlaces.any((p) => p.id == autoId)) {
          setState(() => _autoLoadingCandidateIds.remove(cand.id));
          continue;
        }
        // Skip if now covered by a place created earlier in this run
        final covered = currentPlaces.any(
          (p) =>
              insightDistanceM(
                cand.latitude,
                cand.longitude,
                p.latitude,
                p.longitude,
              ) <=
              p.radiusM,
        );
        if (covered) {
          setState(() => _autoLoadingCandidateIds.remove(cand.id));
          continue;
        }
        // Re-check candidate still exists (not already named by another run)
        final freshData = buildPlacesData(
          places: currentPlaces,
          trips: (await src2.insightTrips(null)).trips,
        );
        if (!freshData.candidates.any((c) => c.id == cand.id)) {
          setState(() => _autoLoadingCandidateIds.remove(cand.id));
          continue;
        }
        final result = await g.reverse(
          lat: cand.latitude,
          lon: cand.longitude,
          optIn: true,
        );
        if (!mounted) break;
        setState(() => _autoLoadingCandidateIds.remove(cand.id));
        if (result == null || result.displayName.trim().isEmpty) continue;
        try {
          final saved = await src2.saveInsightPlace(
            id: autoId,
            name: '',
            latitude: cand.latitude,
            longitude: cand.longitude,
            radiusM: kInsightPlaceRadiusM,
            autoName: result.displayName,
            autoNameUpdatedAtUtcMillis: DateTime.now().millisecondsSinceEpoch,
            autoNameSource: 'nominatim',
          );
          currentPlaces = [...currentPlaces, saved];
          didWork = true;
        } catch (_) {}
      }

      if (!mounted) return;
      setState(() {
        _autoLoadingNamedIds.clear();
        _autoLoadingCandidateIds.clear();
      });
      if (didWork) _query.refresh();
    });
  }

  /// The line a refused write shows. A near duplicate travels as its own
  /// message; other bridge failures keep their code.
  String _saveErrorMessage(Object error) => switch (error) {
    DuplicatePlaceException() => error.toString(),
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

  /// A refused write that names an existing near-duplicate offers the merge
  /// right where the refusal happened: the snackbar action opens the same
  /// merge dialog used by the banner, against the blocker row.
  ///
  /// [attemptName]/[latitude]/[longitude]/[radiusM] describe what the user
  /// tried to save; the blocker is re-derived from the live table so the
  /// pair matches what the banner would show.
  void _showSaveErrorWithMerge(
    Object error, {
    required String attemptName,
    required double latitude,
    required double longitude,
    required double radiusM,
  }) {
    if (error is! DuplicatePlaceException) {
      _showSaveError(error);
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        key: const Key('places-save-error-snackbar'),
        duration: const Duration(seconds: 6),
        content: Text(_saveErrorMessage(error)),
        action: SnackBarAction(
          key: const Key('places-save-error-merge'),
          label: PlacesBody.duplicatesMergeLabel,
          onPressed: () => _mergeRefusal(error, latitude, longitude, radiusM),
        ),
      ),
    );
  }

  Future<void> _mergeRefusal(
    DuplicatePlaceException error,
    double latitude,
    double longitude,
    double radiusM,
  ) async {
    final data = _query.state.value;
    if (data == null || !mounted) return;
    final allPlaces = data.named.map((e) => e.place).toList();
    final blocker = findBlockingDuplicate(
      id: null,
      name: error.name,
      latitude: latitude,
      longitude: longitude,
      existing: allPlaces,
    );
    if (blocker == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final attempt = InsightPlace(
      // Never a stored row: it stands in for what the user tried to save,
      // purely to drive the merge dialog's labels and proposal.
      id: 'merge-attempt',
      name: error.name,
      latitude: latitude,
      longitude: longitude,
      radiusM: radiusM,
      createdAtUtcMillis: now,
    );
    final keeper = resolveMergeKeep(blocker, attempt);
    final pair = keeper == blocker
        ? PlaceDuplicatePair(
            placeA: blocker,
            placeB: attempt,
            distanceM: error.distanceM,
          )
        : PlaceDuplicatePair(
            placeA: attempt,
            placeB: blocker,
            distanceM: error.distanceM,
          );
    final result = await showPlacesMergeDialog(
      context: context,
      pair: pair,
      barrierLabel: PlacesBody.duplicatesMergeLabel,
    );
    if (result == null || !mounted) return;
    // The attempt was never a real row: only the keeper update runs. The
    // existing place absorbs the proposed center and radius.
    try {
      await widget.source.saveInsightPlace(
        id: result.keepId,
        name: blocker.name,
        latitude: result.latitude,
        longitude: result.longitude,
        radiusM: result.radiusM,
        autoName: blocker.autoName,
        autoNameUpdatedAtUtcMillis: null,
        autoNameSource: blocker.autoNameSource,
      );
    } catch (e) {
      _showSaveError(e);
      return;
    }
    _query.refresh();
  }

  void _handleOpenSettings() {
    final callback = widget.onOpenSettings;
    if (callback != null) {
      Navigator.of(context).pop();
      // Run after pop frame so shell tab switch is visible.
      WidgetsBinding.instance.addPostFrameCallback((_) => callback());
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _openNamed(NamedPlaceEntry entry) async {
    final data = _query.state.value;
    final allPlaces = data?.named.map((e) => e.place).toList() ?? [];
    final otherPlaces = allPlaces.where((p) => p.id != entry.place.id).toList();
    final isOptIn = widget.nominatimOptIn?.enabled ?? false;
    final enableSuggest =
        isOptIn &&
        (entry.place.autoName == null || entry.place.autoName!.trim().isEmpty);
    final result = await showPlaceDetailDialog(
      context: context,
      latitude: entry.place.latitude,
      longitude: entry.place.longitude,
      placeId: entry.place.id,
      initialName: entry.place.name,
      initialAutoName: entry.place.autoName,
      initialRadiusM: entry.place.radiusM,
      otherPlaces: otherPlaces,
      title: 'Detalhe do local',
      hintText: 'Nome',
      saveLabel: 'Salvar',
      cancelLabel: 'Cancelar',
      barrierLabel: 'Cancelar',
      enableSuggest: enableSuggest,
      onSuggest: enableSuggest
          ? () => _suggestFor(entry.place.latitude, entry.place.longitude)
          : null,
      suggestManualPrompt: NominatimGateway.kManualPrompt,
    );
    if (result == null || !mounted) return;
    try {
      await widget.source.saveInsightPlace(
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
      _showSaveErrorWithMerge(
        error,
        attemptName: result.name,
        latitude: entry.place.latitude,
        longitude: entry.place.longitude,
        radiusM: result.radiusM,
      );
      return;
    }
    _query.refresh();
  }

  Future<void> _openCandidate(CandidatePlace candidate) async {
    final data = _query.state.value;
    final allPlaces = data?.named.map((e) => e.place).toList() ?? [];
    final isOptIn = widget.nominatimOptIn?.enabled ?? false;
    // If an existing place already covers this candidate (an auto place from
    // a previous run, same cell), edit that row instead of creating a twin
    // at the same spot.
    final autoId = NominatimAutoNamer.autoIdFor(
      NominatimGateway.cellKeyFor(candidate.latitude, candidate.longitude),
    );
    InsightPlace? existing;
    for (final p in allPlaces) {
      if (p.id == autoId ||
          insightDistanceM(
                candidate.latitude,
                candidate.longitude,
                p.latitude,
                p.longitude,
              ) <=
              p.radiusM) {
        existing = p;
        break;
      }
    }
    final result = await showPlaceDetailDialog(
      context: context,
      latitude: existing?.latitude ?? candidate.latitude,
      longitude: existing?.longitude ?? candidate.longitude,
      placeId: existing?.id,
      initialName: existing?.name,
      initialAutoName: existing?.autoName,
      initialRadiusM: existing?.radiusM ?? kInsightPlaceRadiusM,
      otherPlaces: existing == null
          ? allPlaces
          : allPlaces.where((p) => p.id != existing!.id).toList(),
      title: 'Detalhe do local',
      hintText: 'Nome',
      saveLabel: 'Salvar',
      cancelLabel: 'Cancelar',
      barrierLabel: 'Cancelar',
      enableSuggest: isOptIn && (existing?.autoName?.trim().isEmpty ?? true),
      onSuggest: isOptIn
          ? () => _suggestFor(
              existing?.latitude ?? candidate.latitude,
              existing?.longitude ?? candidate.longitude,
            )
          : null,
      suggestManualPrompt: NominatimGateway.kManualPrompt,
    );
    if (result == null || !mounted) return;
    try {
      await widget.source.saveInsightPlace(
        id: existing?.id,
        name: result.name,
        latitude: existing?.latitude ?? candidate.latitude,
        longitude: existing?.longitude ?? candidate.longitude,
        radiusM: result.radiusM,
        autoName: result.autoName ?? existing?.autoName,
        autoNameUpdatedAtUtcMillis: result.autoName != null
            ? DateTime.now().millisecondsSinceEpoch
            : null,
        autoNameSource: result.autoName != null ? 'nominatim' : null,
      );
    } catch (error) {
      _showSaveErrorWithMerge(
        error,
        attemptName: result.name,
        latitude: existing?.latitude ?? candidate.latitude,
        longitude: existing?.longitude ?? candidate.longitude,
        radiusM: result.radiusM,
      );
      return;
    }
    _query.refresh();
  }

  Future<void> _openNamedWithSuggestion(
    NamedPlaceEntry entry,
    String suggestion,
  ) async {
    final data = _query.state.value;
    final allPlaces = data?.named.map((e) => e.place).toList() ?? [];
    final otherPlaces = allPlaces.where((p) => p.id != entry.place.id).toList();
    final result = await showPlaceDetailDialog(
      context: context,
      latitude: entry.place.latitude,
      longitude: entry.place.longitude,
      placeId: entry.place.id,
      initialName: entry.place.name,
      initialAutoName: suggestion,
      initialRadiusM: entry.place.radiusM,
      otherPlaces: otherPlaces,
      title: 'Detalhe do local',
      hintText: 'Nome',
      saveLabel: 'Salvar',
      cancelLabel: 'Cancelar',
      barrierLabel: 'Cancelar',
      enableSuggest: false,
      suggestManualPrompt: NominatimGateway.kManualPrompt,
    );
    // If user saves with empty name, fallback will use suggestion via result.name empty check.
    // The dialog already pre-filled name field if it was empty; for named entry we kept original name,
    // so we need to ensure autoName is persisted even if name not changed.
    String? effectiveName = result?.name;
    String? effectiveAuto = result?.autoName ?? suggestion;
    // If dialog was cancelled, treat as direct save of suggestion? For row suggest flow, spec says
    // aceitar sugestao preenche campo editavel antes de salvar — so we opened dialog pre-filled,
    // user must still press Salvar. If they cancelled, do nothing.
    if (result == null || !mounted) return;
    // If user left name empty but we have suggestion, use suggestion as fallback display via autoName.
    // Save with result.name (could be empty) and autoName = effectiveAuto.
    try {
      await widget.source.saveInsightPlace(
        id: entry.place.id,
        name: effectiveName ?? entry.place.name,
        latitude: entry.place.latitude,
        longitude: entry.place.longitude,
        radiusM: result.radiusM,
        autoName: effectiveAuto,
        autoNameUpdatedAtUtcMillis: DateTime.now().millisecondsSinceEpoch,
        autoNameSource: 'nominatim',
      );
    } catch (error) {
      _showSaveErrorWithMerge(
        error,
        attemptName: effectiveName ?? entry.place.name,
        latitude: entry.place.latitude,
        longitude: entry.place.longitude,
        radiusM: result.radiusM,
      );
      return;
    }
    _query.refresh();
  }

  Future<void> _openCandidateWithSuggestion(
    CandidatePlace candidate,
    String suggestion,
  ) async {
    final data = _query.state.value;
    final allPlaces = data?.named.map((e) => e.place).toList() ?? [];
    final result = await showPlaceDetailDialog(
      context: context,
      latitude: candidate.latitude,
      longitude: candidate.longitude,
      placeId: null,
      initialName: suggestion,
      initialAutoName: suggestion,
      initialRadiusM: kInsightPlaceRadiusM,
      otherPlaces: allPlaces,
      title: 'Detalhe do local',
      hintText: 'Nome',
      saveLabel: 'Salvar',
      cancelLabel: 'Cancelar',
      barrierLabel: 'Cancelar',
      enableSuggest: false,
      suggestManualPrompt: NominatimGateway.kManualPrompt,
    );
    if (result == null || !mounted) return;
    try {
      await widget.source.saveInsightPlace(
        name: result.name,
        latitude: candidate.latitude,
        longitude: candidate.longitude,
        radiusM: result.radiusM,
        autoName: result.autoName ?? suggestion,
        autoNameUpdatedAtUtcMillis: DateTime.now().millisecondsSinceEpoch,
        autoNameSource: 'nominatim',
      );
    } catch (error) {
      _showSaveErrorWithMerge(
        error,
        attemptName: result.name,
        latitude: candidate.latitude,
        longitude: candidate.longitude,
        radiusM: result.radiusM,
      );
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
      // writes to the car.
      await widget.source.deleteInsightPlace(result.deleteId);
      await widget.source.saveInsightPlace(
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
    final colors = AppThemeColors.of(context);
    final isOptIn = widget.nominatimOptIn?.enabled ?? false;
    final enableSuggest = isOptIn && gateway != null;
    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        title: const Text('Consultar locais'),
        backgroundColor: colors.canvas,
        elevation: 0,
      ),
      body: PlacesBody(
        state: _query.state,
        capabilities: capabilities,
        isOptIn: isOptIn,
        onOpenSettings: _handleOpenSettings,
        onRetry: _query.refresh,
        onSelectNamed: _openNamed,
        onSelectCandidate: _openCandidate,
        onMergePlaces: _openMerge,
        enableSuggest: enableSuggest,
        onSuggest: enableSuggest ? _suggestFor : null,
        onSuggestNamed: enableSuggest ? _openNamedWithSuggestion : null,
        onSuggestCandidate: enableSuggest ? _openCandidateWithSuggestion : null,
        suggestManualPrompt: NominatimGateway.kManualPrompt,
        autoLoadingNamedIds: _autoLoadingNamedIds,
        autoLoadingCandidateIds: _autoLoadingCandidateIds,
      ),
    );
  }
}
