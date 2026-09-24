import 'dto/telemetry_store_models.dart';
import 'energy_buckets.dart';
import 'measurement.dart';

export 'dto/telemetry_store_models.dart';

/// Layer 3 read surface: every historical screen asks one of three questions.
///
/// Section 4.4 settles this interface:
/// 1. `listSessions(filter, page)` -> rollups
/// 2. `session(id)` -> rollup + events
/// 3. `series(id, keys, width)` -> intervals and samples
///
/// Every quantity returned is a [Measurement], preserving Rule 2.5 across the boundary.
/// The phone implementation ([SqfliteStore]) is the reference.
abstract interface class TelemetryStore {
  /// The sessions matching [filter], paged by [page].
  ///
  /// Every returned session carries its rollup and endpoints wrapped in [Measurement]s.
  Future<SessionListPage> listSessions({
    SessionFilter? filter,
    PageRequest? page,
  });

  /// One session, with its rollup and event transition log.
  ///
  /// Returns null if the session does not exist.
  Future<SessionDetail?> session(String id);

  /// The intervals and sparse samples of one session.
  ///
  /// [widthMillis] applies strictly to intervals (Rule 2.3).
  /// [keys] filters which sparse sample series to retrieve from `sample`.
  /// Samples are returned at their recorded instants; charts hold the last value between them.
  Future<TelemetrySeries> series(
    String id, {
    Set<String>? keys,
    int? widthMillis,
  });
}

/// Reduces a list of [IntervalRecord] into intervals of wider bucket width [widthMillis].
///
/// [widthMillis] must be a positive multiple of 60,000 (1 minute).
/// Only reduces intervals; does not integrate CAN frames (Rule 2.1 & 2.3).
List<IntervalRecord> reduceIntervalRecords(
  List<IntervalRecord> intervals, {
  required int widthMillis,
  int? originUtcMillis,
}) {
  return reduceIntervalRecordsByIndex(
    intervals,
    widthMillis: widthMillis,
    // The full-stamp basis is the current behaviour for callers that name no
    // origin: the first interval's stamp opens the grid.
    positionOf: (interval) => interval.startUtcMillis,
    originUtcMillis: originUtcMillis,
  );
}

/// Reduces a list of [IntervalRecord] into intervals of wider bucket width
/// [widthMillis], placing every interval by [positionOf] instead of by its
/// wall-clock stamp.
///
/// The wall clock on the car is not trustworthy until the TBox syncs it: rows
/// recorded before that carry boot-default stamps months or years away from the
/// session. A position computed from those stamps inherits a defect the row
/// had no part in creating, so a consumer that can read a position — an index,
/// a count, a monotonic clock — states it explicitly here. See
/// `gb-time-authority-scout` for the coming authority; this seam is where that
/// design plugs in.
///
/// [positionOf] must return the interval's place in milliseconds; buckets stay
/// [widthMillis] wide, and the returned rows always claim
/// `widthMillis` regardless of what the inputs claimed.
///
/// [widthMillis] must be a positive multiple of 60,000 (1 minute).
/// Only reduces intervals; does not integrate CAN frames (Rule 2.1 & 2.3).
List<IntervalRecord> reduceIntervalRecordsByIndex(
  List<IntervalRecord> intervals, {
  required int widthMillis,
  required int Function(IntervalRecord interval) positionOf,
  int? originUtcMillis,
}) {
  if (intervals.isEmpty || widthMillis <= 60000) {
    return intervals;
  }
  final origin =
      originUtcMillis ??
      intervals.map(positionOf).reduce((a, b) => a < b ? a : b);
  final result = <IntervalRecord>[];
  final grouped = <int, List<IntervalRecord>>{};
  for (final interval in intervals) {
    final offset = positionOf(interval) - origin;
    final index = (offset / widthMillis).floor();
    final bucketStart = origin + index * widthMillis;
    grouped.putIfAbsent(bucketStart, () => []).add(interval);
  }

  final sortedStarts = grouped.keys.toList()..sort();
  for (final start in sortedStarts) {
    final bucketIntervals = grouped[start]!
      ..sort((a, b) => positionOf(a).compareTo(positionOf(b)));
    var traction = const Measurement.measured(0, unit: 'Wh');
    var regen = const Measurement.measured(0, unit: 'Wh');
    var auxiliary = const Measurement.measured(0, unit: 'Wh');
    var climate = const Measurement.measured(0, unit: 'Wh');
    var delivered = const Measurement.measured(0, unit: 'Wh');
    var distance = const Measurement.measured(0, unit: 'km');
    var coveredSeconds = 0.0;
    var climateCoveredSeconds = 0.0;
    var speedCoveredSeconds = 0.0;
    var deliveredCoveredSeconds = 0.0;

    for (final inv in bucketIntervals) {
      traction = Measurement.combine(
        traction,
        inv.traction,
        unit: 'Wh',
        compute: (a, b) => a + b,
      );
      regen = Measurement.combine(
        regen,
        inv.regen,
        unit: 'Wh',
        compute: (a, b) => a + b,
      );
      auxiliary = Measurement.combine(
        auxiliary,
        inv.auxiliary,
        unit: 'Wh',
        compute: (a, b) => a + b,
      );
      climate = Measurement.combine(
        climate,
        inv.climate,
        unit: 'Wh',
        compute: (a, b) => a + b,
      );
      delivered = Measurement.combine(
        delivered,
        inv.delivered,
        unit: 'Wh',
        compute: (a, b) => a + b,
      );
      distance = Measurement.combine(
        distance,
        inv.distance,
        unit: 'km',
        compute: (a, b) => a + b,
      );
      coveredSeconds += inv.coveredSeconds;
      climateCoveredSeconds += inv.climateCoveredSeconds;
      speedCoveredSeconds += inv.speedCoveredSeconds;
      deliveredCoveredSeconds += inv.deliveredCoveredSeconds;
    }

    final startSoc = bucketIntervals
        .firstWhere(
          (inv) => inv.startSoc.hasValue,
          orElse: () => bucketIntervals.first,
        )
        .startSoc;
    final endSoc = bucketIntervals
        .lastWhere(
          (inv) => inv.endSoc.hasValue,
          orElse: () => bucketIntervals.last,
        )
        .endSoc;
    final startVoltage = bucketIntervals
        .firstWhere(
          (inv) => inv.startVoltage.hasValue,
          orElse: () => bucketIntervals.first,
        )
        .startVoltage;
    final endVoltage = bucketIntervals
        .lastWhere(
          (inv) => inv.endVoltage.hasValue,
          orElse: () => bucketIntervals.last,
        )
        .endVoltage;

    result.add(
      IntervalRecord(
        sessionId: bucketIntervals.first.sessionId,
        startUtcMillis: start,
        widthMillis: widthMillis,
        traction: traction,
        regen: regen,
        auxiliary: auxiliary,
        climate: climate,
        delivered: delivered,
        distance: distance,
        coveredSeconds: coveredSeconds,
        climateCoveredSeconds: climateCoveredSeconds,
        speedCoveredSeconds: speedCoveredSeconds,
        deliveredCoveredSeconds: deliveredCoveredSeconds,
        startSoc: startSoc,
        endSoc: endSoc,
        startVoltage: startVoltage,
        endVoltage: endVoltage,
      ),
    );
  }
  return result;
}

