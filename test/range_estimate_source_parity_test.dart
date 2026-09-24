import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the source names in `RangeEstimate` against the ones the car sends.
///
/// `RangeEstimateMonitor` names where a reading came from, and `RangeEstimate`
/// refuses a name it does not recognise — which is not a cosmetic refusal: an
/// unknown capacity source drops the capacity, and the app estimate then reads
/// `--` on the car while every test and the web mock still pass, because both
/// spell the name themselves.
///
/// That is exactly what happened. On 2026-08-15 capacity moved to one source
/// and the Kotlin constant became `SETTINGS`, while the Dart set still held the
/// three vehicle-read names it replaced. The suite was green and the charging
/// screen showed no estimate at all.
void main() {
  const monitorPath =
      'android/app/src/main/kotlin/com/timhss/capyenergy/telemetry/'
      'RangeEstimateMonitor.kt';
  const dtoPath = 'packages/telemetry_core/lib/dto/telemetry_models.dart';

  late Map<String, Set<String>> kotlinSources;
  late Map<String, Set<String>> dartSources;

  setUpAll(() {
    kotlinSources = _kotlinSources(File(monitorPath).readAsStringSync());
    dartSources = _dartSources(File(dtoPath).readAsStringSync());
  });

  test('the extractors find the names they are meant to read', () {
    // Without this a pattern that stopped matching would compare two empty
    // maps and pass, which is the failure this file exists to prevent.
    for (final group in const ['CAR', 'CAPACITY', 'EFFICIENCY']) {
      expect(
        kotlinSources[group],
        isNotEmpty,
        reason: 'the ${group}_SOURCE_* pattern stopped matching $monitorPath',
      );
    }
    for (final set in const [
      '_carSources',
      '_capacitySources',
      '_efficiencySources',
    ]) {
      expect(
        dartSources[set],
        isNotEmpty,
        reason: 'the $set pattern stopped matching $dtoPath',
      );
    }
  });

  test('the app accepts exactly the source names the car states', () {
    expect(
      dartSources['_carSources'],
      kotlinSources['CAR'],
      reason: 'RangeEstimate would drop a vehicle range the car published',
    );
    expect(
      dartSources['_capacitySources'],
      kotlinSources['CAPACITY'],
      reason:
          'RangeEstimate would drop the pack capacity, and with it the '
          'whole SOC-and-efficiency estimate',
    );
    expect(
      dartSources['_efficiencySources'],
      kotlinSources['EFFICIENCY'],
      reason: 'RangeEstimate would drop the closed-trip efficiency',
    );
  });
}

/// The `*_SOURCE_*` string constants of `RangeEstimateMonitor`, by group.
Map<String, Set<String>> _kotlinSources(String source) {
  final pattern = RegExp(
    r'const\s+val\s+(CAR|CAPACITY|EFFICIENCY)_SOURCE_\w+\s*=\s*"([^"]+)"',
  );
  final result = <String, Set<String>>{
    'CAR': <String>{},
    'CAPACITY': <String>{},
    'EFFICIENCY': <String>{},
  };
  for (final match in pattern.allMatches(source)) {
    result[match.group(1)!]!.add(match.group(2)!);
  }
  return result;
}

/// The three accepted-name sets of `RangeEstimate`, by field name.
Map<String, Set<String>> _dartSources(String source) {
  final quoted = RegExp(r"'([^']+)'");
  final result = <String, Set<String>>{};
  for (final field in const [
    '_carSources',
    '_capacitySources',
    '_efficiencySources',
  ]) {
    final match = RegExp(
      'static const $field\\s*=\\s*\\{([^}]*)\\}',
      dotAll: true,
    ).firstMatch(source);
    result[field] = match == null
        ? <String>{}
        : quoted.allMatches(match.group(1)!).map((m) => m.group(1)!).toSet();
  }
  return result;
}
