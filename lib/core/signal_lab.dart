/// The reading model behind the Signal Lab `INSPECTOR` tab.
///
/// Stage 4 of the Signal Lab plan. Pure: it takes a schema and one batched
/// CAN read and answers with rows. It opens no bridge and holds no timer.
///
/// The row carries one column the original specification did not ask for: the
/// **tier**. Stage 0 existed to answer a single question — has this signal ever
/// published on this car? — and the answer separated 24 fresh signals from 492
/// published and 2103 never seen. That question was answered once, by hand,
/// against a capture file. A signal that has never published since boot must be
/// distinguishable at a glance from one that published a minute ago, so the
/// screen answers it continuously instead.
library;

import 'can_bridge_models.dart';

/// How recently a signal was seen, which is a different question from whether
/// its current value is good.
enum SignalTier {
  /// The frame changed within [kSignalFreshWindow]. The value describes now.
  fresh,

  /// Observed since boot, but the frame has not changed recently.
  ///
  /// This is a weaker statement than it looks. The stamp belongs to the frame,
  /// not to the signal, so a frame with no alive counter can keep arriving with
  /// the same eight bytes and stay in this tier. Read it as "arrived at least
  /// once, and not seen to move lately", never as "stopped publishing".
  published,

  /// Never observed since boot. There is no value at all, and a zero here is
  /// the absence of a signal rather than a measurement of zero.
  never,
}

/// The window inside which a signal counts as fresh.
const Duration kSignalFreshWindow = Duration(seconds: 10);

/// Age above which a row is drawn as stale.
///
/// The plan sets the row colours at 200 ms and 500 ms. Those thresholds are for
/// the eye; they are not a validity rule, and nothing in this file drops a
/// value because of them.
const Duration kSignalAgeWarn = Duration(milliseconds: 200);
const Duration kSignalAgeStale = Duration(milliseconds: 500);

/// One signal, as the inspector shows it.
class SignalRow {
  const SignalRow({
    required this.name,
    required this.unit,
    required this.canId,
    required this.tier,
    required this.raw,
    required this.physical,
    required this.valid,
    required this.calibrated,
    required this.age,
    required this.sessionMin,
    required this.sessionMax,
    this.sessionIsCount = false,
  });

  final String name;
  final String unit;
  final int canId;

  final SignalTier tier;

  /// The count on the bus, before scale and offset. Null when the signal has
  /// never published: there is no count to show.
  final int? raw;

  /// The decoded value. Null for the same reason, and also when the daemon has
  /// no calibration, because an assumed scale must not be printed as a plain
  /// measurement.
  final double? physical;

  final bool valid;

  /// Whether the daemon negotiated a real scale for this signal. A false here
  /// is why [physical] can be null while [raw] is not.
  final bool calibrated;

  /// Time since the frame last changed. Null when there is no change to date
  /// it from, which covers a never-observed frame and an observed one whose
  /// change stamp is still zero.
  final Duration? age;

  final double? sessionMin;
  final double? sessionMax;

  /// Whether the session span above is in counts rather than in [unit].
  ///
  /// It is carried on the row rather than derived from the current sample,
  /// because a span survives the sample that made it: a signal now silent or
  /// disowned still has the span it built earlier, and the reader has to know
  /// which quantity it is looking at.
  final bool sessionIsCount;

  /// The number the scope plots and the session span is folded from.
  ///
  /// The decoded value when the daemon has a scale, and the raw count when it
  /// does not. Without this fallback the two signals the calibration work
  /// depends on — `VCU_ThermalPwrAct` and `VCU_DCDCPwrAct`, both uncalibrated
  /// by definition — would draw an empty trace and carry no session span, so
  /// the lab could not observe the very signals it exists to help scale.
  ///
  /// This is not a decoded value in disguise. [plotsRawCount] says which of the
  /// two it is, and every surface that prints it must say so too.
  ///
  /// A sample the bus marked invalid has no number here, count or otherwise.
  /// The daemon disowned it, and a span or a trace built from it would outlive
  /// the moment that produced it.
  double? get plottable => physical ?? (valid ? raw?.toDouble() : null);

  /// Whether [plottable] is a count on the bus rather than a measurement.
  bool get plotsRawCount => physical == null && plottable != null;

  /// Whether the row should be drawn as stale rather than live.
  bool get isStale => age == null || age! >= kSignalAgeStale;
}

/// Session extremes, kept across reads because one read cannot know them.
///
/// This is the only mutable state in the file. It is separate from [SignalRow]
/// so that building a row stays a pure function of one bridge read.
class SignalSessionExtremes {
  final Map<String, double> _min = <String, double>{};
  final Map<String, double> _max = <String, double>{};
  final Map<String, bool> _counts = <String, bool>{};

  double? minOf(String name) => _min[name];
  double? maxOf(String name) => _max[name];

  /// Whether the span held for [name] is in counts rather than in the unit.
  bool? isCountOf(String name) => _counts[name];

  /// Folds one sample in, as a decoded value or as a raw count.
  ///
  /// [isCount] is required rather than inferred, because the two are the same
  /// Dart type and only the caller knows which it holds. A span that mixed them
  /// would be two quantities under one pair of numbers.
  ///
  /// A signal that changes kind mid-session — the daemon gained or lost a
  /// scale under a running app — starts a new span instead of widening the old
  /// one. The alternative is a minimum in counts beside a maximum in kilowatts,
  /// which no reader could detect afterwards.
  void observe(String name, double? value, {required bool isCount}) {
    if (value == null || !value.isFinite) return;
    if (_counts[name] != isCount) {
      _counts[name] = isCount;
      _min[name] = value;
      _max[name] = value;
      return;
    }
    final currentMin = _min[name];
    final currentMax = _max[name];
    if (currentMin == null || value < currentMin) _min[name] = value;
    if (currentMax == null || value > currentMax) _max[name] = value;
  }