/// The placement basis shared by the stores' series readers: the interval's
/// ordinal in the stamp-ordered list, as milliseconds on a one-minute grid.
///
/// The row's own [IntervalRecord.widthMillis] is authoritative (it is always
/// 60,000 today), so one interval occupies exactly one slot. The wall-clock
/// stamp is a label, not a span: deriving a position from it would turn a
/// boot-default stamp (months or years out of date) into a bar that claims a
/// 22000-hour session.
int indexOfIntervalPosition(int index, IntervalRecord interval) =>
    index * 60000;

/// Nanoseconds in one minute on the elapsed-realtime clock.
const _nanosPerMinute = 60000000000;

/// The placement basis the stores' series readers share: the monotonic axis
/// when the series still waits for the boot's anchor, the ordinal otherwise.
///
/// A pending series carries boot-default stamps, so the stamp order is the
/// order the broken clock wrote — not the order the car measured. The
/// monotonic pair (T2) is the true axis within one boot: position is
/// `(elapsed − sessionStartElapsed)` on the one-minute grid, and the stale
/// `startUtcMillis` never takes part in it.
///
/// The fallback is the ordinal ([indexOfIntervalPosition]), byte-identical to
/// today, whenever the pair cannot answer: no pending minute (a trusted
/// series positions exactly as today), a missing pair (every row written
/// before T2), a missing boot count, or more than one boot in the series.
/// Elapsed realtime restarts every boot, so a subtraction across a reboot is
/// not a span at all — the T5 family already paid for that confusion once.
int Function(IntervalRecord interval) intervalPositionOf(
  List<IntervalRecord> intervals,
) {
  int ordinal(IntervalRecord interval) =>
      indexOfIntervalPosition(intervals.indexOf(interval), interval);
  // A trusted series positions exactly as today: the monotonic axis is only
  // for rows whose stamps the sweeper will still correct.
  if (!seriesTimePending(intervals)) return ordinal;
  int? anchorBoot;
  int? anchorElapsed;
  for (final interval in intervals) {
    final elapsed = interval.startElapsedNanos;
    final boot = interval.startBootCount;
    // A missing pair, negative elapsed, or missing boot count means the
    // monotonic axis cannot answer for the whole series: fall back to ordinal.
    if (elapsed == null || elapsed < 0 || boot == null) return ordinal;
    if (anchorBoot == null) {
      anchorBoot = boot;
      anchorElapsed = elapsed;
    } else if (boot != anchorBoot) {
      // A reboot restarts the counter: one anchor cannot place two boots.
      return ordinal;
    } else if (elapsed < anchorElapsed!) {
      anchorElapsed = elapsed;
    }
  }
  if (anchorBoot == null || anchorElapsed == null) return ordinal;
  final boot = anchorBoot;
  final anchor = anchorElapsed;
  return (IntervalRecord interval) {
    final elapsed = interval.startElapsedNanos;
    if (elapsed == null ||
        elapsed < anchor ||
        interval.startBootCount != boot) {
      return ordinal(interval);
    }
    return ((elapsed - anchor) ~/ _nanosPerMinute) * 60000;
  };
}
