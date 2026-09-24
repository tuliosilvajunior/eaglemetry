/// What a detail screen reads from one session.
///
/// The store answers three questions. A detail screen draws a header, a set of
/// charts and a route, and every one of those is a **reduction** over the
/// record, the events and the series the store already returned — never a
/// second integral (Rule 2.1). The car folded the energy at bus rate and
/// stored it; this file divides, subtracts, decimates and counts.
///
/// It is the one reduction for both apps. The car app and the companion app
/// read the same session the same way, because they read it here.
library;

import 'dart:math' as math;

import 'dto/telemetry_dto.dart';
import 'measurement.dart';
import 'session_reading.dart';
import 'telemetry_store.dart';
import 'track.dart';

/// How many points a chart series is decimated to.
const int kDetailChartPointLimit = 480;

/// How many route points the small card and the large card get.
///
/// The card gets the coarse route and the fullscreen the fine one: a route
/// drawn at preview resolution across half the screen shows its own corners
/// cut.
const int kRoutePreviewPointLimit = 120;
const int kRouteExpandedPointLimit = 1200;

/// The event a charge writes when the target state of charge is reached.
const String kChargeLimitReachedEvent = 'CHARGE_LIMIT_REACHED';

/// One drive, read.
class TripDetailReading {
  TripDetailReading({
    required this.session,
    required this.series,
    this.events = const [],
    this.lastPricedCharge,
    this.track,
  });

  final SessionRecord session;
  final TelemetrySeries series;
  final List<TelemetryEventRecord> events;
  final TrackRow? track;

  /// The last charge priced before this drive started.
  ///
  /// The car scores a drive at the rate of the charge that filled it, so the
  /// cost of a drive is a fact about an earlier session. Null when nothing
  /// before it was priced, which is not a free drive — it is an unpriced one.
  final SessionRecord? lastPricedCharge;

  String get sessionId => session.id;

  /// Odometer first, the stored integral second. Same order as the car.
  Measurement get distance => sessionReadingDistance(session);

  double? get distanceKm => distance.displayValue;

  Measurement get netEnergy => session.rollup.netPackEnergy;
  double? get netEnergyKwh =>
      netEnergy.map((wh) => wh / 1000, unit: 'kWh').displayValue;
  double? get regeneratedKwh =>
      session.rollup.regen.map((wh) => wh / 1000, unit: 'kWh').displayValue;
  double? get tractionKwh =>
      session.rollup.traction.map((wh) => wh / 1000, unit: 'kWh').displayValue;
  double? get auxiliaryKwh =>
      session.rollup.auxiliary.map((wh) => wh / 1000, unit: 'kWh').displayValue;
  double? get climateKwh =>
      session.rollup.climate.map((wh) => wh / 1000, unit: 'kWh').displayValue;
  double? get measuredPackWh => netEnergy.displayValue;
  double? get measuredTractionWh => session.rollup.traction.displayValue;
  double? get measuredRegeneratedWh => session.rollup.regen.displayValue;
  double? get measuredAuxiliaryWh => session.rollup.auxiliary.displayValue;
  double? get measuredClimateWh => session.rollup.climate.displayValue;
  double? get measuredSeconds => session.rollup.integratedSeconds.displayValue;

  /// Does the integral point the same way the state of charge moved?
  ///
  /// The car decides this, because only the car saw the frames. It is a
  /// direction check, never a second measurement: `contradicts` withholds the
  /// cost instead of correcting a number.
  String? get socAgreement => session.socAgreesWithIntegral;
  bool? get measuredAgreesWithSoc => switch (socAgreement) {
    'agrees' => true,
    'contradicts' => false,
    _ => null,
  };

  double? get efficiencyWhPerKm {
    final km = distanceKm;
    final wh = measuredPackWh;
    if (km == null || wh == null || km <= 0) return null;
    return wh / km;
  }

  double? get efficiencyKmPerKwh {
    final km = distanceKm;
    final kwh = netEnergyKwh;
    if (km == null || kwh == null || kwh <= 0) return null;
    return km / kwh;
  }

  int? get durationMillis => sessionReadingDurationMillis(session);

  double? get averageSpeedKmh {
    final km = distanceKm;
    final millis = durationMillis;
    if (km == null || millis == null || millis <= 0) return null;
    return km / (millis / 3600000.0);
  }

  double? get meanAmbientTempC => session.meanAmbientTemp.displayValue;

  List<TelemetrySeriesPoint> get speedSeries =>
      _trackSeries((p) => p.speedKmh) ?? const [];
  List<TelemetrySeriesPoint> get socSeries => _endpointSeriesFromIntervals(
    (i) => i.startSoc.displayValue,
    (i) => i.endSoc.displayValue,
  );

