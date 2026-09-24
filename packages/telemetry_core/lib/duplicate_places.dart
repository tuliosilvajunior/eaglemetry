import 'dart:math' as math;

import 'insight_place.dart';

/// Near-duplicate rules for [InsightPlace]s.
///
/// Two named places that share a normalized name and sit within
/// [kPlaceDuplicateNearM] of each other are the same place recorded twice:
/// creation refuses the second row, and the list offers a manual merge.
/// The helpers here are pure so every implementation of
/// `saveInsightPlace` (car repository, phone source, mock) enforces the
/// same rule and shows the same words.
const kPlaceDuplicateNearM = 500.0;

/// Smallest radius a place may carry. Same bound the detail slider uses.
const kInsightPlaceMinRadiusM = 50.0;

/// Largest radius a place may carry. Same bound the detail slider uses.
const kInsightPlaceMaxRadiusM = 2000.0;

/// [name] with the outer whitespace gone and case folded.
String normalizedPlaceName(String name) => name.trim().toLowerCase();

/// The line a blocked save shows: the distance and the two ways out.
String duplicatePlaceMessage(String name, double distanceM) =>
    "Ja existe '${name.trim()}' a ${distanceM.round()} m — "
    'use raio maior ou mescle';

/// Raised by `saveInsightPlace` when the write would create a near
/// duplicate. [toString] is the line the UI shows, so a caller can print
/// the error as-is.
class DuplicatePlaceException implements Exception {
  DuplicatePlaceException({required this.name, required this.distanceM});

  final String name;
  final double distanceM;

  @override
  String toString() => duplicatePlaceMessage(name, distanceM);
}

/// One unordered pair of live places that read as the same place.
class PlaceDuplicatePair {
  const PlaceDuplicatePair({
    required this.placeA,
    required this.placeB,
    required this.distanceM,
  });

  /// The older of the two (or the lexicographically first id on a tie).
  final InsightPlace placeA;

  /// The newer of the two.
  final InsightPlace placeB;

  /// Distance between centers, metres.
  final double distanceM;
}

/// Every pair of [places] that reads as the same place: one normalized
/// **display** name (user name, falling back to autoName) inside
/// [kPlaceDuplicateNearM]. Comparing the display name is what makes two
/// companion-autonamed rows pair up even though both user names are still
/// empty. Rows with an empty display name never pair, and input order breaks
/// ties, so the result is stable for the same list.
List<PlaceDuplicatePair> findDuplicatePairs(List<InsightPlace> places) {
  final result = <PlaceDuplicatePair>[];
  for (var i = 0; i < places.length; i++) {
    for (var j = i + 1; j < places.length; j++) {
      final a = places[i];
      final b = places[j];
      final aName = normalizedPlaceName(a.displayName);
      final bName = normalizedPlaceName(b.displayName);
      if (aName != bName) continue;
      if (aName.isEmpty) continue;
      final d = insightDistanceM(
        a.latitude,
        a.longitude,
        b.latitude,
        b.longitude,
      );
      if (d >= kPlaceDuplicateNearM) continue;
      final keeper = resolveMergeKeep(a, b);
      result.add(
        keeper == a
            ? PlaceDuplicatePair(placeA: a, placeB: b, distanceM: d)
            : PlaceDuplicatePair(placeA: b, placeB: a, distanceM: d),
      );
    }
  }
  return result;
}

/// The live row whose write would land on top of an existing place, or
/// null when the write is safe.
///
/// [existing] holds the live places of this replica; the row being updated
/// is excluded by [id]. An unnamed candidate never collides: there is no
/// name to match against.
InsightPlace? findBlockingDuplicate({
  required String? id,
  required String name,
  required double latitude,
  required double longitude,
  required List<InsightPlace> existing,
}) {
  final candidate = normalizedPlaceName(name);
  if (candidate.isEmpty) return null;
  for (final place in existing) {
    if (id != null && id.isNotEmpty && place.id == id) continue;
    if (normalizedPlaceName(place.name) != candidate) continue;
    final d = insightDistanceM(
      latitude,
      longitude,
      place.latitude,
      place.longitude,
    );
    if (d < kPlaceDuplicateNearM) return place;
  }
  return null;
}

/// Center of the merged circle: the mean of the two centers.
InsightPoint proposeMergeCenter(InsightPlace placeA, InsightPlace placeB) =>
    InsightPoint(
      (placeA.latitude + placeB.latitude) / 2,
      (placeA.longitude + placeB.longitude) / 2,
    );

/// Radius of the merged circle: both circles stay covered, clamped to the
/// slider bounds.
double proposeMergeRadiusM(InsightPlace placeA, InsightPlace placeB) {
  final d = insightDistanceM(
    placeA.latitude,
    placeA.longitude,
    placeB.latitude,
    placeB.longitude,
  );
  final widest = math.max(placeA.radiusM, placeB.radiusM);
  final radius = d / 2 + widest;
  return radius
      .clamp(kInsightPlaceMinRadiusM, kInsightPlaceMaxRadiusM)
      .toDouble();
}

/// Which of the two rows survives a merge: the older creation stamp wins,
/// and a missing stamp or a tie falls back to the smaller id so the choice
/// lands the same way on every replica.
InsightPlace resolveMergeKeep(InsightPlace placeA, InsightPlace placeB) {
  final aCreated = placeA.createdAtUtcMillis;
  final bCreated = placeB.createdAtUtcMillis;
  if (aCreated != null && bCreated != null && aCreated != bCreated) {
    return aCreated < bCreated ? placeA : placeB;
  }
  return placeA.id.compareTo(placeB.id) <= 0 ? placeA : placeB;
}
