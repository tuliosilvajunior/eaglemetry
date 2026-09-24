import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

/// The Dart half of the shared annotation-convergence fixture.
///
/// The same cases run against `AnnotationConvergence` in Kotlin, so a rule
/// that moved in one language fails the other suite. The fixture now holds
/// the clock-skew and late-arrival cases; both sides read this one file so a
/// divergence fails one of them.
///
/// Additional tests in this file cover the three step-6c invariants:
/// clock-skew (via the shared fixture), late-arrival, and permutation.
/// The permutation test is regression scaffolding only — the investigation
/// proved it is a tautology against this LWW rule and cannot find a bug.
/// It locks the invariant that any order converges to the same winner.
void main() {
  test('fixture cases match', () {
    final fixture =
        jsonDecode(
              File(
                'testdata/annotation_convergence_cases.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final cases = (fixture['cases']! as List<Object?>)
        .cast<Map<String, Object?>>();
    expect(cases, isNotEmpty, reason: 'the fixture must hold cases');

    for (final input in cases) {
      final existing = (input['existing']! as Map<String, Object?>)
          .cast<String, Object?>();
      final incoming = (input['incoming']! as Map<String, Object?>)
          .cast<String, Object?>();
      final expectedWinner = input['winner']! as String;

      int hlcMillis(Map<String, Object?> m) {
        if (m.containsKey('hlcMillis')) return (m['hlcMillis']! as num).toInt();
        final hlc = m['hlc'] as Map<String, Object?>?;
        if (hlc != null && hlc.containsKey('millis')) {
          return (hlc['millis']! as num).toInt();
        }
        return (m['updatedAtUtcMillis']! as num).toInt();
      }

      int hlcCounter(Map<String, Object?> m) {
        if (m.containsKey('hlcCounter')) {
          return (m['hlcCounter']! as num).toInt();
        }
        final hlc = m['hlc'] as Map<String, Object?>?;
        if (hlc != null && hlc.containsKey('counter')) {
          return (hlc['counter']! as num).toInt();
        }
        return 0;
      }

      String hlcDeviceId(Map<String, Object?> m) {
        if (m.containsKey('hlcDeviceId')) return m['hlcDeviceId']! as String;
        final hlc = m['hlc'] as Map<String, Object?>?;
        if (hlc != null && hlc.containsKey('deviceId')) {
          return hlc['deviceId']! as String;
        }
        return (m['origin'] as String?) ?? '';
      }

      final replace = annotationShouldReplace(
        existingHlcMillis: hlcMillis(existing),
        existingHlcCounter: hlcCounter(existing),
        existingHlcDeviceId: hlcDeviceId(existing),
        existingOrigin: existing['origin'] as String?,
        incomingHlcMillis: hlcMillis(incoming),
        incomingHlcCounter: hlcCounter(incoming),
        incomingHlcDeviceId: hlcDeviceId(incoming),
        incomingOrigin: incoming['origin'] as String?,
      );

      expect(
        replace ? 'incoming' : 'existing',
        expectedWinner,
        reason: input['name']! as String,
      );
    }
  });

  test(
    'late arrival: three-week offline stale edit loses to newer winning edit',
    () {
      // Simulate a device offline for three weeks (21 days = 1_814_400_000 ms).
      // A phone made intervening edits; the car reconnects with a stale row.
      // The stale edit must NOT overwrite the newer winning edit, whichever
      // arrival order the merge sees it in. This exercises the same path as
      // the late-arrival fixture cases but as an in-code assertion on the
      // comparison, so a regression to wall-clock would fail here even without
      // the fixture.
      const threeWeeksMs = 21 * 24 * 3600 * 1000;
      const staleMillis = 1708185600000;
      const freshMillis = staleMillis + threeWeeksMs + 5000;
      const staleHlc = HlcTimestamp(
        millis: staleMillis,
        counter: 0,
        deviceId: 'car',
      );
      const freshHlc = HlcTimestamp(
        millis: freshMillis,
        counter: 5,
        deviceId: 'phone',
      );

      // Stale arriving second loses (existing = fresh, incoming = stale)
      expect(
        annotationShouldReplaceHlc(
          existingHlc: freshHlc,
          existingOrigin: 'phone',
          incomingHlc: staleHlc,
          incomingOrigin: 'car',
        ),
        isFalse,
        reason:
            'stale car edit arriving late must not overwrite fresh phone edit',
      );
      // Fresh arriving second wins (existing = stale, incoming = fresh)
      expect(
        annotationShouldReplaceHlc(
          existingHlc: staleHlc,
          existingOrigin: 'car',
          incomingHlc: freshHlc,
          incomingOrigin: 'phone',
        ),
        isTrue,
        reason: 'fresh phone edit must win over three-week stale car row',
      );
      // Also verify via millis/counter/deviceId overload
      expect(
        annotationShouldReplace(
          existingHlcMillis: freshMillis,
          existingHlcCounter: 5,
          existingHlcDeviceId: 'phone',
          existingOrigin: 'phone',
          incomingHlcMillis: staleMillis,
          incomingHlcCounter: 0,
          incomingHlcDeviceId: 'car',
          incomingOrigin: 'car',
        ),
        isFalse,
      );
    },
  );

  test(
    'permutation: shuffled orders converge to same final state — regression scaffolding only',
    () {
      // Regression scaffolding only: LWW over a deterministic total order
      // (HLC millis -> counter -> deviceId, plus ADR 0009 auto_name variant
      // with originRank) is tautologically convergent. Locked so a future
      // regression to the total-order property would be caught.

      // A small write type with same id but different stamps.
      final writes = [
        _Row(
          id: 'p1',
          hlc: const HlcTimestamp(millis: 1000, counter: 0, deviceId: 'car'),
          origin: 'car',
          value: 'a',
        ),
        _Row(
          id: 'p1',
          hlc: const HlcTimestamp(millis: 2000, counter: 0, deviceId: 'phone'),
          origin: 'phone',
          value: 'b',
        ),
        _Row(
          id: 'p1',
          hlc: const HlcTimestamp(millis: 2000, counter: 1, deviceId: 'phone'),
          origin: 'phone',
          value: 'c',
        ),
        _Row(
          id: 'p1',
          hlc: const HlcTimestamp(millis: 3000, counter: 0, deviceId: 'car'),
          origin: 'car',
          value: 'd',
        ),
      ];
      const expectedWinner = 'd'; // maximal HLC (3000,0,car) is d

      String? applyInOrder(List<_Row> order) {
        _Row? store;
        for (final w in order) {
          final existing = store;
          if (existing == null) {
            store = w;
          } else if (annotationShouldReplaceHlc(
            existingHlc: existing.hlc,
            existingOrigin: existing.origin,
            incomingHlc: w.hlc,
            incomingOrigin: w.origin,
          )) {
            store = w;
          }
        }
        return store?.value;
      }

      final perms = _permutations(writes);
      expect(perms.length, 24);
      for (final perm in perms) {
        expect(
          applyInOrder(perm),
          expectedWinner,
          reason: 'every permutation must converge to $expectedWinner',
        );
      }

      // Tie-break convergence: same HLC millis/counter, deviceId lexicographic decides (H-1 fix)
      final tieWrites = [
        _Row(
          id: 'p1',
          hlc: const HlcTimestamp(millis: 5000, counter: 0, deviceId: 'phone'),
          origin: 'phone',
          value: 'phone',
        ),
        _Row(
          id: 'p1',
          hlc: const HlcTimestamp(millis: 5000, counter: 0, deviceId: 'car'),
          origin: 'car',
          value: 'car',
        ),
        _Row(
          id: 'p1',
          hlc: const HlcTimestamp(millis: 5000, counter: 0, deviceId: 'cloud'),
          origin: 'cloud',
          value: 'cloud',
        ),
      ];
      for (final perm in _permutations(tieWrites)) {
        expect(
          applyInOrder(perm),
          'phone',
          reason:
              'tie-break must converge to phone (lexicographically max deviceId)',
        );
      }

      // ADR 0009: auto_name keeps origin-rank tie-break (car > phone > cloud)
      String? applyAutoNameInOrder(List<_Row> order) {
        _Row? store;
        for (final w in order) {
          final existing = store;
          if (existing == null) {
            store = w;
          } else if (annotationShouldReplaceWithOriginRankHlc(
            existingHlc: existing.hlc,
            existingOrigin: existing.origin,
            incomingHlc: w.hlc,
            incomingOrigin: w.origin,
          )) {
            store = w;
          }
        }
        return store?.value;
      }

      for (final perm in _permutations(tieWrites)) {
        expect(
          applyAutoNameInOrder(perm),
          'car',
          reason: 'auto_name tie-break must converge to car (origin rank)',
        );
      }
    },
  );
}

class _Row {
  final String id;
  final HlcTimestamp hlc;
  final String? origin;
  final String value;
  _Row({
    required this.id,
    required this.hlc,
    required this.origin,
    required this.value,
  });
}

List<List<T>> _permutations<T>(List<T> list) {
  if (list.length <= 1) return [List<T>.from(list)];
  final result = <List<T>>[];
  for (var i = 0; i < list.length; i++) {
    final head = list[i];
    final tail = [...list.sublist(0, i), ...list.sublist(i + 1)];
    for (final perm in _permutations(tail)) {
      result.add([head, ...perm]);
    }
  }
  return result;
}