  List<TelemetrySeriesPoint> get altitudeSeries =>
      _trackSeries((p) => p.altitudeM) ?? const [];

  /// Mean pack power over each stored minute, kW.
  ///
  /// An energy divided by the time it was measured over. The car integrated
  /// the power; this states the same energy per hour instead of per minute.
  List<TelemetrySeriesPoint> get measuredPackPowerSeries =>
      _powerSeries((interval) {
        final traction = interval.traction.displayValue;
        final regen = interval.regen.displayValue;
        final auxiliary = interval.auxiliary.displayValue;
        if (traction == null) return null;
        return traction - (regen ?? 0) + (auxiliary ?? 0);
      });

  /// Mean traction power over each stored minute, kW, regeneration removed.
  List<TelemetrySeriesPoint> get measuredDrivePowerSeries =>
      _powerSeries((interval) {
        final traction = interval.traction.displayValue;
        final regen = interval.regen.displayValue;
        if (traction == null) return null;
        return traction - (regen ?? 0);
      });

  /// The climb and the descent.
  double? get altitudeGainM => session.climbM;
  double? get altitudeLossM => session.descentM;

  /// Where the drive went. The GPS members are written as one group, so a
  /// point is only a point when both coordinates come from the same write.
  List<TelemetryRoutePoint> routePoints({required bool expanded}) {
    final all = _routePoints();
    final limit = expanded ? kRouteExpandedPointLimit : kRoutePreviewPointLimit;
    return _decimateRoute(all, limit);
  }

  int get gpsPointCount {
    final count = session.fixCount;
    if (count != null) return count;
    final t = track;
    if (t != null && t.pointCount > 0) return t.pointCount;
    return _routePoints().length;
  }

  double? get lastChargeCostPerKwh => lastPricedCharge?.costPerKwh;
  String? get lastChargeCostCurrency => lastPricedCharge?.costCurrency;

  /// What the drive cost at the rate of the charge before it.
  ///
  /// Withheld when the integral contradicts the state of charge: a price on a
  /// number the car itself does not trust is a claim nothing measured.
  double? get estimatedTripCost {
    if (measuredAgreesWithSoc == false) return null;
    final rate = lastChargeCostPerKwh;
    final kwh = netEnergyKwh;
    if (rate == null || kwh == null || kwh <= 0) return null;
    return kwh * rate;
  }

  List<TrackPoint>? _trackPointsCache;
  bool _trackPointsDecoded = false;

  /// Decoded [track] points, or null when there is no usable Track.
  ///
  /// Decoded once and cached: the polyline and delta arrays are only worth
  /// walking a single time per reading.
  List<TrackPoint>? _decodedTrackPoints() {
    if (_trackPointsDecoded) return _trackPointsCache;
    _trackPointsDecoded = true;
    final t = track;
    if (t == null || t.pointCount == 0) return null;
    return _trackPointsCache = TrackCodec.decode(t);
  }

  /// A chart series read straight from the Track, or null to fall back to
  /// the Sample series.
  ///
  /// The Track already carries the drive's final, once-simplified shape —
  /// including the points a stop protected — so no further decimation runs
  /// here beyond the shared point-limit reduction every chart series gets.
  List<TelemetrySeriesPoint>? _trackSeries(double Function(TrackPoint) yOf) {
    final points = _decodedTrackPoints();
    if (points == null) return null;
    final series = [
      for (final p in points) TelemetrySeriesPoint(x: p.tSeconds, y: yOf(p)),
    ];
    return _decimateSeries(series, kDetailChartPointLimit);
  }

  List<TelemetryRoutePoint>? _routeCache;

  List<TelemetryRoutePoint> _routePoints() {
    final cached = _routeCache;
    if (cached != null) return cached;
    final points = _decodedTrackPoints();
    if (points != null) {
      return _routeCache = [
        for (final p in points)
          TelemetryRoutePoint(
            latitude: p.latitude,
            longitude: p.longitude,
            altitudeM: p.altitudeM,
            speedKmh: p.speedKmh,
          ),
      ];
    }
    return _routeCache = const [];
  }

  List<TelemetrySeriesPoint> _powerSeries(
    double? Function(IntervalRecord) whOf,
  ) {
    final intervals = series.intervals;
    if (intervals.isEmpty) return const [];
    final startUtc = session.startedAtUtcMillis;
    final points = <TelemetrySeriesPoint>[];
    for (final interval in series.intervals) {
      final wh = whOf(interval);
      final seconds = interval.coveredSeconds;
      if (wh == null || seconds <= 0) continue;
      points.add(
        TelemetrySeriesPoint(
          x: (interval.startUtcMillis - startUtc) / 1000.0,
          y: wh / 1000.0 / (seconds / 3600.0),
        ),
      );
    }
    return points;
  }

