import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  const fixturePath = 'testdata/interval_cases.json';

  final fixture =
      jsonDecode(File(fixturePath).readAsStringSync()) as Map<String, Object?>;

  test('interval fixture contains 5 cases including charging', () {
    final cases = (fixture['cases']! as List<Object?>)
        .cast<Map<String, Object?>>();
    expect(cases, hasLength(5));
  });

  test('every interval fixture case folds to the expected quantities', () {
    final tolerance = (fixture['toleranceWh'] as num).toDouble();
    final cases = (fixture['cases']! as List<Object?>)
        .cast<Map<String, Object?>>();

    for (final testCase in cases) {
      final name = testCase['name'] as String;
      final expected = testCase['expected']! as Map<String, Object?>;
      final rawIntervals = (testCase['intervals']! as List<Object?>)
          .cast<Map<String, Object?>>();

      final buckets = rawIntervals.map((m) => EnergyBucket.fromMap(m)).toList();

      final totalTraction = buckets.fold<double>(
        0.0,
        (sum, b) => sum + b.tractionWh,
      );
      final totalRegen = buckets.fold<double>(
        0.0,
        (sum, b) => sum + b.regeneratedWh,
      );
      final totalAux = buckets.fold<double>(
        0.0,
        (sum, b) => sum + b.auxiliaryWh,
      );
      final totalClimate = buckets.fold<double>(
        0.0,
        (sum, b) => sum + b.climateWh,
      );
      final totalDelivered = buckets.fold<double>(
        0.0,
        (sum, b) => sum + b.deliveredWh,
      );
      final totalSeconds = buckets.fold<double>(
        0.0,
        (sum, b) => sum + b.integratedSeconds,
      );

      expect(
        totalTraction,
        closeTo((expected['tractionWh'] as num).toDouble(), tolerance),
        reason: '$name: tractionWh',
      );
      expect(
        totalRegen,
        closeTo((expected['regeneratedWh'] as num).toDouble(), tolerance),
        reason: '$name: regeneratedWh',
      );
      expect(
        totalAux,
        closeTo((expected['auxiliaryWh'] as num).toDouble(), tolerance),
        reason: '$name: auxiliaryWh',
      );
      expect(
        totalClimate,
        closeTo((expected['climateWh'] as num).toDouble(), tolerance),
        reason: '$name: climateWh',
      );
      expect(
        totalDelivered,
        closeTo(
          (expected['deliveredWh'] as num?)?.toDouble() ?? 0.0,
          tolerance,
        ),
        reason: '$name: deliveredWh',
      );
      expect(
        totalSeconds,
        closeTo((expected['integratedSeconds'] as num).toDouble(), tolerance),
        reason: '$name: integratedSeconds',
      );
    }
  });
}
