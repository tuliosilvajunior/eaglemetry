import 'dart:math' as math;

import 'dto/telemetry_store_models.dart';
import 'generated/telemetry_wire.g.dart';

/// Time-authority state names, spelled once. The detector sees a wrong clock
/// but can only wait for truth, so a minute born before the boot's anchor is
/// `pendingTimeState`: consumers keep drawing it and say the time is not
/// synced yet, instead of trusting a stamp the sweeper will still correct.
const pendingTimeState = 'pending';

/// True when any minute of the series still waits for the boot's anchor.
/// A pending series draws exactly like a known one — the bars are ordinal
/// since PR 286 — but the axis must not claim a confident wall time.
bool seriesTimePending(Iterable<IntervalRecord> intervals) =>
    intervals.any((interval) => interval.timeState == pendingTimeState);

/// One wall-clock-aligned interval of trip energy, in Wh, discharge positive.
///
/// The native side emits these one minute wide and sends them as the
/// `intervals` sync stream. Nothing in Dart folds them from frames.
/// Every wider bar the chart draws is made by [reduceEnergyBuckets] summing
/// adjacent minutes, never by re-integrating: the minute is the only place the
/// power integral is evaluated, so the chart, the donut and the session summary
/// cannot drift into three different answers for one trip.
class EnergyBucket {
  const EnergyBucket({
    required this.start,
    required this.width,
    required this.tractionWh,
    required this.regeneratedWh,
    required this.auxiliaryWh,
    required this.integratedSeconds,
    this.deliveredWh = 0,
    this.speedDistanceKm = 0,
    this.odometerDistanceKm = 0,
    this.speedIntegratedSeconds = 0,
    this.climateWh = 0,
    this.climateIntegratedSeconds = 0,
    this.startSoc,
    this.endSoc,
  });

  /// [width] is the cut the native accumulator used, and the caller knows it
  /// from the envelope's `bucketMillis`. It defaults to the minute because that
  /// is the only width anything is stored or charted at; the live efficiency
  /// window is the one reader that asks for a finer one.
  factory EnergyBucket.fromMap(
    Map<String, Object?> map, {
    Duration width = oneMinute,
  }) {
    return EnergyBucket(
      start: DateTime.fromMillisecondsSinceEpoch(
        (map['startUtcMillis'] as num?)?.toInt() ?? 0,
      ),
      width: width,
      tractionWh: (map['tractionWh'] as num?)?.toDouble() ?? 0,
      regeneratedWh: (map['regeneratedWh'] as num?)?.toDouble() ?? 0,
      auxiliaryWh: (map['auxiliaryWh'] as num?)?.toDouble() ?? 0,
      integratedSeconds:
          (map['integratedSeconds'] as num?)?.toDouble() ??
          (map['coveredSeconds'] as num?)?.toDouble() ??
          0,
      deliveredWh: (map['deliveredWh'] as num?)?.toDouble() ?? 0,
      speedDistanceKm:
          (map['speedDistanceKm'] as num?)?.toDouble() ??
          (map['distanceKm'] as num?)?.toDouble() ??
          0,
      odometerDistanceKm: (map['odometerDistanceKm'] as num?)?.toDouble() ?? 0,
      speedIntegratedSeconds:
          (map['speedIntegratedSeconds'] as num?)?.toDouble() ?? 0,
      climateWh: (map['climateWh'] as num?)?.toDouble() ?? 0,
      climateIntegratedSeconds:
          (map['climateIntegratedSeconds'] as num?)?.toDouble() ??
          (map['climateCoveredSeconds'] as num?)?.toDouble() ??
          0,
      startSoc:
          (map['startSoc'] as num?)?.toDouble() ??
          (map['startSocPercent'] as num?)?.toDouble(),
      endSoc:
          (map['endSoc'] as num?)?.toDouble() ??
          (map['endSocPercent'] as num?)?.toDouble(),
    );
  }