  List<TelemetrySeriesPoint> _endpointSeriesFromIntervals(
    double? Function(IntervalRecord) startOf,
    double? Function(IntervalRecord) endOf,
  ) {
    final startUtc = session.startedAtUtcMillis;
    final points = <TelemetrySeriesPoint>[];
    for (final interval in series.intervals) {
      final start = startOf(interval);
      final end = endOf(interval);
      if (start != null) {
        points.add(
          TelemetrySeriesPoint(
            x: (interval.startUtcMillis - startUtc) / 1000.0,
            y: start,
          ),
        );
      }
      if (end != null) {
        points.add(
          TelemetrySeriesPoint(
            x:
                (interval.startUtcMillis + interval.widthMillis - startUtc) /
                1000.0,
            y: end,
          ),
        );
      }
    }
    return _decimateSeries(points, kDetailChartPointLimit);
  }
}

/// One charge, read.
class ChargeDetailReading {
  const ChargeDetailReading({
    required this.session,
    required this.series,
    this.events = const [],
  });

  final SessionRecord session;
  final TelemetrySeries series;
  final List<TelemetryEventRecord> events;

  String get sessionId => session.id;

  /// What went into the pack. The car integrated the DC power; this only
  /// states it in kWh.
  Measurement get delivered => sessionReadingDeliveredKwh(session);
  double? get estimatedEnergyKwh {
    final fromRollup = delivered.displayValue;
    if (fromRollup != null && fromRollup > 0) return fromRollup;
    var intervalWh = 0.0;
    var hasInterval = false;
    for (final interval in series.intervals) {
      final wh = interval.delivered.displayValue;
      if (wh != null && wh > 0) {
        intervalWh += wh;
        hasInterval = true;
      }
    }
    if (hasInterval && intervalWh > 0) {
      return intervalWh / 1000.0;
    }
    return fromRollup;
  }

  int? get durationMillis => sessionReadingDurationMillis(session);

  /// The mean charging power over the minutes that delivered energy, kW.
  double? get averagePowerKw {
    var wh = 0.0;
    var seconds = 0.0;
    for (final interval in series.intervals) {
      final delivered = interval.delivered.displayValue;
      if (delivered == null) continue;
      final covered = interval.deliveredCoveredSeconds;
      if (covered <= 0) continue;
      wh += delivered;
      seconds += covered;
    }
    if (seconds <= 0) return null;
    return wh / 1000.0 / (seconds / 3600.0);
  }

  /// The strongest stored minute, kW.
  ///
  /// A minute, never an instant: the stored width is the minute, so this is
  /// the highest mean the record holds and not the highest reading the car saw.
  double? get peakPowerKw {
    double? peak;
    for (final point in powerSeries) {
      peak = peak == null ? point.y : math.max(peak, point.y);
    }
    return peak;
  }

  List<TelemetrySeriesPoint> get powerSeries {
    final startUtc = session.startedAtUtcMillis;
    final points = <TelemetrySeriesPoint>[];
    for (final interval in series.intervals) {
      final delivered = interval.delivered.displayValue;
      final covered = interval.deliveredCoveredSeconds;
      if (delivered == null || covered <= 0) continue;
      points.add(
        TelemetrySeriesPoint(
          x: (interval.startUtcMillis - startUtc) / 1000.0,
          y: delivered / 1000.0 / (covered / 3600.0),
        ),
      );
    }
    return points;
  }

  /// The state of charge, one point at the start and one at the end of every
  /// bucket that carried a reading.
  List<TelemetrySeriesPoint> get socSeries => _endpointSeriesFromIntervals(
    (i) => i.startSoc.displayValue,
    (i) => i.endSoc.displayValue,
  );

  List<TelemetrySeriesPoint> get voltageSeries => _endpointSeriesFromIntervals(
    (i) => i.startVoltage.displayValue,
    (i) => i.endVoltage.displayValue,
  );

  List<TelemetrySeriesPoint> _endpointSeriesFromIntervals(
    double? Function(IntervalRecord) startOf,
    double? Function(IntervalRecord) endOf,
  ) {
    final startUtc = session.startedAtUtcMillis;
    final points = <TelemetrySeriesPoint>[];
    for (final interval in series.intervals) {
      final start = startOf(interval);
      final end = endOf(interval);
      if (start != null) {
        points.add(
          TelemetrySeriesPoint(
            x: (interval.startUtcMillis - startUtc) / 1000.0,
            y: start,
          ),
        );
      }
      if (end != null) {
        points.add(
          TelemetrySeriesPoint(
            x:
                (interval.startUtcMillis + interval.widthMillis - startUtc) /
                1000.0,
            y: end,
          ),
        );
      }
    }
    return _decimateSeries(points, kDetailChartPointLimit);
  }

