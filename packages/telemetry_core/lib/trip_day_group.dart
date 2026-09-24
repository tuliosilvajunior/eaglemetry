import 'package:flutter/foundation.dart';

import 'dto/telemetry_store_models.dart';
import 'insight_place.dart';
import 'session_reading.dart';

/// Value object representing an individual trip session with resolved places,
/// route coordinates, and calculated metrics.
@immutable
class TripSessionEntry {
  const TripSessionEntry({
    required this.id,
    required this.startedAtUtcMillis,
    this.endedAtUtcMillis,
    this.durationMillis,
    this.distanceKm,
    this.netEnergyKwh,
    this.avgSpeedKmh,
    this.startPlace,
    this.endPlace,
    this.startLatitude,
    this.startLongitude,
    this.endLatitude,
    this.endLongitude,
    this.routePoints = const [],
    this.startSoc,
    this.endSoc,
    required this.session,
  });

  final String id;
  final int startedAtUtcMillis;
  final int? endedAtUtcMillis;
  final int? durationMillis;
  final double? distanceKm;
  final double? netEnergyKwh;
  final double? avgSpeedKmh;
  final String? startPlace;
  final String? endPlace;
  final double? startLatitude;
  final double? startLongitude;
  final double? endLatitude;
  final double? endLongitude;
  final List<InsightPoint> routePoints;
  final double? startSoc;
  final double? endSoc;
  final SessionRecord session;

  String get displayStartLocation {
    if (startPlace != null && startPlace!.trim().isNotEmpty) return startPlace!;
    if (startLatitude != null && startLongitude != null) {
      return '${startLatitude!.toStringAsFixed(4)}, ${startLongitude!.toStringAsFixed(4)}';
    }
    return '';
  }

  String get displayEndLocation {
    if (endPlace != null && endPlace!.trim().isNotEmpty) return endPlace!;
    if (endLatitude != null && endLongitude != null) {
      return '${endLatitude!.toStringAsFixed(4)}, ${endLongitude!.toStringAsFixed(4)}';
    }
    return '';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TripSessionEntry &&
          other.id == id &&
          other.startedAtUtcMillis == startedAtUtcMillis &&
          other.endedAtUtcMillis == endedAtUtcMillis &&
          other.distanceKm == distanceKm &&
          other.netEnergyKwh == netEnergyKwh &&
          other.startPlace == startPlace &&
          other.endPlace == endPlace;

  @override
  int get hashCode => Object.hash(
    id,
    startedAtUtcMillis,
    endedAtUtcMillis,
    distanceKm,
    netEnergyKwh,
    startPlace,
    endPlace,
  );
}

/// A calendar day of trips, sorted newest first, with daily totals.
@immutable
class TripDayGroup {
  const TripDayGroup({
    required this.date,
    required this.trips,
    required this.totalDistanceKm,
    required this.totalNetKwh,
  });

  /// Local date (year, month, day).
  final DateTime date;
  final List<TripSessionEntry> trips;
  final double totalDistanceKm;
  final double totalNetKwh;

  int get tripCount => trips.length;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TripDayGroup &&
          other.date == date &&
          listEquals(other.trips, trips) &&
          other.totalDistanceKm == totalDistanceKm &&
          other.totalNetKwh == totalNetKwh;

  @override
  int get hashCode => Object.hash(date, trips, totalDistanceKm, totalNetKwh);
}

/// Quick timeframe filters for trips.
enum TripsTimePreset { all, days7, days30 }

/// Filter predicate for querying and searching trip entries.
@immutable
class TripsFilter {
  const TripsFilter({
    this.timePreset = TripsTimePreset.all,
    this.query = '',
    this.fromUtcMillis,
    this.toUtcMillis,
  });

  final TripsTimePreset timePreset;
  final String query;
  final int? fromUtcMillis;
  final int? toUtcMillis;

  bool matches(TripSessionEntry entry, {DateTime? now}) {
    final search = query.trim().toLowerCase();
    if (search.isNotEmpty) {
      final start = (entry.startPlace ?? entry.displayStartLocation)
          .toLowerCase();
      final end = (entry.endPlace ?? entry.displayEndLocation).toLowerCase();
      if (!start.contains(search) && !end.contains(search)) {
        return false;
      }
    }

    final current = now ?? DateTime.now();
    switch (timePreset) {
      case TripsTimePreset.all:
        break;
      case TripsTimePreset.days7:
        final cutoff = current
            .subtract(const Duration(days: 7))
            .millisecondsSinceEpoch;
        if (entry.startedAtUtcMillis < cutoff) return false;
      case TripsTimePreset.days30:
        final cutoff = current
            .subtract(const Duration(days: 30))
            .millisecondsSinceEpoch;
        if (entry.startedAtUtcMillis < cutoff) return false;
    }

    if (fromUtcMillis != null && entry.startedAtUtcMillis < fromUtcMillis!) {
      return false;
    }
    if (toUtcMillis != null && entry.startedAtUtcMillis > toUtcMillis!) {
      return false;
    }

    return true;
  }

