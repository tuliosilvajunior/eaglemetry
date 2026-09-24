import 'dart:async';

import 'package:flutter/foundation.dart';

import 'telemetry_api.dart';

/// Which of the two readings of a window the chart is showing.
///
/// They are not two versions of one series. The drive track is what the car
/// spent moving; the parked track is what it spent standing still. Their bars
/// never overlap in time, and neither is the other's total minus something.
enum EnergyTrack {
  drive,
  parked;

  bool get isParked => this == EnergyTrack.parked;
}

/// Chart-ready series for one plot width.
@immutable
class EnergyChartSeries {
  const EnergyChartSeries({
    required this.buckets,
    required this.width,
    required this.openIndex,
    this.labels,
    this.estimated,
    this.timePending = false,
  });

  static const empty = EnergyChartSeries(
    buckets: [],
    width: EnergyBucket.oneMinute,
    openIndex: null,
  );

  /// Reduced to [width] and expanded to the complete visible slot grid.
  ///
  /// Every entry is one consecutive interval. Leading, internal, and trailing
  /// gaps are empty buckets, so the list index is also the bucket's real time
  /// position on the chart.
  final List<EnergyBucket> buckets;

  final Duration width;

  /// The interval still being accumulated, marked so a bar that is short
  /// because it is filling does not read as one where consumption dropped.
  final int? openIndex;

  /// One [ContinuousLabel] per entry in [buckets], aligned by index. Null for
  /// every window but `sincePowerOn`.
  final List<ContinuousLabel>? labels;

  final List<bool>? estimated;

  /// Time-authority T6: the backing series still waits for the boot's
  /// anchor. The host shows the "time not synced" mark; the bars are
  /// unchanged.
  final bool timePending;

  bool get isEmpty => buckets.isEmpty;
}

/// Metrics for the exact bucket cut currently shown by the energy chart.
@immutable
class EnergyMonitorStats {
  const EnergyMonitorStats({
    required this.measuredKmPerKwh,
    required this.distanceKm,
    required this.averageSpeedKmh,
    required this.estimatedCost,
    required this.costCurrency,
  });

  factory EnergyMonitorStats.fromBuckets(
    List<EnergyBucket> buckets, {
    required double? costPerKwh,
    required String? costCurrency,
  }) {
    var packWh = 0.0;
    var speedDistanceKm = 0.0;
    var odometerDistanceKm = 0.0;
    var speedSeconds = 0.0;
    for (final bucket in buckets) {
      packWh += bucket.drawnWh - bucket.regeneratedWh;
      speedDistanceKm += bucket.speedDistanceKm;
      odometerDistanceKm += bucket.odometerDistanceKm;
      speedSeconds += bucket.speedIntegratedSeconds;
    }

    final distanceKm = odometerDistanceKm >= 0.01
        ? odometerDistanceKm
        : speedDistanceKm >= 0.01
        ? speedDistanceKm
        : null;
    final usablePackWh = packWh.isFinite && packWh > 0 ? packWh : null;
    final usableRate = costPerKwh?.isFinite == true && costPerKwh! >= 0
        ? costPerKwh
        : null;

    return EnergyMonitorStats(
      measuredKmPerKwh: distanceKm == null || usablePackWh == null
          ? null
          : distanceKm * 1000 / usablePackWh,
      distanceKm: distanceKm,
      averageSpeedKmh: speedSeconds > 0 && speedDistanceKm.isFinite
          ? speedDistanceKm * 3600 / speedSeconds
          : null,
      estimatedCost: usablePackWh == null || usableRate == null
          ? null
          : usablePackWh / 1000 * usableRate,
      costCurrency: costCurrency,
    );
  }

  final double? measuredKmPerKwh;
  final double? distanceKm;
  final double? averageSpeedKmh;
  final double? estimatedCost;
  final String? costCurrency;
}

/// What a parked window is scored by.
///
/// A rate and a total, and no distance anywhere. The drive stats cannot simply
/// be reused with the movement columns coming out null: efficiency, distance
/// and average speed are questions that do not apply to a car standing still,
/// and four `--` under a chart full of bars reads as a broken screen rather
/// than as an inapplicable one.
@immutable
class ParkedMonitorStats {
  const ParkedMonitorStats({
    required this.averageDrainW,
    required this.totalEnergyKwh,
    required this.measuredSeconds,
    required this.climateShareKwh,
    required this.estimatedCost,
    required this.costCurrency,
  });

