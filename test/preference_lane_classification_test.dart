import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

/// The Dart half (head-unit read) of the shared preference-lane
/// classification fixture.
///
/// The same catalogue runs against `PreferenceRepository.PREFERENCE_LANE` in
/// Kotlin, so a key classified one way in one language fails the other suite.
/// The fixture's exact-equality assertion also catches a key registered on
/// only one side.
///
/// The rule being pinned — issue #227, Lane C: "if it changes what the car
/// does or records, it is control; if it only changes what a screen shows, it
/// is annotation."
void main() {
  test('registry matches the shared fixture exactly', () {
    final fixture =
        jsonDecode(File('testdata/preference_lanes.json').readAsStringSync())
            as Map<String, Object?>;
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
    // The only keys that change what the car records.
    expect(
      kControlPreferenceKeys,
      unorderedEquals(['pack_capacity_wh', 'default_charge_cost_per_kwh']),
    );
    // The derived control set and the classification map did not drift apart.
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
    // The synced-keys whitelist is the lane B channel; every key on it must
    // classify as annotation, or a control write could reach the car through
    // the annotation merge path.
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
