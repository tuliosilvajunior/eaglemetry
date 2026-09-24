import 'dart:math' as math;

/// One user-named place. The app never invents these.
///
/// [name] is the user's label. When empty the display falls back to
/// [autoName], which the companion may have suggested via Nominatim.
class InsightPlace {
  const InsightPlace({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    this.radiusM = kInsightPlaceRadiusM,
    this.createdAtUtcMillis,
    this.autoName,
    this.autoNameUpdatedAtUtcMillis,
    this.autoNameSource,
  });

  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final double radiusM;

  /// Creation stamp when the source carries one. The merge keeps the older
  /// row; a source without it leaves null and the tie-break is the id.
  final int? createdAtUtcMillis;

  /// Suggested name from reverse geocode. Companion only, nullable.
  final String? autoName;

  /// When [autoName] was last set.
  final int? autoNameUpdatedAtUtcMillis;

  /// Origin of [autoName], e.g. "nominatim".
  final String? autoNameSource;

  /// What the UI shows: the user's [name] wins, otherwise [autoName].
  String get displayName => name.trim().isNotEmpty ? name : (autoName ?? name);

  /// Effective name for matcher display, same as [displayName] but may be empty
  /// when neither is set.
  String get effectiveName => displayName;
}

/// A coordinate the grouping engine may see. Always from persisted segments,
/// never from frames.
class InsightPoint {
  const InsightPoint(this.latitude, this.longitude);

  final double latitude;
  final double longitude;
}

/// One ordered pair of named places, and the variant the path belongs to.
class InsightRouteMatch {
  const InsightRouteMatch({
    required this.from,
    required this.to,
    required this.variantSignature,
    required this.tripCount,
    required this.variantCount,
  });

  final InsightPlace from;
  final InsightPlace to;
  final String variantSignature;
  final int tripCount;
  final int variantCount;
}

/// Starting radius. A product value, not a measurement from the car.
const kInsightPlaceRadiusM = 150.0;

/// Grid used to tell two ways between the same places apart. 100 m is larger
/// than the GPS step and smaller than the place radius.
const kInsightVariantGridM = 100.0;

const _earthRadiusM = 6371000.0;
const _metersPerDegree = 111320.0;

/// Great-circle distance in metres.
double insightDistanceM(
  double latitudeA,
  double longitudeA,
  double latitudeB,
  double longitudeB,
) {
  final lat1 = latitudeA * math.pi / 180;
  final lat2 = latitudeB * math.pi / 180;
  final dLat = (latitudeB - latitudeA) * math.pi / 180;
  final dLon = (longitudeB - longitudeA) * math.pi / 180;
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1) * math.cos(lat2) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * _earthRadiusM * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

/// The nearest place that contains [point], or null.
InsightPlace? placeContaining(InsightPoint point, List<InsightPlace> places) {
  InsightPlace? best;
  var bestDistance = double.infinity;
  for (final place in places) {
    final distance = insightDistanceM(
      point.latitude,
      point.longitude,
      place.latitude,
      place.longitude,
    );
    if (distance > place.radiusM) continue;
    if (distance < bestDistance) {
      best = place;
      bestDistance = distance;
    }
  }
  return best;
}

/// The name of the place containing a coordinate, or null when none does.
///
/// The one reduction a session read makes of the place table: a session
/// carries its start coordinate, and a list of places is a handful of rows,
/// so the match costs a bounding-box walk per session and no join. A place
/// is never stamped on the session itself.
String? placeNameAt({
  required double? latitude,
  required double? longitude,
  required List<InsightPlace> places,
}) {
  if (latitude == null || longitude == null || places.isEmpty) return null;
  if (!latitude.isFinite || !longitude.isFinite) return null;
  final place = placeContaining(InsightPoint(latitude, longitude), places);
  if (place == null) return null;
  final display = place.displayName.trim();
  return display.isEmpty ? null : display;
}

/// Parses the `lat,lon;lat,lon` string stored on segments.
List<InsightPoint> parseInsightPath(String? path) {
  if (path == null || path.isEmpty) return const [];
  final points = <InsightPoint>[];
  for (final token in path.split(';')) {
    final parts = token.split(',');
    if (parts.length != 2) continue;
    final latitude = double.tryParse(parts[0].trim());
    final longitude = double.tryParse(parts[1].trim());
    if (latitude == null || longitude == null) continue;
    if (!latitude.isFinite || !longitude.isFinite) continue;
    points.add(InsightPoint(latitude, longitude));
  }
  return points;
}

/// Snapped cells of [points]. Two runs of the same road share this string.
String variantSignature(List<InsightPoint> points) {
  if (points.isEmpty) return '';
  final cells = <String>[];
  for (final point in points) {
    final latM = point.latitude * _metersPerDegree;
    final lonM =
        point.longitude *
        _metersPerDegree *
        math.cos(point.latitude * math.pi / 180);
    final cell =
        '${(latM / kInsightVariantGridM).round()},${(lonM / kInsightVariantGridM).round()}';
    if (cells.isEmpty || cells.last != cell) cells.add(cell);
  }
  return cells.join(';');
}

/// Groups [subject] against [corpus] using only named places and segment
/// geometry. A trip with one unnamed end is not on a route.
/// Groups [subject] against [corpus] using only named places and segment
/// geometry. A trip with one unnamed end is not on a route.
InsightRouteMatch? matchTripRoute({
  required InsightPoint? start,
  required InsightPoint? end,
  required String? path,
  required List<InsightPlace> places,
  required List<({InsightPoint? start, InsightPoint? end, String? path})>
  corpus,
}) {
  if (start == null || end == null || places.isEmpty) return null;
  final from = placeContaining(start, places);
  final to = placeContaining(end, places);
  if (from == null || to == null || from.id == to.id) return null;

  final subjectSignature = variantSignature(parseInsightPath(path));
  final signatures = <String>{};
  var tripCount = 0;
  for (final trip in corpus) {
    final tripStart = trip.start;
    final tripEnd = trip.end;
    if (tripStart == null || tripEnd == null) continue;
    final tripFrom = placeContaining(tripStart, places);
    final tripTo = placeContaining(tripEnd, places);
    if (tripFrom?.id != from.id || tripTo?.id != to.id) continue;
    tripCount += 1;
    final signature = variantSignature(parseInsightPath(trip.path));
    if (signature.isNotEmpty) signatures.add(signature);
  }
  return InsightRouteMatch(
    from: from,
    to: to,
    variantSignature: subjectSignature,
    tripCount: tripCount,
    variantCount: signatures.length,
  );
}
