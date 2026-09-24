import 'package:telemetry_core/telemetry_core.dart';

import '../settings/nominatim_opt_in_store.dart';
import 'local_telemetry_source.dart';
import 'nominatim_gateway.dart';

/// Companion-only auto-namer.
///
/// Runs as early as possible, without manual taps:
///
/// - Fills `autoName` for existing [InsightPlace] where `name` is empty and
///   `autoName` is empty (keeps `name` empty; display falls back to
///   `autoName`).
/// - Creates a stored [InsightPlace] for each [CandidatePlace] derived from
///   trip endpoints, with `name=''` and `autoName` = short address
///   (rua + número). Id is deterministic `auto-<cellKey>` so two runs on the
///   same cell converge to one row instead of twins.
///
/// Respects:
/// - Opt-in gate: no request when disabled.
/// - Cache per 100 m cell (via [NominatimGateway]).
/// - Throttle 15 req/min (4 s) (via [NominatimGateway]).
/// - Never overwrites a non-empty `name` or a non-empty `autoName`.
/// - Never runs on car (companion only).
class NominatimAutoNamer {
  NominatimAutoNamer({
    required this.source,
    required this.gateway,
    required this.optInStore,
  });

  final LocalTelemetrySource source;
  final NominatimGateway gateway;
  final NominatimOptInStore optInStore;

  bool _running = false;

  /// Deterministic id for the auto place of one 100 m cell.
  static String autoIdFor(String cellKey) => 'auto-$cellKey';

  /// Deletes redundant places that share a 100 m cell with another place,
  /// when at least one of the two has an empty name. Two named places are
  /// never touched: that pair belongs to the manual merge flow.
  ///
  /// This cleans historical twins left by older runs (random ids), including
  /// the case where the user just named an auto place and an unnamed twin
  /// from a racing run stayed behind. Returns how many rows were removed.
  Future<int> dedupeSameCell(List<InsightPlace> places) async {
    var removed = 0;
    final Map<String, List<InsightPlace>> byCell = {};
    for (final p in places) {
      byCell
          .putIfAbsent(
            NominatimGateway.cellKeyFor(p.latitude, p.longitude),
            () => [],
          )
          .add(p);
    }
    for (final group in byCell.values) {
      if (group.length <= 1) continue;
      // Prefer the named row, then the earliest created.
      group.sort((a, b) {
        final aNamed = a.name.trim().isNotEmpty ? 0 : 1;
        final bNamed = b.name.trim().isNotEmpty ? 0 : 1;
        if (aNamed != bNamed) return aNamed.compareTo(bNamed);
        final aCreated = a.createdAtUtcMillis ?? 0;
        final bCreated = b.createdAtUtcMillis ?? 0;
        if (aCreated != bCreated) return aCreated.compareTo(bCreated);
        return a.id.compareTo(b.id);
      });
      final keep = group.first;
      if (keep.name.trim().isEmpty && group.every((p) => p.id == keep.id)) {
        continue;
      }
      for (final dup in group.skip(1)) {
        final dist = insightDistanceM(
          keep.latitude,
          keep.longitude,
          dup.latitude,
          dup.longitude,
        );
        // Same cell but verify overlap explicitly before deleting.
        if (dist > keep.radiusM && dist > dup.radiusM) continue;
        final keepEmpty = keep.name.trim().isEmpty;
        final dupEmpty = dup.name.trim().isEmpty;
        if (!keepEmpty && !dupEmpty) continue;
        try {
          await source.deleteInsightPlace(dup.id);
          removed++;
        } catch (_) {}
      }
    }
    return removed;
  }

