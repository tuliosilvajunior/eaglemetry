import 'insight.dart';

/// Raw inputs for assembling an [InsightTrip].
///
/// Contains the unmodified fields of a session before domain decisions
/// (such as net CAN energy, SOC agreement, minute bucket presence and aggregation version)
/// are applied.
class InsightTripInputs {
  const InsightTripInputs({
    required this.id,
    this.endedAtUtcMillis,
    this.rollupDistanceKm,
    this.startOdometerKm,
    this.endOdometerKm,
    this.rollupTractionWh,
    this.rollupRegenWh,
    this.rollupAuxiliaryWh,
    this.socAgreesWithIntegral,
    this.hasMinuteBuckets = false,
    this.startLatitude,
    this.startLongitude,
    this.endLatitude,
    this.endLongitude,
    this.path,
    this.meanAmbientTempC,
  });

  factory InsightTripInputs.fromMap(
    Map<String, Object?> map, {
    bool? hasMinuteBuckets,
  }) {
    final startOdo = _asDouble(map['startOdometerKm']);
    final endOdo = _asDouble(map['endOdometerKm']);
    final meanAmbient =
        _asDouble(map['meanAmbientTempC']) ??
        _asDouble(map['startAmbientTempC']);

    return InsightTripInputs(
      id: map['id'] as String? ?? '',
      endedAtUtcMillis: _asInt(map['endedAtUtcMillis']),
      rollupDistanceKm:
          _asDouble(map['rollupDistanceKm']) ?? _asDouble(map['distanceKm']),
      startOdometerKm: startOdo,
      endOdometerKm: endOdo,
      rollupTractionWh:
          _asDouble(map['rollupTractionWh']) ?? _asDouble(map['canPackWh']),
      rollupRegenWh: _asDouble(map['rollupRegenWh']),
      rollupAuxiliaryWh: _asDouble(map['rollupAuxiliaryWh']),
      socAgreesWithIntegral: map['socAgreesWithIntegral'] as String?,
      hasMinuteBuckets:
          hasMinuteBuckets ?? _asBool(map['hasMinuteBuckets'], orElse: false),
      startLatitude: _asDouble(map['startLatitude']),
      startLongitude: _asDouble(map['startLongitude']),
      endLatitude: _asDouble(map['endLatitude']),
      endLongitude: _asDouble(map['endLongitude']),
      path: map['path'] as String?,
      meanAmbientTempC: meanAmbient,
    );
  }

  final String id;
  final int? endedAtUtcMillis;
  final double? rollupDistanceKm;
  final double? startOdometerKm;
  final double? endOdometerKm;
  final double? rollupTractionWh;
  final double? rollupRegenWh;
  final double? rollupAuxiliaryWh;
  final String? socAgreesWithIntegral;
  final bool hasMinuteBuckets;
  final double? startLatitude;
  final double? startLongitude;
  final double? endLatitude;
  final double? endLongitude;
  final String? path;
  final double? meanAmbientTempC;
}

/// Assembles an [InsightTrip] from raw session inputs.
///
/// This is the SINGLE canonical place across the car and companion applications
/// that decides:
/// - `canPackWh` (net CAN pack energy: traction - regen + auxiliary)
/// - `hasMinuteBuckets`
/// - `canAgreesWithSoc` (mapped from `socAgreesWithIntegral`: 'agrees' -> true, 'contradicts' -> false, other -> null)
/// - `aggregationVersion` (1 if traction rollup is present, else 0)
/// - `distanceKm` (rollup distance if valid, else odometer delta if non-negative)
InsightTrip assembleInsightTrip(InsightTripInputs raw) {
  final double? canPackWh;
  final int aggregationVersion;
  if (raw.rollupTractionWh != null) {
    canPackWh =
        raw.rollupTractionWh! -
        (raw.rollupRegenWh ?? 0.0) +
        (raw.rollupAuxiliaryWh ?? 0.0);
    aggregationVersion = 1;
  } else {
    canPackWh = null;
    aggregationVersion = 0;
  }

  final bool? canAgreesWithSoc;
  switch (raw.socAgreesWithIntegral) {
    case 'agrees':
      canAgreesWithSoc = true;
      break;
    case 'contradicts':
      canAgreesWithSoc = false;
      break;
    default:
      canAgreesWithSoc = null;
      break;
  }

  final double? distanceKm;
  if (raw.rollupDistanceKm != null &&
      raw.rollupDistanceKm!.isFinite &&
      raw.rollupDistanceKm! >= 0.0) {
    distanceKm = raw.rollupDistanceKm;
  } else if (raw.startOdometerKm != null && raw.endOdometerKm != null) {
    final delta = raw.endOdometerKm! - raw.startOdometerKm!;
    if (delta.isFinite && delta >= 0.0) {
      distanceKm = delta;
    } else {
      distanceKm = null;
    }
  } else {
    distanceKm = null;
  }

  return InsightTrip(
    id: raw.id,
    endedAtUtcMillis: raw.endedAtUtcMillis,
    distanceKm: distanceKm,
    canPackWh: canPackWh,
    hasMinuteBuckets: raw.hasMinuteBuckets,
    canAgreesWithSoc: canAgreesWithSoc,
    aggregationVersion: aggregationVersion,
    startLatitude: raw.startLatitude,
    startLongitude: raw.startLongitude,
    endLatitude: raw.endLatitude,
    endLongitude: raw.endLongitude,
    path: raw.path,
    meanAmbientTempC: raw.meanAmbientTempC,
  );
}

double? _asDouble(Object? value) {
  if (value is double) return value;
  if (value is int) return value.toDouble();
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value);
  return null;
}

bool _asBool(Object? value, {required bool orElse}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    switch (value.toLowerCase()) {
      case 'true':
        return true;
      case 'false':
        return false;
    }
  }
  return orElse;
}
