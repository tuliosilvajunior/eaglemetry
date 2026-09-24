import 'insight.dart';
import 'insight_place.dart';

/// A derived grouping of [InsightTrip] endpoints that match no [InsightPlace].
///
/// It exists only to suggest naming and is never stored. Grouped by 100 m
/// snapped cell ([kInsightVariantGridM]) and ordered by [PlaceRecurrence]
/// (origin + destination).
class CandidatePlace {
  const CandidatePlace({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.count,
    required this.tripCountAsOrigin,
    required this.tripCountAsDestination,
  });

  /// Cell signature `latCell,lonCell` derived via [variantSignature] snapping.
  final String id;

  /// Representative coordinate (mean of endpoints in this cell).
  final double latitude;
  final double longitude;

  /// Total recurrence: origin + destination.
  final int count;

  /// How many trips had this cell as origin.
  final int tripCountAsOrigin;

  /// How many trips had this cell as destination.
  final int tripCountAsDestination;

  @override
  String toString() =>
      'CandidatePlace(id: $id, lat: $latitude, lon: $longitude, count: $count, origin: $tripCountAsOrigin, dest: $tripCountAsDestination)';
}

/// Derives [CandidatePlace]s from closed [InsightTrip] endpoints backed by
/// [InsightTrip.startPoint]/[InsightTrip.endPoint] (i.e. TripSegment geometry,
/// never frames).
///
/// An endpoint that falls inside any [InsightPlace] (distance <= [InsightPlace.radiusM],
/// nearest wins via [placeContaining]) is excluded. Remaining endpoints are
/// grouped by 100 m snapped cell using [variantSignature]/[kInsightVariantGridM]
/// semantics — no duplicated entries. Result is ordered by total recurrence
/// descending (origin + destination).
List<CandidatePlace> deriveCandidatePlaces({
  required List<InsightTrip> trips,
  required List<InsightPlace> places,
}) {
  return deriveCandidatePlacesFromEndpoints(
    endpoints: [
      for (final trip in trips) (start: trip.startPoint, end: trip.endPoint),
    ],
    places: places,
  );
}

/// Same as [deriveCandidatePlaces] but accepts pre-extracted endpoints.
///
/// Accepts `List<({InsightPoint? start, InsightPoint? end})>` as required
/// by the spec — useful for testing without constructing full [InsightTrip]s.
List<CandidatePlace> deriveCandidatePlacesFromEndpoints({
  required List<({InsightPoint? start, InsightPoint? end})> endpoints,
  required List<InsightPlace> places,
}) {
  final Map<String, _MutableCandidate> byCell = {};

  for (final ep in endpoints) {
    final start = ep.start;
    if (start != null && placeContaining(start, places) == null) {
      final id = variantSignature([start]);
      if (id.isEmpty) continue;
      final acc = byCell.putIfAbsent(id, () => _MutableCandidate(id: id));
      acc.add(start, isOrigin: true);
    }
    final end = ep.end;
    if (end != null && placeContaining(end, places) == null) {
      final id = variantSignature([end]);
      if (id.isEmpty) continue;
      final acc = byCell.putIfAbsent(id, () => _MutableCandidate(id: id));
      acc.add(end, isOrigin: false);
    }
  }

  final result = [for (final acc in byCell.values) acc.toCandidate()];
  result.sort((a, b) {
    final cmp = b.count.compareTo(a.count);
    if (cmp != 0) return cmp;
    final cmpOrigin = b.tripCountAsOrigin.compareTo(a.tripCountAsOrigin);
    if (cmpOrigin != 0) return cmpOrigin;
    return a.id.compareTo(b.id);
  });
  return result;
}

class _MutableCandidate {
  _MutableCandidate({required this.id});

  final String id;
  double sumLat = 0;
  double sumLon = 0;
  int count = 0;
  int asOrigin = 0;
  int asDestination = 0;

  void add(InsightPoint point, {required bool isOrigin}) {
    sumLat += point.latitude;
    sumLon += point.longitude;
    count += 1;
    if (isOrigin) {
      asOrigin += 1;
    } else {
      asDestination += 1;
    }
  }

  CandidatePlace toCandidate() => CandidatePlace(
    id: id,
    latitude: count == 0 ? 0 : sumLat / count,
    longitude: count == 0 ? 0 : sumLon / count,
    count: count,
    tripCountAsOrigin: asOrigin,
    tripCountAsDestination: asDestination,
  );
}
