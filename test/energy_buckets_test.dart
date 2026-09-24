import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';
import 'package:capy_energy/core/mock_telemetry_data.dart';
import 'package:capy_ui/capy_ui.dart';

final _base = DateTime(2026, 8, 3, 13);

/// A moment [seconds] into the minute at [minute].
DateTime _at(int minute, {int seconds = 0}) =>
    _base.add(Duration(minutes: minute, seconds: seconds));

/// A minute bucket starting [minute] minutes after a round local hour.
EnergyBucket _minute(
  int minute, {
  double traction = 60,
  double regenerated = 0,
  double auxiliary = 6,
  double seconds = 60,
  double climate = 0,
  double climateSeconds = 0,
}) {
  return EnergyBucket(
    start: _base.add(Duration(minutes: minute)),
    width: EnergyBucket.oneMinute,
    tractionWh: traction,
    regeneratedWh: regenerated,
    auxiliaryWh: auxiliary,
    integratedSeconds: seconds,
    climateWh: climate,
    climateIntegratedSeconds: climateSeconds,
  );
}

void main() {
  group('energy composition', () {
    test('leaves the whole remainder unnamed when nothing measured it', () {
      final energy = readEnergyComposition([
        _minute(0, traction: 100, auxiliary: 30),
        _minute(1, traction: 80, auxiliary: 20),
      ]);

      expect(energy.divided, isFalse);
      expect(energy.climate, 0);
      expect(energy.system, 50);
      expect(energy.drawn, 230);
    });

    test('names the climate share once the reading covers the interval', () {
      final energy = readEnergyComposition([
        _minute(
          0,
          traction: 100,
          auxiliary: 30,
          climate: 12,
          climateSeconds: 60,
        ),
        _minute(1, traction: 80, auxiliary: 20, climate: 8, climateSeconds: 60),
      ]);

      expect(energy.divided, isTrue);
      expect(energy.climate, 20);
      expect(energy.system, 30);
      // The named shares still add back to the remainder they came out of.
      expect(energy.climate + energy.system, energy.auxiliary);
      expect(energy.drawn, 230);
    });

    test('refuses a partial cover instead of charging it to the system', () {
      // The climate reading arrived for one of the two minutes. Splitting on
      // that would report the uncovered minute's climate as system load.
      final energy = readEnergyComposition([
        _minute(
          0,
          traction: 100,
          auxiliary: 30,
          climate: 12,
          climateSeconds: 60,
        ),
        _minute(1, traction: 80, auxiliary: 20),
      ]);

      expect(energy.divided, isFalse);
      expect(energy.climate, 0);
      expect(energy.system, 50);
    });

    test('refuses a climate reading larger than the remainder', () {
      // A negative system share is not a share of anything, and no heater
      // returns energy to the pack.
      final energy = readEnergyComposition([
        _minute(
          0,
          traction: 100,
          auxiliary: 10,
          climate: 25,
          climateSeconds: 60,
        ),
      ]);

      expect(energy.divided, isFalse);
      expect(energy.system, 10);
    });

    test('a covered zero is a measurement, not an absence', () {
      final energy = readEnergyComposition([
        _minute(
          0,
          traction: 100,
          auxiliary: 30,
          climate: 0,
          climateSeconds: 60,
        ),
      ]);

      expect(energy.divided, isTrue);
      expect(energy.climate, 0);
      expect(energy.system, 30);
    });

    test('no measured seconds cannot be divided', () {
      expect(readEnergyComposition(const []).divided, isFalse);
      expect(readEnergyComposition([_minute(0, seconds: 0)]).divided, isFalse);
    });

    test('reduce carries the climate share and its coverage', () {
      final wide = reduceEnergyBuckets([
        _minute(0, auxiliary: 30, climate: 12, climateSeconds: 60),
        _minute(1, auxiliary: 20, climate: 8, climateSeconds: 60),
      ], const Duration(minutes: 5));

      expect(wide, hasLength(1));
      expect(wide.single.climateWh, 20);
      expect(wide.single.climateIntegratedSeconds, 120);
      // Reducing must not change what the ring reads.
      expect(readEnergyComposition(wide).divided, isTrue);
      expect(readEnergyComposition(wide).system, 30);
    });
  });

  group('bar capacity', () {
    // The grid lives in the design system. `slotsIn` is how a chart reaches
    // this function; calling it bare is what the profile exists to stop.
    int capacity(
      double plotWidth, {
      ChartBarProfile profile = AppSizes.chartBarProfile,
    }) => profile.slotsIn(plotWidth);

    test(
      'counts fixed-width bars against the plot, sparing a trailing gap',
      () {
        const profile = AppSizes.chartBarProfile;
        final slot = profile.pitch;

        // Exactly three slots' worth of content: three bars and two gaps.
        final threeBars = profile.contentWidth(3);
        expect(capacity(threeBars), 3);

        // One pixel short of the fourth bar still only fits three.
        expect(capacity(threeBars + slot - 1), 3);
        expect(capacity(threeBars + slot), 4);
      },
    );

    test('a plot with no room reports none rather than a negative', () {
      expect(capacity(0), 0);
      expect(capacity(-40), 0);
      expect(capacity(4), 0);
    });

    test('a dense bar profile fits more slots in the same plot', () {
      const plotWidth = 594.0;

      expect(capacity(plotWidth), 30);
      expect(capacity(plotWidth, profile: AppSizes.chartDenseBarProfile), 36);
    });
  });

  group('progressive bucket size', () {
    test('uses minute, five-minute, and fifteen-minute granularity', () {
      expect(progressiveEnergyBucketMinutes(32), 32);
      expect(progressiveEnergyBucketMinutes(61), 65);
      expect(progressiveEnergyBucketMinutes(179), 180);
      expect(progressiveEnergyBucketMinutes(181), 195);
      expect(
        nextEnergyBucketWidth(const Duration(minutes: 5)),
        const Duration(minutes: 6),
      );
      expect(
        nextEnergyBucketWidth(const Duration(minutes: 60)),
        const Duration(minutes: 65),
      );
    });

    test('a step that re-cuts boundaries still conserves the total', () {
      // 5 does not nest inside 2, so crossing that step moves energy between
      // bars. It must not create or lose any.
      final minutes = [
        for (var i = 0; i < 60; i++) _minute(i, traction: 7.0 + i),
      ];
      final two = reduceEnergyBuckets(minutes, const Duration(minutes: 2));
      final five = reduceEnergyBuckets(minutes, const Duration(minutes: 5));

      expect(
        five.fold(0.0, (sum, b) => sum + b.tractionWh),
        closeTo(two.fold(0.0, (sum, b) => sum + b.tractionWh), 1e-9),
      );
      expect(two, hasLength(30));
      expect(five, hasLength(12));
    });

    test('picks the finest width that fits the budget', () {
      // Thirty bars of budget: half an hour stays at one minute, and the step
      // up happens the minute it would overflow.
      expect(
        chooseEnergyBucketWidth(
          span: const Duration(minutes: 30),
          capacity: 30,
        ),
        const Duration(minutes: 1),
      );
      expect(
        chooseEnergyBucketWidth(
          span: const Duration(minutes: 31),
          capacity: 30,
        ),
        const Duration(minutes: 2),
      );
      expect(
        chooseEnergyBucketWidth(
          span: const Duration(minutes: 61),
          capacity: 30,
        ),
        const Duration(minutes: 3),
      );
    });

    test('width only ever steps up as a trip runs on', () {
      // A trip's duration is monotonic, so the chosen width must be too:
      // anything else would let the chart flap between two layouts.
      var previous = Duration.zero;
      for (var minutes = 1; minutes <= 600; minutes++) {
        final width = chooseEnergyBucketWidth(
          span: Duration(minutes: minutes),
          capacity: 30,
        );
        expect(width, greaterThanOrEqualTo(previous));
        previous = width;
      }
    });

    test('long spans continue to grow instead of overflowing silently', () {
      expect(
        chooseEnergyBucketWidth(span: const Duration(hours: 40), capacity: 30),
        const Duration(minutes: 80),
      );
      expect(
        chooseEnergyBucketWidth(span: const Duration(minutes: 5), capacity: 0),
        const Duration(minutes: 1),
      );
    });

    test('a partial minute still claims a whole bar', () {
      expect(
        chooseEnergyBucketWidth(
          span: const Duration(seconds: 20),
          capacity: 30,
        ),
        const Duration(minutes: 1),
      );
    });
  });

  group('reduction', () {
    test('a wider bucket is the exact sum of the minutes under it', () {
      final minutes = [
        for (var i = 0; i < 5; i++)
          _minute(i, traction: 10.0 * (i + 1), regenerated: i.toDouble()),
      ];

      final reduced = reduceEnergyBuckets(minutes, const Duration(minutes: 5));

      expect(reduced, hasLength(1));
      expect(reduced.single.tractionWh, closeTo(150, 1e-9));
      expect(reduced.single.regeneratedWh, closeTo(10, 1e-9));
      expect(reduced.single.auxiliaryWh, closeTo(30, 1e-9));
      expect(reduced.single.integratedSeconds, closeTo(300, 1e-9));
      expect(reduced.single.width, const Duration(minutes: 5));
    });

    test('boundaries land on the clock, not on the first sample', () {
      // A trip whose first minute is 13:03 still produces a five-minute bar
      // labelled 13:00, so the axis reads in round times and two trips are
      // comparable.
      final minutes = [for (var i = 3; i < 12; i++) _minute(i)];
      final reduced = reduceEnergyBuckets(minutes, const Duration(minutes: 5));

      expect(reduced.map((b) => b.start.minute).toList(), [0, 5, 10]);
      // 13:00 holds only 13:03 and 13:04 — the bar is short because the trip
      // started mid-interval, not because consumption dropped.
      expect(reduced.first.integratedSeconds, closeTo(120, 1e-9));
      expect(reduced[1].integratedSeconds, closeTo(300, 1e-9));
    });

    test('conserves energy across representative progressive steps', () {
      final minutes = [
        for (var i = 0; i < 97; i++)
          _minute(i, traction: 12.0 + i, regenerated: i % 7, auxiliary: 3),
      ];
      final total = minutes.fold(0.0, (sum, b) => sum + b.tractionWh);
      final regen = minutes.fold(0.0, (sum, b) => sum + b.regeneratedWh);

      for (final step in const [1, 2, 5, 16, 32, 65, 195]) {
        final reduced = reduceEnergyBuckets(minutes, Duration(minutes: step));
        expect(
          reduced.fold(0.0, (sum, b) => sum + b.tractionWh),
          closeTo(total, 1e-6),
          reason: 'traction lost at $step min',
        );
        expect(
          reduced.fold(0.0, (sum, b) => sum + b.regeneratedWh),
          closeTo(regen, 1e-6),
          reason: 'regeneration lost at $step min',
        );
      }
    });

    test('reducing twice is the same as reducing once', () {
      // Ten one-minute buckets reduced to ten minutes must match the same
      // buckets reduced to five and then summed by hand. Re-bucketing must not
      // change the numbers on screen.
      final minutes = [
        for (var i = 0; i < 10; i++) _minute(i, traction: 5.0 * i),
      ];

      final direct = reduceEnergyBuckets(minutes, const Duration(minutes: 10));
      final viaFive = reduceEnergyBuckets(minutes, const Duration(minutes: 5));

      expect(direct.single.tractionWh, closeTo(225, 1e-9));
      expect(
        viaFive.fold(0.0, (sum, b) => sum + b.tractionWh),
        closeTo(direct.single.tractionWh, 1e-9),
      );
    });

    test('the one-minute series passes through untouched', () {
      final minutes = [_minute(0), _minute(1)];
      expect(reduceEnergyBuckets(minutes, EnergyBucket.oneMinute), minutes);
    });

    test('an empty series reduces to nothing', () {
      expect(
        reduceEnergyBuckets(const [], const Duration(minutes: 5)),
        isEmpty,
      );
    });
  });

  group('gaps', () {
    test('a fixed slot grid preserves leading and trailing absence', () {
      final slots = fillEnergyBucketSlots(
        buckets: [_minute(2), _minute(4)],
        start: _base,
        width: EnergyBucket.oneMinute,
        slotCount: 6,
      );

      expect(slots, hasLength(6));
      expect(slots.map((bucket) => bucket.start.minute), [0, 1, 2, 3, 4, 5]);
      expect(slots.where((bucket) => bucket.isEmpty), hasLength(4));
      expect(slots[2].isEmpty, isFalse);
      expect(slots[4].isEmpty, isFalse);
    });

    test('an unreported stretch keeps its place on the axis', () {
      // 13:00, then nothing until 13:04. The three missing minutes have to
      // occupy their slots or the axis would compress time.
      final buckets = fillEnergyBucketGaps([_minute(0), _minute(4)]);

      expect(buckets, hasLength(5));
      expect(buckets.map((b) => b.start.minute).toList(), [0, 1, 2, 3, 4]);
      // The filler reads as absence, not as a minute that consumed nothing.
      for (final filler in buckets.getRange(1, 4)) {
        expect(filler.isEmpty, isTrue);
        expect(filler.integratedSeconds, 0);
        expect(filler.drawnWh, 0);
      }
      expect(buckets.first.isEmpty, isFalse);
    });

    test('a contiguous series is left alone', () {
      final buckets = [_minute(0), _minute(1), _minute(2)];
      expect(fillEnergyBucketGaps(buckets), hasLength(3));
    });

    test('filling works at any width', () {
      final reduced = reduceEnergyBuckets([
        _minute(0),
        _minute(20),
      ], const Duration(minutes: 5));
      final filled = fillEnergyBucketGaps(reduced);

      expect(filled.map((b) => b.start.minute).toList(), [0, 5, 10, 15, 20]);
      expect(filled.where((b) => b.isEmpty), hasLength(3));
    });
  });

  test('span is the sum of recorded widths, never a stamp difference', () {
    // Two recorded minutes, nine apart on the (untrustworthy) stamp. The axis
    // covers two minutes of recorded driving — the stamp gap is the clock's
    // lie, and `fillEnergyBucketSlots` reserves gap slots by position.
    expect(
      energyBucketSpan([_minute(0), _minute(9)]),
      const Duration(minutes: 2),
    );
    expect(energyBucketSpan(const []), Duration.zero);
  });

  group('windows', () {
    test('only the current drive is bounded by a session', () {
      expect(EnergyWindow.currentDrive.minutes, isNull);
      expect(EnergyWindow.currentDrive.isLive, isTrue);
      for (final window in EnergyWindow.values.where((w) => !w.isLive)) {
        expect(window.minutes, greaterThan(0));
      }
    });

    test('every window fits the bar budget at a progressive width', () {
      // A window the scale cannot fit would render past the plot, which
      // `_ChartGeometry` does not guard against.
      const capacity = 30;
      for (final window in EnergyWindow.values) {
        final minutes = window.minutes;
        if (minutes == null) continue;
        final width = chooseEnergyBucketWidth(
          span: Duration(minutes: minutes),
          capacity: capacity,
        );
        expect(
          (minutes / width.inMinutes).ceil(),
          lessThanOrEqualTo(capacity),
          reason: '$window overflows at ${width.inMinutes} min',
        );
      }
    });

    test('the short windows keep a fine resolution', () {
      // Fifteen minutes is the option for watching the drive happen, so it has
      // to stay at the one-minute bar the reference shows.
      expect(
        chooseEnergyBucketWidth(
          span: const Duration(minutes: 15),
          capacity: 30,
        ),
        const Duration(minutes: 1),
      );
      expect(
        chooseEnergyBucketWidth(
          span: const Duration(minutes: 60),
          capacity: 30,
        ),
        const Duration(minutes: 2),
      );
      expect(
        chooseEnergyBucketWidth(
          span: const Duration(minutes: 480),
          capacity: 30,
        ),
        const Duration(minutes: 16),
      );
    });

    test('a window spanning parked time keeps its scale', () {
      final result = EnergyWindowBucketsResult.fromMap(
        MockTelemetryData().energyBucketsInWindow(minutes: 480),
      );
      final width = chooseEnergyBucketWidth(
        span: const Duration(minutes: 480),
        capacity: 30,
      );
      final bars = fillEnergyBucketGaps(
        reduceEnergyBuckets(result.buckets, width),
      );

      // Real parked stretches are gaps WITHIN the window; the window itself
      // is a clock window of fixed length, so its scale is the window's own.
      expect(bars.any((b) => b.isEmpty), isTrue);
      expect(
        bars.fold(0.0, (sum, b) => sum + b.tractionWh),
        closeTo(result.buckets.fold(0.0, (sum, b) => sum + b.tractionWh), 1e-6),
      );
    });

    test('a window with no driving at all reports empty, not zero', () {
      final result = EnergyWindowBucketsResult.fromMap({
        'startUtcMillis': 0,
        'endUtcMillis': 60000,
        'buckets': <Object?>[],
      });
      expect(result.isEmpty, isTrue);
      expect(
        openEnergyBucketIndex(result.buckets, live: true, now: _base),
        isNull,
      );
    });
  });

  group('merge', () {
    test('the minute in progress comes from the live read', () {
      final stored = [_minute(0), _minute(1, seconds: 18, traction: 18)];
      final live = [_minute(1, seconds: 41, traction: 41)];

      final merged = mergeEnergyBuckets(stored, live);

      expect(merged, hasLength(2));
      // The database was written partway through the minute; memory has more
      // of it, so memory wins.
      expect(merged.last.integratedSeconds, 41);
      expect(merged.last.tractionWh, 41);
    });

    test('a whole stored minute survives a partial live one', () {
      // The screen opened mid-drive, so the monitor only caught the tail of
      // that minute. The database has all of it and must not be overwritten.
      final stored = [_minute(0, seconds: 60, traction: 60)];
      final live = [_minute(0, seconds: 12, traction: 12)];

      expect(mergeEnergyBuckets(stored, live).single.tractionWh, 60);
    });

    test('live minutes the database has not caught up to are added', () {
      final merged = mergeEnergyBuckets([_minute(0)], [_minute(1), _minute(2)]);
      expect(merged.map((b) => b.start.minute).toList(), [0, 1, 2]);
    });

    test(
      'the result stays chronological whatever order the inputs arrive in',
      () {
        final merged = mergeEnergyBuckets(
          [_minute(4), _minute(0)],
          [_minute(2)],
        );
        expect(merged.map((b) => b.start.minute).toList(), [0, 2, 4]);
      },
    );

    test('an empty side leaves the other untouched', () {
      final stored = [_minute(0), _minute(1)];
      expect(mergeEnergyBuckets(stored, const []), hasLength(2));
      expect(mergeEnergyBuckets(const [], stored), hasLength(2));
      expect(mergeEnergyBuckets(const [], const []), isEmpty);
    });

    test('merging is idempotent', () {
      // The chart merges on every poll, so a series that has already absorbed
      // the live read must not drift when it absorbs it again.
      final stored = [_minute(0), _minute(1, seconds: 30, traction: 30)];
      final live = [_minute(1, seconds: 52, traction: 52)];

      final once = mergeEnergyBuckets(stored, live);
      final twice = mergeEnergyBuckets(once, live);

      expect(twice.map((b) => b.tractionWh).toList(), [
        once[0].tractionWh,
        once[1].tractionWh,
      ]);
    });
  });

  group('open bucket', () {
    test('a short last minute is the one still filling', () {
      final buckets = [_minute(0), _minute(1, seconds: 24)];
      expect(
        openEnergyBucketIndex(buckets, live: true, now: _at(1, seconds: 24)),
        1,
      );
    });

    test('a complete last minute is not open', () {
      expect(
        openEnergyBucketIndex(
          [_minute(0), _minute(1)],
          live: true,
          now: _at(1, seconds: 59),
        ),
        isNull,
      );
    });

    test('an earlier short minute is a gap, not progress', () {
      // Only the last bucket can still be accumulating. A short one before it
      // is a stretch the car reported nothing for.
      final buckets = [_minute(0, seconds: 20), _minute(1)];
      expect(
        openEnergyBucketIndex(buckets, live: true, now: _at(1, seconds: 30)),
        isNull,
      );
    });

    test('a filled gap is not mistaken for an open minute', () {
      final buckets = fillEnergyBucketGaps([_minute(0), _minute(3)]);
      expect(buckets.last.integratedSeconds, 60);
      expect(
        openEnergyBucketIndex(buckets, live: true, now: _at(3, seconds: 30)),
        isNull,
      );
    });

    test('an empty series has no open minute', () {
      expect(openEnergyBucketIndex(const [], live: true, now: _base), isNull);
    });

    test('a trip that ended leaves no minute in progress', () {
      // The drive stopped 24 seconds into the minute. That bucket is final at
      // 24 seconds; nothing further is coming, even though the clock has not
      // left the interval yet. Reported as open, it kept an ended trip showing
      // a bar labelled as still filling.
      final buckets = [_minute(0), _minute(1, seconds: 24)];
      expect(
        openEnergyBucketIndex(buckets, live: false, now: _at(1, seconds: 40)),
        isNull,
      );
    });

    test('a stale last minute is not filling while a trip runs', () {
      // A trip is running but the newest bucket is minutes old — a data gap.
      // Nothing is landing in it, so it is not progress either.
      final buckets = [_minute(0), _minute(1, seconds: 24)];
      expect(openEnergyBucketIndex(buckets, live: true, now: _at(6)), isNull);
    });
    test(
      'an anomalous stored width is kept as recorded, and read honestly',
      () {
        // One stored interval once arrived 8.5 hours wide. The width is now
        // trusted as recorded (it is a row fact, not a stamp derivation), and
        // the open-bucket check reads it against the clock: an end hours past
        // now is a stale row, not a bar still filling.
        final bucket = EnergyBucket.fromInterval(
          IntervalRecord(
            sessionId: 'trip-1',
            startUtcMillis: _base.millisecondsSinceEpoch,
            widthMillis: 30600000,
            traction: const Measurement.measured(320, unit: 'Wh'),
            regen: const Measurement.measured(150, unit: 'Wh'),
            auxiliary: const Measurement.measured(10, unit: 'Wh'),
            climate: const Measurement.measured(0, unit: 'Wh'),
            delivered: const Measurement.measured(0, unit: 'Wh'),
            distance: const Measurement.measured(1.9, unit: 'km'),
            coveredSeconds: 60,
            climateCoveredSeconds: 0,
            speedCoveredSeconds: 60,
            deliveredCoveredSeconds: 0,
          ),
        );
        expect(bucket.width, const Duration(hours: 8, minutes: 30));
        // The measured energy stays — the width is read, never invented.
        expect(bucket.tractionWh, 320);
        expect(bucket.regeneratedWh, 150);
        // Read honestly: the width is the row's own fact, so the row genuinely
        // claims to reach 8.5 hours past its start, and the clock reads it as
        // still within that interval. Nothing here invents a shorter span.
        expect(
          openEnergyBucketIndex(
            [bucket],
            live: true,
            now: _base.add(const Duration(minutes: 3, seconds: 30)),
          ),
          0,
        );
      },
    );
  });

  test('drawn energy is traction plus auxiliary, before regeneration', () {
    // Regeneration is measured against what was drawn, not subtracted from it:
    // that is what puts it on the donut's inner arc instead of in the ring.
    final bucket = _minute(0, traction: 100, auxiliary: 20, regenerated: 30);
    expect(bucket.drawnWh, closeTo(120, 1e-9));
  });

  group('reconcileSessionEnergyBuckets', () {
    test('empty list returns empty', () {
      expect(reconcileSessionEnergyBuckets(const []), isEmpty);
    });

    test('consistent series without clock jumps is unmodified', () {
      final buckets = [_minute(0), _minute(1), _minute(2)];
      final reconciled = reconcileSessionEnergyBuckets(
        buckets,
        sessionStart: _base,
      );
      expect(reconciled, buckets);
    });

    test(
      're-anchors pre-jump bucket from May 2025 to session start in August 2026',
      () {
        final oldStart2025 = DateTime(2025, 5, 23, 22, 8);
        final newStart2026 = DateTime(2026, 8, 18, 22, 0);

        final preJumpBucket = EnergyBucket(
          start: oldStart2025,
          width: EnergyBucket.oneMinute,
          tractionWh: 17.5,
          regeneratedWh: 0,
          auxiliaryWh: 1.0,
          integratedSeconds: 44.3,
        );
        final postJumpBucket1 = EnergyBucket(
          start: newStart2026.add(const Duration(minutes: 1)),
          width: EnergyBucket.oneMinute,
          tractionWh: 31.9,
          regeneratedWh: 16.4,
          auxiliaryWh: 5.0,
          integratedSeconds: 25.8,
        );
        final postJumpBucket2 = EnergyBucket(
          start: newStart2026.add(const Duration(minutes: 2)),
          width: EnergyBucket.oneMinute,
          tractionWh: 134.8,
          regeneratedWh: 68.2,
          auxiliaryWh: 8.0,
          integratedSeconds: 60.0,
        );

        final reconciled = reconcileSessionEnergyBuckets([
          preJumpBucket,
          postJumpBucket1,
          postJumpBucket2,
        ], sessionStart: newStart2026);

        expect(reconciled.length, 3);
        expect(reconciled[0].start, newStart2026);
        expect(reconciled[0].tractionWh, 17.5);
        expect(reconciled[0].integratedSeconds, 44.3);

        expect(
          reconciled[1].start,
          newStart2026.add(const Duration(minutes: 1)),
        );
        expect(reconciled[1].tractionWh, 31.9);

        expect(
          reconciled[2].start,
          newStart2026.add(const Duration(minutes: 2)),
        );
        expect(reconciled[2].tractionWh, 134.8);
      },
    );

    test(
      'merges colliding buckets when clock jump aligns with an existing slot',
      () {
        final oldStart2025 = DateTime(2025, 5, 23, 22, 8);
        final newStart2026 = DateTime(2026, 8, 18, 22, 0);

        final preJumpBucket = EnergyBucket(
          start: oldStart2025,
          width: EnergyBucket.oneMinute,
          tractionWh: 10.0,
          regeneratedWh: 0,
          auxiliaryWh: 1.0,
          integratedSeconds: 20.0,
          startSoc: 85.0,
          endSoc: 84.8,
        );
        final postJumpBucket = EnergyBucket(
          start: newStart2026,
          width: EnergyBucket.oneMinute,
          tractionWh: 20.0,
          regeneratedWh: 5.0,
          auxiliaryWh: 2.0,
          integratedSeconds: 40.0,
          startSoc: 84.8,
          endSoc: 84.0,
        );

        final reconciled = reconcileSessionEnergyBuckets([
          preJumpBucket,
          postJumpBucket,
        ], sessionStart: newStart2026);

        expect(reconciled.length, 1);
        expect(reconciled[0].start, newStart2026);
        expect(reconciled[0].tractionWh, 30.0);
        expect(reconciled[0].integratedSeconds, 60.0);
        expect(reconciled[0].startSoc, 85.0);
        expect(reconciled[0].endSoc, 84.0);
      },
    );
  });

  group('state of charge in EnergyBucket', () {
    test('carries startSoc and endSoc from map, interval, and wire', () {
      final mapBucket = EnergyBucket.fromMap({
        'startUtcMillis': 1710000000000,
        'tractionWh': 50.0,
        'startSoc': 82.5,
        'endSoc': 81.0,
      });
      expect(mapBucket.startSoc, 82.5);
      expect(mapBucket.endSoc, 81.0);

      final intervalBucket = EnergyBucket.fromInterval(
        const IntervalRecord(
          sessionId: 's-1',
          startUtcMillis: 1710000000000,
          widthMillis: 60000,
          traction: Measurement.measured(50, unit: 'Wh'),
          regen: Measurement.measured(0, unit: 'Wh'),
          auxiliary: Measurement.measured(5, unit: 'Wh'),
          climate: Measurement.unreported(unit: 'Wh'),
          delivered: Measurement.unreported(unit: 'Wh'),
          distance: Measurement.measured(1.0, unit: 'km'),
          coveredSeconds: 60,
          climateCoveredSeconds: 0,
          speedCoveredSeconds: 60,
          deliveredCoveredSeconds: 0,
          startSoc: Measurement.measured(90.0, unit: '%'),
          endSoc: Measurement.measured(89.5, unit: '%'),
        ),
      );
      expect(intervalBucket.startSoc, 90.0);
      expect(intervalBucket.endSoc, 89.5);

      final wireBucket = EnergyBucket.fromWire(
        EnergyBucketWire(
          startUtcMillis: 1710000000000,
          tractionWh: 50.0,
          regeneratedWh: 0.0,
          auxiliaryWh: 5.0,
          integratedSeconds: 60.0,
          speedDistanceKm: 1.0,
          odometerDistanceKm: 1.0,
          speedIntegratedSeconds: 60.0,
          climateWh: 0.0,
          climateIntegratedSeconds: 0.0,
          deliveredWh: 3.5,
          startSoc: 77.0,
          endSoc: 76.5,
        ),
      );
      expect(wireBucket.startSoc, 77.0);
      expect(wireBucket.endSoc, 76.5);
    });

    test(
      'reduceEnergyBuckets preserves earliest startSoc and latest endSoc',
      () {
        final minutes = [
          EnergyBucket(
            start: _base,
            width: EnergyBucket.oneMinute,
            tractionWh: 60,
            regeneratedWh: 0,
            auxiliaryWh: 6,
            integratedSeconds: 60,
            startSoc: 80.0,
            endSoc: 79.5,
          ),
          EnergyBucket(
            start: _base.add(const Duration(minutes: 1)),
            width: EnergyBucket.oneMinute,
            tractionWh: 60,
            regeneratedWh: 0,
            auxiliaryWh: 6,
            integratedSeconds: 60,
            startSoc: 79.5,
            endSoc: 79.0,
          ),
        ];

        final reduced = reduceEnergyBuckets(
          minutes,
          const Duration(minutes: 5),
        );
        expect(reduced.length, 1);
        expect(reduced[0].startSoc, 80.0);
        expect(reduced[0].endSoc, 79.0);
      },
    );

    test(
      'reduceEnergyBuckets leaves startSoc and endSoc null when unmeasured',
      () {
        final minutes = [_minute(0), _minute(1)];

        final reduced = reduceEnergyBuckets(
          minutes,
          const Duration(minutes: 5),
        );
        expect(reduced.length, 1);
        expect(reduced[0].startSoc, isNull);
        expect(reduced[0].endSoc, isNull);
      },
    );
  });
}