  List<TripSessionEntry> apply(
    List<TripSessionEntry> entries, {
    DateTime? now,
  }) {
    return entries.where((e) => matches(e, now: now)).toList(growable: false);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TripsFilter &&
          other.timePreset == timePreset &&
          other.query == query &&
          other.fromUtcMillis == fromUtcMillis &&
          other.toUtcMillis == toUtcMillis;

  @override
  int get hashCode =>
      Object.hash(timePreset, query, fromUtcMillis, toUtcMillis);
}

/// Assembles a [TripSessionEntry] from a session record, driver places, and
/// optional path/end location.
TripSessionEntry assembleTripSessionEntry({
  required SessionRecord session,
  required List<InsightPlace> places,
  double? startLatitude,
  double? startLongitude,
  double? endLatitude,
  double? endLongitude,
  String? path,
}) {
  final startLat = startLatitude ?? session.startLatitude;
  final startLon = startLongitude ?? session.startLongitude;
  final endLat = endLatitude;
  final endLon = endLongitude;

  final startPlace = placeNameAt(
    latitude: startLat,
    longitude: startLon,
    places: places,
  );

  final endPlace = placeNameAt(
    latitude: endLat,
    longitude: endLon,
    places: places,
  );

  var points = parseInsightPath(path);
  if (points.isEmpty) {
    if (startLat != null && startLon != null) {
      if (endLat != null &&
          endLon != null &&
          (startLat != endLat || startLon != endLon)) {
        points = [
          InsightPoint(startLat, startLon),
          InsightPoint(endLat, endLon),
        ];
      } else {
        points = [InsightPoint(startLat, startLon)];
      }
    } else if (endLat != null && endLon != null) {
      points = [InsightPoint(endLat, endLon)];
    }
  }

  final distance = sessionReadingDistance(session).displayValue;
  final durationMillis = sessionReadingDurationMillis(session);

  double? netEnergyKwh;
  final netPack = session.rollup.netPackEnergy.displayValue;
  if (netPack != null) {
    netEnergyKwh = netPack / 1000.0;
  }

  double? avgSpeedKmh;
  if (distance != null && durationMillis != null && durationMillis > 0) {
    final hours = durationMillis / 3600000.0;
    if (hours > 0) {
      avgSpeedKmh = distance / hours;
    }
  }

  return TripSessionEntry(
    id: session.id,
    startedAtUtcMillis: session.startedAtUtcMillis,
    endedAtUtcMillis: session.endedAtUtcMillis,
    durationMillis: durationMillis,
    distanceKm: distance,
    netEnergyKwh: netEnergyKwh,
    avgSpeedKmh: avgSpeedKmh,
    startPlace: startPlace,
    endPlace: endPlace,
    startLatitude: startLat,
    startLongitude: startLon,
    endLatitude: endLat,
    endLongitude: endLon,
    routePoints: points,
    startSoc: session.startSoc.displayValue,
    endSoc: session.endSoc.displayValue,
    session: session,
  );
}

/// Groups trip session entries by local calendar day, newest day first,
/// with sorted trips and daily totals.
List<TripDayGroup> assembleTripDayGroups(List<TripSessionEntry> entries) {
  if (entries.isEmpty) return const [];

  final groupsByDay = <DateTime, List<TripSessionEntry>>{};
  for (final entry in entries) {
    final localTime = DateTime.fromMillisecondsSinceEpoch(
      entry.startedAtUtcMillis,
    );
    final dayKey = DateTime(localTime.year, localTime.month, localTime.day);
    groupsByDay.putIfAbsent(dayKey, () => []).add(entry);
  }

  final sortedKeys = groupsByDay.keys.toList()..sort((a, b) => b.compareTo(a));

  return [
    for (final day in sortedKeys) _createDayGroup(day, groupsByDay[day]!),
  ];
}

TripDayGroup _createDayGroup(DateTime date, List<TripSessionEntry> trips) {
  final sortedTrips = List<TripSessionEntry>.of(trips)
    ..sort((a, b) => b.startedAtUtcMillis.compareTo(a.startedAtUtcMillis));

  var totalDist = 0.0;
  var totalEnergy = 0.0;

  for (final t in sortedTrips) {
    if (t.distanceKm != null && t.distanceKm! > 0) {
      totalDist += t.distanceKm!;
    }
    if (t.netEnergyKwh != null && t.netEnergyKwh! > 0) {
      totalEnergy += t.netEnergyKwh!;
    }
  }

  return TripDayGroup(
    date: date,
    trips: List.unmodifiable(sortedTrips),
    totalDistanceKm: totalDist,
    totalNetKwh: totalEnergy,
  );
}