  /// From one stored interval.
  ///
  /// The interval **is** the bucket: the store returns the cut the car folded
  /// (the minute, or a reduced row whose width the store itself states), and
  /// this only spells it for the charts. The width comes from the row — never
  /// from a difference between stamps, which is exactly the derivation that
  /// turned a boot-default clock into a 22000-hour bar. The one distance the
  /// row holds serves both readings, exactly as the car's own mapping does —
  /// the stored row does not keep the odometer and the speed integral apart.
  factory EnergyBucket.fromInterval(IntervalRecord interval) {
    final widthMillis = interval.widthMillis;
    return EnergyBucket(
      start: DateTime.fromMillisecondsSinceEpoch(interval.startUtcMillis),
      width: Duration(milliseconds: widthMillis),
      tractionWh: interval.traction.displayValue ?? 0,
      regeneratedWh: interval.regen.displayValue ?? 0,
      auxiliaryWh: interval.auxiliary.displayValue ?? 0,
      integratedSeconds: interval.coveredSeconds,
      deliveredWh: interval.delivered.displayValue ?? 0,
      speedDistanceKm: interval.distance.displayValue ?? 0,
      odometerDistanceKm: interval.distance.displayValue ?? 0,
      speedIntegratedSeconds: interval.speedCoveredSeconds,
      climateWh: interval.climate.displayValue ?? 0,
      climateIntegratedSeconds: interval.climateCoveredSeconds,
      startSoc: interval.startSoc.displayValue,
      endSoc: interval.endSoc.displayValue,
    );
  }

  /// From the generated wire class.
  ///
  /// The width still comes from the envelope, not from the bucket: one bucket
  /// in a series cannot be cut differently from the rest, so it is not a field
  /// the wire repeats per bucket.
  factory EnergyBucket.fromWire(
    EnergyBucketWire wire, {
    Duration width = oneMinute,
  }) {
    return EnergyBucket(
      start: DateTime.fromMillisecondsSinceEpoch(wire.startUtcMillis),
      width: width,
      tractionWh: wire.tractionWh,
      regeneratedWh: wire.regeneratedWh,
      auxiliaryWh: wire.auxiliaryWh,
      integratedSeconds: wire.integratedSeconds,
      speedDistanceKm: wire.speedDistanceKm,
      odometerDistanceKm: wire.odometerDistanceKm,
      speedIntegratedSeconds: wire.speedIntegratedSeconds,
      climateWh: wire.climateWh,
      climateIntegratedSeconds: wire.climateIntegratedSeconds,
      deliveredWh: wire.deliveredWh,
      startSoc: wire.startSoc,
      endSoc: wire.endSoc,
    );
  }

  static const oneMinute = Duration(minutes: 1);

  /// Local start of the interval, aligned to [width] on the wall clock.
  final DateTime start;

  final Duration width;

  final double tractionWh;
  final double regeneratedWh;
  final double auxiliaryWh;
  final double deliveredWh;

  /// Seconds of [width] the integral actually covers. Less than the full width
  /// means the car reported nothing for the rest of it — the bar is drawn from
  /// what was measured, and the shortfall is not filled in.
  final double integratedSeconds;

  /// Distance integrated from speed samples inside this exact wall-clock cut.
  final double speedDistanceKm;

  /// Positive odometer movement assigned to this exact wall-clock cut.
  final double odometerDistanceKm;

  /// Valid speed coverage used to calculate a time-weighted average speed.
  final double speedIntegratedSeconds;

  /// Climate energy, a named share of [auxiliaryWh] rather than a fourth
  /// quantity beside it. The rest of the remainder is the system load.
  final double climateWh;

  /// Seconds of [integratedSeconds] the climate reading covered.
  ///
  /// Zero on every minute recorded before the Roadcast daemon published climate
  /// power with a verified scale, which is most of what is on disk. It is what
  /// separates "climate drew nothing" from "the remainder was never divided" —
  /// see [readEnergyComposition].
  final double climateIntegratedSeconds;

  final double? startSoc;
  final double? endSoc;

  DateTime get end => start.add(width);

  /// Energy drawn from the pack over the interval: traction plus everything
  /// else, before regeneration is credited back.
  double get drawnWh => tractionWh + auxiliaryWh;

  bool get isEmpty => integratedSeconds <= 0;
}

/// Fraction of the measured interval the climate reading must cover before the
/// auxiliary remainder is shown divided.
///
/// Anything short of complete cover would charge the uncovered seconds to the
/// system share, which is the one term nothing measures directly. The tolerance
/// exists for the boundary case — a daemon that gained the calibration part way
/// through a drive — not to permit a partial reading to be presented as a
/// division.
const double kClimateCoverageFloor = 0.98;

