/// Track format and Dart codec, with shared vectors.
///
/// One row per Session holding the drive as parallel arrays: time, position,
/// speed and altitude, one entry per point, plus the count and the encoding
/// version.
///
/// See issue 174 and the parent 173.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;

/// Which encoder wrote this row. A decoder refuses a version it does not know.
const int kTrackEncodingVersion = 1;

/// Precision and encoding for each channel.
///
/// * `kTrackPolylineFactor`  1e5 => 0.00001 deg ~ 1.1 m on the ground.
///   Google polyline with 5 decimal places. Encode returns empty string for
///   an empty path.
///
/// * `kTrackTimeFactor` 1000 => milliseconds. `t` is seconds from session
///   start, delta encoded as millis deltas. Round-trip error < 0.5 ms.
///
/// * `kTrackSpeedFactor` 10 => 0.1 km/h steps. Not delta encoded.
///
/// * `kTrackAltFactor` 10 => 0.1 m steps. Delta encoded as deci-metres.
///
/// Declared precision is half the step: lat/lon 5e-6 deg, time 0.0005 s,
/// speed 0.05 km/h, altitude 0.05 m.
const double kTrackPolylineFactor = 1e5;
const int kTrackTimeFactor = 1000;
const int kTrackSpeedFactor = 10;
const int kTrackAltFactor = 10;

/// Tolerance for Douglas-Peucker simplification, in metres.
///
/// ADR-0010 measured 14.4 m mean distance a discarded fix stands from the
/// one kept before it at the 20 m position gate. At 30 m the same sits at
/// 19.6 m and shows on a city corner. The chosen tolerance sits well inside
/// the first and far from the second.
const double kTrackSimplifyToleranceM = 10.0;

/// One point of a drive, before encoding.
class TrackPoint {
  const TrackPoint({
    required this.latitude,
    required this.longitude,
    required this.tSeconds,
    required this.speedKmh,
    required this.altitudeM,
    this.protected = false,
  });

  final double latitude;
  final double longitude;
  final double tSeconds;
  final double speedKmh;
  final double altitudeM;

  /// True when this point must survive simplification: first, last, or both
  /// ends of a stop. See issue 173 and 178.
  final bool protected;

  TrackPoint copyWith({
    double? latitude,
    double? longitude,
    double? tSeconds,
    double? speedKmh,
    double? altitudeM,
    bool? protected,
  }) => TrackPoint(
    latitude: latitude ?? this.latitude,
    longitude: longitude ?? this.longitude,
    tSeconds: tSeconds ?? this.tSeconds,
    speedKmh: speedKmh ?? this.speedKmh,
    altitudeM: altitudeM ?? this.altitudeM,
    protected: protected ?? this.protected,
  );

  @override
  bool operator ==(Object other) =>
      other is TrackPoint &&
      other.latitude == latitude &&
      other.longitude == longitude &&
      other.tSeconds == tSeconds &&
      other.speedKmh == speedKmh &&
      other.altitudeM == altitudeM &&
      other.protected == protected;

  @override
  int get hashCode => Object.hash(
    latitude,
    longitude,
    tSeconds,
    speedKmh,
    altitudeM,
    protected,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'lat': latitude,
    'lon': longitude,
    't': tSeconds,
    'speed': speedKmh,
    'alt': altitudeM,
    if (protected) 'protected': true,
  };

  factory TrackPoint.fromJson(Map<String, Object?> json) => TrackPoint(
    latitude: (json['lat'] as num).toDouble(),
    longitude: (json['lon'] as num).toDouble(),
    tSeconds: (json['t'] as num).toDouble(),
    speedKmh: (json['speed'] as num).toDouble(),
    altitudeM: (json['alt'] as num).toDouble(),
    protected: json['protected'] == true,
  );
}

/// The row as it is stored and synced. One row per Session.
///
/// The four arrays each carry exactly [pointCount] entries. A short array
/// is a failing decode, not a shifted map. The path string encodes
/// [pointCount] points as a Google polyline at 1e5.
class TrackRow {
  const TrackRow({
    required this.encodingVersion,
    required this.pointCount,
    required this.t,
    required this.path,
    required this.speed,
    required this.alt,
  });

  final int encodingVersion;
  final int pointCount;

  /// Seconds from session start, delta encoded as millis ints.
  final List<int> t;

