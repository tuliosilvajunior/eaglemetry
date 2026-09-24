import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

/// Drives the Dart half of the canonical session duration from the shared
/// fixture.
///
/// `android/app/src/test/kotlin/.../SessionDurationFixtureTest.kt` drives the
/// Kotlin half from the same file. The expected values are hand-derived from
/// the rule, so a failure here says the rule changed — not merely that one
/// language drifted from the other.
///
/// The rule exists twice because the duration is derived and never stored: the
/// car derives it in the repository that answers Flutter, and the phone has to
/// derive it from the synced row, which carries the endpoints alone.
void main() {
  const fixturePath = 'testdata/session_duration_cases.json';

  final fixture =
      jsonDecode(File(fixturePath).readAsStringSync()) as Map<String, Object?>;
  final cases = (fixture['cases']! as List<Object?>)
      .cast<Map<String, Object?>>();

  test('the fixture carries every case the Kotlin side expects', () {
    expect(cases, hasLength(8));
  });

  test('the caps in the fixture are the caps the app holds', () {
    // The fixture states them so the Kotlin side can assert the same numbers.
    // A cap that moved on one side only would let a corrupt stamp through
    // there and be refused here.
    expect(fixture['maxTripWallDurationMillis'], kMaxTripWallDurationMillis);
    expect(
      fixture['maxChargeWallDurationMillis'],
      kMaxChargeWallDurationMillis,
    );
  });

  for (final testCase in cases) {
    test(testCase['name']! as String, () {
      expect(
        sessionDurationMillis(
          startUtcMillis: testCase['startUtcMillis']! as int,
          startElapsedNanos: testCase['startElapsedNanos']! as int,
          startBootCount: testCase['startBootCount'] as int?,
          endUtcMillis: testCase['endUtcMillis']! as int,
          endElapsedNanos: testCase['endElapsedNanos']! as int,
          endBootCount: testCase['endBootCount'] as int?,
          maxWallDurationMillis: testCase['maxWallDurationMillis']! as int,
        ),
        testCase['expected'] as int?,
        reason: testCase['why']! as String,
      );
    });
  }
}