  factory ParkedMonitorStats.fromBuckets(
    List<EnergyBucket> buckets, {
    required double? costPerKwh,
    required String? costCurrency,
  }) {
    var packWh = 0.0;
    var seconds = 0.0;
    var climateWh = 0.0;
    var climateSeconds = 0.0;
    for (final bucket in buckets) {
      packWh += bucket.drawnWh - bucket.regeneratedWh;
      seconds += bucket.integratedSeconds;
      climateWh += bucket.climateWh;
      climateSeconds += bucket.climateIntegratedSeconds;
    }

    final usablePackWh = packWh.isFinite && packWh > 0 ? packWh : null;
    final usableRate = costPerKwh?.isFinite == true && costPerKwh! >= 0
        ? costPerKwh
        : null;

    return ParkedMonitorStats(
      // The average over the measured seconds, never one sample over another.
      // A parked car is exactly where an instantaneous ratio is worst: the
      // draw is small, intermittent, and the denominator is a whole minute.
      averageDrainW: usablePackWh == null || seconds <= 0
          ? null
          : usablePackWh * 3600 / seconds,
      totalEnergyKwh: usablePackWh == null ? null : usablePackWh / 1000,
      measuredSeconds: seconds,
      // Absent, not zero, unless the car covered every measured second with a
      // climate reading. A partial cover cannot say what the heater drew over
      // the seconds nobody measured.
      climateShareKwh: seconds > 0 && climateSeconds >= seconds
          ? climateWh / 1000
          : null,
      estimatedCost: usablePackWh == null || usableRate == null
          ? null
          : usablePackWh / 1000 * usableRate,
      costCurrency: costCurrency,
    );
  }

  /// Mean pack draw over the measured seconds, in W.
  final double? averageDrainW;
  final double? totalEnergyKwh;

  /// Seconds the integral actually covers, which is not the window's length.
  final double measuredSeconds;

  /// The named climate share, or null when the split was not measured whole.
  final double? climateShareKwh;
  final double? estimatedCost;
  final String? costCurrency;
}

/// What "Since power on" is scored by: a ledger, not a drive's own figures.
///
/// The window can cover a trip, a charge and a parked stretch all at once, and
/// none of those three already answers "what went in, what went out here" —
/// that question is about the whole period, not about any one session inside
/// it. [inWh] and [outWh] are sums over buckets the window already holds, so
/// this is a reduction, never a second integral: the continuous stream shows
/// the shape, and this is the one figure it is allowed to add on top, because
/// no session was ever asked this question in the first place.
@immutable
class EnergyLedgerStats {
  const EnergyLedgerStats({
    required this.inWh,
    required this.outWh,
    required this.startSoc,
    required this.endSoc,
    this.includesEstimate = false,
  });

  factory EnergyLedgerStats.fromBuckets(
    List<EnergyBucket> buckets, {
    bool Function(EnergyBucket bucket)? isEstimated,
  }) {
    var inWh = 0.0;
    var outWh = 0.0;
    double? startSoc;
    double? endSoc;
    var includesEstimate = false;
    for (final bucket in buckets) {
      // Charging and regeneration both add to the pack; traction and the
      // auxiliary load both draw from it. A minute inside a charge and a
      // minute inside a trip answer the same two questions the same way —
      // this does not need to know which label the minute carries.
      inWh += bucket.deliveredWh + bucket.regeneratedWh;
      outWh += bucket.tractionWh + bucket.auxiliaryWh;
      startSoc ??= bucket.startSoc;
      if (bucket.endSoc != null) endSoc = bucket.endSoc;
      if (isEstimated?.call(bucket) ?? false) includesEstimate = true;
    }
    return EnergyLedgerStats(
      inWh: inWh,
      outWh: outWh,
      startSoc: startSoc,
      endSoc: endSoc,
      includesEstimate: includesEstimate,
    );
  }

  final double inWh;
  final double outWh;

  /// The pack's own state at the edges of the period, ridden along as a
  /// cross-check against [inWh]/[outWh] — never a second measurement of them.
  final double? startSoc;
  final double? endSoc;

  /// True when the sleep-gap estimate contributed to [inWh] or [outWh]. A
  /// total built from a measured minute alone never sets this — the reader
  /// must be told when part of a figure is a reconstruction rather than a
  /// reading, and must not be told when it is not.
  final bool includesEstimate;

  /// What the period actually cost or gained the pack: positive is a net
  /// gain, negative is a net loss.
  double get balanceWh => inWh - outWh;
}

