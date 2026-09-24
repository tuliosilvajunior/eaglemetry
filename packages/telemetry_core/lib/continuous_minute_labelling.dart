/// The single pure seam where CONTINUOUS mode decides what a minute was.
///
/// A CONTINUOUS session records one minute of energy for every minute the car
/// is awake, gated on nothing. `TRIP`, `PARKED` and `CHARGE` sessions keep
/// recording exactly as they do today; this file answers, for a minute the
/// continuous session already holds, which of those three covered it — or
/// names the fourth state when none did.
///
/// Labels are derived here, at read time, from the minutes and the session
/// spans the caller already has. Nothing here reads a database, a platform
/// channel or a clock of its own, so a trip finalized late or a charge
/// repriced after the fact corrects the marks the next time this runs,
/// without a stamped column ever holding a wrong answer.
library;

import 'dto/telemetry_store_models.dart';
import 'energy_buckets.dart';

/// One instant on the reconciled clock.
///
/// The head unit's wall clock steps when the car corrects it, so two instants
/// that are genuinely close together can carry UTC millis far apart. The
/// monotonic pair — [elapsedNanos] and [bootCount] — is what actually measures
/// elapsed time; it is the same pair sessions already carry for
/// monotonic-duration-style comparison. [bootCount] is null when the
/// boot is unknown, which forces every comparison against this instant onto
/// the wall clock.
class ReconciledInstant {
  const ReconciledInstant({
    required this.utcMillis,
    required this.elapsedNanos,
    this.bootCount,
  });

  final int utcMillis;
  final int elapsedNanos;
  final int? bootCount;

  /// The instant [duration] later.
  ///
  /// Used to turn a minute's start plus its width into the minute's end. A
  /// single minute never spans a reboot, so advancing both clocks by the same
  /// duration and keeping the boot count is safe.
  ReconciledInstant operator +(Duration duration) => ReconciledInstant(
    utcMillis: utcMillis + duration.inMilliseconds,
    elapsedNanos: elapsedNanos + duration.inMicroseconds * 1000,
    bootCount: bootCount,
  );
}

/// Orders [a] against [b] on the reconciled clock.
///
/// Compares elapsed nanos when both instants name the same non-null boot,
/// because that comparison survives a wall-clock step within the boot. Falls
/// back to UTC millis otherwise — a genuine reboot between the two instants,
/// or a boot count neither side can state.
int compareReconciledInstants(ReconciledInstant a, ReconciledInstant b) {
  final bootCount = a.bootCount;
  if (bootCount != null && bootCount == b.bootCount) {
    return a.elapsedNanos.compareTo(b.elapsedNanos);
  }
  return a.utcMillis.compareTo(b.utcMillis);
}

/// Which of the recording states a continuous minute belongs to.
///
/// [poweredOn] is the fourth state: a minute the continuous session recorded
/// that no `TRIP`, `PARKED` or `CHARGE` session covers. It is a real, named
/// answer — "Ligado" on screen — not a blank cell standing in for one.
enum ContinuousLabel { charge, trip, parked, poweredOn }

/// The order [ContinuousLabel] wins in when spans genuinely overlap.
///
/// A charge can run with the car in P, so a `PARKED` span and a `CHARGE` span
/// can both cover the same minute; this is the order #199 settled on to
/// resolve it. [ContinuousLabel.poweredOn] is never in this list: it is what a
/// minute gets when nothing here claims it, not a competitor for one.
const List<ContinuousLabel> continuousLabelPrecedence = [
  ContinuousLabel.charge,
  ContinuousLabel.trip,
  ContinuousLabel.parked,
];

/// One `TRIP`, `PARKED` or `CHARGE` session's span, as the labeller sees it.
///
/// [end] is the session's own end for a closed session, or the caller's "now"
/// for one still open — the labeller has no clock of its own to ask.
class ContinuousLabelSpan {
  ContinuousLabelSpan({
    required this.label,
    required this.start,
    required this.end,
  }) {
    // Finding 13d: was `assert(label != poweredOn)`, which Dart AOT strips
    // in release builds. An explicit throw keeps the invariant in production.
    if (label == ContinuousLabel.poweredOn) {
      throw ArgumentError(
        'poweredOn is assigned by the labeller, not read from a span',
      );
    }
  }

  final ContinuousLabel label;
  final ReconciledInstant start;
  final ReconciledInstant end;

  /// Whether this span covers any part of [start] to [end], half-open on
  /// both sides so two spans that merely touch do not count as overlapping.
  bool _coversInterval(ReconciledInstant start, ReconciledInstant end) =>
      compareReconciledInstants(this.start, end) < 0 &&
      compareReconciledInstants(start, this.end) < 0;
}