  /// Geometry as encoded polyline (1e5). Empty for zero points.
  final String path;

  /// km/h per point, tenth km/h absolute ints.
  final List<int> speed;

  /// Metres per point, delta encoded as deci-metre ints.
  final List<int> alt;

  @override
  bool operator ==(Object other) =>
      other is TrackRow &&
      other.encodingVersion == encodingVersion &&
      other.pointCount == pointCount &&
      other.path == path &&
      listEquals(other.t, t) &&
      listEquals(other.speed, speed) &&
      listEquals(other.alt, alt);

  @override
  int get hashCode => Object.hash(
    encodingVersion,
    pointCount,
    path,
    Object.hashAll(t),
    Object.hashAll(speed),
    Object.hashAll(alt),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'encoding_version': encodingVersion,
    'point_count': pointCount,
    't': t,
    'path': path,
    'speed': speed,
    'alt': alt,
  };

  factory TrackRow.fromJson(Map<String, Object?> json) => TrackRow(
    encodingVersion: (json['encoding_version'] as num).toInt(),
    pointCount: (json['point_count'] as num).toInt(),
    t: (json['t'] as List).map((e) => (e as num).toInt()).toList(),
    path: json['path'] as String,
    speed: (json['speed'] as List).map((e) => (e as num).toInt()).toList(),
    alt: (json['alt'] as List).map((e) => (e as num).toInt()).toList(),
  );
}

/// Reads the row shape the car puts on the sync wire.
///
/// Two things differ from [TrackRow.fromJson], which reads the test fixtures.
/// The wire names its keys the way the Room entity does — `encodingVersion`,
/// not `encoding_version` — and it carries `t`, `speed` and `alt` as JSON
/// **strings**, because on the car each is one TEXT column. A list is accepted
/// too, so a sender that has already parsed them is not refused.
///
/// Throws [TrackDecodeException] on anything else. A row this build cannot
/// read is not a row it may guess at: the arrays are positional, and a wrong
/// guess is a route drawn through places the vehicle never went.
TrackRow trackRowFromWire(Map<String, Object?> item) {
  final version = (item['encodingVersion'] ?? item['encoding_version']) as num?;
  final count = (item['pointCount'] ?? item['point_count']) as num?;
  final path = item['path'];
  if (version == null || count == null || path is! String) {
    throw const TrackDecodeException(
      'wire row needs encodingVersion, pointCount and path',
    );
  }
  return TrackRow(
    encodingVersion: version.toInt(),
    pointCount: count.toInt(),
    t: _wireInts(item['t'], 't'),
    path: path,
    speed: _wireInts(item['speed'], 'speed'),
    alt: _wireInts(item['alt'], 'alt'),
  );
}

List<int> _wireInts(Object? value, String field) {
  final list = value is String ? jsonDecode(value) : value;
  if (list is! List) {
    throw TrackDecodeException('$field is not a list of integers');
  }
  return [
    for (final entry in list)
      if (entry is num)
        entry.toInt()
      else
        throw TrackDecodeException('$field holds a non-number'),
  ];
}

class TrackDecodeException implements Exception {
  const TrackDecodeException(this.message);
  @override
  String toString() => 'TrackDecodeException: $message';
  final String message;
}

/// Codec for the Track: encode a path, decode it back, validate row shape.
class TrackCodec {
  const TrackCodec._();

  static TrackRow encode(List<TrackPoint> points) {
    final n = points.length;
    if (n == 0) {
      return const TrackRow(
        encodingVersion: kTrackEncodingVersion,
        pointCount: 0,
        t: <int>[],
        path: '',
        speed: <int>[],
        alt: <int>[],
      );
    }
    // t delta millis
    final tMillis = points
        .map((p) => (p.tSeconds * kTrackTimeFactor).round())
        .toList();
    final tDelta = <int>[];
    for (var i = 0; i < n; i++) {
      if (i == 0) {
        tDelta.add(tMillis[0]);
      } else {
        tDelta.add(tMillis[i] - tMillis[i - 1]);
      }
    }
    // alt delta deci-metres
    final altDeci = points
        .map((p) => (p.altitudeM * kTrackAltFactor).round())
        .toList();
    final altDelta = <int>[];
    for (var i = 0; i < n; i++) {
      if (i == 0) {
        altDelta.add(altDeci[0]);
      } else {
        altDelta.add(altDeci[i] - altDeci[i - 1]);
      }
    }
    final speedTenth = points
        .map((p) => (p.speedKmh * kTrackSpeedFactor).round())
        .toList();
    final path = _encodePolyline(
      points.map((p) => (p.latitude, p.longitude)).toList(),
    );
    return TrackRow(
      encodingVersion: kTrackEncodingVersion,
      pointCount: n,
      t: tDelta,
      path: path,
      speed: speedTenth,
      alt: altDelta,
    );
  }