/// One read of the written buckets, with what the window was scored against.
///
/// The cost rate travels with the series because it belongs to the same read:
/// the car scores a trip at the rate of the last charge priced before it, so a
/// rate kept apart from its buckets can describe a different window than the
/// one on screen.
class _StoredEnergy {
  const _StoredEnergy({
    required this.buckets,
    this.windowStart,
    this.costPerKwh,
    this.costCurrency,
    this.spans,
    this.estimatedMinuteStarts,
    this.timePending = false,
  });

  /// No trip is running, so `currentDrive` has nothing to show. This is not a
  /// failure and it is not the last trip either.
  static const empty = _StoredEnergy(buckets: <EnergyBucket>[]);

  final List<EnergyBucket> buckets;

  /// Where a clock window begins. Null for a trip, whose own first bucket is
  /// the left edge.
  final DateTime? windowStart;

  final double? costPerKwh;
  final String? costCurrency;

  /// The `TRIP`/`PARKED`/`CHARGE` spans covering this read's window, for
  /// [EnergyMonitorController.seriesForChartWidth] to label the minutes with.
  /// Null for every window but `sincePowerOn` — a trip or a clock window is
  /// already known to be one state throughout, so labelling it minute by
  /// minute would answer a question nobody asked.
  final List<SessionSpan>? spans;

  /// [EnergyBucket.start] millis of every minute [synthesizeSleepGapEnergyBuckets]
  /// filled in, so a reader downstream of the merge can still tell a
  /// reconstructed minute from a measured one. Null for every window but
  /// `sincePowerOn`, alongside [spans].
  final Set<int>? estimatedMinuteStarts;

  /// Time-authority T6: true when the backing series still waits for the
  /// boot's anchor. Reads served from native buckets (clock windows) carry
  /// no per-minute state and report false — the mark only fires where the
  /// intervals were actually read.
  final bool timePending;
}

/// Feeds the energy monitor from whichever pool currently holds the data.
///
/// Two sources, one series. The database holds everything already written; the
/// native monitor holds the minutes it is still accumulating. Both are the same
/// integral over the same frames, so [mergeEnergyBuckets] can join them on
/// coverage rather than either one being authoritative.
///
/// The rates are deliberately different. The live read is memory-only, so it
/// runs every second and is what makes the open bar grow. The stored read
/// sweeps sessions, so it runs once a minute — which is exactly when a bucket
/// boundary passes and there is something new for it to find.
class EnergyMonitorController extends ChangeNotifier {
  EnergyMonitorController({
    TelemetryApi? telemetryApi,
    DateTime Function()? now,
    this.livePollInterval = const Duration(seconds: 1),
    this.storedReloadInterval = const Duration(minutes: 1),
  }) : _telemetryApi = telemetryApi ?? TelemetryApi.shared,
       _now = now ?? DateTime.now;

  final TelemetryApi _telemetryApi;

  /// Injected by tests. Whether the newest bucket is still filling is a
  /// question about the clock, so it cannot be answered from the series alone.
  final DateTime Function() _now;
  final Duration livePollInterval;
  final Duration storedReloadInterval;

  EnergyWindow _window = EnergyWindow.currentDrive;
  EnergyTrack _track = EnergyTrack.drive;
  List<EnergyBucket> _live = const [];
  String? _activeSessionId;

  /// The `CONTINUOUS` session's tail, polled independently of the trip's.
  ///
  /// Both are polled every tick regardless of which window is selected: the
  /// figures under "Since power on" have to keep updating while no trip is
  /// running, which a poll gated on the selected window could not do the
  /// instant the reader switches to it.
  List<EnergyBucket> _liveContinuous = const [];
  String? _activeContinuousSessionId;
  DateTime? _continuousSessionStart;
  bool _disposed = false;

  /// The live tail stays a plain loop rather than a query.
  ///
  /// A query keeps the last good value through a failed read, which is right
  /// for an answer but wrong for this: the live tail is the minute still being
  /// accumulated, and holding the last one would freeze the open bar at the
  /// moment the read broke. Here a failure means "no tail", and the stored
  /// series still carries the trip.
  late final PollLoop _liveLoop = PollLoop(
    interval: livePollInterval,
    read: _pollLive,
    debugLabel: 'EnergyMonitorController.live',
  );

  /// The written buckets for whichever window is selected.
  ///
  /// It listens for session writes because the cost this chart reports is not
  /// its own: the car scores a trip at the rate of the last charge priced
  /// before it, so pricing a charge changes what this window costs. Without the
  /// event that correction waited for the next slow tick.
  late final TelemetryQuery<_StoredEnergy> _stored = TelemetryQuery(
    read: _readStored,
    interval: storedReloadInterval,
    debugLabel: 'EnergyMonitorController.stored',
    refreshOn: _telemetryApi.sessionChanges().where(
      (c) => c.charges || c.trips,
    ),
  );

