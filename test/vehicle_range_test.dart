import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  // The SOC-based remaining-range estimate now comes from the native range
  // contract (getRangeEstimate); this file keeps only the graph-footer helper
  // that still runs entirely in Dart.

  test('range gain shares the plausibility bounds with the range panels', () {
    // 18.8 kWh at the fake 7.18 km/kWh.
    expect(
      estimateRangeGainKm(history: _history(), energyKwh: 18.8),
      closeTo(134.98, 0.01),
    );
  });

  test('range gain stays missing whenever remaining range would be', () {
    // The readings that make the range panels show `--` must not produce a
    // confident gain figure elsewhere on the same screen.
    for (final history in [
      null,
      _history(tripCount: 0),
      _history(efficiency: 0.4),
      _history(efficiency: 20.1),
      _history(efficiency: null),
    ]) {
      expect(estimateRangeGainKm(history: history, energyKwh: 18.8), isNull);
    }
  });

  test('range gain rejects absent or negative energy', () {
    expect(estimateRangeGainKm(history: _history(), energyKwh: null), isNull);
    expect(estimateRangeGainKm(history: _history(), energyKwh: -1), isNull);
    expect(estimateRangeGainKm(history: _history(), energyKwh: 0), 0);
  });
}

RecentTripEfficiency _history({int tripCount = 2, double? efficiency = 7.18}) {
  // Distance and energy, not a ratio: the reading divides one by the other,
  // and a test that handed it the answer would not exercise that.
  final energy = efficiency == null ? 0.0 : 10.0;
  return RecentTripEfficiency(
    tripCount: tripCount,
    distanceKm: efficiency == null ? 0.0 : efficiency * energy,
    netEnergyKwh: energy,
  );
}
