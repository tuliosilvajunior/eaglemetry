import 'dart:math' as math;

import 'insight_place.dart';
import 'insight_route_index.dart';
import 'measurement.dart';

/// The assertion an [Insight] makes. Localized copy is generated from this
/// value; the engine never stores a sentence.
enum InsightClaim { tripVsOwnAverage30d, variantVsVariant }

/// Which reference the measured side was compared to.
enum InsightBaseline { ownAverage30d, otherVariantSameRoute }

/// Why a trip did not enter a statistic. [InsightSupport] counts each
/// separately; they must not be folded into one `n`.
enum InsightExclusion {
  /// No CAN pack energy. The trip is outside the universe.
  neverRecorded,

  /// No minute buckets. The integral cannot be recomputed.
  noMinuteBuckets,

  /// The integral and the SOC disagree about direction.
  signContradiction,

  /// The SOC is absent or inside the noise floor, so it cannot confirm.
  unconfirmedSign,

  /// Distance below [kInsightDistanceFloorKm].
  tooShort,

  /// No close time, so the 30-day window cannot place it.
  notClosed,

  /// A different [InsightTrip.aggregationVersion] than the subject.
  versionMismatch,

  /// Closed outside the moving window. Only applies to the reference set.
  outsideWindow,

  /// Not on the same named route as the subject.
  notOnRoute,

  /// On the route, but on a third way that is not in this pair.
  otherVariant,
}

/// Why slice 1 produced no [Insight]. The subject or the reference could not
/// fill the fields the type requires.
enum InsightAbsence {
  subjectNeverRecorded,
  subjectNoMinuteBuckets,
  subjectSignContradiction,
  subjectUnconfirmedSign,
  subjectTooShort,
  subjectNotClosed,
  insufficientSupport,
  notOnRoute,
  noOtherVariant,
}

enum InsightConfidence { notDistinguishable, supported }

/// Last 30 days. A product window, not the retention setting.
const kInsightOwnAverageWindow = Duration(days: 30);

/// Trips shorter than this stay out of the reference and cannot be a subject.
const kInsightDistanceFloorKm = 0.5;

/// Quartiles need this many considered trips. Below it the layer says there
/// is not enough data, which is the honest first-week answer.
const kInsightMinReferenceTrips = 4;

/// All recorded trips of a route. Not the 30-day product window.
const kInsightRouteWindow = Duration.zero;

/// Pairs further apart than this are not pairs.
const kInsightPairMaxCalendar = Duration(days: 14);

/// Pairs whose clock time of day differs by more than this are not pairs.
const kInsightPairMaxTimeOfDay = Duration(hours: 3);

/// Pairs whose mean ambient differs by more than this are not pairs.
const kInsightPairMaxTempC = 8.0;

/// Two pairs give a group comparison. One pair is a single difference.
const kInsightMinPairs = 2;

/// Unpaired fallback needs this many usable trips on each way.
const kInsightMinVariantTrips = 2;

/// How many trips the comparison kept, how many it refused, and why.
class InsightSupport {
  const InsightSupport({
    required this.window,
    required this.considered,
    required this.excluded,
  });

  final Duration window;
  final int considered;
  final Map<InsightExclusion, int> excluded;

  int get excludedTotal =>
      excluded.values.fold<int>(0, (sum, count) => sum + count);