  /// The parked minutes of the same window.
  ///
  /// It is read whether or not the parked track is selected, because whether
  /// the toggle appears at all is the question "is there parked data here" —
  /// and a toggle that had to be pressed to find that out would be a toggle
  /// with a dead option half the time.
  ///
  /// There is no live tail to merge. The live monitor publishes the trip's open
  /// minute, not the parked one, so this series ends at the last written minute
  /// and the parked chart has no growing bar.
  late final TelemetryQuery<_StoredEnergy> _parked = TelemetryQuery(
    read: _readParked,
    interval: storedReloadInterval,
    debugLabel: 'EnergyMonitorController.parked',
    refreshOn: _telemetryApi.sessionChanges().where((c) => c.parked),
  );

  /// Whether the CONTINUOUS mode is on, so "Since power on" belongs in the
  /// selector.
  ///
  /// No push event exists for a settings change made elsewhere, so this polls
  /// on the same slow cadence as the stored series rather than on every tick
  /// of the live loop — the toggle itself changes rarely, unlike a trip.
  late final TelemetryQuery<bool> _continuousMode = TelemetryQuery(
    read: () async =>
        (await _telemetryApi.getTelemetrySettings()).continuousModeEnabled,
    interval: storedReloadInterval,
    debugLabel: 'EnergyMonitorController.continuousMode',
  );

  EnergyWindow get window => _window;

  /// Whether the CONTINUOUS mode is on, as last read.
  bool get continuousModeEnabled => _continuousMode.value ?? false;

  /// The windows the selector may offer right now.
  ///
  /// "Since power on" is withheld while the mode is off: turning the mode off
  /// removes the window from the selector, and the minutes already recorded
  /// are untouched by that removal.
  List<EnergyWindow> get availableWindows => [
    for (final candidate in EnergyWindow.values)
      if (candidate != EnergyWindow.sincePowerOn || continuousModeEnabled)
        candidate,
  ];

  EnergyTrack get track => _track;

  /// Whether the window holds any parked minute. The `Drive | Parked` control
  /// appears only when this is true.
  bool get hasParkedData => (_parked.value?.buckets ?? const []).isNotEmpty;

  /// True until the first stored read lands, so the screen can tell "no data
  /// yet" from "no driving in this window".
  bool get isLoading =>
      _track.isParked ? _parked.state.isFirstLoad : _stored.state.isFirstLoad;

  /// A read failed. Distinct from an empty series: one is a broken pool, the
  /// other is a car that did not drive.
  bool get hasFailed => _track.isParked
      ? _parked.state.error != null
      : _stored.state.error != null;

  /// The trip being accumulated, or null when none is running.
  String? get activeSessionId => _activeSessionId;

  /// The `CONTINUOUS` session being accumulated, or null with the mode off.
  String? get activeContinuousSessionId => _activeContinuousSessionId;

  /// The merged one-minute series, before any reduction.
  ///
  /// The last good stored series survives a failed read. An unreachable bridge
  /// is not a car that did not drive, and [hasFailed] is what says which of the
  /// two the screen is looking at.
  List<EnergyBucket> get minutes => _track.isParked
      ? (_parked.value?.buckets ?? const [])
      : mergeEnergyBuckets(_stored.value?.buckets ?? const [], _liveTail);

  /// The live tail for whichever window is selected. Trip and continuous are
  /// two different sessions, so only one of them ever answers the question
  /// the current window is asking.
  List<EnergyBucket> get _liveTail =>
      _window == EnergyWindow.sincePowerOn ? _liveContinuous : _live;

  /// Summary of the same one-minute cut [minutes] exposes to the chart.
  ///
  /// Null on the parked track: every figure here is a driving figure, and
  /// km/kWh over a car that did not move is not a small number, it is not a
  /// number. [parkedStats] is what that track is scored by.
  EnergyMonitorStats? get selectedStats {
    if (_track.isParked) return null;
    final buckets = minutes;
    if (buckets.isEmpty) return null;
    return EnergyMonitorStats.fromBuckets(
      buckets,
      costPerKwh: _stored.value?.costPerKwh,
      costCurrency: _stored.value?.costCurrency,
    );
  }

  /// What the parked track is scored by, over the same cut the chart draws.
  ParkedMonitorStats? get parkedStats {
    if (!_track.isParked) return null;
    final buckets = minutes;
    if (buckets.isEmpty) return null;
    return ParkedMonitorStats.fromBuckets(
      buckets,
      costPerKwh: _parked.value?.costPerKwh,
      costCurrency: _parked.value?.costCurrency,
    );
  }