/// How a stretch of driving divides, in Wh, discharge positive.
///
/// [traction] and [auxiliary] partition the energy drawn. [climate] and
/// [system] then partition [auxiliary], but only when [divided] is true;
/// otherwise the whole remainder sits in [system] unnamed, which is what every
/// minute recorded before the climate signal had a verified scale means.
///
/// [regenerated] is measured against the energy drawn rather than being a slice
/// of it, which is why it is not part of either partition.
class EnergyComposition {
  const EnergyComposition({
    required this.traction,
    required this.auxiliary,
    required this.regenerated,
    required this.climate,
    required this.divided,
    required this.seconds,
  });

  static const empty = EnergyComposition(
    traction: 0,
    auxiliary: 0,
    regenerated: 0,
    climate: 0,
    divided: false,
    seconds: 0,
  );

  final double traction;
  final double auxiliary;
  final double regenerated;

  /// Zero unless [divided]. A zero here with [divided] true is a measurement:
  /// the climate drew nothing over the interval.
  final double climate;

  /// Whether the climate reading covered the interval well enough to name part
  /// of the remainder. False leaves [system] equal to [auxiliary].
  final bool divided;

  final double seconds;

  /// The remainder nothing has named: the steering assist, the pumps, the
  /// lamps, the electronics, and in cooling the part of the climate package the
  /// car's own counter leaves out.
  double get system => auxiliary - climate;

  /// Energy taken from the pack before regeneration is credited back.
  double get drawn => traction + auxiliary;

  /// Net energy the pack gave, which is the integral of pack power itself.
  ///
  /// The identity holds slice by slice, not only in total: the trapezoid of a
  /// signed drive power equals the trapezoid of its positive part minus that of
  /// its negative part. So this is the same number a separate pack integral
  /// would produce, and adding one would be a second answer to a question the
  /// buckets already answer.
  double get packWh => traction - regenerated + auxiliary;

  /// Share of traction energy that regeneration returned.
  ///
  /// Null below a whole watt-hour of traction, because the ratio there is a
  /// division of noise by noise and prints as a percentage nobody measured.
  double? get regenerationRatio =>
      traction > 1.0 ? regenerated / traction : null;
}

/// Reduces buckets to the composition the donut and the legend both read.
///
/// One reduction, so the ring and the figures beside it cannot disagree.
EnergyComposition readEnergyComposition(Iterable<EnergyBucket> buckets) {
  var traction = 0.0;
  var auxiliary = 0.0;
  var regenerated = 0.0;
  var climate = 0.0;
  var seconds = 0.0;
  var climateSeconds = 0.0;
  for (final bucket in buckets) {
    traction += bucket.tractionWh;
    auxiliary += bucket.auxiliaryWh;
    regenerated += bucket.regeneratedWh;
    climate += bucket.climateWh;
    seconds += bucket.integratedSeconds;
    climateSeconds += bucket.climateIntegratedSeconds;
  }

  // A climate reading larger than the remainder that contains it leaves a
  // negative system share, which is not a share of anything. That is a reading
  // the split cannot use, not a car that recovered energy through its heater.
  final covered =
      seconds > 0 && climateSeconds >= seconds * kClimateCoverageFloor;
  final divided = covered && climate >= 0 && climate <= auxiliary;

  return EnergyComposition(
    traction: traction,
    auxiliary: auxiliary,
    regenerated: regenerated,
    climate: divided ? climate : 0,
    divided: divided,
    seconds: seconds,
  );
}

/// What stretch of driving the energy chart is showing.
///
/// [currentDrive] and [sincePowerOn] are each bounded by a running session —
/// the trip, and the `CONTINUOUS` session respectively — and are the only two
/// that grow while you watch them. The rest are fixed windows of clock time
/// that take in whatever trips fell inside them, so a window can span several
/// drives and the parked gaps between them.
enum EnergyWindow {
  currentDrive(null),
  sincePowerOn(null),
  last15Minutes(15),
  lastHour(60),
  last8Hours(480);

  const EnergyWindow(this.minutes);

  /// Null for [currentDrive] and [sincePowerOn], each bounded by a session
  /// rather than by a span of clock.
  final int? minutes;

