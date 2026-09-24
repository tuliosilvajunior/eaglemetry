import 'dart:math' as math;

import 'package:telemetry_core/telemetry_core.dart';

/// Shared power ceiling for the charge chart, in kW.
///
/// Fixed so two sessions can be compared by eye. It sits above the vehicle's
/// 70 kW maximum, so in practice every session is plotted on the same scale.
const double chargeGraphMaximumPowerKw = 80;

/// Maps real charging power onto the shared 0–100 chart height.
///
/// The logarithmic curve keeps a 1 kW charge visible while preserving an
/// absolute comparison between sessions. [ceilingKw] is the value that maps to
/// full height; it is a parameter rather than a constant so the curve, the axis
/// ticks, and the tooltip can never disagree about the scale in use.
double chargePowerPlotValue(
  double powerKw, {
  double ceilingKw = chargeGraphMaximumPowerKw,
}) {
  if (!powerKw.isFinite || ceilingKw <= 0) return double.nan;
  // Clamping is only ever reached for a reading above the resolved ceiling,
  // and `buildChargeGraphData` raises the ceiling past the observed peak
  // precisely so a real measurement is never flattened into the top gridline.
  final bounded = powerKw.clamp(0, ceilingKw).toDouble();
  return math.log(1 + bounded) / math.log(1 + ceilingKw) * 100;
}

/// What a bucket of a charge session is doing.
enum ChargePhase {
  /// Energy is going in. The bucket plots what was measured.
  charging,

  /// The limit has been met and the car is idle on the plug.
  ///
  /// SOC is carried forward rather than left missing. That is only honest
  /// here: with no current flowing the charge is known to be sitting still,
  /// so repeating the last reading states a fact rather than inventing one.
  holding,

  /// Nothing was recorded. Left empty, because nothing is known.
  gap,
}

/// One time bucket for the V2 charge-session chart.
class ChargeGraphBucket {
  const ChargeGraphBucket({
    required this.startSeconds,
    required this.endSeconds,
    required this.socPercent,
    required this.powerKw,
    this.phase = ChargePhase.charging,
  });

  final double startSeconds;
  final double endSeconds;
  final double? socPercent;
  final double? powerKw;
  final ChargePhase phase;

  /// True where SOC is carried forward rather than measured in this bucket.
  bool get isHeld => phase == ChargePhase.holding;
}

/// Screen-ready charge chart data with a fixed, time-based resolution.
class ChargeGraphData {
  const ChargeGraphData({
    required this.buckets,
    required this.intervalSeconds,
    required this.axisMaximumKw,
    this.targetReachedSeconds = const [],
    this.truncatedTail = Duration.zero,
  });

  final List<ChargeGraphBucket> buckets;
  final int intervalSeconds;

  /// Plotted offsets, in seconds, where the charge limit was met.
  final List<double> targetReachedSeconds;

  /// Idle plugged-in time dropped from the right edge.
  ///
  /// A car left connected for days would otherwise squeeze the charge itself
  /// into a few pixels. Non-zero means the plot stops short of the unplug.
  final Duration truncatedTail;

  /// Power that maps to full chart height. Normally
  /// [chargeGraphMaximumPowerKw]; raised to clear the observed peak when a
  /// session charges harder than the shared ceiling, so a real reading is never
  /// silently flattened against the top of the plot.
  final double axisMaximumKw;

  bool get isEmpty => buckets.isEmpty;

  /// Y-axis rules, in kW, from the top down. Derived here so the screen never
  /// restates the ceiling as a literal.
  List<double> get powerTicksKw => [
    axisMaximumKw,
    for (final tick in const [30.0, 10.0])
      if (tick < axisMaximumKw) tick,
    0,
  ];
}