/// One minute a `CONTINUOUS` session recorded, before it is labelled.
///
/// [bucket] carries the minute's own energy and its start/end SOC; [start] is
/// that same minute restated on the reconciled clock, since [EnergyBucket]
/// itself only knows wall-clock time. [estimated] marks a minute the sleep-gap
/// reconstruction filled in rather than one the collector actually measured;
/// it must never read as an ordinary measured minute once labelled.
class ContinuousMinute {
  const ContinuousMinute({
    required this.start,
    required this.bucket,
    this.estimated = false,
  });

  final ReconciledInstant start;
  final EnergyBucket bucket;
  final bool estimated;

  ReconciledInstant get end => start + bucket.width;
}

/// A [ContinuousMinute] together with the label it was resolved to.
class LabelledContinuousMinute {
  const LabelledContinuousMinute({required this.minute, required this.label});

  final ContinuousMinute minute;
  final ContinuousLabel label;

  EnergyBucket get bucket => minute.bucket;
  bool get estimated => minute.estimated;
}

/// Labels every minute in [minutes] against [spans].
///
/// This is a total function over what it is given: a stretch with no
/// [ContinuousMinute] in [minutes] produces no entry in the result. It is a
/// gap, and gaps are the caller's decision to draw or estimate — this
/// function never fabricates a minute to fill one, measured or zero.
List<LabelledContinuousMinute> labelContinuousMinutes({
  required List<ContinuousMinute> minutes,
  required List<ContinuousLabelSpan> spans,
}) {
  return [
    for (final minute in minutes)
      LabelledContinuousMinute(
        minute: minute,
        label: _resolveLabel(minute, spans),
      ),
  ];
}

ContinuousLabel _resolveLabel(
  ContinuousMinute minute,
  List<ContinuousLabelSpan> spans,
) {
  final covering = <ContinuousLabel>{
    for (final span in spans)
      if (span._coversInterval(minute.start, minute.end)) span.label,
  };
  for (final label in continuousLabelPrecedence) {
    if (covering.contains(label)) return label;
  }
  return ContinuousLabel.poweredOn;
}

/// Resolves one label for a stretch made of several already-labelled
/// minutes, by the same precedence [labelContinuousMinutes] resolves one
/// minute with.
///
/// For a chart bucket wider than one minute: the widened bucket's label is
/// the highest-precedence label among the minutes it covers, or
/// [ContinuousLabel.poweredOn] when [labels] is empty. This is the same rule
/// applied at a coarser grain, not a second rule — a five-minute bar that
/// contains one minute of charging reads as charging for the same reason one
/// minute of charging inside a parked stretch does.
ContinuousLabel resolveStretchLabel(Iterable<ContinuousLabel> labels) {
  final present = labels.toSet();
  for (final label in continuousLabelPrecedence) {
    if (present.contains(label)) return label;
  }
  return ContinuousLabel.poweredOn;
}

/// One `TRIP`, `PARKED` or `CHARGE` session's span, in the shape a store read
/// returns: wall-clock boundaries, [end] null while the session is open.
class SessionSpan {
  const SessionSpan({
    required this.kind,
    required this.start,
    this.end,
    this.sleepSeconds,
    this.sleepSocDeltaPercent,
    this.sleepEnergyWhEstimate,
  });

  /// From an untyped map.
  factory SessionSpan.fromMap(Map<String, Object?> map) {
    final endedAtUtcMillis = (map['endedAtUtcMillis'] as num?)?.toInt();
    return SessionSpan(
      kind: SessionKind.fromName(map['kind'] as String? ?? 'TRIP'),
      start: DateTime.fromMillisecondsSinceEpoch(
        (map['startedAtUtcMillis'] as num?)?.toInt() ?? 0,
      ),
      end: endedAtUtcMillis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(endedAtUtcMillis),
      sleepSeconds: (map['sleepSeconds'] as num?)?.toInt(),
      sleepSocDeltaPercent: (map['sleepSocDeltaPercent'] as num?)?.toDouble(),
      sleepEnergyWhEstimate: (map['sleepEnergyWhEstimate'] as num?)?.toDouble(),
    );
  }

  final SessionKind kind;
  final DateTime start;

  /// Null for a session still open. [labelEnergyBuckets] closes it at the
  /// `now` it is given, the same way [ContinuousLabelSpan.end] documents.
  final DateTime? end;

  /// The reconstructed overnight-drain estimate this `PARKED` span resumed
  /// behind five sanity gates, or null when none applies — including for
  /// every non-`PARKED` kind. Non-null only together with
  /// [sleepSocDeltaPercent] and [sleepEnergyWhEstimate].
  final int? sleepSeconds;
  final double? sleepSocDeltaPercent;
  final double? sleepEnergyWhEstimate;
}