  bool get isLive =>
      this == EnergyWindow.currentDrive || this == EnergyWindow.sincePowerOn;
}

/// Rounds a required bucket width onto the progressive minute scale.
///
/// Short windows keep one-minute precision. Longer windows change less often:
/// five-minute steps start above one hour and fifteen-minute steps start above
/// three hours. The scale remains open-ended, so a long session can always fit
/// instead of overflowing at a fixed coarsest value.
int progressiveEnergyBucketMinutes(int requiredMinutes) {
  final minutes = math.max(1, requiredMinutes);
  if (minutes <= 60) return minutes;
  if (minutes <= 180) return ((minutes + 4) ~/ 5) * 5;
  return ((minutes + 14) ~/ 15) * 15;
}

/// How many bars fit in [plotWidth] logical pixels, on a grid whose slots are
/// [pitch] apart with [gap] of clear space between neighbours.
///
/// Bars keep a fixed width, so the chart does not compress them to fit. This
/// count defines the complete visible time grid. The bucket width must be
/// selected against it so the same screen adapts to a wider head unit without
/// changing the bar pitch.
///
/// The grid arrives as arguments, not defaults: pixel geometry belongs to the
/// design system, and [pitch] is stated once there, by `ChartBarProfile`. This
/// package neither holds a pixel nor restates the sum. Reach it through
/// `profile.slotsIn(plotWidth)` rather than calling it bare. See ADR 0011.
int energyChartBarCapacity(
  double plotWidth, {
  required double pitch,
  required double gap,
}) {
  if (plotWidth <= 0) return 0;
  assert(pitch > 0);
  assert(gap >= 0);
  // The last bar needs no trailing gap.
  return math.max(0, ((plotWidth + gap) / pitch).floor());
}

/// Smallest progressive width whose bar count fits [capacity].
///
/// [span] is the whole stretch the axis has to cover, gaps included, because an
/// interval with no data still occupies its slot on a time axis.
Duration chooseEnergyBucketWidth({
  required Duration span,
  required int capacity,
}) {
  if (capacity <= 0) return EnergyBucket.oneMinute;
  final spanMinutes = math.max(1, (span.inSeconds / 60).ceil());
  final requiredMinutes = (spanMinutes / capacity).ceil();
  return Duration(minutes: progressiveEnergyBucketMinutes(requiredMinutes));
}

/// Next stable width after a live chart completes its final slot.
Duration nextEnergyBucketWidth(Duration width) {
  final nextRequiredMinute = math.max(1, width.inMinutes + 1);
  return Duration(minutes: progressiveEnergyBucketMinutes(nextRequiredMinute));
}

/// Merges minute buckets into [width]-wide ones.
///
/// By default, alignment uses the local clock. Pass [origin] for a live session
/// whose first bucket must start at the session start. Historical windows keep
/// clock boundaries because their range is a clock-time query.
///
/// Input must be the one-minute series. Reducing an already-reduced list would
/// compound rounding and, worse, hide whether the source was ever measured.
List<EnergyBucket> reduceEnergyBuckets(
  List<EnergyBucket> minutes,
  Duration width, {
  DateTime? origin,
}) {
  assert(
    minutes.every((b) => b.width == EnergyBucket.oneMinute),
    'reduce the one-minute series, not an already-widened one',
  );
  if (minutes.isEmpty) return const [];
  if (width <= EnergyBucket.oneMinute) return List.unmodifiable(minutes);

  final grouped = <int, List<EnergyBucket>>{};
  for (final bucket in minutes) {
    final aligned = origin == null
        ? floorEnergyBucketBoundary(bucket.start, width)
        : _floorEnergyBucketFromOrigin(bucket.start, width, origin);
    grouped.putIfAbsent(aligned.millisecondsSinceEpoch, () => []).add(bucket);
  }

  final starts = grouped.keys.toList()..sort();
  return List.unmodifiable([
    for (final start in starts)
      () {
        final group = grouped[start]!;
        return EnergyBucket(
          start: DateTime.fromMillisecondsSinceEpoch(start),
          width: width,
          tractionWh: group.fold(0.0, (sum, b) => sum + b.tractionWh),
          regeneratedWh: group.fold(0.0, (sum, b) => sum + b.regeneratedWh),
          auxiliaryWh: group.fold(0.0, (sum, b) => sum + b.auxiliaryWh),
          integratedSeconds: group.fold(
            0.0,
            (sum, b) => sum + b.integratedSeconds,
          ),
          speedDistanceKm: group.fold(0.0, (sum, b) => sum + b.speedDistanceKm),
          odometerDistanceKm: group.fold(
            0.0,
            (sum, b) => sum + b.odometerDistanceKm,
          ),
          speedIntegratedSeconds: group.fold(
            0.0,
            (sum, b) => sum + b.speedIntegratedSeconds,
          ),
          climateWh: group.fold(0.0, (sum, b) => sum + b.climateWh),
          climateIntegratedSeconds: group.fold(
            0.0,
            (sum, b) => sum + b.climateIntegratedSeconds,
          ),
          startSoc: group
              .firstWhere((b) => b.startSoc != null, orElse: () => group.first)
              .startSoc,
          endSoc: group
              .lastWhere((b) => b.endSoc != null, orElse: () => group.last)
              .endSoc,
        );
      }(),
  ]);
}