  /// Runs one full pass. Returns a report of what was done.
  ///
  /// Sequential, throttled, cache-aware. Call repeatedly — it is idempotent
  /// for already-named cells due to the gateway cache and the deterministic
  /// per-cell id.
  Future<AutoNameReport> runOnce() async {
    if (_running) return const AutoNameReport(skipped: true);
    _running = true;
    try {
      final isOptIn = optInStore.enabled;
      if (!isOptIn) return const AutoNameReport(optInDisabled: true);

      var placesResult = await source.insightPlaces();
      var tripsResult = await source.insightTrips(null);
      var data = buildPlacesData(
        places: placesResult.places,
        trips: tripsResult.trips,
      );

      var filledExisting = 0;
      var createdFromCandidates = 0;
      var failed = 0;
      final deduped = await dedupeSameCell(placesResult.places);
      if (deduped > 0) {
        // Re-read so pending lists reflect the cleaned table.
        placesResult = await source.insightPlaces();
        tripsResult = await source.insightTrips(null);
        data = buildPlacesData(
          places: placesResult.places,
          trips: tripsResult.trips,
        );
      }

      // --- Existing places with empty name and empty autoName ---
      for (final entry in data.named) {
        if (entry.place.name.trim().isNotEmpty) continue;
        if (entry.place.autoName != null &&
            entry.place.autoName!.trim().isNotEmpty) {
          continue;
        }
        final result = await gateway.reverse(
          lat: entry.place.latitude,
          lon: entry.place.longitude,
          optIn: true,
        );
        if (result == null || result.displayName.trim().isEmpty) {
          failed++;
          continue;
        }
        try {
          await source.saveInsightPlace(
            id: entry.place.id,
            name: entry.place.name,
            latitude: entry.place.latitude,
            longitude: entry.place.longitude,
            radiusM: entry.place.radiusM,
            autoName: result.displayName,
            autoNameUpdatedAtUtcMillis: DateTime.now().millisecondsSinceEpoch,
            autoNameSource: 'nominatim',
          );
          filledExisting++;
        } catch (_) {
          failed++;
        }
      }

      // Keep a mutable list for radius/id exclusion so a candidate covered by
      // a place created earlier in this pass is skipped.
      final currentPlaces = <InsightPlace>[...placesResult.places];

      for (final candidate in data.candidates) {
        final autoId = autoIdFor(candidate.id);
        if (currentPlaces.any((p) => p.id == autoId)) continue;
        // Skip when any existing or newly-created place already covers it.
        final covered = currentPlaces.any(
          (p) =>
              insightDistanceM(
                candidate.latitude,
                candidate.longitude,
                p.latitude,
                p.longitude,
              ) <=
              p.radiusM,
        );
        if (covered) continue;

        final result = await gateway.reverse(
          lat: candidate.latitude,
          lon: candidate.longitude,
          optIn: true,
        );
        if (result == null || result.displayName.trim().isEmpty) {
          failed++;
          continue;
        }
        try {
          final saved = await source.saveInsightPlace(
            id: autoId,
            name: '',
            latitude: candidate.latitude,
            longitude: candidate.longitude,
            radiusM: kInsightPlaceRadiusM,
            autoName: result.displayName,
            autoNameUpdatedAtUtcMillis: DateTime.now().millisecondsSinceEpoch,
            autoNameSource: 'nominatim',
          );
          currentPlaces.add(saved);
          createdFromCandidates++;
        } catch (_) {
          failed++;
        }
      }

      return AutoNameReport(
        filledExisting: filledExisting,
        createdFromCandidates: createdFromCandidates,
        failed: failed,
        deduped: deduped,
      );
    } finally {
      _running = false;
    }
  }
}

class AutoNameReport {
  const AutoNameReport({
    this.filledExisting = 0,
    this.createdFromCandidates = 0,
    this.failed = 0,
    this.deduped = 0,
    this.optInDisabled = false,
    this.skipped = false,
  });

  final int filledExisting;
  final int createdFromCandidates;
  final int failed;

  /// Redundant same-cell rows removed before naming.
  final int deduped;
  final bool optInDisabled;
  final bool skipped;

  bool get didWork =>
      filledExisting > 0 || createdFromCandidates > 0 || deduped > 0;
}