/// Groups a charge session into fixed, readable time intervals.
///
/// Sessions use readable bucket intervals as their duration increases. When
/// [capacity] is supplied, the smallest interval that fits the visible slot
/// grid wins. SOC uses the latest observed value in each bucket. Power uses the
/// mean of the observed samples in that bucket. Missing samples stay missing.
ChargeGraphData buildChargeGraphData({
  required ChargeDetailReading detail,
  required Duration? duration,
  int? capacity,
}) {
  final seriesEnd = [
    for (final point in detail.socSeries) point.x,
    for (final point in detail.powerSeries) point.x,
  ].fold<double>(0, math.max);
  // The window covers the whole plug-in, charge and idle alike: time spent
  // sitting at the limit is worth seeing, and the phases below tell it apart
  // from charging rather than the window hiding it. What a long idle tail
  // cannot be allowed to do is squeeze the charge itself into nothing, so it
  // is capped relative to the charge that earned the plot.
  final windowSeconds = (duration?.inMilliseconds ?? 0) / 1000;
  final requested = windowSeconds > 0 ? windowSeconds : seriesEnd;
  final durationSeconds = _cappedWindowSeconds(requested, detail);
  if (durationSeconds <= 0 ||
      (detail.socSeries.isEmpty && detail.powerSeries.isEmpty)) {
    return const ChargeGraphData(
      buckets: [],
      intervalSeconds: 60,
      axisMaximumKw: chargeGraphMaximumPowerKw,
    );
  }

  final intervalSeconds = _fixedIntervalSeconds(
    durationSeconds,
    capacity: capacity,
  );
  final bucketCount = (durationSeconds / intervalSeconds).ceil();

  // Both series are reduced in a single pass each: a sample's bucket is a
  // division, not a search, so cost is linear in samples instead of
  // samples × buckets.
  final socLatest = List<double?>.filled(bucketCount, null);
  for (final point in detail.socSeries) {
    final index = _bucketIndex(point, intervalSeconds, bucketCount);
    // Last sample in series order wins, matching "latest observed SOC".
    if (index != null) socLatest[index] = point.y.clamp(0, 100).toDouble();
  }

  final powerSum = List<double>.filled(bucketCount, 0);
  final powerCount = List<int>.filled(bucketCount, 0);
  for (final point in detail.powerSeries) {
    final index = _bucketIndex(point, intervalSeconds, bucketCount);
    if (index == null) continue;
    powerSum[index] += point.y;
    powerCount[index] += 1;
  }

  // The first met limit opens the holding phase.
  final firstTargetSeconds = detail.targetReachedSeconds.isEmpty
      ? null
      : detail.targetReachedSeconds.reduce(math.min);

  final buckets = <ChargeGraphBucket>[];
  double? carried =
      detail.session.startSoc.displayValue ??
      (detail.socSeries.isNotEmpty ? detail.socSeries.first.y : null);
  for (var index = 0; index < bucketCount; index++) {
    final startSeconds = index * intervalSeconds.toDouble();
    final measuredSoc = socLatest[index];
    final power = powerCount[index] == 0
        ? null
        : powerSum[index] / powerCount[index];
    final charging = power != null && power > chargeIdlePowerKw;
    final afterTarget =
        firstTargetSeconds != null &&
        startSeconds + intervalSeconds > firstTargetSeconds;
    if (measuredSoc != null) {
      carried = measuredSoc;
    }
    final effectiveSoc = carried;
    final ChargePhase phase;
    if (charging) {
      phase = ChargePhase.charging;
    } else if (afterTarget) {
      phase = ChargePhase.holding;
    } else if (effectiveSoc != null) {
      phase = ChargePhase.charging;
    } else {
      phase = ChargePhase.gap;
    }
    buckets.add(
      ChargeGraphBucket(
        startSeconds: startSeconds,
        endSeconds: math.min(
          durationSeconds,
          (index + 1) * intervalSeconds.toDouble(),
        ),
        socPercent: effectiveSoc,
        // Holding reports zero rather than nothing, on the same grounds that
        // let its SOC be carried: the phase is only entered once the limit was
        // met and the charger stopped, so no current is flowing whether or not
        // a sample says so. Leaving it absent broke the curve in mid-air at the
        // last measured kilowatt instead of closing it at zero where charging
        // actually ended. A gap keeps nothing, because there nothing is known.
        powerKw: phase == ChargePhase.holding ? (power ?? 0) : power,
        phase: phase,
      ),
    );
  }

  return ChargeGraphData(
    buckets: List.unmodifiable(buckets),
    intervalSeconds: intervalSeconds,
    axisMaximumKw: _axisMaximumKw(buckets),
    targetReachedSeconds: List.unmodifiable([
      for (final seconds in detail.targetReachedSeconds)
        if (seconds >= 0 && seconds <= durationSeconds) seconds,
    ]),
    truncatedTail: Duration(
      milliseconds: ((requested - durationSeconds) * 1000).round(),
    ),
  );
}