  @override
  bool operator ==(Object other) {
    if (other is! InsightSupport) return false;
    if (window != other.window || considered != other.considered) return false;
    if (excluded.length != other.excluded.length) return false;
    for (final entry in excluded.entries) {
      if (other.excluded[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(window, considered, Object.hashAll(excluded.entries));
}

/// One comparison: measured − reference, with the support that produced it.
class Insight {
  const Insight({
    required this.claim,
    required this.magnitude,
    required this.subject,
    required this.reference,
    required this.baseline,
    required this.support,
    required this.aggregationVersion,
    required this.confidence,
  });

  final InsightClaim claim;

  /// Subject minus reference, in the same unit as [subject].
  final Measurement magnitude;
  final Measurement subject;
  final Measurement reference;
  final InsightBaseline baseline;
  final InsightSupport support;
  final int aggregationVersion;
  final InsightConfidence confidence;
}

/// What slice 1 answers for one closed trip against the 30-day average.
class InsightRead {
  const InsightRead._({required this.support, this.insight, this.absence});

  factory InsightRead.none({
    required InsightAbsence absence,
    required InsightSupport support,
  }) {
    return InsightRead._(absence: absence, support: support);
  }

  factory InsightRead.present(Insight insight) {
    return InsightRead._(insight: insight, support: insight.support);
  }

  final Insight? insight;
  final InsightAbsence? absence;
  final InsightSupport support;

  bool get hasInsight => insight != null;
}

/// The primary [InsightRead] selected for a trip according to engine policy,
/// along with the secondary/discarded comparison if one was computed.
class InsightSelection {
  const InsightSelection({required this.primary, this.secondary});

  factory InsightSelection.none({
    InsightAbsence absence = InsightAbsence.subjectNeverRecorded,
    Duration window = kInsightOwnAverageWindow,
  }) {
    return InsightSelection(
      primary: InsightRead.none(
        absence: absence,
        support: InsightSupport(
          window: window,
          considered: 0,
          excluded: const {},
        ),
      ),
    );
  }

  final InsightRead primary;
  final InsightRead? secondary;

  /// The discarded / alternate comparison, if one was computed.
  InsightRead? get discarded => secondary;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InsightSelection &&
          other.primary == primary &&
          other.secondary == secondary;

  @override
  int get hashCode => Object.hash(primary, secondary);

  @override
  String toString() =>
      'InsightSelection(primary: $primary, secondary: $secondary)';
}

/// The sentence structure decided by the engine.
///
/// Each app maps an [InsightPhrase] to its own localized string resource.
sealed class InsightPhrase {
  const InsightPhrase();

  const factory InsightPhrase.subjectUnusable() = InsightPhraseSubjectUnusable;
  const factory InsightPhrase.notEnoughData(int count) =
      InsightPhraseNotEnoughData;
  const factory InsightPhrase.notDistinguishable(int count) =
      InsightPhraseNotDistinguishable;
  const factory InsightPhrase.usedLess(String difference, int count) =
      InsightPhraseUsedLess;
  const factory InsightPhrase.usedMore(String difference, int count) =
      InsightPhraseUsedMore;
  const factory InsightPhrase.variantNotEnough(int count) =
      InsightPhraseVariantNotEnough;
  const factory InsightPhrase.variantNotDistinguishable(
    String place,
    int count,
  ) = InsightPhraseVariantNotDistinguishable;
  const factory InsightPhrase.variantUsedLess(
    String difference,
    String place,
    int count,
  ) = InsightPhraseVariantUsedLess;
  const factory InsightPhrase.variantUsedMore(
    String difference,
    String place,
    int count,
  ) = InsightPhraseVariantUsedMore;
}

final class InsightPhraseSubjectUnusable extends InsightPhrase {
  const InsightPhraseSubjectUnusable();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is InsightPhraseSubjectUnusable;

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() => 'InsightPhrase.subjectUnusable()';
}

final class InsightPhraseNotEnoughData extends InsightPhrase {
  const InsightPhraseNotEnoughData(this.count);
  final int count;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InsightPhraseNotEnoughData && other.count == count;

  @override
  int get hashCode => count.hashCode;

  @override
  String toString() => 'InsightPhrase.notEnoughData($count)';
}

final class InsightPhraseNotDistinguishable extends InsightPhrase {
  const InsightPhraseNotDistinguishable(this.count);
  final int count;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InsightPhraseNotDistinguishable && other.count == count;

  @override
  int get hashCode => count.hashCode;

  @override
  String toString() => 'InsightPhrase.notDistinguishable($count)';
}

final class InsightPhraseUsedLess extends InsightPhrase {
  const InsightPhraseUsedLess(this.difference, this.count);
  final String difference;
  final int count;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InsightPhraseUsedLess &&
          other.difference == difference &&
          other.count == count;

  @override
  int get hashCode => Object.hash(difference, count);

  @override
  String toString() => 'InsightPhrase.usedLess($difference, $count)';
}

final class InsightPhraseUsedMore extends InsightPhrase {
  const InsightPhraseUsedMore(this.difference, this.count);
  final String difference;
  final int count;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InsightPhraseUsedMore &&
          other.difference == difference &&
          other.count == count;

  @override
  int get hashCode => Object.hash(difference, count);

  @override
  String toString() => 'InsightPhrase.usedMore($difference, $count)';
}

final class InsightPhraseVariantNotEnough extends InsightPhrase {
  const InsightPhraseVariantNotEnough(this.count);
  final int count;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InsightPhraseVariantNotEnough && other.count == count;

  @override
  int get hashCode => count.hashCode;

  @override
  String toString() => 'InsightPhrase.variantNotEnough($count)';
}

final class InsightPhraseVariantNotDistinguishable extends InsightPhrase {
  const InsightPhraseVariantNotDistinguishable(this.place, this.count);
  final String place;
  final int count;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InsightPhraseVariantNotDistinguishable &&
          other.place == place &&
          other.count == count;

  @override
  int get hashCode => Object.hash(place, count);

  @override
  String toString() =>
      'InsightPhrase.variantNotDistinguishable($place, $count)';
}

final class InsightPhraseVariantUsedLess extends InsightPhrase {
  const InsightPhraseVariantUsedLess(this.difference, this.place, this.count);
  final String difference;
  final String place;
  final int count;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InsightPhraseVariantUsedLess &&
          other.difference == difference &&
          other.place == place &&
          other.count == count;

  @override
  int get hashCode => Object.hash(difference, place, count);

  @override
  String toString() =>
      'InsightPhrase.variantUsedLess($difference, $place, $count)';
}

final class InsightPhraseVariantUsedMore extends InsightPhrase {
  const InsightPhraseVariantUsedMore(this.difference, this.place, this.count);
  final String difference;
  final String place;
  final int count;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InsightPhraseVariantUsedMore &&
          other.difference == difference &&
          other.place == place &&
          other.count == count;

  @override
  int get hashCode => Object.hash(difference, place, count);

  @override
  String toString() =>
      'InsightPhrase.variantUsedMore($difference, $place, $count)';
}

/// Determines the phrase and arguments for [read].
///
/// When [placeName] is supplied and [read] represents a variant comparison,
/// returns a variant-specific phrase.
InsightPhrase insightPhrase(InsightRead read, {String? placeName}) {
  final insight = read.insight;
  if (insight == null) {
    return switch (read.absence) {
      InsightAbsence.insufficientSupport =>
        (placeName != null && read.support.window == kInsightRouteWindow)
            ? InsightPhrase.variantNotEnough(read.support.considered)
            : InsightPhrase.notEnoughData(read.support.considered),
      InsightAbsence.notOnRoute || InsightAbsence.noOtherVariant =>
        InsightPhrase.variantNotEnough(read.support.considered),
      InsightAbsence.subjectNeverRecorded ||
      InsightAbsence.subjectNoMinuteBuckets ||
      InsightAbsence.subjectSignContradiction ||
      InsightAbsence.subjectUnconfirmedSign ||
      InsightAbsence.subjectTooShort ||
      InsightAbsence.subjectNotClosed ||
      null => const InsightPhrase.subjectUnusable(),
    };
  }

  final count = insight.support.considered;
  final isVariant =
      insight.claim == InsightClaim.variantVsVariant && placeName != null;

  if (insight.confidence == InsightConfidence.notDistinguishable) {
    return isVariant
        ? InsightPhrase.variantNotDistinguishable(placeName, count)
        : InsightPhrase.notDistinguishable(count);
  }

  final gap = insight.magnitude.displayValue;
  if (gap == null) return const InsightPhrase.subjectUnusable();
  final shown = gap.abs().toStringAsFixed(1);

  if (isVariant) {
    return gap < 0
        ? InsightPhrase.variantUsedLess(shown, placeName, count)
        : InsightPhrase.variantUsedMore(shown, placeName, count);
  }

  return gap < 0
      ? InsightPhrase.usedLess(shown, count)
      : InsightPhrase.usedMore(shown, count);
}

/// The fields the comparison engine is allowed to see. There is no frame
/// list and no GPS: retention must not be able to change an [Insight].
class InsightTrip {
  const InsightTrip({
    required this.id,
    required this.aggregationVersion,
    required this.hasMinuteBuckets,
    this.endedAtUtcMillis,
    this.distanceKm,
    this.canPackWh,
    this.canAgreesWithSoc,
    this.startLatitude,
    this.startLongitude,
    this.endLatitude,
    this.endLongitude,
    this.path,
    this.meanAmbientTempC,
  });

  final String id;
  final int? endedAtUtcMillis;
  final double? distanceKm;

  /// Net pack energy from the CAN integral. Discharge is positive.
  final double? canPackWh;
  final bool hasMinuteBuckets;

  /// Native agreement flag. False is a contradiction; null is unconfirmed.
  final bool? canAgreesWithSoc;
  final int aggregationVersion;

  /// Trip ends from persisted segments, never from frames.
  final double? startLatitude;
  final double? startLongitude;
  final double? endLatitude;
  final double? endLongitude;

  /// `lat,lon;lat,lon` from the segments. Empty when the trip had no GPS.
  final String? path;

  /// Mean outside temperature from the session aggregate. Survives retention.
  final double? meanAmbientTempC;

  InsightPoint? get startPoint => _point(startLatitude, startLongitude);

  InsightPoint? get endPoint => _point(endLatitude, endLongitude);
}

InsightPoint? _point(double? latitude, double? longitude) {
  if (latitude == null || longitude == null) return null;
  if (!latitude.isFinite || !longitude.isFinite) return null;
  return InsightPoint(latitude, longitude);
}

InsightRouteMatch? matchInsightTripRoute({
  required InsightTrip subject,
  required List<InsightTrip> corpus,
  required List<InsightPlace> places,
}) {
  return matchTripRoute(
    start: subject.startPoint,
    end: subject.endPoint,
    path: subject.path,
    places: places,
    corpus: [
      for (final trip in corpus)
        (start: trip.startPoint, end: trip.endPoint, path: trip.path),
    ],
  );
}

/// Evaluates both route-variant and own-average comparisons for [subject] and
/// returns the primary [InsightRead] chosen by engine policy.
///
/// Order of preference:
/// 1. Route variant comparison is chosen when the trip is on a named route
///    that has multiple variants (whether supported, not distinguishable, or
///    insufficient support to compare variants).
/// 2. Vehicle 30-day own average is chosen when the trip is not on a named
///    route (`notOnRoute`) or the route has no other variant (`noOtherVariant`).
///
/// If [subject] is unusable, the subject-level gate absence is returned.
InsightSelection primaryInsight({
  required InsightTrip subject,
  required List<InsightTrip> corpus,
  required InsightRouteIndex index,
  required DateTime now,
}) {
  final variantRead = compareRouteVariants(
    subject: subject,
    corpus: corpus,
    index: index,
  );
  final ownAverageRead = compareTripToOwnAverage(
    subject: subject,
    corpus: corpus,
    now: now,
  );

  final prefersVariant =
      variantRead.hasInsight ||
      variantRead.absence == InsightAbsence.insufficientSupport;

  if (prefersVariant) {
    return InsightSelection(primary: variantRead, secondary: ownAverageRead);
  }

  return InsightSelection(primary: ownAverageRead, secondary: variantRead);
}

/// Finds [subjectId] in [corpus] and compares it to the last 30 days.
///
/// A missing subject is [InsightAbsence.subjectNeverRecorded]: the trip the
/// screen is showing is not in the aggregate read, so it has no CAN energy
/// the engine is allowed to use.
InsightRead insightReadForSubject({
  required String subjectId,
  required List<InsightTrip> corpus,
  required DateTime now,
}) {
  InsightTrip? subject;
  for (final trip in corpus) {
    if (trip.id == subjectId) {
      subject = trip;
      break;
    }
  }
  if (subject == null) {
    return InsightRead.none(
      absence: InsightAbsence.subjectNeverRecorded,
      support: const InsightSupport(
        window: kInsightOwnAverageWindow,
        considered: 0,
        excluded: {},
      ),
    );
  }
  return compareTripToOwnAverage(subject: subject, corpus: corpus, now: now);
}

/// Returns the trips that entered the comparison sample for an [InsightRead].
List<InsightTrip> consideredTripsForInsight({
  required InsightRead read,
  required InsightTrip subject,
  required List<InsightTrip> corpus,
  required InsightRouteIndex index,
  required DateTime now,
}) {
  final insight = read.insight;
  if (insight == null) {
    if (read.support.window == kInsightRouteWindow) {
      return consideredTripsForRouteVariants(
        subject: subject,
        corpus: corpus,
        index: index,
      );
    }
    return consideredTripsForOwnAverage(
      subject: subject,
      corpus: corpus,
      now: now,
    );
  }
  return switch (insight.baseline) {
    InsightBaseline.ownAverage30d => consideredTripsForOwnAverage(
      subject: subject,
      corpus: corpus,
      now: now,
    ),
    InsightBaseline.otherVariantSameRoute => consideredTripsForRouteVariants(
      subject: subject,
      corpus: corpus,
      index: index,
    ),
  };
}

/// Returns the trips that entered the own-average comparison reference set.
List<InsightTrip> consideredTripsForOwnAverage({
  required InsightTrip subject,
  required List<InsightTrip> corpus,
  required DateTime now,
}) {
  final windowStart = now.subtract(kInsightOwnAverageWindow);
  if (_gate(subject) != null) return const [];
  final considered = <InsightTrip>[];
  for (final trip in corpus) {
    if (trip.id == subject.id) continue;
    if (trip.aggregationVersion != subject.aggregationVersion) continue;
    final ended = trip.endedAtUtcMillis;
    if (ended == null) continue;
    final endedAt = DateTime.fromMillisecondsSinceEpoch(ended, isUtc: true);
    if (endedAt.isBefore(windowStart) || endedAt.isAfter(now)) continue;
    if (_gate(trip) != null) continue;
    considered.add(trip);
  }
  return considered;
}

/// Returns the trips that entered the route-variants comparison reference set.
List<InsightTrip> consideredTripsForRouteVariants({
  required InsightTrip subject,
  required List<InsightTrip> corpus,
  required InsightRouteIndex index,
}) {
  if (_gate(subject) != null) return const [];
  final route = index.routeOf(subject.id);
  if (route == null) return const [];
  final subjectSignature = index.variantSignatureOf(subject.id);
  final mine = <InsightTrip>[];
  final other = <InsightTrip>[];
  for (final trip in corpus) {
    if (trip.aggregationVersion != subject.aggregationVersion) continue;
    if (_gate(trip) != null) continue;
    final tripRoute = index.routeOf(trip.id);
    if (tripRoute == null ||
        tripRoute.from.id != route.from.id ||
        tripRoute.to.id != route.to.id) {
      continue;
    }
    final signature = index.variantSignatureOf(trip.id);
    if (signature == subjectSignature ||
        (signature.isEmpty && subjectSignature.isEmpty)) {
      mine.add(trip);
    } else {
      other.add(trip);
    }
  }
  if (other.isEmpty) return const [];
  final otherBySig = <String, List<InsightTrip>>{};
  for (final trip in other) {
    final signature = index.variantSignatureOf(trip.id);
    otherBySig.putIfAbsent(signature, () => []).add(trip);
  }
  if (otherBySig.length > 1) {
    final ranked = otherBySig.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    other
      ..clear()
      ..addAll(ranked.first.value);
  }
  final pairs = _pairTrips(mine, other);
  if (pairs.length >= kInsightMinPairs) {
    return [
      for (final pair in pairs) pair.$1,
      for (final pair in pairs) pair.$2,
    ];
  }
  if (mine.length >= kInsightMinVariantTrips &&
      other.length >= kInsightMinVariantTrips &&
      mine.length + other.length >= kInsightMinReferenceTrips) {
    return [...mine, ...other];
  }
  return const [];
}

/// Compares [subject] to the ratio of sums over the last 30 days of [corpus].
///
/// The subject is never part of its own reference. A difference smaller than
/// the IQR of the reference trips is not a claim.
InsightRead compareTripToOwnAverage({
  required InsightTrip subject,
  required List<InsightTrip> corpus,
  required DateTime now,
}) {
  final windowStart = now.subtract(kInsightOwnAverageWindow);
  final excluded = <InsightExclusion, int>{};

  void count(InsightExclusion reason) {
    excluded[reason] = (excluded[reason] ?? 0) + 1;
  }

  InsightSupport support(int considered) => InsightSupport(
    window: kInsightOwnAverageWindow,
    considered: considered,
    excluded: Map<InsightExclusion, int>.unmodifiable(excluded),
  );

  final subjectGate = _gate(subject);
  if (subjectGate != null) {
    return InsightRead.none(
      absence: _absenceFor(subjectGate),
      support: support(0),
    );
  }

  final considered = <InsightTrip>[];
  for (final trip in corpus) {
    if (trip.id == subject.id) continue;
    if (trip.aggregationVersion != subject.aggregationVersion) {
      count(InsightExclusion.versionMismatch);
      continue;
    }
    final ended = trip.endedAtUtcMillis;
    if (ended == null) {
      count(InsightExclusion.notClosed);
      continue;
    }
    final endedAt = DateTime.fromMillisecondsSinceEpoch(ended, isUtc: true);
    if (endedAt.isBefore(windowStart) || endedAt.isAfter(now)) {
      count(InsightExclusion.outsideWindow);
      continue;
    }
    final reason = _gate(trip);
    if (reason != null) {
      count(reason);
      continue;
    }
    considered.add(trip);
  }

  if (considered.length < kInsightMinReferenceTrips) {
    return InsightRead.none(
      absence: InsightAbsence.insufficientSupport,
      support: support(considered.length),
    );
  }

  var energyWh = 0.0;
  var distanceKm = 0.0;
  final rates = <double>[];
  for (final trip in considered) {
    final energy = trip.canPackWh!;
    final distance = trip.distanceKm!;
    energyWh += energy;
    distanceKm += distance;
    rates.add(energy / distance);
  }
  if (distanceKm <= 0) {
    return InsightRead.none(
      absence: InsightAbsence.insufficientSupport,
      support: support(considered.length),
    );
  }

  rates.sort();
  final referenceWhPerKm = energyWh / distanceKm;
  final subjectWhPerKm = subject.canPackWh! / subject.distanceKm!;
  final difference = subjectWhPerKm - referenceWhPerKm;
  final spread = _iqr(rates);
  final distinguishable = difference.abs() > 0 && difference.abs() >= spread;

  return InsightRead.present(
    Insight(
      claim: InsightClaim.tripVsOwnAverage30d,
      magnitude: Measurement.measured(difference, unit: 'Wh/km'),
      subject: Measurement.measured(subjectWhPerKm, unit: 'Wh/km'),
      reference: Measurement.measured(referenceWhPerKm, unit: 'Wh/km'),
      baseline: InsightBaseline.ownAverage30d,
      support: support(considered.length),
      aggregationVersion: subject.aggregationVersion,
      confidence: distinguishable
          ? InsightConfidence.supported
          : InsightConfidence.notDistinguishable,
    ),
  );
}

/// Compares the subject's way to the other way of the same named route.
///
/// Uses every usable CAN trip of that pair, not the 30-day window. Pairs
/// trips that are near in calendar time, time of day and temperature.
/// The threshold is the IQR divided by the root of the pair count.
InsightRead compareRouteVariants({
  required InsightTrip subject,
  required List<InsightTrip> corpus,
  required InsightRouteIndex index,
}) {
  final excluded = <InsightExclusion, int>{};

  void count(InsightExclusion reason) {
    excluded[reason] = (excluded[reason] ?? 0) + 1;
  }

  InsightSupport support(int considered) => InsightSupport(
    window: kInsightRouteWindow,
    considered: considered,
    excluded: Map<InsightExclusion, int>.unmodifiable(excluded),
  );

  final subjectGate = _gate(subject);
  if (subjectGate != null) {
    return InsightRead.none(
      absence: _absenceFor(subjectGate),
      support: support(0),
    );
  }

  final route = index.routeOf(subject.id);
  if (route == null) {
    return InsightRead.none(
      absence: InsightAbsence.notOnRoute,
      support: support(0),
    );
  }

  final subjectSignature = index.variantSignatureOf(subject.id);
  final mine = <InsightTrip>[];
  final other = <InsightTrip>[];
  for (final trip in corpus) {
    if (trip.aggregationVersion != subject.aggregationVersion) {
      count(InsightExclusion.versionMismatch);
      continue;
    }
    final reason = _gate(trip);
    if (reason != null) {
      count(reason);
      continue;
    }
    final tripRoute = index.routeOf(trip.id);
    if (tripRoute == null ||
        tripRoute.from.id != route.from.id ||
        tripRoute.to.id != route.to.id) {
      count(InsightExclusion.notOnRoute);
      continue;
    }
    final signature = index.variantSignatureOf(trip.id);
    if (signature == subjectSignature) {
      mine.add(trip);
    } else if (signature.isEmpty && subjectSignature.isEmpty) {
      mine.add(trip);
    } else {
      other.add(trip);
    }
  }

  if (other.isEmpty) {
    return InsightRead.none(
      absence: InsightAbsence.noOtherVariant,
      support: support(mine.length),
    );
  }

  // Keep only the most common other way, so a third path is not mixed in.
  final otherBySig = <String, List<InsightTrip>>{};
  for (final trip in other) {
    final signature = index.variantSignatureOf(trip.id);
    otherBySig.putIfAbsent(signature, () => []).add(trip);
  }
  if (otherBySig.length > 1) {
    final ranked = otherBySig.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    for (final extra in ranked.skip(1)) {
      for (final _ in extra.value) {
        count(InsightExclusion.otherVariant);
      }
    }
    other
      ..clear()
      ..addAll(ranked.first.value);
  }

  final pairs = _pairTrips(mine, other);
  if (pairs.length >= kInsightMinPairs) {
    return _variantRead(
      subject: subject,
      left: [for (final pair in pairs) pair.$1],
      right: [for (final pair in pairs) pair.$2],
      considered: pairs.length,
      excluded: excluded,
      paired: true,
      routeRates: [...mine, ...other],
    );
  }

  if (mine.length >= kInsightMinVariantTrips &&
      other.length >= kInsightMinVariantTrips &&
      mine.length + other.length >= kInsightMinReferenceTrips) {
    return _variantRead(
      subject: subject,
      left: mine,
      right: other,
      considered: mine.length + other.length,
      excluded: excluded,
      paired: false,
      routeRates: [...mine, ...other],
    );
  }

  return InsightRead.none(
    absence: InsightAbsence.insufficientSupport,
    support: support(pairs.length),
  );
}

InsightRead _variantRead({
  required InsightTrip subject,
  required List<InsightTrip> left,
  required List<InsightTrip> right,
  required int considered,
  required Map<InsightExclusion, int> excluded,
  required bool paired,
  required List<InsightTrip> routeRates,
}) {
  final leftRate = _ratioOfSums(left);
  final rightRate = _ratioOfSums(right);
  if (leftRate == null || rightRate == null) {
    return InsightRead.none(
      absence: InsightAbsence.insufficientSupport,
      support: InsightSupport(
        window: kInsightRouteWindow,
        considered: considered,
        excluded: Map<InsightExclusion, int>.unmodifiable(excluded),
      ),
    );
  }
  final difference = leftRate - rightRate;
  final pairDiffs = <double>[];
  if (paired && left.length == right.length) {
    for (var i = 0; i < left.length; i++) {
      final a = left[i].canPackWh! / left[i].distanceKm!;
      final b = right[i].canPackWh! / right[i].distanceKm!;
      pairDiffs.add(a - b);
    }
    pairDiffs.sort();
  }
  final rates = [
    for (final trip in routeRates) trip.canPackWh! / trip.distanceKm!,
  ]..sort();
  final n = paired
      ? left.length
      : (left.length < right.length ? left.length : right.length);
  final spread = (paired && pairDiffs.length >= kInsightMinReferenceTrips)
      ? _iqr(pairDiffs)
      : _iqr(rates);
  final threshold = n <= 0 ? spread : spread / _sqrt(n);
  final distinguishable = difference.abs() > 0 && difference.abs() >= threshold;
  return InsightRead.present(
    Insight(
      claim: InsightClaim.variantVsVariant,
      magnitude: Measurement.measured(difference, unit: 'Wh/km'),
      subject: Measurement.measured(leftRate, unit: 'Wh/km'),
      reference: Measurement.measured(rightRate, unit: 'Wh/km'),
      baseline: InsightBaseline.otherVariantSameRoute,
      support: InsightSupport(
        window: kInsightRouteWindow,
        considered: considered,
        excluded: Map<InsightExclusion, int>.unmodifiable(excluded),
      ),
      aggregationVersion: subject.aggregationVersion,
      confidence: distinguishable
          ? InsightConfidence.supported
          : InsightConfidence.notDistinguishable,
    ),
  );
}

double? _ratioOfSums(List<InsightTrip> trips) {
  var energy = 0.0;
  var distance = 0.0;
  for (final trip in trips) {
    energy += trip.canPackWh!;
    distance += trip.distanceKm!;
  }
  if (distance <= 0) return null;
  return energy / distance;
}

double _sqrt(int n) {
  if (n <= 1) return 1;
  return math.sqrt(n.toDouble());
}

List<(InsightTrip, InsightTrip)> _pairTrips(
  List<InsightTrip> left,
  List<InsightTrip> right,
) {
  final remaining = [...right];
  final pairs = <(InsightTrip, InsightTrip)>[];
  final ordered = [...left]
    ..sort(
      (a, b) => (a.endedAtUtcMillis ?? 0).compareTo(b.endedAtUtcMillis ?? 0),
    );
  for (final trip in ordered) {
    InsightTrip? best;
    var bestScore = double.infinity;
    for (final candidate in remaining) {
      final score = _pairScore(trip, candidate);
      if (score == null || score >= bestScore) continue;
      best = candidate;
      bestScore = score;
    }
    if (best == null) continue;
    pairs.add((trip, best));
    remaining.remove(best);
  }
  return pairs;
}

double? _pairScore(InsightTrip a, InsightTrip b) {
  final endedA = a.endedAtUtcMillis;
  final endedB = b.endedAtUtcMillis;
  if (endedA == null || endedB == null) return null;
  final timeA = DateTime.fromMillisecondsSinceEpoch(endedA, isUtc: true);
  final timeB = DateTime.fromMillisecondsSinceEpoch(endedB, isUtc: true);
  final calendar = timeA.difference(timeB).abs();
  if (calendar > kInsightPairMaxCalendar) return null;
  final tod = _timeOfDayDelta(timeA, timeB);
  if (tod > kInsightPairMaxTimeOfDay) return null;
  var tempScore = 0.0;
  final tempA = a.meanAmbientTempC;
  final tempB = b.meanAmbientTempC;
  if (tempA != null && tempB != null) {
    final delta = (tempA - tempB).abs();
    if (delta > kInsightPairMaxTempC) return null;
    tempScore = delta / kInsightPairMaxTempC;
  }
  return calendar.inSeconds / kInsightPairMaxCalendar.inSeconds +
      tod.inSeconds / kInsightPairMaxTimeOfDay.inSeconds +
      tempScore;
}

Duration _timeOfDayDelta(DateTime a, DateTime b) {
  final minutesA = a.hour * 60 + a.minute;
  final minutesB = b.hour * 60 + b.minute;
  var delta = (minutesA - minutesB).abs();
  if (delta > 12 * 60) delta = 24 * 60 - delta;
  return Duration(minutes: delta);
}

/// Whether [trip] can enter any comparison: closed, CAN-measured, minute
/// buckets present, sign confirmed, and long enough to integrate honestly.
///
/// Public so a route card can count the same trips the statistics would,
/// without duplicating the rules.
bool insightTripComparable(InsightTrip trip) {
  if (trip.endedAtUtcMillis == null) return false;
  if (trip.canPackWh == null) return false;
  if (!trip.hasMinuteBuckets) return false;
  if (trip.canAgreesWithSoc == false) return false;
  if (trip.canAgreesWithSoc == null) return false;
  final distance = trip.distanceKm;
  if (distance == null || distance < kInsightDistanceFloorKm) return false;
  return true;
}

InsightExclusion? _gate(InsightTrip trip) {
  if (trip.endedAtUtcMillis == null) return InsightExclusion.notClosed;
  if (trip.canPackWh == null) return InsightExclusion.neverRecorded;
  if (!trip.hasMinuteBuckets) return InsightExclusion.noMinuteBuckets;
  if (trip.canAgreesWithSoc == false) return InsightExclusion.signContradiction;
  if (trip.canAgreesWithSoc == null) return InsightExclusion.unconfirmedSign;
  final distance = trip.distanceKm;
  if (distance == null || distance < kInsightDistanceFloorKm) {
    return InsightExclusion.tooShort;
  }
  return null;
}

InsightAbsence _absenceFor(InsightExclusion reason) => switch (reason) {
  InsightExclusion.neverRecorded => InsightAbsence.subjectNeverRecorded,
  InsightExclusion.noMinuteBuckets => InsightAbsence.subjectNoMinuteBuckets,
  InsightExclusion.signContradiction => InsightAbsence.subjectSignContradiction,
  InsightExclusion.unconfirmedSign => InsightAbsence.subjectUnconfirmedSign,
  InsightExclusion.tooShort => InsightAbsence.subjectTooShort,
  InsightExclusion.notClosed => InsightAbsence.subjectNotClosed,
  InsightExclusion.versionMismatch ||
  InsightExclusion.outsideWindow ||
  InsightExclusion.notOnRoute ||
  InsightExclusion.otherVariant => InsightAbsence.insufficientSupport,
};

/// Tukey hinges: median of each half, the median itself dropped when [n] is
/// odd. The comparison threshold is this spread, not a percentage of the
/// reference.
double _iqr(List<double> sorted) {
  final n = sorted.length;
  if (n < 2) return 0;
  final lower = sorted.sublist(0, n ~/ 2);
  final upper = sorted.sublist((n + 1) ~/ 2);
  return _median(upper) - _median(lower);
}

double _median(List<double> sorted) {
  final n = sorted.length;
  if (n.isOdd) return sorted[n ~/ 2];
  return (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
}