  /// The ledger "Since power on" is scored by, over the same cut the chart
  /// draws. Null on every other window — a trip or a clock window bounded to
  /// one kind of session already has its own figures, and this ledger exists
  /// precisely for the period no session answers alone.
  EnergyLedgerStats? get ledgerStats {
    if (_window != EnergyWindow.sincePowerOn) return null;
    final buckets = minutes;
    if (buckets.isEmpty) return null;
    return EnergyLedgerStats.fromBuckets(
      buckets,
      isEstimated: _isEstimatedMinute,
    );
  }

  /// Whether [bucket] is one [synthesizeSleepGapEnergyBuckets] filled in,
  /// against the same set every "Since power on" reader checks — the ledger
  /// and the chart's own label/estimated fold must never disagree about which
  /// minute is which.
  bool Function(EnergyBucket bucket)? get _isEstimatedMinute {
    final estimatedStarts = _stored.value?.estimatedMinuteStarts;
    if (estimatedStarts == null) return null;
    return (bucket) =>
        estimatedStarts.contains(bucket.start.millisecondsSinceEpoch);
  }

  /// True between [start] and [stop]. Hidden tabs use this to know the poll
  /// is actually off, not merely unpainted.
  bool get isPolling => _liveLoop.isRunning;

  void start() {
    if (_liveLoop.isRunning) return;
    _stored.addListener(_notify);
    _parked.addListener(_notify);
    _continuousMode.addListener(_onContinuousModeChanged);
    // The first read is [refresh], not two independent ticks, because the
    // stored read needs the session id the live read reports.
    unawaited(refresh());
    _liveLoop.start(immediate: false);
    _stored.startLater();
    _parked.startLater();
    _continuousMode.startLater();
  }

  void stop() {
    _liveLoop.stop();
    _stored.removeListener(_notify);
    _stored.stop();
    _parked.removeListener(_notify);
    _parked.stop();
    _continuousMode.removeListener(_onContinuousModeChanged);
    _continuousMode.stop();
  }

  @override
  void dispose() {
    _disposed = true;
    _liveLoop.dispose();
    _stored.dispose();
    _parked.dispose();
    _continuousMode.dispose();
    super.dispose();
  }

  /// A read in flight when the screen is left completes after this controller
  /// is gone. Notifying then throws, so the answer is simply dropped.
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// The mode turning off is not merely a new value to redraw: a selector
  /// that dropped its selected option out from under it would leave the
  /// dropdown showing a value it no longer offers. Falling back to
  /// [EnergyWindow.currentDrive] keeps the selection inside what is offered,
  /// the way [selectWindow] already keeps the track inside what a live window
  /// can answer.
  void _onContinuousModeChanged() {
    if (_disposed) return;
    if (_continuousMode.value == false &&
        _window == EnergyWindow.sincePowerOn) {
      selectWindow(EnergyWindow.currentDrive);
      return;
    }
    notifyListeners();
  }

  void selectWindow(EnergyWindow window) {
    if (_window == window) return;
    _window = window;
    // `currentDrive` is bounded by a trip, so it has no parked reading at all.
    // Leaving the reader on a track the new window cannot answer would show an
    // empty chart that looks like a car which never stood still.
    if (window.isLive) _track = EnergyTrack.drive;
    _notify();
    // The previous window's series is not a stale version of this one, it is a
    // different question. `ask` drops the answer and reads at once, so the
    // chart does not show the old series under the new label. It deliberately
    // skips the tick's coalescing guard: a read in flight belongs to the window
    // the reader has just left, and the query's own counter is what keeps its
    // answer off the screen whichever order the two land in.
    unawaited(_stored.ask());
    unawaited(_parked.ask());
  }

  /// Switches which reading of the window the chart draws.
  ///
  /// No read follows. Both series are already being kept for this window — the
  /// parked one has to be, or the control could not know whether to appear —
  /// so the switch is a change of what is drawn, not a change of question.
  void selectTrack(EnergyTrack track) {
    if (_track == track) return;
    if (track.isParked && _window.isLive) return;
    _track = track;
    _notify();
  }

  /// Live first, then stored. `currentDrive` and `sincePowerOn` are each
  /// identified by the session their own live read reports, so reading the
  /// database before it would ask for a session nobody has named yet and
  /// settle on "nothing running".
  Future<void> refresh() async {
    await Future.wait([_pollLive(), _pollLiveContinuous()]);
    await Future.wait([
      _stored.refresh(),
      _parked.refresh(),
      _continuousMode.refresh(),
    ]);
  }

