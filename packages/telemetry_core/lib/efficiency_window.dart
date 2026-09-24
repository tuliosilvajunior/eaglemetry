import 'dart:math' as math;

import 'energy_buckets.dart';

/// What one interval of driving says about efficiency.
///
/// Efficiency is a ratio, and a ratio needs both terms. These states name the
/// ways an interval can fail to supply them, so the chart can draw absence as
/// absence instead of as a zero the car never reported.
enum EfficiencyState {
  /// Moved, and drew energy to do it. The only state with a real ratio.
  consuming,

  /// Moved on almost no energy — coasting. The ratio is arithmetically huge
  /// rather than informative, so it is not reported as a number.
  coasting,

  /// Spent energy without moving: stopped with the climate system running.
  /// Zero km/kWh is the honest reading, not a missing one.
  idle,

  /// Gave more back than it took. A ratio would divide by a negative, so the
  /// interval reports recovered energy instead.
  regenerating,

  /// Reported, and reported stillness: stopped, with nothing running that the
  /// pack could measure. There is no ratio, but there is a measurement — this
  /// is a car at a traffic light, not a car that went quiet.
  still,

  /// The car reported nothing for this interval. Not a measurement.
  ///
  /// Kept apart from [still] because the two are different facts about the car,
  /// and folding them together would make the line break identically for a red
  /// light and for a bus that stopped publishing.
  unreported,
}

/// One interval of the efficiency series.
class EfficiencyPoint {
  const EfficiencyPoint({
    required this.start,
    required this.measured,
    required this.state,
    required this.distanceKm,
    required this.drawnWh,
    required this.regeneratedWh,
    this.kmPerKwh,
  });

  /// Start of the interval, carried straight from the source bucket so the
  /// series keeps the wall-clock grid the buckets were aligned to.
  final DateTime start;

  /// How much of the trailing window the car actually reported.
  ///
  /// **Not the interval.** Since the series reads over a trailing window, this
  /// is the covered part of that window — up to three minutes for a point that
  /// sits ten seconds after its neighbour — so `start + measured` describes
  /// nothing. It exists to scale the floors below, which are rates, so a window
  /// the car only half covered is judged on the half it has.
  final Duration measured;

  final EfficiencyState state;

  /// Distance covered over the trailing window, **not over this interval**.
  ///
  /// Same span as [measured]: [readEfficiency] sums this across every bucket in
  /// the window, so at a three-minute window over ten-second buckets it is the
  /// sum of eighteen of them. See the warning on [regeneratedWh].
  final double distanceKm;

  /// Energy taken from the pack before regeneration is credited back, summed
  /// over the trailing window — **not over this interval**.
  ///
  /// This is the window's *demand*, and it is the term the chart draws as a
  /// line, because a car that is moving is always asking for some energy. It
  /// never approaches zero, so it has no pole.
  final double drawnWh;

  /// Energy the pack took back, summed over the trailing window — **not over
  /// this interval**.
  ///
  /// Drawn as the band under the demand line. Its thickness is the whole
  /// reason the two lines are worth showing together.
  ///
  /// **Do not total these across points.** [distanceKm], [drawnWh] and
  /// [regeneratedWh] all carry window sums while the points sit ten seconds
  /// apart, so consecutive points overlap by seventeen buckets out of
  /// eighteen. Summing `points.map((p) => p.drawnWh)` overstates the energy by
  /// about the span. The ratios are unaffected — [drawnWhPerKm] and
  /// [netWhPerKm] divide a window sum by a window sum, and [EfficiencyWindow]
  /// totals the raw buckets rather than these fields — but anything new that
  /// aggregates a series, a CSV export above all, has to reduce the buckets and
  /// not these.
  ///
  /// The field names say interval and the values are windows. Renaming them is
  /// the real repair; this warning is the interim one.
  final double regeneratedWh;

  /// Energy taken from the pack, regeneration already credited back. Negative
  /// means the interval was a net gain.
  ///
  /// This is the interval's *cost*, and it is the honest efficiency term — but
  /// it is a difference of two large numbers. On this car regeneration returns
  /// 40 to 47 % of what is drawn, so over a short interval the two nearly
  /// cancel and the remainder is dominated by the auxiliary load. That is why
  /// the series is reduced over a trailing window rather than per interval;
  /// see [readEfficiency].
  double get netWh => drawnWh - regeneratedWh;

