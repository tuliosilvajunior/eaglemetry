import 'insight_place.dart';
import 'insight_route_index.dart';

/// A pair of named places shown as one card, with every recorded direction
/// under it.
///
/// `NamedRoute` is an ordered pair, so `Casa → Spazio` and `Spazio → Casa`
/// are two routes. A driver experiences them as one commute, so the list
/// groups them: the pair is unordered, and each direction keeps its own
/// ranking and its own comparison gate.
class RouteGroup {
  const RouteGroup({
    required this.a,
    required this.b,
    required this.directions,
  });

  final InsightPlace a;
  final InsightPlace b;

  /// The routes recorded on this pair, each one direction. Ordered by trip
  /// count descending so the busier direction leads.
  final List<NamedRoute> directions;

  int get totalTrips =>
      directions.fold<int>(0, (sum, route) => sum + route.count);

  bool get hasBothDirections => directions.length >= 2;
}

/// Groups [routes] by unordered place pair, keeping each direction separate.
///
/// The pair key is the two place ids in sorted order, so `A → B` and `B → A`
/// land in the same group. Directions keep their own identity and their own
/// ranking.
List<RouteGroup> groupRoutesByPair(List<NamedRoute> routes) {
  final groups = <(String, String), List<NamedRoute>>{};

  for (final route in routes) {
    final low = route.from.id.compareTo(route.to.id) <= 0
        ? route.from
        : route.to;
    final high = identical(low, route.from) ? route.to : route.from;
    final key = (low.id, high.id);
    (groups[key] ??= <NamedRoute>[]).add(route);
  }

  final result = <RouteGroup>[];
  for (final entry in groups.entries) {
    final (placeA, placeB) = _placesFor(entry.key, routes);
    final directions = [...entry.value]
      ..sort((x, y) => y.count.compareTo(x.count));
    result.add(RouteGroup(a: placeA, b: placeB, directions: directions));
  }

  result.sort((x, y) => y.totalTrips.compareTo(x.totalTrips));
  return result;
}

/// Resolves the two [InsightPlace]s of a pair key from any direction route.
(InsightPlace, InsightPlace) _placesFor(
  (String, String) key,
  List<NamedRoute> routes,
) {
  for (final route in routes) {
    if (route.from.id == key.$1 && route.to.id == key.$2) {
      return (route.from, route.to);
    }
    if (route.from.id == key.$2 && route.to.id == key.$1) {
      return (route.to, route.from);
    }
  }
  throw StateError('route group key has no route');
}