/// Power at or below which a sample counts as idle rather than charging.
const double chargeIdlePowerKw = 0.05;

/// Fraction of the charge the idle tail may add before it is cut.
const double _maxTailShare = 0.35;

/// Window to plot, with a runaway idle tail trimmed off the end.
///
/// The charge is what the chart is about. A car left plugged in for days would
/// otherwise reduce it to a sliver, so the tail past the last measured power is
/// allowed to take only [_maxTailShare] of the plot before it is cut short.
double _cappedWindowSeconds(double requested, ChargeDetailReading detail) {
  if (requested <= 0) return requested;
  var lastActive = 0.0;
  for (final point in detail.powerSeries) {
    if (point.y > chargeIdlePowerKw && point.x > lastActive) {
      lastActive = point.x;
    }
  }
  if (lastActive <= 0) return requested;
  final cap = lastActive * (1 + _maxTailShare);
  return math.min(requested, cap);
}

/// Resolves the plotted power ceiling for a session.
///
/// Stays at the shared [chargeGraphMaximumPowerKw] for every session under it,
/// which is what makes two charts comparable at a glance. A session that peaks
/// above it raises the ceiling to the next 10 kW step instead of clamping, so
/// the curve keeps reporting a real measurement rather than flattening into the
/// top gridline while the tooltip still reads the true kW.
double _axisMaximumKw(List<ChargeGraphBucket> buckets) {
  var peak = 0.0;
  for (final bucket in buckets) {
    final power = bucket.powerKw;
    if (power != null && power.isFinite && power > peak) peak = power;
  }
  if (peak <= chargeGraphMaximumPowerKw) return chargeGraphMaximumPowerKw;
  return (peak / 10).ceil() * 10;
}

/// Bucket for [point], or null when it falls outside the plotted window.
///
/// A sample landing exactly on a boundary belongs to the interval it opens,
/// and the trailing edge of the last interval is inclusive so a final reading
/// is never dropped.
int? _bucketIndex(
  TelemetrySeriesPoint point,
  int intervalSeconds,
  int bucketCount,
) {
  final x = point.x;
  if (!x.isFinite || x < 0) return null;
  final index = x ~/ intervalSeconds;
  if (index < bucketCount) return index;
  return x == bucketCount * intervalSeconds ? bucketCount - 1 : null;
}

int _fixedIntervalSeconds(double durationSeconds, {int? capacity}) {
  // Keep the previous 24-bar default for callers that do not have layout
  // information yet.
  final budget = capacity ?? 24;
  if (budget <= 0) return 60;
  // The minute is the floor, as it is everywhere else. A five-minute floor
  // gave a short charge four bars and hid the taper the driver plugged in to
  // see; the slot grid already widens the bucket as the session grows.
  final width = chooseEnergyBucketWidth(
    span: Duration(milliseconds: (durationSeconds * 1000).ceil()),
    capacity: budget,
  );
  return width.inSeconds;
}