  /// Demand per kilometre. Null when the interval did not move enough to
  /// divide by — see [efficiencyDistanceFloorKm].
  double? get drawnWhPerKm =>
      measured > Duration.zero &&
          distanceKm >= efficiencyDistanceFloorKm(measured)
      ? drawnWh / distanceKm
      : null;

  /// Cost per kilometre, on the same terms as [drawnWhPerKm].
  double? get netWhPerKm =>
      measured > Duration.zero &&
          distanceKm >= efficiencyDistanceFloorKm(measured)
      ? netWh / distanceKm
      : null;

  /// Only set for [EfficiencyState.consuming] and [EfficiencyState.idle].
  ///
  /// The value is the true ratio and is not clamped. A chart with a fixed axis
  /// clips it for display; clamping here would put an invented number into the
  /// window average.
  final double? kmPerKwh;

  bool get hasValue => kmPerKwh != null;

  /// Whether the interval added range instead of spending it.
  bool get gainedRange => state == EfficiencyState.regenerating;
}

/// The efficiency series and the average over the same intervals.
class EfficiencySeries {
  const EfficiencySeries({
    required this.points,
    required this.distanceKm,
    required this.netWh,
    this.averageKmPerKwh,
  });

  static const empty = EfficiencySeries(
    points: <EfficiencyPoint>[],
    distanceKm: 0,
    netWh: 0,
  );

  final List<EfficiencyPoint> points;

  /// Distance over every measured interval in the window.
  final double distanceKm;

  /// Net pack energy over every measured interval in the window.
  final double netWh;

  /// [distanceKm] divided by [netWh], not the mean of [points].
  ///
  /// A mean of ratios weights a crawling interval the same as a fast one and
  /// reports an average the trip never achieved. The ratio of the sums is the
  /// window's actual efficiency.
  ///
  /// Null when the window has no measured distance or gave back at least as
  /// much energy as it took, because neither has an efficiency.
  final double? averageKmPerKwh;

  bool get isEmpty => points.isEmpty;

  /// Newest interval that carries a state worth pointing at, or null.
  ///
  /// The chart head and its slider follow this. Only [EfficiencyState.unreported]
  /// is skipped: a car that has just stopped reporting should leave the marker
  /// on the last thing it did say. A standstill is not skipped, because a
  /// standstill is one of the things it can say.
  EfficiencyPoint? get head {
    for (var index = points.length - 1; index >= 0; index--) {
      if (points[index].state != EfficiencyState.unreported) {
        return points[index];
      }
    }
    return null;
  }
}

/// Which distance term to divide by.
enum EfficiencyDistanceSource {
  /// Odometer movement, falling back to integrated speed. Correct for wide
  /// intervals, where whole odometer kilometres land often enough to resolve.
  odometerFirst,

  /// Integrated speed only. Below a minute the odometer resolves in steps far
  /// coarser than the interval, so it reports one interval's whole kilometre
  /// and zero for its neighbours.
  speedOnly,
}

/// Speed below which an interval counts as not having moved, in km/h.
///
/// Two kilometres an hour. Slow enough that a crawl in traffic still registers,
/// fast enough that integration noise around a standstill does not read as
/// motion.
const double kEfficiencyMinSpeedKmh = 2.0;

