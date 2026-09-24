import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/can_bridge_models.dart';
import 'package:capy_energy/core/signal_lab.dart';

const int kSecond = 1000000000;

RoadcastSchemaEntry entry(
  String name, {
  int index = 0,
  int canId = 0x315,
  String unit = 'kW',
  bool calibrated = true,
}) {
  return RoadcastSchemaEntry(
    stableId: index,
    index: index,
    invalidSignalIndex: null,
    canId: canId,
    kind: 0,
    source: 0,
    width: 12,
    flags: calibrated ? 0x02 : 0x00,
    scale: 0.1,
    offset: -204.0,
    name: name,
    unit: unit,
  );
}

CanBridgeReading reading({
  required List<double> values,
  required List<int> raws,
  required List<int> changeNanos,
  required List<bool> valid,
  List<bool>? calibrated,
  List<int>? firstObservedNanos,
}) {
  final flags = Uint8List(values.length);
  for (var i = 0; i < values.length; i++) {
    flags[i] =
        (valid[i] ? 0x01 : 0x00) | ((calibrated?[i] ?? true) ? 0x02 : 0x00);
  }
  return CanBridgeReading(
    values: values,
    raws: raws,
    timestampsNs: Int64List.fromList(changeNanos),
    // A frame that has changed has necessarily been observed, so the default
    // mirrors the change stamp. A test that needs the two to disagree — the
    // frame that arrived and then held still — passes its own list.
    firstObservedNs: Int64List.fromList(firstObservedNanos ?? changeNanos),
    flags: flags,
  );
}