  /// What the climate package drew from the pack while the charge ran.
  double? get climateEnergyKwh {
    var wh = 0.0;
    var seen = false;
    for (final interval in series.intervals) {
      final climate = interval.climate.displayValue;
      if (climate == null) continue;
      wh += climate;
      seen = true;
    }
    return seen ? wh / 1000.0 : null;
  }

  /// How much of the charge the climate integral actually covered, seconds.
  double? get climateIntegratedSeconds {
    var seconds = 0.0;
    for (final interval in series.intervals) {
      seconds += interval.climateCoveredSeconds;
    }
    return seconds > 0 ? seconds : null;
  }

  /// [climateEnergyKwh] and how much of [span] stands behind it.
  ///
  /// The value is a **lower bound** whenever the cover is short of the whole
  /// charge. The seconds the bus went quiet can only have added climate
  /// energy, never removed it, so an incomplete integral understates the load
  /// rather than describing a different one. Refusing such a figure gives the
  /// reader less than showing it and saying what it is.
  ///
  /// [kChargeClimateSanityFloor] is the one thing still refused: an integral
  /// that watched less than half the charge is not a total of it, minimum or
  /// otherwise.
  ChargeClimateEnergy? climateEnergyKwhOver(Duration? span) {
    final energy = climateEnergyKwh;
    final covered = climateIntegratedSeconds;
    if (energy == null || covered == null || !energy.isFinite) return null;
    if (energy < 0) return null;
    if (span == null || span.inMilliseconds <= 0) return null;
    final seconds = span.inMilliseconds / 1000.0;
    final coverage = covered / seconds;
    if (coverage < kChargeClimateSanityFloor) return null;
    return ChargeClimateEnergy(
      kwh: energy,
      // A cover that reaches the whole span is complete. Above it is rounding
      // between two clocks, not a claim to have measured more than happened.
      complete: coverage >= 1 - kChargeClimateCompleteTolerance,
    );
  }

  /// When the charge limit was met, in seconds on the series axis.
  ///
  /// More than one is normal: the soft switch does not survive an ignition
  /// cycle, so a car left plugged in tops up and is cut again on each wake.
  List<double> get targetReachedSeconds => [
    for (final millis in targetReachedAtUtcMillis)
      (millis - session.startedAtUtcMillis) / 1000,
  ];

  /// When the car said the target state of charge was reached.
  ///
  /// It is an event, not a threshold crossed in a chart: the car decides it,
  /// and a series read back at sample resolution cannot re-decide it.
  List<int> get targetReachedAtUtcMillis => [
    for (final event in events)
      if (event.type == kChargeLimitReachedEvent) event.occurredAtUtcMillis,
  ];
}

/// Keeps the shape of a series while bounding its point count.
///
/// Each bucket keeps its first, lowest, highest and last point, so a spike
/// survives decimation. A mean would erase exactly what a reader looks for.
List<TelemetrySeriesPoint> _decimateSeries(
  List<TelemetrySeriesPoint> points,
  int limit,
) {
  if (points.length <= limit) return points;
  final buckets = math.max(1, limit ~/ 4);
  final first = points.first.x;
  final last = points.last.x;
  final span = last - first;
  if (span <= 0) return points.sublist(0, limit);

  final kept = <int, List<TelemetrySeriesPoint>>{};
  for (final point in points) {
    final index = math.min(
      buckets - 1,
      ((point.x - first) / span * buckets).floor(),
    );
    kept.putIfAbsent(index, () => []).add(point);
  }

  final result = <TelemetrySeriesPoint>[];
  final indexes = kept.keys.toList()..sort();
  for (final index in indexes) {
    final bucket = kept[index]!;
    var lowest = bucket.first;
    var highest = bucket.first;
    for (final point in bucket) {
      if (point.y < lowest.y) lowest = point;
      if (point.y > highest.y) highest = point;
    }
    final chosen = <TelemetrySeriesPoint>{
      bucket.first,
      lowest,
      highest,
      bucket.last,
    }.toList()..sort((a, b) => a.x.compareTo(b.x));
    result.addAll(chosen);
  }
  return result;
}

/// Thins a route to [limit] points, keeping the ends.
///
/// A route is thinned by position in the list rather than by envelope: a
/// corner is a place the car was, and no point on the line is more true than
/// its neighbours.
List<TelemetryRoutePoint> _decimateRoute(
  List<TelemetryRoutePoint> points,
  int limit,
) {
  if (points.length <= limit) return points;
  final step = points.length / limit;
  final result = <TelemetryRoutePoint>[];
  for (var i = 0; i < limit; i++) {
    result.add(points[math.min(points.length - 1, (i * step).floor())]);
  }
  if (result.last != points.last) result[result.length - 1] = points.last;
  return result;
}
