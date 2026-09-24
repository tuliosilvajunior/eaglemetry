part of 'telemetry_dto.dart';

/// Closed trips the Insights engine may compare.
///
/// The native read is session aggregates and minute-bucket presence. There is
/// no frame list: retention must not be able to change the comparison.
class InsightTripsResult {
  const InsightTripsResult({required this.trips, this.subjectId});

  factory InsightTripsResult.fromMap(Map<String, Object?> map) =>
      InsightTripsResult(
        trips: List.unmodifiable(
          _asMapList(map['trips']).map(_insightTripFromMap),
        ),
        subjectId: map['subjectId'] as String?,
      );

  factory InsightTripsResult.fromWire(InsightTripsWire wire) =>
      InsightTripsResult(
        trips: List.unmodifiable(wire.trips.map(_insightTripFromWire)),
        subjectId: wire.subjectId,
      );

  final List<InsightTrip> trips;
  final String? subjectId;

  /// The trip [subjectId] names, or null when it is absent from [trips].
  InsightTrip? get subject {
    final id = subjectId;
    if (id == null) return null;
    for (final trip in trips) {
      if (trip.id == id) return trip;
    }
    return null;
  }
}

InsightTrip _insightTripFromMap(Map<String, Object?> map) =>
    assembleInsightTrip(InsightTripInputs.fromMap(map));

InsightTrip _insightTripFromWire(InsightTripWire wire) => assembleInsightTrip(
  InsightTripInputs(
    id: wire.id,
    endedAtUtcMillis: wire.endedAtUtcMillis,
    rollupDistanceKm: wire.rollupDistanceKm,
    startOdometerKm: wire.startOdometerKm,
    endOdometerKm: wire.endOdometerKm,
    rollupTractionWh: wire.rollupTractionWh,
    rollupRegenWh: wire.rollupRegenWh,
    rollupAuxiliaryWh: wire.rollupAuxiliaryWh,
    socAgreesWithIntegral: wire.socAgreesWithIntegral,
    hasMinuteBuckets: wire.hasMinuteBuckets,
    startLatitude: wire.startLatitude,
    startLongitude: wire.startLongitude,
    endLatitude: wire.endLatitude,
    endLongitude: wire.endLongitude,
    path: wire.path,
    meanAmbientTempC: wire.meanAmbientTempC,
  ),
);

/// Places the driver named.
class InsightPlacesResult {
  const InsightPlacesResult({required this.places});

  factory InsightPlacesResult.fromMap(Map<String, Object?> map) =>
      InsightPlacesResult(
        places: List.unmodifiable(
          _asMapList(map['places']).map(_insightPlaceFromMap),
        ),
      );

  factory InsightPlacesResult.fromWire(InsightPlacesWire wire) =>
      InsightPlacesResult(
        places: List.unmodifiable(wire.places.map(_insightPlaceFromWire)),
      );

  final List<InsightPlace> places;
}

InsightPlace _insightPlaceFromMap(Map<String, Object?> map) => InsightPlace(
  id: map['id'] as String? ?? '',
  name: map['name'] as String? ?? '',
  latitude: _asDouble(map['latitude']) ?? 0,
  longitude: _asDouble(map['longitude']) ?? 0,
  radiusM: _asDouble(map['radiusM']) ?? kInsightPlaceRadiusM,
  createdAtUtcMillis: (map['createdAtUtcMillis'] as num?)?.toInt(),
  autoName: map['autoName'] as String?,
  autoNameUpdatedAtUtcMillis:
      (map['autoNameUpdatedAtUtcMillis'] as num?)?.toInt() ??
      (map['autoNameUpdatedAt'] as num?)?.toInt(),
  autoNameSource: map['autoNameSource'] as String?,
);

InsightPlace _insightPlaceFromWire(InsightPlaceWire wire) => InsightPlace(
  id: wire.id,
  name: wire.name,
  latitude: wire.latitude,
  longitude: wire.longitude,
  radiusM: wire.radiusM,
  autoName: wire.autoName,
  autoNameUpdatedAtUtcMillis: wire.autoNameUpdatedAtUtcMillis,
  autoNameSource: wire.autoNameSource,
);
