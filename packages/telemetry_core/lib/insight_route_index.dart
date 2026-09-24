import 'insight.dart';
import 'insight_place.dart';

/// A named route between two [InsightPlace]s with all trips recorded on it.
class NamedRoute {
  const NamedRoute({required this.from, required this.to, required this.trips});

  final InsightPlace from;
  final InsightPlace to;
  final List<InsightTrip> trips;

  int get count => trips.length;

  /// The trips that would enter a comparison: the same gate the statistics
  /// apply. A route card counts these to decide whether it may claim anything
  /// at all.
  List<InsightTrip> get measuredTrips => [
    for (final trip in trips)
      if (insightTripComparable(trip)) trip,
  ];

  int get measuredCount => measuredTrips.length;

  /// Whether this route holds enough measured trips for comparisons to run.
  bool get isComparable => measuredCount >= kInsightMinReferenceTrips;

  /// How many more measured trips the route needs, or zero when comparable.
  int get missingTrips {
    final missing = kInsightMinReferenceTrips - measuredCount;
    return missing > 0 ? missing : 0;
  }

  /// Every measured trip ordered most efficient first: Wh/km ascending. This
  /// is the ranking a driver asks for — which run of this route was the best —
  /// and it makes no statistical claim on its own.
  List<(InsightTrip trip, double whPerKm)> get rankingByEfficiency {
    final ranked = <(InsightTrip trip, double whPerKm)>[
      for (final trip in measuredTrips)
        if (trip.distanceKm != null && trip.distanceKm! > 0)
          (trip, trip.canPackWh! / trip.distanceKm!),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    return ranked;
  }

  double? get averageDistanceKm {
    final distances = [
      for (final t in trips)
        if (t.distanceKm != null && t.distanceKm! > 0) t.distanceKm!,
    ];
    if (distances.isEmpty) return null;
    return distances.reduce((a, b) => a + b) / distances.length;
  }

  double? get averageWhPerKm {
    var totalWh = 0.0;
    var totalKm = 0.0;
    for (final t in trips) {
      if (t.canPackWh != null && t.distanceKm != null && t.distanceKm! > 0) {
        totalWh += t.canPackWh!;
        totalKm += t.distanceKm!;
      }
    }
    if (totalKm <= 0) return null;
    return totalWh / totalKm;
  }
}

/// Index of named routes and their variants built once from trips and places.
class InsightRouteIndex {
  const InsightRouteIndex._({
    required this.routes,
    required this._routeByTripId,
    required this._variantSignatureByTripId,
  });

  factory InsightRouteIndex.build(
    List<InsightTrip> trips,
    List<InsightPlace> places,
  ) {
    if (trips.isEmpty || places.isEmpty) {
      return const InsightRouteIndex._(
        routes: [],
        routeByTripId: {},
        variantSignatureByTripId: {},
      );
    }

    final groups =
        <
          (String, String),
          ({InsightPlace from, InsightPlace to, List<InsightTrip> trips})
        >{};
    final variantSignatureByTripId = <String, String>{};

    for (final trip in trips) {
      final sig = variantSignature(parseInsightPath(trip.path));
      if (sig.isNotEmpty) {
        variantSignatureByTripId[trip.id] = sig;
      }

      final start = trip.startPoint;
      final end = trip.endPoint;
      if (start == null || end == null) continue;

      final from = placeContaining(start, places);
      final to = placeContaining(end, places);
      if (from == null || to == null || from.id == to.id) continue;

      final key = (from.id, to.id);
      final existing = groups[key];
      if (existing != null) {
        existing.trips.add(trip);
      } else {
        groups[key] = (from: from, to: to, trips: [trip]);
      }
    }

    final routes = <NamedRoute>[];
    final routeByTripId = <String, NamedRoute>{};

    for (final entry in groups.values) {
      final route = NamedRoute(
        from: entry.from,
        to: entry.to,
        trips: List<InsightTrip>.unmodifiable(entry.trips),
      );
      routes.add(route);
      for (final trip in entry.trips) {
        routeByTripId[trip.id] = route;
      }
    }

    routes.sort((a, b) => b.count.compareTo(a.count));

    return InsightRouteIndex._(
      routes: List<NamedRoute>.unmodifiable(routes),
      routeByTripId: routeByTripId,
      variantSignatureByTripId: variantSignatureByTripId,
    );
  }

  /// Ordered by trip count descending.
  final List<NamedRoute> routes;
  final Map<String, NamedRoute> _routeByTripId;
  final Map<String, String> _variantSignatureByTripId;

  /// The route [tripId] belongs to, or null if the trip is not on a named route.
  NamedRoute? routeOf(String tripId) => _routeByTripId[tripId];

  /// Variant signature of [tripId], or empty string if absent/unrecorded.
  String variantSignatureOf(String tripId) =>
      _variantSignatureByTripId[tripId] ?? '';

  /// The [InsightRouteMatch] for [tripId], or null if the trip is not on a named route.
  InsightRouteMatch? matchOf(String tripId) {
    final route = routeOf(tripId);
    if (route == null) return null;
    final sig = variantSignatureOf(tripId);
    final variantCount = route.trips
        .map((t) => variantSignatureOf(t.id))
        .where((s) => s.isNotEmpty)
        .toSet()
        .length;
    return InsightRouteMatch(
      from: route.from,
      to: route.to,
      variantSignature: sig,
      tripCount: route.count,
      variantCount: variantCount,
    );
  }
}