  /// Decodes a row back to points.
  ///
  /// Protection is not on the wire. Simplification happens once, before the
  /// row is written, so a decoder has nothing left to protect. Every decoded
  /// point comes back unprotected.
  static List<TrackPoint> decode(TrackRow row) {
    if (row.encodingVersion != kTrackEncodingVersion) {
      throw TrackDecodeException(
        'unknown encoding version ${row.encodingVersion}, expected $kTrackEncodingVersion',
      );
    }
    if (row.t.length != row.pointCount) {
      throw TrackDecodeException(
        't length ${row.t.length} != point_count ${row.pointCount}',
      );
    }
    if (row.speed.length != row.pointCount) {
      throw TrackDecodeException(
        'speed length ${row.speed.length} != point_count ${row.pointCount}',
      );
    }
    if (row.alt.length != row.pointCount) {
      throw TrackDecodeException(
        'alt length ${row.alt.length} != point_count ${row.pointCount}',
      );
    }
    final positions = _decodePolyline(row.path);
    if (positions.length != row.pointCount) {
      throw TrackDecodeException(
        'path point count ${positions.length} != point_count ${row.pointCount}',
      );
    }
    if (row.pointCount == 0) return const <TrackPoint>[];
    // reconstruct cumulative millis and deci-alt
    final tMillis = <int>[];
    var cum = 0;
    for (final d in row.t) {
      cum += d;
      tMillis.add(cum);
    }
    final altDeci = <int>[];
    cum = 0;
    for (final d in row.alt) {
      cum += d;
      altDeci.add(cum);
    }
    final result = <TrackPoint>[];
    for (var i = 0; i < row.pointCount; i++) {
      final pos = positions[i];
      result.add(
        TrackPoint(
          latitude: pos.$1,
          longitude: pos.$2,
          tSeconds: tMillis[i] / kTrackTimeFactor,
          speedKmh: row.speed[i] / kTrackSpeedFactor,
          altitudeM: altDeci[i] / kTrackAltFactor,
        ),
      );
    }
    return result;
  }
}

// ---------------------------------------------------------------------------
// Polyline codec at 1e5, Google algorithm.

String _encodePolyline(List<(double, double)> points) {
  if (points.isEmpty) return '';
  final out = StringBuffer();
  var prevLat = 0;
  var prevLon = 0;
  for (final p in points) {
    final lat = (p.$1 * kTrackPolylineFactor).round();
    final lon = (p.$2 * kTrackPolylineFactor).round();
    final dLat = lat - prevLat;
    final dLon = lon - prevLon;
    _encodeSignedNumber(dLat, out);
    _encodeSignedNumber(dLon, out);
    prevLat = lat;
    prevLon = lon;
  }
  return out.toString();
}

List<(double, double)> _decodePolyline(String encoded) {
  if (encoded.isEmpty) return const <(double, double)>[];
  final result = <(double, double)>[];
  var index = 0;
  var lat = 0;
  var lon = 0;
  while (index < encoded.length) {
    final latResult = _decodeSignedNumber(encoded, index);
    lat += latResult.$1;
    index = latResult.$2;
    final lonResult = _decodeSignedNumber(encoded, index);
    lon += lonResult.$1;
    index = lonResult.$2;
    result.add((lat / kTrackPolylineFactor, lon / kTrackPolylineFactor));
  }
  return result;
}

void _encodeSignedNumber(int value, StringBuffer out) {
  var s = value < 0 ? ~(value << 1) : value << 1;
  // Encode unsigned s as 5-bit chunks.
  while (s >= 0x20) {
    out.writeCharCode((0x20 | (s & 0x1f)) + 63);
    s >>= 5;
  }
  out.writeCharCode(s + 63);
}