DateTime _floorEnergyBucketFromOrigin(
  DateTime value,
  Duration width,
  DateTime origin,
) {
  final elapsed = value.difference(origin).inMicroseconds;
  final index = _floorDiv(elapsed, width.inMicroseconds);
  return origin.add(width * index);
}

/// The wall-clock boundary at or before [value] for buckets of [width].
///
/// Alignment uses local time for the same reason as [reduceEnergyBuckets]: the
/// boundary on screen must be the clock time the driver reads.
DateTime floorEnergyBucketBoundary(DateTime value, Duration width) {
  final widthMillis = width.inMilliseconds;
  assert(widthMillis > 0);
  final offset = value.timeZoneOffset.inMilliseconds;
  final local = value.millisecondsSinceEpoch + offset;
  final aligned = _floorDiv(local, widthMillis) * widthMillis - offset;
  return DateTime.fromMillisecondsSinceEpoch(aligned, isUtc: value.isUtc);
}

/// The first wall-clock bucket boundary at or after [value].
DateTime ceilEnergyBucketBoundary(DateTime value, Duration width) {
  final floor = floorEnergyBucketBoundary(value, width);
  return floor.isBefore(value) ? floor.add(width) : floor;
}

/// Builds an exact fixed-size time grid and places [buckets] in their slots.
///
/// Leading, internal, and trailing gaps become empty buckets. Data outside the
/// grid is ignored. Empty buckets are absence, not measured zeroes.
List<EnergyBucket> fillEnergyBucketSlots({
  required List<EnergyBucket> buckets,
  required DateTime start,
  required Duration width,
  required int slotCount,
}) {
  if (slotCount <= 0) return const [];
  assert(buckets.every((bucket) => bucket.width == width));

  final byStart = <int, EnergyBucket>{
    for (final bucket in buckets) bucket.start.millisecondsSinceEpoch: bucket,
  };
  return List.unmodifiable([
    for (var index = 0; index < slotCount; index++)
      () {
        final slotStart = start.add(width * index);
        return byStart[slotStart.millisecondsSinceEpoch] ??
            emptyEnergyBucket(start: slotStart, width: width);
      }(),
  ]);
}

/// One unmeasured interval used only to preserve a time slot.
EnergyBucket emptyEnergyBucket({
  required DateTime start,
  required Duration width,
}) => EnergyBucket(
  start: start,
  width: width,
  tractionWh: 0,
  regeneratedWh: 0,
  auxiliaryWh: 0,
  integratedSeconds: 0,
  speedDistanceKm: 0,
  odometerDistanceKm: 0,
  speedIntegratedSeconds: 0,
  climateWh: 0,
  climateIntegratedSeconds: 0,
);

/// Fills the gaps in [buckets] with empty intervals of the same width.
///
/// A time axis has to keep its scale: a stretch the car reported nothing for
/// occupies its slot rather than letting the bars either side sit next to each
/// other as if no time had passed. The filler carries no energy and no measured
/// seconds, so it renders as absence, not as zero consumption.
List<EnergyBucket> fillEnergyBucketGaps(List<EnergyBucket> buckets) {
  if (buckets.length <= 1) return List.unmodifiable(buckets);

  final width = buckets.first.width;
  final filled = <EnergyBucket>[];
  for (var i = 0; i < buckets.length; i++) {
    filled.add(buckets[i]);
    if (i + 1 >= buckets.length) break;
    var cursor = buckets[i].end;
    final next = buckets[i + 1].start;
    while (cursor.isBefore(next)) {
      filled.add(emptyEnergyBucket(start: cursor, width: width));
      cursor = cursor.add(width);
    }
  }
  return List.unmodifiable(filled);
}

