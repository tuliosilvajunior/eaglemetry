import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

const _oneMinute = Duration(minutes: 1);
const _nanosPerMinute = 60 * 1000000000;

ReconciledInstant _at(int minute, {int? bootCount = 1}) => ReconciledInstant(
  utcMillis: minute * 60000,
  elapsedNanos: minute * _nanosPerMinute,
  bootCount: bootCount,
);

ContinuousMinute _minute(int atMinute, {bool estimated = false}) =>
    ContinuousMinute(
      start: _at(atMinute),
      bucket: EnergyBucket(
        start: DateTime.fromMillisecondsSinceEpoch(atMinute * 60000),
        width: _oneMinute,
        tractionWh: 5,
        regeneratedWh: 0,
        auxiliaryWh: 1,
        integratedSeconds: 60,
      ),
      estimated: estimated,
    );

DateTime _time(int atMinute) =>
    DateTime.fromMillisecondsSinceEpoch(atMinute * 60000);

EnergyBucket _bucket(int atMinute) => EnergyBucket(
  start: _time(atMinute),
  width: _oneMinute,
  tractionWh: 5,
  regeneratedWh: 0,
  auxiliaryWh: 1,
  integratedSeconds: 60,
);

void main() {
  group('continuous minute labelling (issue 199 / 203)', () {
    test('precedence: a charge over standing time over nothing', () {
      final minutes = [_minute(10)];
      final spans = [
        ContinuousLabelSpan(
          label: ContinuousLabel.charge,
          start: _at(0),
          end: _at(20),
        ),
        ContinuousLabelSpan(
          label: ContinuousLabel.parked,
          start: _at(0),
          end: _at(20),
        ),
      ];

      final result = labelContinuousMinutes(minutes: minutes, spans: spans);

      expect(result, hasLength(1));
      expect(result.single.label, ContinuousLabel.charge);
    });

    test('precedence: a trip over standing time', () {
      final minutes = [_minute(10)];
      final spans = [
        ContinuousLabelSpan(
          label: ContinuousLabel.trip,
          start: _at(0),
          end: _at(20),
        ),
        ContinuousLabelSpan(
          label: ContinuousLabel.parked,
          start: _at(0),
          end: _at(20),
        ),
      ];

      final result = labelContinuousMinutes(minutes: minutes, spans: spans);

      expect(result.single.label, ContinuousLabel.trip);
    });

    test('precedence: a charge over a trip, when both somehow overlap', () {
      final minutes = [_minute(10)];
      final spans = [
        ContinuousLabelSpan(
          label: ContinuousLabel.trip,
          start: _at(0),
          end: _at(20),
        ),
        ContinuousLabelSpan(
          label: ContinuousLabel.charge,
          start: _at(0),
          end: _at(20),
        ),
      ];

      final result = labelContinuousMinutes(minutes: minutes, spans: spans);

      expect(result.single.label, ContinuousLabel.charge);
    });

    test(
      'a minute no session covers reads as the fourth state, never a blank',
      () {
        final minutes = [_minute(10)];
        final spans = [
          ContinuousLabelSpan(
            label: ContinuousLabel.trip,
            start: _at(100),
            end: _at(120),
          ),
        ];

        final result = labelContinuousMinutes(minutes: minutes, spans: spans);

        expect(result.single.label, ContinuousLabel.poweredOn);
      },
    );

    test('an empty span list still labels every minute Powered on', () {
      final minutes = [_minute(1), _minute(2), _minute(3)];

      final result = labelContinuousMinutes(minutes: minutes, spans: const []);

      expect(
        result.map((r) => r.label),
        everyElement(ContinuousLabel.poweredOn),
      );
    });

    test('a stretch with no recorded minute stays a gap: the result has no '
        'entry for it, measured or zero', () {
      // Minute 5 is simply absent from the input, the way a stretch the
      // collector never saw is absent from what it stored.
      final minutes = [_minute(1), _minute(2), _minute(6)];
      final spans = [
        ContinuousLabelSpan(
          label: ContinuousLabel.trip,
          start: _at(0),
          end: _at(10),
        ),
      ];

      final result = labelContinuousMinutes(minutes: minutes, spans: spans);

      expect(result, hasLength(3));
      expect(
        result.map((r) => r.minute.start.utcMillis),
        [_at(1).utcMillis, _at(2).utcMillis, _at(6).utcMillis],
        reason: 'no synthetic minute is inserted for the missing minute 5',
      );
    });

    test('an estimated minute stays distinguishable from a measured one', () {
      final minutes = [_minute(1), _minute(2, estimated: true)];
      final spans = [
        ContinuousLabelSpan(
          label: ContinuousLabel.parked,
          start: _at(0),
          end: _at(10),
        ),
      ];

      final result = labelContinuousMinutes(minutes: minutes, spans: spans);

      expect(result[0].estimated, isFalse);
      expect(result[1].estimated, isTrue);
      // Estimated or not, the label itself still resolves the same way.
      expect(result[0].label, ContinuousLabel.parked);
      expect(result[1].label, ContinuousLabel.parked);
    });

    test('the same span is labelled identically across a wall-clock jump, '
        'because the reconciled clock did not move', () {
      // The minute and the trip span share a boot. Their elapsed-nanos
      // distance says the minute is well inside the trip. Their UTC millis
      // disagree by hours, as if the car corrected the wall clock between
      // the trip starting and this minute being recorded — the exact
      // scenario the reconciled clock exists to survive.
      const bootCount = 7;
      final tripStart = ReconciledInstant(
        utcMillis: 1000,
        elapsedNanos: 0,
        bootCount: bootCount,
      );
      final tripEnd = ReconciledInstant(
        utcMillis: 2000,
        elapsedNanos: 10 * _nanosPerMinute,
        bootCount: bootCount,
      );
      final minuteStart = ReconciledInstant(
        utcMillis: 1000 + const Duration(hours: 3).inMilliseconds,
        elapsedNanos: 5 * _nanosPerMinute,
        bootCount: bootCount,
      );
      final minute = ContinuousMinute(
        start: minuteStart,
        bucket: EnergyBucket(
          start: DateTime.fromMillisecondsSinceEpoch(minuteStart.utcMillis),
          width: _oneMinute,
          tractionWh: 5,
          regeneratedWh: 0,
          auxiliaryWh: 1,
          integratedSeconds: 60,
        ),
      );

      final result = labelContinuousMinutes(
        minutes: [minute],
        spans: [
          ContinuousLabelSpan(
            label: ContinuousLabel.trip,
            start: tripStart,
            end: tripEnd,
          ),
        ],
      );

      expect(result.single.label, ContinuousLabel.trip);
    });

    test('a genuine reboot between the minute and the span falls back to the '
        'wall clock', () {
      final tripStart = ReconciledInstant(
        utcMillis: 0,
        elapsedNanos: 0,
        bootCount: 1,
      );
      final tripEnd = ReconciledInstant(
        utcMillis: 20 * 60000,
        elapsedNanos: 20 * _nanosPerMinute,
        bootCount: 1,
      );
      // A different boot: elapsed nanos alone would be meaningless here, so
      // the comparison must use UTC millis, which places this minute inside
      // the trip's wall-clock window.
      final minute = ContinuousMinute(
        start: ReconciledInstant(
          utcMillis: 10 * 60000,
          elapsedNanos: 500,
          bootCount: 2,
        ),
        bucket: EnergyBucket(
          start: DateTime.fromMillisecondsSinceEpoch(10 * 60000),
          width: _oneMinute,
          tractionWh: 5,
          regeneratedWh: 0,
          auxiliaryWh: 1,
          integratedSeconds: 60,
        ),
      );

      final result = labelContinuousMinutes(
        minutes: [minute],
        spans: [
          ContinuousLabelSpan(
            label: ContinuousLabel.trip,
            start: tripStart,
            end: tripEnd,
          ),
        ],
      );

      expect(result.single.label, ContinuousLabel.trip);
    });

    test('two spans that only touch do not count as overlapping', () {
      // The minute [10, 11) sits exactly at the boundary between a trip that
      // ends at 10 and a park that starts at 10. Only the park covers it.
      final minute = _minute(10);
      final spans = [
        ContinuousLabelSpan(
          label: ContinuousLabel.trip,
          start: _at(0),
          end: _at(10),
        ),
        ContinuousLabelSpan(
          label: ContinuousLabel.parked,
          start: _at(10),
          end: _at(20),
        ),
      ];

      final result = labelContinuousMinutes(minutes: [minute], spans: spans);

      expect(result.single.label, ContinuousLabel.parked);
    });

    test('a CONTINUOUS span never claims a minute it recorded', () {
      final result = labelEnergyBuckets(
        buckets: [_bucket(10)],
        spans: [
          SessionSpan(kind: SessionKind.continuous, start: _time(0)),
          SessionSpan(kind: SessionKind.trip, start: _time(10), end: _time(11)),
        ],
        now: _time(20),
      );

      expect(result.single.label, ContinuousLabel.trip);
    });

    test('poweredOn cannot be constructed as an input span', () {
      // Finding 13d: explicit ArgumentError, enforced in release too.
      expect(
        () => ContinuousLabelSpan(
          label: ContinuousLabel.poweredOn,
          start: _at(0),
          end: _at(1),
        ),
        throwsArgumentError,
      );
    });
  });

  group('synthesizeSleepGapEnergyBuckets (issue 199 / 211)', () {
    test(
      'fills a genuine gap inside a closed PARKED span with an estimate',
      () {
        final buckets = [_bucket(0), _bucket(1)];
        final spans = [
          SessionSpan(
            kind: SessionKind.parked,
            start: _time(0),
            end: _time(5),
            sleepSeconds: 180,
            sleepSocDeltaPercent: 1.2,
            sleepEnergyWhEstimate: 90,
          ),
        ];

        final synthesized = synthesizeSleepGapEnergyBuckets(
          buckets: buckets,
          spans: spans,
        );

        // Minutes 0 and 1 are already measured; the gap is minutes 2, 3, 4.
        expect(synthesized, hasLength(3));
        expect(synthesized.map((b) => b.start), [_time(2), _time(3), _time(4)]);
        for (final bucket in synthesized) {
          expect(bucket.auxiliaryWh, closeTo(30, 1e-9));
          expect(bucket.tractionWh, 0);
          expect(bucket.regeneratedWh, 0);
          expect(bucket.isEmpty, isFalse);
        }
      },
    );

    test('a PARKED span with no sleep estimate leaves its gap alone', () {
      final spans = [
        SessionSpan(kind: SessionKind.parked, start: _time(0), end: _time(5)),
      ];

      final synthesized = synthesizeSleepGapEnergyBuckets(
        buckets: const [],
        spans: spans,
      );

      expect(synthesized, isEmpty);
    });

    test('no measured minute at all leaves no session range to anchor to, so '
        'nothing is fabricated even with a real estimate', () {
      final spans = [
        SessionSpan(
          kind: SessionKind.parked,
          start: _time(10),
          end: _time(15),
          sleepSeconds: 180,
          sleepSocDeltaPercent: 1.2,
          sleepEnergyWhEstimate: 90,
        ),
      ];

      final synthesized = synthesizeSleepGapEnergyBuckets(
        buckets: const [],
        spans: spans,
      );

      expect(synthesized, isEmpty);
    });

    test('a PARKED span predating the continuous session never backfills past '
        "the session's own first minute", () {
      // The mode turned on mid-park (or the car was already asleep): the
      // span claims to start ten minutes before this session ever recorded
      // anything. Minutes -10 through -1 were never watched by this
      // session and must stay unfabricated, no matter what the span says
      // it covers -- only the genuine internal gap (2, 3, 4) is filled.
      final buckets = [_bucket(0), _bucket(1), _bucket(5)];
      final spans = [
        SessionSpan(
          kind: SessionKind.parked,
          start: _time(-10),
          end: _time(5),
          sleepSeconds: 900,
          sleepSocDeltaPercent: 3,
          sleepEnergyWhEstimate: 150,
        ),
      ];

      final synthesized = synthesizeSleepGapEnergyBuckets(
        buckets: buckets,
        spans: spans,
      );

      expect(synthesized.map((b) => b.start), [_time(2), _time(3), _time(4)]);
    });

    test('an already-measured minute is never duplicated', () {
      // Minute 1, sandwiched between two measured minutes, is the only
      // genuine gap; 0 and 2 must come back untouched, not doubled up.
      final buckets = [_bucket(0), _bucket(2)];
      final spans = [
        SessionSpan(
          kind: SessionKind.parked,
          start: _time(0),
          end: _time(3),
          sleepSeconds: 60,
          sleepSocDeltaPercent: 0.4,
          sleepEnergyWhEstimate: 30,
        ),
      ];

      final synthesized = synthesizeSleepGapEnergyBuckets(
        buckets: buckets,
        spans: spans,
      );

      expect(synthesized.map((b) => b.start), [_time(1)]);
    });

    test('a TRIP or CHARGE span is never a source of estimated minutes', () {
      final spans = [
        SessionSpan(
          kind: SessionKind.trip,
          start: _time(0),
          end: _time(5),
          sleepSeconds: 180,
          sleepSocDeltaPercent: 1.2,
          sleepEnergyWhEstimate: 90,
        ),
      ];

      final synthesized = synthesizeSleepGapEnergyBuckets(
        buckets: const [],
        spans: spans,
      );

      expect(synthesized, isEmpty);
    });

    test('an open PARKED span has nothing to fill yet', () {
      final spans = [
        SessionSpan(
          kind: SessionKind.parked,
          start: _time(0),
          sleepSeconds: 180,
          sleepSocDeltaPercent: 1.2,
          sleepEnergyWhEstimate: 90,
        ),
      ];

      final synthesized = synthesizeSleepGapEnergyBuckets(
        buckets: const [],
        spans: spans,
      );

      expect(synthesized, isEmpty);
    });
  });
}
