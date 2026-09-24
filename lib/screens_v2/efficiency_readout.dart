import 'dart:async';

import 'package:flutter/material.dart';

import '../core/efficiency_unit.dart';
import '../core/live_roadcast_runtime.dart';
import '../core/live_trip_can.dart';
import '../core/live_trip_can_hub.dart';
import '../core/live_vehicle_speed.dart';
import '../core/range_estimate_controller.dart';
import '../core/telemetry_api.dart';
import '../core/telemetry_scope.dart';
import '../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';

/// The efficiency card, wired to the car, for the shell's instant-readout
/// footer.
///
/// ## It feeds itself
///
/// Every live value is read inside this widget and nothing is passed down from
/// the shell. That is a hard requirement of where the strip sits, not a
/// preference: the footer is chrome *above* the `PageView`, so a value held in
/// the shell's own state would rebuild the shell — and with it every mounted
/// destination, including the ones the user is not looking at — at whatever
/// rate that value changes. A live screen has nothing underneath it and can
/// afford to be careless here. This cannot.
///
/// ## Two readings, two clocks
///
/// - the **line** reduces the ten-second buckets that arrive over
///   [TelemetryApi.getLiveEfficiencyBuckets]. A new bucket lands every ten
///   seconds, so the line rebuilds six times a minute;
/// - the **pill** folds live speed and traction power into a
///   [DrivingSmoothness]. The power comes off CAN through
///   [LiveRoadcastRuntime] at 60 Hz; the speed comes from the VHAL's own
///   narrow channel, which publishes every `VEHICLE_SPEED` update at the 5 Hz
///   the subscription asks for. [SmoothnessTracker] resamples both onto its own
///   200 ms grid, so the pill republishes five times a second however fast the
///   bus runs.
///
/// The speed is not read from CAN. `ESC_VehicleSpeed` was withdrawn on
/// 2026-08-07: it stops arriving for whole trips at a time, and the pill cannot
/// tell a missing speed from a stopped car — both read as no motion. The VHAL
/// value is slower, but it is the one the trip record is built from, so the
/// pill and the line can no longer disagree about whether the car is moving.
/// The ratio still answers within a frame, because power is what moves fast
/// when a driver lifts off.
///
/// The fast one is handed to [EfficiencyCard] as a [ValueNotifier] rather than
/// as a value, which is what keeps it inside the pill's own builder — see that
/// class. This widget owns *what* the readings are; the card owns how they are
/// arranged and which of them rebuilds on the fast clock.
///
/// ## Sampling stops when nobody can see it
///
/// The 60 Hz FFI read runs on its own timer whether or not anything repaints,
/// so the cost is in the sampling, not the painting. Two cases stop it, and
/// both are invisible to [LiveRoadcastRuntime] itself: the app going to the
/// background, and the footer being pushed off screen by a card taking over —
/// see [stage]. Buckets keep their much cheaper poll on the same switch.
class EfficiencyReadout extends StatefulWidget {
  const EfficiencyReadout({
    this.stage,
    this.telemetryApi,
    this.liveCan,
    this.samplingEnabled = true,
    super.key,
  });

  /// The shell's card stage, watched only to stop sampling while the footer is
  /// off screen. Null for a journey whose chrome never leaves.
  final CardStageController? stage;

  /// Test seam. Production uses the default channel-backed API.
  final TelemetryApi? telemetryApi;

  /// Shared 60 Hz client. The shell owns one and hands it to this card and to
  /// [InclineReadout]. Null in tests, which then open a private runtime.
  final LiveTripCanHub? liveCan;

  /// False when the footer is off screen for a reason this card does not own
  /// (History taking the strip). [stage] still covers a fullscreen card.
  final bool samplingEnabled;

  @override
  State<EfficiencyReadout> createState() => _EfficiencyReadoutState();
}

