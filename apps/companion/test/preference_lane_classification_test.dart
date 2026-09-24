import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

/// The companion half of the shared preference-lane classification fixture.
///
/// Mirrors `test/preference_lane_classification_test.dart` at the workspace
/// root so `cd apps/companion && flutter test` exercises the same shared
/// fixture. The same catalogue runs against
/// `PreferenceRepository.PREFERENCE_LANE` in Kotlin, so a key registered on
/// only one side fails a suite.
///
/// The rule being pinned — issue #227, Lane C: "if it changes what the car
/// does or records, it is control; if it only changes what a screen shows, it
/// is annotation."
void main() {
  test('registry matches the shared fixture exactly', () {
    final fixture = _loadFixture();
    final lanes = (fixture['lanes']! as Map<String, Object?>)
        .cast<String, String>();

    expect(
      kPreferenceLane.keys,
      unorderedEquals(lanes.keys),
      reason: 'every kitchen-sink fixture key is registered',
    );
    for (final entry in lanes.entries) {
      expect(
        kPreferenceLane[entry.key],
        _laneFromName(entry.value),
        reason: '${entry.key} must classify as ${entry.value} in Dart',
      );
    }
  });

  test('classification honors the mechanical rule', () {
    expect(
      kControlPreferenceKeys,
      unorderedEquals(['pack_capacity_wh', 'default_charge_cost_per_kwh']),
    );
    expect(
      kControlPreferenceKeys,
      unorderedEquals(
        kPreferenceLane.entries
            .where((e) => e.value == PreferenceLane.control)
            .map((e) => e.key),
      ),
    );
  });

  test('the annotation channel never carries control keys', () {
    expect(
      kSyncedPreferenceKeys.keys.every(
        (key) => kPreferenceLane[key] == PreferenceLane.annotation,
      ),
      isTrue,
      reason: 'a control key must not ride the annotation channel',
    );
  });
}

PreferenceLane _laneFromName(String name) => switch (name) {
  'annotation' => PreferenceLane.annotation,
  'control' => PreferenceLane.control,
  _ => throw ArgumentError('unknown lane in fixture: $name'),
};

Map<String, Object?> _loadFixture() {
  const candidates = [
    'testdata/preference_lanes.json',
    '../../testdata/preference_lanes.json',
    '../testdata/preference_lanes.json',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync()) {
      return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    }
  }
  final fallback = File('../../testdata/preference_lanes.json');
  if (fallback.existsSync()) {
    return jsonDecode(fallback.readAsStringSync()) as Map<String, Object?>;
  }
  throw StateError(
    'preference_lanes.json fixture not found in candidates $candidates (cwd=${Directory.current.path})',
  );
}