/// Average pack draw below which an interval counts as not having drawn, in W.
///
/// A hundred watts. Far under any real auxiliary load — the climate system
/// alone sits near 2.5 kW — and far over integration noise, so it separates a
/// coasting car from one that is running something.
///
/// This is the old fixed floor of half a watt-hour, restated as the rate it
/// always was: over the ten-second interval it was written for, 0.5 Wh is
/// 180 W. Expressing it as a power is what lets the same judgement apply to a
/// three-minute window without either loosening or tightening it.
///
/// **KNOWN DEFECT, measured 2026-08-07. The sentence above about auxiliary
/// load is wrong, and this floor lands in the middle of the resting draw.**
///
/// It was written before the car had ever been measured at rest. Two stationary
/// sessions that night, both with every load off and drive power at exactly
/// zero, read **39.8 W and 159.3 W**. The floor sits between
/// them, so one physical state classifies two ways:
///
/// | Resting draw | `drew` | `moved` | State | Painted as |
/// |---|---|---|---|---|
/// | 39.8 W | false | false | [EfficiencyState.still] | line breaks |
/// | 159.3 W | true | false | [EfficiencyState.idle] | pinned to `plot.bottom` |
///
/// The same parked car therefore either breaks the line or is thrown to the
/// worst end of the axis, depending on nothing the driver did.
///
/// Raising the number does not fix it. The resting draw is not a constant — it
/// moved by a factor of four between two readings an hour apart — so any fixed
/// floor in this range will keep flipping. Two honest repairs exist:
///
///  * derive the floor from the session's own observed resting draw, so it
///    tracks whatever the car happens to idle at; or
///  * accept that [EfficiencyState.still] and [EfficiencyState.idle] are not
///    separable below roughly 200 W and merge them **explicitly**, which is
///    the same reasoning the enum already applies to the pairs it refuses to
///    merge — the point being that the merge is stated, not accidental.
///
/// Not repaired here because both options change what the card claims, and that
/// is a decision about the product rather than about a constant.
const double kEfficiencyMinPowerW = 100.0;

/// Distance an interval of [width] must cover before a ratio is taken.
///
/// The floor is a *rate*, not a fixed amount, because the interval is no longer
/// one fixed width. A constant of one metre was right for ten seconds and lets
/// a barely-moving car through a three-minute window, where the tiny distance
/// then divides into a large energy and reports several hundred Wh/km as if it
/// were a measurement of driving.
double efficiencyDistanceFloorKm(Duration width) =>
    kEfficiencyMinSpeedKmh *
    width.inMilliseconds /
    Duration.millisecondsPerHour;

/// Energy an interval of [width] must account for before a ratio is taken.
///
/// Scales with the interval for the same reason as [efficiencyDistanceFloorKm].
double efficiencyEnergyFloorWh(Duration width) =>
    kEfficiencyMinPowerW * width.inMilliseconds / Duration.millisecondsPerHour;

/// How far back each point of the series reaches.
///
/// Three minutes. Regeneration returns energy that was spent earlier, so an
/// interval narrower than the spend-and-recover cycle sees one side of it at a
/// time: the climb reads as waste and the descent that pays it back reads as a
/// miracle. Measured over the recorded drives, the mean step between adjacent
/// points falls from 4.9 km/kWh at ten seconds to 0.43 here, and the series
/// stops clipping. Five minutes is calmer still but stops answering "what am I
/// doing now", which is the only question a live card is for.
///
/// The points stay ten seconds apart. Each one simply looks further back.
const Duration kEfficiencyWindow = Duration(minutes: 3);