  Future<void> _pollLive() async {
    try {
      final live = await _telemetryApi.getLiveEnergyBuckets();
      final sessionChanged = live.sessionId != _activeSessionId;
      _activeSessionId = live.sessionId;
      _live = live.buckets;
      _notify();
      // A trip starting or ending changes what `currentDrive` refers to, so
      // that series is asked again rather than waiting for the slow tick. A
      // clock window is untouched by it, and so is `sincePowerOn`: neither
      // one's meaning depends on whether a trip is running.
      if (sessionChanged && _window == EnergyWindow.currentDrive) {
        unawaited(_stored.ask());
      }
    } catch (_) {
      // The live read is a fast poll; one failure is a dropped tick, not a
      // broken screen. The stored series still carries the trip.
      if (_live.isNotEmpty) {
        _live = const [];
        _notify();
      }
    }
  }

  /// Same shape as [_pollLive], for the `CONTINUOUS` session.
  ///
  /// Polled unconditionally, whatever window is selected: the figures under
  /// "Since power on" have to keep updating the moment the reader switches to
  /// it, not a poll interval later.
  Future<void> _pollLiveContinuous() async {
    try {
      final live = await _telemetryApi.getLiveContinuousEnergyBuckets();
      final sessionChanged = live.sessionId != _activeContinuousSessionId;
      _activeContinuousSessionId = live.sessionId;
      _continuousSessionStart = live.startedAt;
      _liveContinuous = live.buckets;
      _notify();
      // A rotation, or the mode turning on or off, changes what
      // `sincePowerOn` refers to. A trip's own state is untouched by it.
      if (sessionChanged && _window == EnergyWindow.sincePowerOn) {
        unawaited(_stored.ask());
      }
    } catch (_) {
      if (_liveContinuous.isNotEmpty) {
        _liveContinuous = const [];
        _notify();
      }
    }
  }

