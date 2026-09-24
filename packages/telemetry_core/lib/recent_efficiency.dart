/// What the recent drives measured, reduced from the session list.
///
/// One reading, from one question: `listSessions` over a window of days. It
/// replaces the car-side history summary for every screen that only wanted to
/// know how far the car goes on a kilowatt-hour lately.
library;

import 'dto/telemetry_store_models.dart';
import 'session_reading.dart';

/// The efficiency of a set of drives, and how many stand behind it.
class RecentTripEfficiency {
  const RecentTripEfficiency({
    required this.tripCount,
    required this.distanceKm,
    required this.netEnergyKwh,
  });

  /// Reduces [sessions] — the drives, in any order.
  ///
  /// A drive whose integral contradicts the state of charge is left out. The
  /// car states that contradiction; this only obeys it, because an efficiency
  /// built on a number the car does not trust would be a confident figure
  /// resting on a refused one.
  factory RecentTripEfficiency.fromSessions(Iterable<SessionRecord> sessions) {
    var count = 0;
    var distance = 0.0;
    var energy = 0.0;
    for (final session in sessions) {
      if (session.kind != SessionKind.trip) continue;
      if (session.socAgreesWithIntegral == 'contradicts') continue;
      final km = sessionReadingDistance(session).displayValue;
      final kwh = sessionReadingNetKwh(session).displayValue;
      if (km == null || kwh == null || km <= 0 || kwh <= 0) continue;
      count += 1;
      distance += km;
      energy += kwh;
    }
    return RecentTripEfficiency(
      tripCount: count,
      distanceKm: distance,
      netEnergyKwh: energy,
    );
  }

  final int tripCount;
  final double distanceKm;
  final double netEnergyKwh;

  /// Total distance over total energy — never the mean of the per-trip ratios,
  /// which would weigh a two-kilometre errand as heavily as a long drive.
  double? get averageEfficiencyKmPerKwh {
    if (tripCount < 1 || netEnergyKwh <= 0) return null;
    return distanceKm / netEnergyKwh;
  }
}