/// Reads a bucket series as efficiency.
///
/// The buckets carry the only power integral the app evaluates. This reduces
/// them and never re-integrates, so the card cannot disagree with the energy
/// chart or the session summary about the same stretch of driving.
///
/// [buckets] should already be on a filled time grid — see
/// [fillEnergyBucketSlots] — because an unmeasured interval has to keep its
/// slot on a time axis.
///
/// Each point reduces the [window] of buckets ending at that slot, so the
/// series keeps one point per bucket while every point answers over a span
/// wide enough for the answer to exist. Setting [window] to [Duration.zero]
/// reduces each bucket on its own, which is what the stored-minute readers
/// want and what the window average has always done.
EfficiencySeries readEfficiency(
  List<EnergyBucket> buckets, {
  EfficiencyDistanceSource? distanceSource,
  Duration window = kEfficiencyWindow,
}) {
  if (buckets.isEmpty) return EfficiencySeries.empty;

  final slot = buckets.first.width;
  final source =
      distanceSource ??
      (slot < EnergyBucket.oneMinute
          ? EfficiencyDistanceSource.speedOnly
          : EfficiencyDistanceSource.odometerFirst);

  // How many slots each point reaches back over. A window shorter than one
  // slot, or none at all, degenerates to the per-bucket reading.
  final span = slot.inMilliseconds <= 0
      ? 1
      : math.max(1, window.inMilliseconds ~/ slot.inMilliseconds);

  final points = <EfficiencyPoint>[];
  var totalDistanceKm = 0.0;
  var totalNetWh = 0.0;
  var measuredSeconds = 0.0;

  for (var index = 0; index < buckets.length; index++) {
    final bucket = buckets[index];

    // The window average sums the raw buckets, not the reduced points, so a
    // bucket inside several windows still contributes exactly once.
    if (!bucket.isEmpty) {
      totalDistanceKm += _distanceOf(bucket, source);
      totalNetWh += bucket.drawnWh - bucket.regeneratedWh;
      measuredSeconds += bucket.integratedSeconds;
    }

    // A slot the car reported nothing for stays a gap, even when the window
    // behind it is full. The trailing window is what gives the reading its
    // value, not what keeps it alive: a car that has gone quiet must not go on
    // showing a figure for three more minutes as though it were current.
    if (bucket.isEmpty) {
      points.add(
        EfficiencyPoint(
          start: bucket.start,
          measured: Duration.zero,
          state: EfficiencyState.unreported,
          distanceKm: 0,
          drawnWh: 0,
          regeneratedWh: 0,
        ),
      );
      continue;
    }

    var distanceKm = 0.0;
    var drawnWh = 0.0;
    var regeneratedWh = 0.0;
    var coveredSeconds = 0.0;
    for (var back = math.max(0, index - span + 1); back <= index; back++) {
      final earlier = buckets[back];
      if (earlier.isEmpty) continue;
      distanceKm += _distanceOf(earlier, source);
      drawnWh += earlier.drawnWh;
      regeneratedWh += earlier.regeneratedWh;
      coveredSeconds += earlier.integratedSeconds;
    }

    // Coverage is what separates absence from a measured zero. A window the
    // car reported nothing for across its whole span has no terms at all; one
    // it partly covered is still a valid ratio over the part it covered.
    if (coveredSeconds <= 0) {
      points.add(
        EfficiencyPoint(
          start: bucket.start,
          measured: Duration.zero,
          state: EfficiencyState.unreported,
          distanceKm: 0,
          drawnWh: 0,
          regeneratedWh: 0,
        ),
      );
      continue;
    }

    // The floors follow the span actually measured, not the nominal window,
    // so a window that is only half covered is judged on the half it has.
    final covered = Duration(milliseconds: (coveredSeconds * 1000).round());
    final netWh = drawnWh - regeneratedWh;
    final moved = distanceKm >= efficiencyDistanceFloorKm(covered);
    final energyFloor = efficiencyEnergyFloorWh(covered);
    final drew = netWh >= energyFloor;
    final gaveBack = netWh <= -energyFloor;

    final state = switch ((moved, drew, gaveBack)) {
      (_, _, true) => EfficiencyState.regenerating,
      (true, true, _) => EfficiencyState.consuming,
      (true, false, _) => EfficiencyState.coasting,
      (false, true, _) => EfficiencyState.idle,
      // Neither moved nor drew. The car was reporting, and what it reported was
      // stillness — which is a measurement, not the absence of one.
      (false, false, _) => EfficiencyState.still,
    };

    points.add(
      EfficiencyPoint(
        start: bucket.start,
        measured: covered,
        state: state,
        distanceKm: distanceKm,
        drawnWh: drawnWh,
        regeneratedWh: regeneratedWh,
        kmPerKwh: switch (state) {
          EfficiencyState.consuming => distanceKm / (netWh / 1000),
          EfficiencyState.idle => 0,
          _ => null,
        },
      ),
    );
  }

  final measured = Duration(milliseconds: (measuredSeconds * 1000).round());
  return EfficiencySeries(
    points: List.unmodifiable(points),
    distanceKm: totalDistanceKm,
    netWh: totalNetWh,
    // The average is judged on the whole measured span, so its floors follow
    // that span rather than one interval's.
    averageKmPerKwh:
        totalDistanceKm >= efficiencyDistanceFloorKm(measured) &&
            totalNetWh >= efficiencyEnergyFloorWh(measured)
        ? totalDistanceKm / (totalNetWh / 1000)
        : null,
  );
}

double _distanceOf(EnergyBucket bucket, EfficiencyDistanceSource source) =>
    switch (source) {
      EfficiencyDistanceSource.speedOnly => bucket.speedDistanceKm,
      EfficiencyDistanceSource.odometerFirst =>
        bucket.odometerDistanceKm > 0
            ? bucket.odometerDistanceKm
            : bucket.speedDistanceKm,
    };
