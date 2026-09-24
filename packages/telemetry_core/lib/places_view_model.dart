import 'candidate_places.dart';
import 'duplicate_places.dart';
import 'insight.dart';
import 'insight_place.dart';

/// One named place with its [PlaceRecurrence] count.
///
/// Recurrence = origin + destination appearances across [InsightTrip]s.
class NamedPlaceEntry {
  const NamedPlaceEntry({required this.place, required this.count});

  final InsightPlace place;
  final int count;

  String get displayName {
    final trimmed = place.name.trim();
    if (trimmed.isNotEmpty) return place.name;
    final auto = place.autoName?.trim();
    if (auto != null && auto.isNotEmpty) return place.autoName!;
    return '';
  }
}

/// What the "Consultar locais" screen shows.
///
/// Both lists are ordered by recurrence descending. [duplicatePairs] holds
/// the near-duplicate pairs the merge banner offers to fix.
class PlacesData {
  const PlacesData({
    required this.named,
    required this.candidates,
    this.duplicatePairs = const [],
  });

  final List<NamedPlaceEntry> named;
  final List<CandidatePlace> candidates;
  final List<PlaceDuplicatePair> duplicatePairs;

  bool get isEmpty => named.isEmpty && candidates.isEmpty;
  bool get hasNoGpsData => isEmpty;
}

/// Computes [PlacesData] from raw [places] and [trips].
///
/// - Named recurrence counts trips where the place contains start or end.
/// - Candidates are derived via [deriveCandidatePlaces].
/// Both lists are sorted by total count descending.
PlacesData buildPlacesData({
  required List<InsightPlace> places,
  required List<InsightTrip> trips,
}) {
  final candidates = deriveCandidatePlaces(trips: trips, places: places);

  final Map<String, int> counts = {for (final p in places) p.id: 0};

  for (final trip in trips) {
    final start = trip.startPoint;
    final end = trip.endPoint;
    InsightPlace? startPlace;
    InsightPlace? endPlace;
    if (start != null) {
      startPlace = placeContaining(start, places);
      if (startPlace != null) {
        counts[startPlace.id] = (counts[startPlace.id] ?? 0) + 1;
      }
    }
    if (end != null) {
      endPlace = placeContaining(end, places);
      if (endPlace != null) {
        counts[endPlace.id] = (counts[endPlace.id] ?? 0) + 1;
      }
    }
  }

  final named = <NamedPlaceEntry>[
    for (final place in places)
      NamedPlaceEntry(place: place, count: counts[place.id] ?? 0),
  ];

  named.sort((a, b) {
    final cmp = b.count.compareTo(a.count);
    if (cmp != 0) return cmp;
    // Tie-breaker: name asc for determinism
    final aName = a.place.displayName.toLowerCase();
    final bName = b.place.displayName.toLowerCase();
    final nameCmp = aName.compareTo(bName);
    if (nameCmp != 0) return nameCmp;
    return a.place.id.compareTo(b.place.id);
  });

  return PlacesData(
    named: List.unmodifiable(named),
    candidates: candidates,
    duplicatePairs: findDuplicatePairs(places),
  );
}

/// Helper for ordered derivation tests: returns named counts map.
Map<String, int> computeNamedPlaceRecurrence({
  required List<InsightPlace> places,
  required List<InsightTrip> trips,
}) {
  final counts = <String, int>{for (final p in places) p.id: 0};
  for (final trip in trips) {
    final start = trip.startPoint;
    final end = trip.endPoint;
    if (start != null) {
      final p = placeContaining(start, places);
      if (p != null) counts[p.id] = (counts[p.id] ?? 0) + 1;
    }
    if (end != null) {
      final p = placeContaining(end, places);
      if (p != null) counts[p.id] = (counts[p.id] ?? 0) + 1;
    }
  }
  return counts;
}