/// Merges the live minutes onto the stored series.
///
/// Both sides are the same integral over the same frames, so a minute they both
/// cover differs only in how much of it each one saw. [integratedSeconds] is
/// exactly that measure, so the wider coverage wins: the database holds a whole
/// minute the in-memory monitor only caught the tail of when the screen opened
/// mid-drive, and the monitor holds the minute in progress that the database
/// has only partly been written for.
///
/// Ties keep [live], which is the fresher read of the same coverage.
///
/// Both inputs must be one-minute series — merging widened buckets would
/// compare coverages of different denominators.
List<EnergyBucket> mergeEnergyBuckets(
  List<EnergyBucket> stored,
  List<EnergyBucket> live,
) {
  assert(
    [...stored, ...live].every((b) => b.width == EnergyBucket.oneMinute),
    'merge the one-minute series, not a widened one',
  );
  if (live.isEmpty) return List.unmodifiable(stored);
  if (stored.isEmpty) return List.unmodifiable(live);

  final byStart = <int, EnergyBucket>{
    for (final bucket in stored) bucket.start.millisecondsSinceEpoch: bucket,
  };
  for (final bucket in live) {
    final key = bucket.start.millisecondsSinceEpoch;
    final existing = byStart[key];
    if (existing == null ||
        bucket.integratedSeconds >= existing.integratedSeconds) {
      byStart[key] = bucket;
    }
  }

  final starts = byStart.keys.toList()..sort();
  return List.unmodifiable([for (final start in starts) byStart[start]!]);
}

/// Index of the interval still being accumulated, or null when none is.
///
/// The open bucket is short because it is still filling, not because
/// consumption dropped, and the chart says so rather than letting it read as a
/// dip. Only the last bucket can be open: an earlier short one is a stretch the
/// car reported nothing for, which is a gap, not progress.
///
/// Partial coverage alone does not make a bucket open, and treating it that way
/// left an ended trip permanently reporting its last minute as in progress —
/// the drive stopped at 21:17:50, so that minute is final at 18 seconds and
/// nothing further is coming. A bucket is only filling when [live] says a trip
/// is running *and* its interval has not yet closed against [now].
int? openEnergyBucketIndex(
  List<EnergyBucket> buckets, {
  required bool live,
  required DateTime now,
}) {
  if (!live || buckets.isEmpty) return null;
  final last = buckets.last;
  if (last.isEmpty) return null;
  // A trip can be running while the newest bucket is old — a data gap. That
  // bucket is not filling either; nothing has landed in it for a while.
  if (!last.end.isAfter(now)) return null;
  return last.integratedSeconds < last.width.inSeconds
      ? buckets.length - 1
      : null;
}

/// Whole stretch the axis must cover, gaps included.
///
/// A sum of recorded widths rather than a difference between stamps: the
/// charts read durations from what the car recorded, never from a wall-clock
/// subtraction. Stamps today are minute-aligned with the widths, so the two
/// agree — and they diverge exactly when the clock is the liar.
Duration energyBucketSpan(List<EnergyBucket> buckets) {
  if (buckets.isEmpty) return Duration.zero;
  var total = Duration.zero;
  for (final bucket in buckets) {
    total += bucket.width;
  }
  return total;
}