class _EfficiencyReadoutState extends State<EfficiencyReadout>
    with WidgetsBindingObserver {
  /// How far back the card reads. The slot count follows from this and the
  /// width the native side states, so neither has to be restated here.
  static const _window = Duration(minutes: 15);

  /// Width to poll at until the first result states the real one.
  ///
  /// It is not a second source of truth for the grid — [_reduce] lays every
  /// bucket out with [LiveEnergyBucketsResult.width]. It only has to pick a
  /// cadence for the very first request, before any result has arrived.
  static const _assumedWidth = Duration(seconds: 10);

  /// How long after a bucket boundary to ask for it.
  ///
  /// The native side closes the bucket on the same wall clock, so a poll landing
  /// exactly on the boundary would race it and read the interval before last.
  static const _settle = Duration(milliseconds: 750);

  /// The width the native side last stated. See [_assumedWidth].
  Duration _bucketWidth = _assumedWidth;

  late final TelemetryApi _telemetryApi =
      widget.telemetryApi ?? TelemetryScope.of(context);
  LiveRoadcastRuntime<LiveTripCanState>? _ownedLive;

  Timer? _bucketTimer;
  EfficiencySeries _series = EfficiencySeries.empty;

  /// The last series still waits for the boot's clock anchor. The line draws
  /// from the buckets themselves, and a chip says the time is not synced yet.
  bool _timeUnsynced = false;
  bool _sampling = false;

  /// Which poll is the newest. A slow channel lets two polls overlap, and the
  /// older answer can return last; a pause can also land while one is in
  /// flight. Both cases would put a reading from the past on a live card, so
  /// every result checks that it is still the one being waited for.
  int _pollSequence = 0;

  /// Newest speed the VHAL published, held between its own updates.
  ///
  /// Kept as the whole reading rather than as a number so every CAN sample can
  /// re-check its age. That is what expires it: a channel that goes quiet
  /// leaves this reading in place, and a held speed divided by live power would
  /// keep the pill moving on a car that is no longer reporting.
  LiveVehicleSpeedReading? _speedReading;

  StreamSubscription<LiveVehicleSpeedReading>? _speedSubscription;

  /// Folds speed and traction power into the pill's reading. Owned here rather
  /// than by the card, because it is state about the car and not about layout.
  final SmoothnessTracker _smoothness = SmoothnessTracker();

  /// The pill's reading, republished whenever the tracker accepts a sample. A
  /// notifier rather than a field so the rebuild it causes stops at the pill
  /// instead of climbing to this widget and taking the line with it.
  final ValueNotifier<DrivingSmoothness> _smoothnessReading = ValueNotifier(
    DrivingSmoothness.unavailable,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // A private runtime only when the shell did not hand one over. The
    // watchlist is the full trip set either way: the read is one batched call.
    if (widget.liveCan == null) {
      _ownedLive = LiveRoadcastRuntime<LiveTripCanState>(
        watchlist: LiveTripCanNames.watchlist,
        createState: (entries) =>
            LiveTripCanState(entries: entries, retainActivityHistory: false),
        observeSample: (state, reading, nowMillis) {
          state.observe(reading, nowMillis);
          _onCanSample(state, nowMillis);
        },
      );
    }
    RangeEstimateController.instance.addListener(_onReferenceChanged);
    widget.stage?.addListener(_onStageChanged);
    _resume();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    RangeEstimateController.instance.removeListener(_onReferenceChanged);
    widget.stage?.removeListener(_onStageChanged);
    _pause();
    _ownedLive?.dispose();
    _smoothnessReading.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant EfficiencyReadout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.samplingEnabled != widget.samplingEnabled) {
      if (widget.samplingEnabled) {
        _resume();
      } else {
        _pause();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _resume();
    } else {
      _pause();
    }
  }

  /// The card is hidden exactly when a card underneath has fully taken over.
  /// Anything short of that leaves part of the strip visible, so it keeps
  /// reading.
  void _onStageChanged() {
    if (widget.stage?.isFullscreen ?? false) {
      _pause();
    } else {
      _resume();
    }
  }

  /// The line's colour divider comes from the shell's own poll; a new estimate
  /// moves it, so the card has to rebuild even when neither of its own sources
  /// ticked. The pill no longer uses this — see [_reference].
  void _onReferenceChanged() {
    if (mounted) setState(() {});
  }

  /// The held speed, or null once it is too old to divide by.
  ///
  /// [LiveVehicleSpeedReading.isUsableAt] also rejects a degraded quality and a
  /// non-VHAL source, so the pill withdraws instead of reading a value the trip
  /// record would not have kept either.
  double? _usableSpeedKmh(int nowMillis) {
    final reading = _speedReading;
    if (reading == null || !reading.isUsableAt(nowMillis)) return null;
    return reading.speedKmh;
  }

  void _onCanSample(LiveTripCanState state, int nowMillis) {
    // The tracker resamples onto its own grid and says when a sample
    // landed, so the notifier fires five times a second rather than sixty.
    if (_smoothness.observe(
      nowMillis: nowMillis,
      speedKmh: _usableSpeedKmh(nowMillis),
      drivePowerKw: state.drivePowerKw,
    )) {
      _smoothnessReading.value = _smoothness.readingAt(nowMillis);
    }
  }

  void _resume() {
    if (_sampling || !mounted) return;
    if (!widget.samplingEnabled) return;
    if (widget.stage?.isFullscreen ?? false) return;
    _sampling = true;
    final hub = widget.liveCan;
    if (hub != null) {
      hub.addListener(_onCanSample);
      unawaited(hub.acquire());
    } else {
      unawaited(_ownedLive!.start());
    }
    _speedSubscription ??= const LiveVehicleSpeedApi().stream().listen(
      (reading) => _speedReading = reading,
      // The pill has no way to show a speed error, and it must not keep the
      // last reading alive across one. Dropping it expires the pill on the next
      // CAN sample, which is the same answer as a quiet channel.
      onError: (Object _) => _speedReading = null,
    );
    _scheduleBucketPoll();
    // One read straight away, so a card that has just come back on screen is
    // not blank until the next boundary.
    unawaited(_loadBuckets());
  }

  /// Puts the poll in phase with the wall-clock bucket grid.
  ///
  /// A plain `Timer.periodic` starts whenever the footer resumed, so its phase
  /// against the grid is arbitrary and a bucket that had just closed could wait
  /// a further full width. That put the line up to two intervals behind the car.
  void _scheduleBucketPoll() {
    _bucketTimer?.cancel();
    final width = _bucketWidth;
    final next = ceilEnergyBucketBoundary(DateTime.now(), width).add(_settle);
    _bucketTimer = Timer(next.difference(DateTime.now()), () {
      unawaited(_loadBuckets());
      _bucketTimer = Timer.periodic(width, (_) => _loadBuckets());
    });
  }

  void _pause() {
    if (!_sampling) return;
    _sampling = false;
    final hub = widget.liveCan;
    if (hub != null) {
      hub.removeListener(_onCanSample);
      hub.release();
    } else {
      _ownedLive?.stop();
    }
    _speedSubscription?.cancel();
    _speedSubscription = null;
    // A speed from before the pause is stale by definition once sampling
    // resumes, and nothing else would clear it.
    _speedReading = null;
    // The tracker holds a window and the power reading that opened it. Across a
    // pause the next difference would span the whole gap, which describes
    // nothing the driver did, so the window restarts rather than resuming.
    _smoothness.reset();
    _smoothnessReading.value = DrivingSmoothness.unavailable;
    _bucketTimer?.cancel();
    _bucketTimer = null;
  }

  Future<void> _loadBuckets() async {
    final sequence = ++_pollSequence;
    try {
      final result = await _telemetryApi.getLiveEfficiencyBuckets();
      if (!mounted || !_sampling || sequence != _pollSequence) return;
      // A width the native side cut differently is a change of grid, so the
      // poll has to be put back in phase with the new one.
      if (result.width > Duration.zero && result.width != _bucketWidth) {
        _bucketWidth = result.width;
        _scheduleBucketPoll();
      }
      setState(() {
        _series = _reduce(result);
        _timeUnsynced =
            result.timeUnsynced &&
            _series.points.any(
              (point) => point.state != EfficiencyState.unreported,
            );
      });
    } catch (_) {
      // A failed poll keeps the last series rather than emptying the card. The
      // line already draws an unreported interval as a break, so a gap that
      // outlives the window disappears on its own.
    }
  }

  /// Lays the buckets back onto an exact grid and reads them.
  ///
  /// The grid uses the width the result carries, never a width held here.
  /// `readEfficiency` needs every slot present so an unreported interval keeps
  /// its place instead of the gap closing; a grid cut at the wrong width lands
  /// no bucket in any slot at all, which would empty the card in a release build
  /// with nothing to say why.
  EfficiencySeries _reduce(LiveEnergyBucketsResult result) {
    final width = result.width;
    if (result.buckets.isEmpty || width <= Duration.zero) {
      return EfficiencySeries.empty;
    }
    final slotCount = _window.inMicroseconds ~/ width.inMicroseconds;
    if (slotCount <= 0) return EfficiencySeries.empty;
    // While the boot's anchor is still unlearned the stamps are the car's
    // birth clock, so a grid cut at now() holds none of them and the line
    // vanishes (boot 142). Grid on the buckets themselves instead: slot
    // order is measured, the stamps are not — same rule as the energy chart.
    final end = result.timeUnsynced
        ? ceilEnergyBucketBoundary(_newestBucketEnd(result.buckets), width)
        : ceilEnergyBucketBoundary(DateTime.now(), width);
    return readEfficiency(
      fillEnergyBucketSlots(
        buckets: result.buckets,
        start: end.subtract(width * slotCount),
        width: width,
        slotCount: slotCount,
      ),
    );
  }

  /// Newest bucket end, without reordering: the native side sends the series
  /// oldest-first on one monotonic line, and a wall jump must not scramble it.
  DateTime _newestBucketEnd(List<EnergyBucket> buckets) {
    var newest = buckets.first.end;
    for (var i = 1; i < buckets.length; i++) {
      final end = buckets[i].end;
      if (end.isAfter(newest)) newest = end;
    }
    return newest;
  }

  /// Efficiency the car's own range estimate assumes, in km/kWh.
  ///
  /// The line's colour divider only. The pill used to share it, which was a
  /// unit error as well as a bad reading: this figure is SOC-derived and
  /// therefore includes the auxiliaries, while the pill divided by
  /// `VCU_DrvPwrAct`, which is traction alone. The pill now measures technique
  /// and needs no efficiency reference, so the mismatch is gone rather than
  /// corrected. Null while the estimate is degraded, which falls back to the
  /// middle of the axis.
  double? get _reference =>
      RangeEstimateController.instance.estimate?.efficiencyKmPerKwh;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return AppCard(
      child: ListenableBuilder(
        listenable: EfficiencyUnitController.instance,
        builder: (context, _) {
          final unit = EfficiencyUnitController.instance.unit;
          final card = EfficiencyCard(
            series: _series,
            smoothness: _smoothnessReading,
            neutral: _reference,
            floorLabel: loc.efficiencyLessRange,
            unitLabel: loc.efficiencyAxisUnit,
            unit: unit,
            unitSuffix: efficiencyUnitSuffix(unit, loc),
            onCycleUnit: () => EfficiencyUnitController.instance.cycle(),
            averageCaption: loc.efficiencyAverageWindow,
            // Always named. The numeral on this card is km/kWh, so an unlabelled
            // pill beside it reads as a second efficiency figure disagreeing with
            // the first. It measures technique, and it has to say so.
            referenceCaption: loc.efficiencySmoothnessLabel,
            referenceDetail: loc.efficiencySmoothnessWindow,
            info: const _EfficiencyInfoButton(),
          );
          // The pending mark never replaces the line: the card keeps working
          // without a trusted time, and says so on the same screen as the
          // data — same rule as the energy chart's mark.
          if (!_timeUnsynced) return card;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _TimeNotSyncedChip(caption: loc.efficiencyTimeNotSynced),
              const SizedBox(height: AppSpacing.x2),
              Flexible(child: card),
            ],
          );
        },
      ),
    );
  }
}