  void clear() {
    _min.clear();
    _max.clear();
    _counts.clear();
  }
}

/// The tier of one signal.
///
/// Two different stamps answer two different questions, and the tier needs
/// both. [firstObservedNanos] answers "has this ever arrived": the daemon
/// leaves it at zero until the frame is first observed, so a zero is silence
/// since boot and nothing else. [changeNanos] answers "did it move recently",
/// measured against [nowNanos].
///
/// Reading the second stamp as if it were the first is the mistake this
/// signature exists to prevent. A frame that arrived once and then held its
/// value has a stale change stamp and a real first observation, and calling
/// that `never` would deny a signal the car does publish. The zero is still
/// tested before any arithmetic, because subtracting it from the current
/// uptime produces a plausible age of several hours and hides the one fact
/// worth knowing.
///
/// [firstObservedNanos] is null when the source does not report it. Then the
/// change stamp is all there is, and the old reading returns — a signal that
/// has never changed cannot be told from one that has never arrived.
SignalTier signalTier(
  int changeNanos,
  int nowNanos, {
  int? firstObservedNanos,
}) {
  final observed = firstObservedNanos == null
      ? changeNanos > 0
      : firstObservedNanos > 0;
  if (!observed) return SignalTier.never;
  if (changeNanos <= 0) return SignalTier.published;
  final ageNanos = nowNanos - changeNanos;
  if (ageNanos < 0) return SignalTier.fresh;
  return ageNanos <= kSignalFreshWindow.inMicroseconds * 1000
      ? SignalTier.fresh
      : SignalTier.published;
}

/// Builds one row from a schema entry and the batched read that goes with it.
///
/// [nowNanos] must come from the same clock the daemon stamps changes with.
SignalRow buildSignalRow({
  required RoadcastSchemaEntry entry,
  required CanBridgeReading reading,
  required int nowNanos,
  SignalSessionExtremes? extremes,
}) {
  final index = entry.index;
  final inRange = index >= 0 && index < reading.length;
  final changeNanos = inRange ? reading.timestampNsAt(index) : 0;
  final firstObservedNanos = inRange ? reading.firstObservedNsAt(index) : 0;
  final tier = signalTier(
    changeNanos,
    nowNanos,
    firstObservedNanos: firstObservedNanos,
  );

  final never = tier == SignalTier.never;
  final valid = inRange && !never && reading.isValidAt(index);
  final calibrated = inRange && reading.isCalibratedAt(index);

  final raw = (inRange && !never) ? reading.rawAt(index) : null;
  final physical = (inRange && !never && calibrated && valid)
      ? reading.valueAt(index)
      : null;

  // The row is the authority on which number is plottable, so build it first
  // and fold from it rather than repeating the rule here.
  final plottable = physical ?? (valid ? raw?.toDouble() : null);
  extremes?.observe(entry.name, plottable, isCount: physical == null);

  return SignalRow(
    name: entry.name,
    unit: entry.unit,
    canId: entry.canId,
    tier: tier,
    raw: raw,
    physical: physical,
    valid: valid,
    calibrated: calibrated,
    // Null whenever there is no change to measure from. An observed frame can
    // still carry a zero change stamp, and dating it from zero would report
    // the whole uptime as the age of the signal.
    age: (never || changeNanos <= 0)
        ? null
        : Duration(
            microseconds: ((nowNanos - changeNanos) ~/ 1000).clamp(0, 1 << 62),
          ),
    sessionMin: extremes?.minOf(entry.name),
    sessionMax: extremes?.maxOf(entry.name),
    sessionIsCount: extremes?.isCountOf(entry.name) ?? false,
  );
}

/// Builds every row for one read, in schema order.
List<SignalRow> buildSignalRows({
  required List<RoadcastSchemaEntry> entries,
  required CanBridgeReading reading,
  required int nowNanos,
  SignalSessionExtremes? extremes,
}) {
  return <SignalRow>[
    for (final entry in entries)
      buildSignalRow(
        entry: entry,
        reading: reading,
        nowNanos: nowNanos,
        extremes: extremes,
      ),
  ];
}

/// How the inspector list is narrowed.
class SignalFilter {
  const SignalFilter({this.query = '', this.tiers = const <SignalTier>{}});

  /// Matched against the signal name, case-insensitively. A hexadecimal CAN id
  /// such as `0x315` matches the frame instead.
  final String query;

  /// Tiers to keep. Empty keeps every tier, which is the default: hiding the
  /// never-published signals by default would hide the answer the tab exists
  /// to give.
  final Set<SignalTier> tiers;

  bool matches(SignalRow row) {
    if (tiers.isNotEmpty && !tiers.contains(row.tier)) return false;
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return true;
    if (row.name.toLowerCase().contains(needle)) return true;
    final frame = '0x${row.canId.toRadixString(16)}';
    return frame.contains(needle);
  }
}

/// Applies a filter, keeping schema order.
List<SignalRow> filterSignalRows(List<SignalRow> rows, SignalFilter filter) =>
    rows.where(filter.matches).toList(growable: false);

/// How many rows fall in each tier.
Map<SignalTier, int> countByTier(List<SignalRow> rows) {
  final counts = <SignalTier, int>{
    SignalTier.fresh: 0,
    SignalTier.published: 0,
    SignalTier.never: 0,
  };
  for (final row in rows) {
    counts[row.tier] = counts[row.tier]! + 1;
  }
  return counts;
}