/// Returns (value, nextIndex)
(int, int) _decodeSignedNumber(String encoded, int start) {
  var result = 0;
  var shift = 0;
  var index = start;
  int b;
  do {
    if (index >= encoded.length) {
      throw const TrackDecodeException('truncated polyline');
    }
    b = encoded.codeUnitAt(index++) - 63;
    result |= (b & 0x1f) << shift;
    shift += 5;
  } while (b >= 0x20);
  final delta = (result & 1) != 0 ? ~(result >> 1) : result >> 1;
  return (delta, index);
}

// ---------------------------------------------------------------------------
// Simplification: Douglas-Peucker at kTrackSimplifyToleranceM.
// Never removes first, last, or protected.

class TrackSimplifier {
  const TrackSimplifier._();

  /// Simplifies [points], keeping the first, the last, and every protected
  /// point.
  ///
  /// A point counts as protected when its own [TrackPoint.protected] flag is
  /// set or when [protected] marks its index. The two are a union: a list
  /// never disarms a flag the point carries.
  ///
  /// The path is cut at every protected index and each section is simplified
  /// on its own. That is what makes a whole path and the same path assembled
  /// from sections cut at protected indices give the same result. Cuts that
  /// fall anywhere else do not hold that equality: Douglas-Peucker is not
  /// incremental.
  static List<TrackPoint> simplify(
    List<TrackPoint> points, {
    double toleranceM = kTrackSimplifyToleranceM,
    List<bool>? protected,
  }) {
    if (points.length <= 2) return List<TrackPoint>.from(points);
    // Build protected set: first+last always, plus any flagged point.
    final n = points.length;
    final isProtected = List<bool>.filled(n, false);
    isProtected[0] = true;
    isProtected[n - 1] = true;
    for (var i = 0; i < n; i++) {
      if (points[i].protected) isProtected[i] = true;
    }
    if (protected != null) {
      for (var i = 0; i < n && i < protected.length; i++) {
        if (protected[i]) isProtected[i] = true;
      }
    }
    // Partition at every protected index, then DP each section.
    final protectedIndexes = <int>[];
    for (var i = 0; i < n; i++) {
      if (isProtected[i]) protectedIndexes.add(i);
    }
    // With no interior protected point this is a single section, which is
    // one Douglas-Peucker pass over the whole path.
    final result = <TrackPoint>[];
    for (var k = 0; k + 1 < protectedIndexes.length; k++) {
      final a = protectedIndexes[k];
      final b = protectedIndexes[k + 1];
      final segment = points.sublist(a, b + 1);
      final simplified = _douglasPeucker(segment, toleranceM);
      if (result.isEmpty) {
        result.addAll(simplified);
      } else {
        // Avoid duplicating the joint protected point.
        result.addAll(simplified.sublist(1));
      }
    }
    return result;
  }

  /// Splits [points] at [cuts], simplifies each section on its own, and joins
  /// the results, dropping the joint point each section repeats.
  ///
  /// [cuts] holds indexes into [points]; the first must be 0 and the last
  /// must be the last index.
  ///
  /// When every cut falls on a protected index the result equals
  /// [simplify] over the whole path. When a cut falls anywhere else the two
  /// differ, because Douglas-Peucker is not incremental: a section cannot
  /// know about the bend that follows it. That is why a Track is held raw
  /// while the Session runs and simplified once when it closes.
  static List<TrackPoint> simplifyInSections(
    List<TrackPoint> points,
    List<int> cuts, {
    double toleranceM = kTrackSimplifyToleranceM,
    List<bool>? protected,
  }) {
    final joined = <TrackPoint>[];
    for (var k = 0; k + 1 < cuts.length; k++) {
      final a = cuts[k];
      final b = cuts[k + 1];
      final section = simplify(
        points.sublist(a, b + 1),
        toleranceM: toleranceM,
        protected: protected?.sublist(a, b + 1),
      );
      joined.addAll(joined.isEmpty ? section : section.sublist(1));
    }
    return joined;
  }