/// Reconciles energy buckets of a session if a clock jump occurred.
///
/// If uncalibrated MCU/firmware clock timestamps (e.g. May 2025) produced
/// buckets that drastically predate [sessionStart] — or drastically postdate
/// it, as a 2027 stamp does — this re-anchors those pre/post-jump buckets so
/// they align to the real-time start of the session.
List<EnergyBucket> reconcileSessionEnergyBuckets(
  List<EnergyBucket> buckets, {
  DateTime? sessionStart,
}) {
  if (buckets.isEmpty) return const [];

  final referenceStart = sessionStart ?? _dominantStart(buckets);
  const outlierThreshold = Duration(hours: 1);

  final preJump = <EnergyBucket>[];
  final postJump = <EnergyBucket>[];

  for (final bucket in buckets) {
    // Outlier in either direction: an uncalibrated clock can stamp a minute
    // months in the past *or* in the future. A future stamp otherwise escapes
    // this remap, reaches the chart's span, and turns a nine-minute trip into
    // a 22000-hour bar.
    if (referenceStart.difference(bucket.start).abs() > outlierThreshold) {
      preJump.add(bucket);
    } else {
      postJump.add(bucket);
    }
  }

  if (preJump.isEmpty) {
    return List.unmodifiable(buckets);
  }

  final targetBase = sessionStart != null
      ? floorEnergyBucketBoundary(sessionStart, EnergyBucket.oneMinute)
      : (postJump.isNotEmpty
            ? postJump.first.start.subtract(Duration(minutes: preJump.length))
            : floorEnergyBucketBoundary(
                referenceStart,
                EnergyBucket.oneMinute,
              ));

  preJump.sort((a, b) => a.start.compareTo(b.start));
  final firstPreJumpStart = preJump.first.start;

  final byStart = <int, EnergyBucket>{
    for (final bucket in postJump) bucket.start.millisecondsSinceEpoch: bucket,
  };

  for (final bucket in preJump) {
    final offset = bucket.start.difference(firstPreJumpStart);
    final newStart = targetBase.add(offset);
    final key = newStart.millisecondsSinceEpoch;
    final existing = byStart[key];
    if (existing == null) {
      byStart[key] = EnergyBucket(
        start: newStart,
        width: bucket.width,
        tractionWh: bucket.tractionWh,
        regeneratedWh: bucket.regeneratedWh,
        auxiliaryWh: bucket.auxiliaryWh,
        integratedSeconds: bucket.integratedSeconds,
        deliveredWh: bucket.deliveredWh,
        speedDistanceKm: bucket.speedDistanceKm,
        odometerDistanceKm: bucket.odometerDistanceKm,
        speedIntegratedSeconds: bucket.speedIntegratedSeconds,
        climateWh: bucket.climateWh,
        climateIntegratedSeconds: bucket.climateIntegratedSeconds,
        startSoc: bucket.startSoc,
        endSoc: bucket.endSoc,
      );
    } else {
      byStart[key] = EnergyBucket(
        start: newStart,
        width: bucket.width,
        tractionWh: existing.tractionWh + bucket.tractionWh,
        regeneratedWh: existing.regeneratedWh + bucket.regeneratedWh,
        auxiliaryWh: existing.auxiliaryWh + bucket.auxiliaryWh,
        integratedSeconds:
            existing.integratedSeconds + bucket.integratedSeconds,
        deliveredWh: existing.deliveredWh + bucket.deliveredWh,
        speedDistanceKm: existing.speedDistanceKm + bucket.speedDistanceKm,
        odometerDistanceKm:
            existing.odometerDistanceKm + bucket.odometerDistanceKm,
        speedIntegratedSeconds:
            existing.speedIntegratedSeconds + bucket.speedIntegratedSeconds,
        climateWh: existing.climateWh + bucket.climateWh,
        climateIntegratedSeconds:
            existing.climateIntegratedSeconds + bucket.climateIntegratedSeconds,
        startSoc: bucket.startSoc ?? existing.startSoc,
        endSoc: existing.endSoc ?? bucket.endSoc,
      );
    }
  }

  final starts = byStart.keys.toList()..sort();
  return List.unmodifiable([for (final start in starts) byStart[start]!]);
}

/// The start of the dominant minute cluster, when no authoritative session
/// start is at hand.
///
/// The median minute is the middle of the recorded session whichever end the
/// clock lied about, so both a past-default and a future-default block are
/// measured against the block that represents the real drive.
DateTime _dominantStart(List<EnergyBucket> buckets) {
  final sorted = [...buckets]..sort((a, b) => a.start.compareTo(b.start));
  return sorted[sorted.length ~/ 2].start;
}

int _floorDiv(int value, int divisor) {
  final quotient = value ~/ divisor;
  return (value % divisor != 0 && value < 0) ? quotient - 1 : quotient;
}