void main() {
  group('signalTier', () {
    test('a zero timestamp is never published, not an ancient signal', () {
      // The sentinel is zero. Subtracting it from an uptime of three hours
      // would produce a plausible age and hide the only fact that matters.
      expect(signalTier(0, 3 * 3600 * kSecond), SignalTier.never);
      expect(signalTier(-1, 3 * 3600 * kSecond), SignalTier.never);
    });

    test('splits fresh from published at ten seconds', () {
      const now = 100 * kSecond;
      expect(signalTier(now, now), SignalTier.fresh);
      expect(signalTier(now - 9 * kSecond, now), SignalTier.fresh);
      expect(signalTier(now - 10 * kSecond, now), SignalTier.fresh);
      expect(signalTier(now - 11 * kSecond, now), SignalTier.published);
      expect(signalTier(1, now), SignalTier.published);
    });

    test('a timestamp from the future is fresh, not negative-aged', () {
      const now = 100 * kSecond;
      expect(signalTier(now + kSecond, now), SignalTier.fresh);
    });

    test(
      'a frame that arrived and then held still is published, not never',
      () {
        // The change stamp and the first observation answer different
        // questions. Reading the first as the second denies a signal the car
        // does publish, which is the whole reason this parameter exists.
        const now = 3 * 3600 * kSecond;
        expect(
          signalTier(0, now, firstObservedNanos: 42 * kSecond),
          SignalTier.published,
        );
      },
    );

    test('never observed stays never even with a change stamp', () {
      const now = 100 * kSecond;
      expect(
        signalTier(now - kSecond, now, firstObservedNanos: 0),
        SignalTier.never,
      );
    });

    test('without a first observation the change stamp is all there is', () {
      const now = 100 * kSecond;
      expect(signalTier(0, now, firstObservedNanos: null), SignalTier.never);
      expect(
        signalTier(now - kSecond, now, firstObservedNanos: null),
        SignalTier.fresh,
      );
    });
  });

  group('buildSignalRow', () {
    test('reads a live calibrated signal whole', () {
      const now = 50 * kSecond;
      final row = buildSignalRow(
        entry: entry('VCU_DrvPwrAct'),
        reading: reading(
          values: const [5.6],
          raws: const [2096],
          changeNanos: const [50 * kSecond - 120000000],
          valid: const [true],
        ),
        nowNanos: now,
      );

      expect(row.tier, SignalTier.fresh);
      expect(row.raw, 2096);
      expect(row.physical, closeTo(5.6, 1e-9));
      expect(row.valid, isTrue);
      expect(row.calibrated, isTrue);
      expect(row.age, const Duration(milliseconds: 120));
      expect(row.isStale, isFalse);
    });

    test('a never-published signal has no raw and no age, not a zero', () {
      final row = buildSignalRow(
        entry: entry('IPU_MOTOR_TQ'),
        reading: reading(
          values: const [0.0],
          raws: const [0],
          changeNanos: const [0],
          valid: const [true],
        ),
        nowNanos: 3600 * kSecond,
      );

      expect(row.tier, SignalTier.never);
      expect(row.raw, isNull);
      expect(row.physical, isNull);
      expect(row.age, isNull);
      expect(row.valid, isFalse);
      expect(row.isStale, isTrue);
    });

    test('keeps the raw count of an uncalibrated signal, but not a value', () {
      // VCU_DCDCPwrAct has no scale. The count is the measurement; a decoded
      // number would be an assumed scale printed as a plain reading.
      final row = buildSignalRow(
        entry: entry('VCU_DCDCPwrAct', calibrated: false, unit: '-'),
        reading: reading(
          values: const [3.0],
          raws: const [3],
          changeNanos: const [49 * kSecond],
          valid: const [true],
          calibrated: const [false],
        ),
        nowNanos: 50 * kSecond,
      );

      expect(row.raw, 3);
      expect(row.physical, isNull);
      expect(row.calibrated, isFalse);
      expect(row.tier, SignalTier.fresh);
      // The count is still plottable, and the row says it is a count.
      expect(row.plottable, 3.0);
      expect(row.plotsRawCount, isTrue);
    });

    test('a disowned sample is not plottable, count or otherwise', () {
      final row = buildSignalRow(
        entry: entry('VCU_DCDCPwrAct', calibrated: false, unit: '-'),
        reading: reading(
          values: const [3.0],
          raws: const [3],
          changeNanos: const [49 * kSecond],
          valid: const [false],
          calibrated: const [false],
        ),
        nowNanos: 50 * kSecond,
      );

      expect(row.raw, 3);
      expect(row.plottable, isNull);
      expect(row.plotsRawCount, isFalse);
    });

    test('an invalid sample keeps its count and withholds its value', () {
      final row = buildSignalRow(
        entry: entry('BMSH_BattCurr'),
        reading: reading(
          values: const [999.0],
          raws: const [7064],
          changeNanos: const [49 * kSecond],
          valid: const [false],
        ),
        nowNanos: 50 * kSecond,
      );

      expect(row.valid, isFalse);
      expect(row.raw, 7064);
      expect(row.physical, isNull);
    });

    test('an index outside the read is never, not an exception', () {
      final row = buildSignalRow(
        entry: entry('Ghost', index: 7),
        reading: reading(
          values: const [1.0],
          raws: const [1],
          changeNanos: const [kSecond],
          valid: const [true],
        ),
        nowNanos: 2 * kSecond,
      );

      expect(row.tier, SignalTier.never);
      expect(row.raw, isNull);
    });
  });

  group('SignalSessionExtremes', () {
    test('tracks the span of the values it was given', () {
      final extremes = SignalSessionExtremes();
      extremes
        ..observe('a', 5.0, isCount: false)
        ..observe('a', -2.0, isCount: false)
        ..observe('a', 3.0, isCount: false);

      expect(extremes.minOf('a'), -2.0);
      expect(extremes.maxOf('a'), 5.0);
      expect(extremes.minOf('b'), isNull);
    });

    test('refuses what the bus disowned', () {
      final extremes = SignalSessionExtremes();
      extremes
        ..observe('a', null, isCount: false)
        ..observe('a', double.nan, isCount: false)
        ..observe('a', double.infinity, isCount: false);
      expect(extremes.minOf('a'), isNull);
      expect(extremes.maxOf('a'), isNull);
    });

    test('an invalid sample never widens the session span', () {
      final extremes = SignalSessionExtremes();
      final entries = [entry('BMSH_BattCurr')];

      buildSignalRows(
        entries: entries,
        reading: reading(
          values: const [40.0],
          raws: const [400],
          changeNanos: const [kSecond],
          valid: const [true],
        ),
        nowNanos: 2 * kSecond,
        extremes: extremes,
      );
      buildSignalRows(
        entries: entries,
        reading: reading(
          values: const [9999.0],
          raws: const [1],
          changeNanos: const [2 * kSecond],
          valid: const [false],
        ),
        nowNanos: 3 * kSecond,
        extremes: extremes,
      );

      expect(extremes.maxOf('BMSH_BattCurr'), 40.0);
    });

    test('an uncalibrated signal builds its span from the counts', () {
      // VCU_ThermalPwrAct and VCU_DCDCPwrAct have no scale and never will
      // until this screen helps find one. A span withheld from them would
      // leave the lab blind to the signals it exists to measure.
      final extremes = SignalSessionExtremes();
      final entries = [entry('VCU_ThermalPwrAct', calibrated: false)];
      for (final count in [19, 32, 4]) {
        buildSignalRows(
          entries: entries,
          reading: reading(
            values: [count.toDouble()],
            raws: [count],
            changeNanos: const [kSecond],
            valid: const [true],
            calibrated: const [false],
          ),
          nowNanos: 2 * kSecond,
          extremes: extremes,
        );
      }

      expect(extremes.minOf('VCU_ThermalPwrAct'), 4.0);
      expect(extremes.maxOf('VCU_ThermalPwrAct'), 32.0);
      expect(extremes.isCountOf('VCU_ThermalPwrAct'), isTrue);
    });

    test('a span never mixes counts with decoded values', () {
      final extremes = SignalSessionExtremes()
        ..observe('a', 3.0, isCount: true)
        ..observe('a', 40.0, isCount: true)
        ..observe('a', 5.6, isCount: false);

      expect(extremes.minOf('a'), 5.6);
      expect(extremes.maxOf('a'), 5.6);
      expect(extremes.isCountOf('a'), isFalse);
    });

    test('clearing forgets the session', () {
      final extremes = SignalSessionExtremes()
        ..observe('a', 1.0, isCount: false);
      extremes.clear();
      expect(extremes.minOf('a'), isNull);
    });
  });

  group('SignalFilter', () {
    final rows = <SignalRow>[
      const SignalRow(
        name: 'VCU_DrvPwrAct',
        unit: 'kW',
        canId: 0x315,
        tier: SignalTier.fresh,
        raw: 2040,
        physical: 0.0,
        valid: true,
        calibrated: true,
        age: Duration(milliseconds: 20),
        sessionMin: null,
        sessionMax: null,
      ),
      const SignalRow(
        name: 'BMSH_BattCurr',
        unit: 'A',
        canId: 0x2FD,
        tier: SignalTier.published,
        raw: 5002,
        physical: 0.0,
        valid: true,
        calibrated: true,
        age: Duration(seconds: 40),
        sessionMin: null,
        sessionMax: null,
      ),
      const SignalRow(
        name: 'IPU_MOTOR_TQ',
        unit: 'Nm',
        canId: 0x111,
        tier: SignalTier.never,
        raw: null,
        physical: null,
        valid: false,
        calibrated: false,
        age: null,
        sessionMin: null,
        sessionMax: null,
      ),
    ];

    test('an empty filter keeps every tier, including never', () {
      final kept = filterSignalRows(rows, const SignalFilter());
      expect(kept.length, 3);
    });

    test('matches a name case-insensitively', () {
      final kept = filterSignalRows(
        rows,
        const SignalFilter(query: 'battcurr'),
      );
      expect(kept.single.name, 'BMSH_BattCurr');
    });

    test('matches a frame by its hexadecimal id', () {
      final kept = filterSignalRows(rows, const SignalFilter(query: '0x315'));
      expect(kept.single.name, 'VCU_DrvPwrAct');
    });

    test('narrows by tier', () {
      final kept = filterSignalRows(
        rows,
        const SignalFilter(tiers: {SignalTier.fresh, SignalTier.published}),
      );
      expect(kept.map((r) => r.name), ['VCU_DrvPwrAct', 'BMSH_BattCurr']);
    });

    test('counts the three tiers, which is the Stage 0 answer', () {
      final counts = countByTier(rows);
      expect(counts[SignalTier.fresh], 1);
      expect(counts[SignalTier.published], 1);
      expect(counts[SignalTier.never], 1);
    });
  });
}