  Future<_StoredEnergy> _readStored() async {
    final window = _window;
    if (window == EnergyWindow.sincePowerOn) {
      String? sessionId = _activeContinuousSessionId;
      DateTime? sessionStart = _continuousSessionStart;

      if (sessionId == null) {
        final page = await _telemetryApi.listSessions(
          filter: const SessionFilter(
            status: 'OPEN',
            kind: SessionKind.continuous,
          ),
          page: const PageRequest(limit: 1, offset: 0),
        );
        if (page.sessions.isNotEmpty) {
          final s = page.sessions.first;
          sessionId = s.id;
          sessionStart = DateTime.fromMillisecondsSinceEpoch(
            s.startedAtUtcMillis,
          );
        }
      }

      if (sessionId == null || sessionStart == null) return _StoredEnergy.empty;

      // No priced-charge lookup here: a rate priced for a drive is not a fact
      // about this timeline, which crosses trips, parked stretches and
      // charges alike. The continuous stream never reprints a figure a
      // session already answers.
      final series = await _telemetryApi.getSeries(sessionId);
      final rawBuckets = [
        for (final interval in series.intervals)
          EnergyBucket.fromInterval(interval),
      ];
      final reconciled = reconcileSessionEnergyBuckets(
        rawBuckets,
        sessionStart: sessionStart,
      );

      final windowStartMs = sessionStart.millisecondsSinceEpoch;
      final nowMs = _now().millisecondsSinceEpoch;
      // Use inWindowAll logic: sessions that started before windowStartMs but ended within the window
      // Replace the start-based filter with overlap detection to fix Finding 2
      final page = await _telemetryApi.listSessions(
        filter: SessionFilter(fromUtcMillis: null, toUtcMillis: nowMs),
        page: const PageRequest(limit: 500, offset: 0),
      );
      // Client-side overlap filter: sessions that ended after windowStartMs but were started before windowStartMs
      // This matches SessionDao.inWindowAll: (endedAt IS NULL OR endedAt >= startUtcMillis) AND startedAtUtcMillis <= endUtcMillis
      final fromMs = windowStartMs - const Duration(hours: 24).inMilliseconds;
      final spans = [
        for (final session in page.sessions)
          if (session.kind != SessionKind.continuous &&
              (session.endedAtUtcMillis == null ||
                  session.endedAtUtcMillis! >= fromMs) &&
              session.startedAtUtcMillis <= nowMs)
            SessionSpan(
              kind: session.kind,
              start: DateTime.fromMillisecondsSinceEpoch(
                session.startedAtUtcMillis,
              ),
              end: session.endedAtUtcMillis == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(
                      session.endedAtUtcMillis!,
                    ),
              sleepSeconds: session.sleepSeconds,
              sleepSocDeltaPercent: session.sleepSocDeltaPercent,
              sleepEnergyWhEstimate: session.sleepEnergyWhEstimate,
            ),
      ];
      // Fills the sleeping stretch a gated sleep-gap estimate backs, so the
      // ledger and the chart both see it; every other gap stays a gap. See
      // issue 199/211.
      final synthesized = synthesizeSleepGapEnergyBuckets(
        buckets: reconciled,
        spans: spans,
      );
      final buckets = mergeEnergyBuckets(reconciled, synthesized);
      final estimatedMinuteStarts = {
        for (final bucket in synthesized) bucket.start.millisecondsSinceEpoch,
      };
      return _StoredEnergy(
        buckets: buckets,
        spans: spans,
        estimatedMinuteStarts: estimatedMinuteStarts,
        timePending: seriesTimePending(series.intervals),
      );
    }
    if (window == EnergyWindow.currentDrive) {
      final sessionId = _activeSessionId;
      if (sessionId == null) return _StoredEnergy.empty;
      // The open drive's own minutes, read as the store's third question, and
      // beside them the rate of the charge that filled the car — a fact about
      // an earlier session, so it is asked for as one.
      //
      // Both at once, and the price is the lesser of the two: a drive with no
      // priced charge behind it still has its minutes, so a failed price
      // leaves the cost unknown rather than losing the series. In sequence
      // they would also make this read two turns deep, and a refresh arriving
      // inside the second turn would be dropped as a tick landing on a read
      // already in flight.
      final (series, priced) = await (
        _telemetryApi.getSeries(sessionId),
        lastPricedChargeBefore(
          _telemetryApi.store,
          DateTime.now().millisecondsSinceEpoch,
        ).catchError((Object _) => null),
      ).wait;
      final rawBuckets = [
        for (final interval in series.intervals)
          EnergyBucket.fromInterval(interval),
      ];
      final buckets = reconcileSessionEnergyBuckets(rawBuckets);
      return _StoredEnergy(
        buckets: buckets,
        costPerKwh: priced?.costPerKwh,
        costCurrency: priced?.costCurrency,
        timePending: seriesTimePending(series.intervals),
      );
    }
    final result = await _telemetryApi.getEnergyBucketsInWindow(window);
    return _StoredEnergy(
      buckets: result.buckets,
      windowStart: result.start,
      costPerKwh: result.costPerKwh,
      costCurrency: result.costCurrency,
    );
  }

  Future<_StoredEnergy> _readParked() async {
    final window = _window;
    // A trip-bounded window has no parked reading, and asking for one would
    // assert its way through `getParkedEnergyBucketsInWindow`.
    if (window.isLive) return _StoredEnergy.empty;
    final result = await _telemetryApi.getParkedEnergyBucketsInWindow(window);
    return _StoredEnergy(
      buckets: result.buckets,
      windowStart: result.start,
      costPerKwh: result.costPerKwh,
      costCurrency: result.costCurrency,
    );
  }