/// The "time not synced" mark, shared with the energy chart's mark in look:
/// an amber caption with the schedule glyph, never a second card and never
/// an empty state.
class _TimeNotSyncedChip extends StatelessWidget {
  const _TimeNotSyncedChip({required this.caption});

  final String caption;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.schedule,
          size: AppSizes.iconSm,
          color: AppThemeColors.of(context).energy.warning,
        ),
        const SizedBox(width: AppSpacing.x1),
        Flexible(
          child: Text(
            caption,
            style: AppText.label.copyWith(
              color: AppThemeColors.of(context).energy.warning,
            ),
          ),
        ),
      ],
    );
  }
}

/// Says how to read the card, and says that the number on it is not the number
/// on the instrument cluster.
///
/// The last point is why this exists. The card and the car both answer "how
/// much energy per distance", they both can print kWh/100 km, and they
/// disagree — because the car averages the literal last 100 km, which is many
/// trips and often many days, while this card averages the last fifteen
/// minutes. Without that sentence the reader has two figures for one question
/// and no way to tell which is wrong. Neither is.
class _EfficiencyInfoButton extends StatelessWidget {
  const _EfficiencyInfoButton();

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return AnchoredTooltipTrigger(
      // The card is the leading one in the footer strip, so the room is
      // outboard. The caret sits low in the panel because the trigger is near
      // the bottom of the screen and the panel has to grow upward from it.
      side: AnchoredTooltipSide.right,
      caretAlignment: 0.9,
      anchorInsets: const EdgeInsets.all(AppSpacing.x4),
      barrierLabel: loc.efficiencyInfoClose,
      tooltipBuilder: (context) => InformationTooltipPanel(
        title: loc.efficiencyInfoTitle,
        children: [
          InformationCard(
            icon: Icons.show_chart,
            iconColor: AppThemeColors.of(context).energy.gain,
            value: loc.efficiencyInfoLinesLabel,
            description: loc.efficiencyInfoLines,
          ),
          InformationCard(
            icon: Icons.straighten,
            value: loc.efficiencyInfoScaleLabel,
            description: loc.efficiencyInfoScale,
          ),
          // What the numeral is, and why the cluster prints a different one.
          // The two belong in one card: the reader who asks what the number
          // means is the reader who has just seen the car disagree with it.
          InformationCard(
            icon: Icons.av_timer,
            value: loc.efficiencyInfoAverageLabel,
            description: loc.efficiencyInfoAverage,
          ),
          InformationCard(
            icon: Icons.tune,
            value: loc.efficiencyInfoSmoothnessLabel,
            description: loc.efficiencyInfoSmoothness,
          ),
        ],
      ),
      builder: (context, isOpen, open) => InfoIconButton(
        selected: isOpen,
        onPressed: open,
        tooltip: loc.efficiencyAbout,
      ),
    );
  }
}