  /// Indexes of [kept] within [all], matched by position, not by value.
  ///
  /// The shared vectors name kept points by index. A path may hold the same
  /// point twice, so searching by value would report the wrong one. Walking
  /// forward keeps the mapping honest, and every implementation reading the
  /// fixture must use this same rule.
  static List<int> indexesIn(List<TrackPoint> kept, List<TrackPoint> all) {
    final out = <int>[];
    var cursor = 0;
    for (final p in kept) {
      while (cursor < all.length && all[cursor] != p) {
        cursor++;
      }
      if (cursor == all.length) {
        throw StateError('kept point is not in the original path: $p');
      }
      out.add(cursor);
      cursor++;
    }
    return out;
  }

  static List<TrackPoint> _douglasPeucker(
    List<TrackPoint> pts,
    double toleranceM,
  ) {
    if (pts.length <= 2) return List<TrackPoint>.from(pts);
    var maxDist = -1.0;
    var maxIndex = -1;
    final first = pts.first;
    final last = pts.last;
    for (var i = 1; i + 1 < pts.length; i++) {
      final d = _perpDistanceM(pts[i], first, last);
      if (d > maxDist) {
        maxDist = d;
        maxIndex = i;
      }
    }
    if (maxDist > toleranceM && maxIndex != -1) {
      final left = _douglasPeucker(pts.sublist(0, maxIndex + 1), toleranceM);
      final right = _douglasPeucker(pts.sublist(maxIndex), toleranceM);
      return <TrackPoint>[...left.sublist(0, left.length - 1), ...right];
    }
    return <TrackPoint>[pts.first, pts.last];
  }

  /// Perpendicular distance from [p] to segment [a]-[b], metres.
  ///
  /// For a degenerate segment (a==b) returns distance to a.
  /// Uses haversine for distances and bearing cross-track. Clamps to
  /// segment ends when projection falls beyond the segment.
  static double _perpDistanceM(TrackPoint p, TrackPoint a, TrackPoint b) {
    // Degenerate segment.
    if (a.latitude == b.latitude && a.longitude == b.longitude) {
      return _haversineM(a.latitude, a.longitude, p.latitude, p.longitude);
    }
    const r = 6371000.0;
    final d13 = _haversineM(a.latitude, a.longitude, p.latitude, p.longitude);
    if (d13 == 0) return 0;
    final theta12 = _bearing(a.latitude, a.longitude, b.latitude, b.longitude);
    final theta13 = _bearing(a.latitude, a.longitude, p.latitude, p.longitude);
    final cross =
        math
            .asin(
              (math.sin(d13 / r) * math.sin(theta13 - theta12)).clamp(
                -1.0,
                1.0,
              ),
            )
            .abs() *
        r;
    // Along-track distance from a to closest point on great circle.
    // cos(d13/R) = cos(cross/R)*cos(at/R) => at = acos(cos(d13/R)/cos(cross/R))*R
    final cosCross = math.cos(cross / r);
    if (cosCross.abs() < 1e-12) {
      return cross;
    }
    final cosD13 = math.cos(d13 / r);
    var at = math.acos((cosD13 / cosCross).clamp(-1.0, 1.0)) * r;
    // Handle sign: if dot indicates behind a, at is negative-like.
    // Decide by checking if bearing difference > 90deg.
    // If along-track beyond segment length, clamp to endpoint distance.
    final segLen = _haversineM(
      a.latitude,
      a.longitude,
      b.latitude,
      b.longitude,
    );
    // Determine sign of at: compare angle between 12 and 13.
    final deltaTheta = (theta13 - theta12).abs();
    // If deltaTheta > pi/2, projection is behind a.
    if (deltaTheta > math.pi / 2 && deltaTheta < 3 * math.pi / 2) {
      at = -at;
    }
    if (at < 0) {
      return d13;
    }
    if (at > segLen) {
      return _haversineM(b.latitude, b.longitude, p.latitude, p.longitude);
    }
    return cross;
  }

  static double _haversineM(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const r = 6371000.0;
    final p1 = lat1 * math.pi / 180;
    final p2 = lat2 * math.pi / 180;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(p1) * math.cos(p2) * math.sin(dLon / 2) * math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  static double _bearing(double lat1, double lon1, double lat2, double lon2) {
    final p1 = lat1 * math.pi / 180;
    final p2 = lat2 * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final y = math.sin(dLon) * math.cos(p2);
    final x =
        math.cos(p1) * math.sin(p2) -
        math.sin(p1) * math.cos(p2) * math.cos(dLon);
    return math.atan2(y, x);
  }
}