  /// Resolves the series against the room the chart actually has.
  ///
  /// [chartWidth] is the whole component's width; the axis gutter is taken off
  /// here so callers can pass their layout constraint straight through.
  EnergyChartSeries seriesForChartWidth(
    double chartWidth, {
    required int capacity,
  }) {
    final source = minutes;
    if (source.isEmpty) return EnergyChartSeries.empty;

    if (capacity <= 0) return EnergyChartSeries.empty;

    final now = _now();
    // The parked series is stored-only, so it has no interval still filling.
    // Which session id has to be non-null depends on which live window is
    // selected: a trip running does not make `sincePowerOn`'s bar open, and
    // the reverse.
    final relevantSessionId = _window == EnergyWindow.sincePowerOn
        ? _activeContinuousSessionId
        : _activeSessionId;
    final live =
        !_track.isParked && _window.isLive && relevantSessionId != null;
    final selectedMinutes = _window.minutes;
    final span = selectedMinutes == null
        ? _liveDomainSpan(source, now)
        : Duration(minutes: selectedMinutes);
    var width = chooseEnergyBucketWidth(span: span, capacity: capacity);

    // The normal chooser steps up only after the current width overflows. A
    // live chart instead steps up at the instant its final slot finishes, so
    // the next update already has an empty tail to grow into.
    if (live && span >= width * capacity) {
      width = nextEnergyBucketWidth(width);
    }

    var reduced = reduceEnergyBuckets(
      source,
      width,
      origin: live ? source.first.start : null,
    );

    // A clock window's left edge falls wherever "the last N minutes" lands, so
    // its first bar can cover a fraction of its interval and read as a drop in
    // consumption. Dropping it costs one bar at the edge and keeps every bar
    // that is drawn comparable. A trip's first bar is kept: that one is short
    // because the drive really began mid-interval, which the axis shows.
    final windowStart = _track.isParked
        ? _parked.value?.windowStart
        : _stored.value?.windowStart;
    final domainStart = windowStart == null
        ? reduced.first.start
        : ceilEnergyBucketBoundary(windowStart, width);
    if (windowStart != null) {
      reduced = [
        for (final bucket in reduced)
          if (!bucket.start.isBefore(domainStart)) bucket,
      ];
    }

    final openBucket = openEnergyBucketIndex(reduced, live: live, now: now);
    final openStart = openBucket == null ? null : reduced[openBucket].start;
    final buckets = fillEnergyBucketSlots(
      buckets: reduced,
      start: domainStart,
      width: width,
      slotCount: capacity,
    );
    final labelling = _labelsAndEstimatedFor(buckets, now);
    return EnergyChartSeries(
      buckets: buckets,
      width: width,
      openIndex: openStart == null
          ? null
          : buckets.indexWhere((bucket) => bucket.start == openStart),
      labels: labelling?.$1,
      estimated: labelling?.$2,
      timePending: _stored.value?.timePending ?? false,
    );
  }

  /// One [ContinuousLabel] and one estimated flag per entry in [buckets], or
  /// null outside `sincePowerOn`.
  ///
  /// Resolved against [minutes] — the merged, un-widened one-minute series —
  /// rather than against [buckets] directly: a chart bucket wider than a
  /// minute has to fold several already-resolved minutes into one label, and
  /// [resolveStretchLabel] is that fold, not a second precedence rule. The
  /// estimated flag folds the same way, by "any": a widened bar that contains
  /// even one estimated minute is not a bar the reader can take as measured.
  (List<ContinuousLabel>, List<bool>)? _labelsAndEstimatedFor(
    List<EnergyBucket> buckets,
    DateTime now,
  ) {
    if (_window != EnergyWindow.sincePowerOn) return null;
    final spans = _stored.value?.spans;
    if (spans == null) return null;
    final labelled = labelEnergyBuckets(
      buckets: minutes,
      spans: spans,
      now: now,
      isEstimated: _isEstimatedMinute,
    );
    final byStart = <int, LabelledContinuousMinute>{
      for (final entry in labelled)
        entry.bucket.start.millisecondsSinceEpoch: entry,
    };
    final labels = <ContinuousLabel>[];
    final estimated = <bool>[];
    for (final bucket in buckets) {
      final covered = [
        for (
          var t = bucket.start;
          t.isBefore(bucket.end);
          t = t.add(EnergyBucket.oneMinute)
        )
          byStart[t.millisecondsSinceEpoch],
      ];
      labels.add(
        resolveStretchLabel([for (final minute in covered) ?minute?.label]),
      );
      estimated.add(covered.any((minute) => minute?.estimated ?? false));
    }
    return (labels, estimated);
  }

  /// The stretch of driving a live window covers, without ever subtracting
  /// wall-clock stamps.
  ///
  /// The axis domain is a count of recorded minutes — gaps included — because
  /// the car's clock is not trustworthy until the TBox syncs it. A stamp
  /// months out of date reaches right through `reconcileSessionEnergyBuckets`
  /// (when it is the newest row's clock that lied) and turns a nine-minute
  /// trip into a 22000-hour axis; the recorded rows are always the minute,
  /// so one minute one slot. The gap after the final measured minute is the
  /// one place clock time still legitimately enters: it is the room the open
  /// bucket has yet to fill.
  Duration _liveDomainSpan(List<EnergyBucket> source, DateTime now) {
    final measured = energyBucketSpan(source);
    if (now.isAfter(source.last.end)) return measured;
    // The newest bucket is still open: `now` stops the domain at the
    // measured progress of that minute instead of claiming its future end.
    final openProgress = now.isAfter(source.last.start)
        ? now.difference(source.last.start)
        : Duration.zero;
    final openRemainder =
        (source.last.width.inMicroseconds - openProgress.inMicroseconds).clamp(
          0,
          source.last.width.inMicroseconds,
        );
    return measured - Duration(microseconds: openRemainder);
  }
}