/// Labels [buckets] against the sessions in [spans], read at [now].
///
/// A thin adapter over [labelContinuousMinutes] for the shape a store read
/// actually returns: wall-clock buckets and wall-clock session boundaries,
/// neither carrying elapsed nanos or a boot count. Every [ReconciledInstant]
/// built here therefore carries a null [ReconciledInstant.bootCount], which
/// forces [compareReconciledInstants] onto the wall clock for every
/// comparison — correct here because the native side already reconciles a
/// session's own boundary across a reboot before it is ever persisted, so
/// the wall-clock value a store read returns is one the app can already
/// trust.
List<LabelledContinuousMinute> labelEnergyBuckets({
  required List<EnergyBucket> buckets,
  required List<SessionSpan> spans,
  required DateTime now,
  bool Function(EnergyBucket bucket)? isEstimated,
}) {
  ReconciledInstant instant(DateTime value) => ReconciledInstant(
    utcMillis: value.millisecondsSinceEpoch,
    elapsedNanos: 0,
  );

  return labelContinuousMinutes(
    minutes: [
      for (final bucket in buckets)
        ContinuousMinute(
          start: instant(bucket.start),
          bucket: bucket,
          estimated: isEstimated?.call(bucket) ?? false,
        ),
    ],
    spans: [
      for (final span in spans)
        if (span.kind != SessionKind.continuous)
          ContinuousLabelSpan(
            label: switch (span.kind) {
              SessionKind.trip => ContinuousLabel.trip,
              SessionKind.parked => ContinuousLabel.parked,
              SessionKind.charge => ContinuousLabel.charge,
              // CONTINUOUS spans are filtered above; the wildcard keeps the
              // switch exhaustive if SessionKind gains a new kind.
              _ => ContinuousLabel.poweredOn,
            },
            start: instant(span.start),
            end: instant(span.end ?? now),
          ),
    ],
  );
}

/// Synthesizes one estimated minute per genuine gap a `PARKED` span's own
/// sleep-gap estimate covers.
///
/// [buckets] is the continuous session's real one-minute series; a minute
/// already present there is never touched or duplicated. A stretch with no
/// minute is a gap, and stays one, UNLESS a closed `PARKED` span in [spans]
/// both covers it and carries [SessionSpan.sleepEnergyWhEstimate] — the
/// reconstructed overnight drain [ParkedSessionDetector.computeSleepGapEstimate]
/// resumed behind five sanity gates on the native side. Every other gap,
/// including one inside a `PARKED` span with no estimate, is left alone: this
/// is the one place #199 allows a minute the collector never watched to be
/// drawn, and only because a specific, gated measurement backs it.
///
/// The estimate names one total for the whole gap, not a per-minute reading,
/// so it is spread evenly across the gap's own minutes. It is a magnitude
/// drained from the pack while nothing else was running, so it lands in
/// [EnergyBucket.auxiliaryWh] — the same share every other unclassified draw
/// already reports through.
///
/// [buckets] also bounds how far back a fill can reach: nothing earlier than
/// its own first minute was ever watched by this continuous session, so a
/// `PARKED` span that started before the session did — the mode was turned on
/// mid-park, or the car was already asleep — never backfills past that edge.
/// An empty [buckets] has no such edge to anchor to, so nothing is
/// synthesized at all.
List<EnergyBucket> synthesizeSleepGapEnergyBuckets({
  required List<EnergyBucket> buckets,
  required List<SessionSpan> spans,
}) {
  if (buckets.isEmpty) return const [];
  final measuredStarts = {
    for (final bucket in buckets) bucket.start.millisecondsSinceEpoch,
  };
  final sessionStart = buckets
      .map((bucket) => bucket.start)
      .reduce((a, b) => a.isBefore(b) ? a : b);
  final synthesized = <EnergyBucket>[];
  for (final span in spans) {
    final energyWh = span.sleepEnergyWhEstimate;
    final end = span.end;
    if (span.kind != SessionKind.parked || energyWh == null || end == null) {
      continue;
    }
    final gapStart = ceilEnergyBucketBoundary(
      span.start,
      EnergyBucket.oneMinute,
    );
    final clampedStart = gapStart.isBefore(sessionStart)
        ? sessionStart
        : gapStart;
    final gapStarts = <DateTime>[
      for (
        var minute = clampedStart;
        minute.isBefore(end);
        minute = minute.add(EnergyBucket.oneMinute)
      )
        if (!measuredStarts.contains(minute.millisecondsSinceEpoch)) minute,
    ];
    if (gapStarts.isEmpty) continue;
    final perMinuteWh = energyWh / gapStarts.length;
    for (final start in gapStarts) {
      synthesized.add(
        EnergyBucket(
          start: start,
          width: EnergyBucket.oneMinute,
          tractionWh: 0,
          regeneratedWh: 0,
          auxiliaryWh: perMinuteWh,
          integratedSeconds: EnergyBucket.oneMinute.inSeconds.toDouble(),
        ),
      );
    }
  }
  synthesized.sort((a, b) => a.start.compareTo(b.start));
  return synthesized;
}
