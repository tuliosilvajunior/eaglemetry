import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/eco_coach.dart';
import '../../core/live_roadcast_runtime.dart';
import '../../core/live_trip_can.dart';
import '../../core/live_vehicle_speed.dart';
import '../../core/telemetry_api.dart';
import '../../core/telemetry_format.dart';
import '../../design_system/design_system.dart';
import '../../l10n/app_localizations.dart';
import 'live_trip_panels.dart';
import 'trip_session_detail_screen.dart';
import 'trip_session_display.dart';

/// Live trip surface backed by Roadcast plus one narrow VEHICLE_SPEED stream.
///
/// The session passed by the list supplies immutable context such as start time,
/// status and initial SOC. Battery/driver inputs come from one batched Dart FFI
/// read; speed comes from a dedicated EventChannel carrying the normalized
/// CarPropertyManager value. No MethodChannel polling, GPS route or Room query
/// belongs to this screen; persisted aggregates remain on historical detail.
class LiveTripDetailScreen extends StatefulWidget {
  const LiveTripDetailScreen({required this.session, super.key});

  final SessionRecord session;

  @override
  State<LiveTripDetailScreen> createState() => _LiveTripDetailScreenState();
}

class _LiveTripDetailScreenState extends State<LiveTripDetailScreen>
    with WidgetsBindingObserver {
  static const Duration _historyWindow = Duration(seconds: 30);
  static const double _wideBreakpoint = 1180;

  final RollingSignalBuffer _speedSeries = RollingSignalBuffer(
    window: _historyWindow,
  );
  final RollingSignalBuffer _powerSeries = RollingSignalBuffer(
    window: _historyWindow,
  );
  final RollingSignalBuffer _currentSeries = RollingSignalBuffer(
    window: _historyWindow,
  );

  late final LiveRoadcastRuntime<LiveTripCanState> _live;
  late final Duration? _initialSessionElapsed;
  late final Stopwatch _sessionStopwatch;
  final LiveVehicleSpeedApi _vehicleSpeedApi = const LiveVehicleSpeedApi();
  StreamSubscription<LiveVehicleSpeedReading>? _vehicleSpeedSubscription;
  LiveVehicleSpeedReading? _vehicleSpeedReading;
  bool _vehicleSpeedWasUsable = false;
  Object? _vehicleSpeedError;
  Timer? _clockTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialSessionElapsed =
        durationFromMillis(widget.session.durationMillis) ??
        boundedDurationBetween(
          dateTimeFromMillis(widget.session.startedAtUtcMillis),
          null,
          maximum: const Duration(hours: 48),
        );
    _sessionStopwatch = Stopwatch()..start();
    _live = LiveRoadcastRuntime<LiveTripCanState>(
      watchlist: LiveTripCanNames.watchlist,
      createState: (entries) =>
          LiveTripCanState(entries: entries, retainActivityHistory: false),
      onConnected: (state) {
        _clearHistory();
        _seedVehicleSpeed(state);
      },
      observeSample: (state, reading, nowMillis) {
        state.observe(reading, nowMillis);
        _powerSeries.add(nowMillis, state.drivePowerKw);
        _currentSeries.add(nowMillis, state.packCurrentA);
      },
    );
    _start();
  }

  void _start() {
    unawaited(_live.start());
    _startVehicleSpeed();
    _clockTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      _expireVehicleSpeedIfNeeded();
      if (mounted) setState(() {});
    });
  }

  void _stop() {
    _clockTimer?.cancel();
    _clockTimer = null;
    _live.stop();
    final speedSubscription = _vehicleSpeedSubscription;
    _vehicleSpeedSubscription = null;
    unawaited(speedSubscription?.cancel());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _start();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clockTimer?.cancel();
    unawaited(_vehicleSpeedSubscription?.cancel());
    _live.dispose();
    super.dispose();
  }

  void _clearHistory() {
    _speedSeries.clear();
    _powerSeries.clear();
    _currentSeries.clear();
  }

  void _refresh() {
    HapticFeedback.selectionClick();
    _clearHistory();
    unawaited(_live.reconnect());
  }

  LiveTripCanState? get _can => _live.isAlive ? _live.state : null;

  Duration? get _sessionElapsed => _initialSessionElapsed == null
      ? null
      : _initialSessionElapsed + _sessionStopwatch.elapsed;

  double? get _vehicleSpeedKmh {
    final reading = _vehicleSpeedReading;
    if (reading == null ||
        !reading.isUsableAt(DateTime.now().millisecondsSinceEpoch)) {
      return null;
    }
    return reading.speedKmh;
  }

  void _startVehicleSpeed() {
    if (_vehicleSpeedSubscription != null) return;
    _vehicleSpeedError = null;
    _vehicleSpeedSubscription = _vehicleSpeedApi.stream().listen(
      _onVehicleSpeed,
      onError: (Object error, StackTrace stackTrace) {
        _vehicleSpeedError = error;
        if (mounted) setState(() {});
      },
    );
  }

  void _onVehicleSpeed(LiveVehicleSpeedReading reading) {
    _vehicleSpeedReading = reading;
    _vehicleSpeedError = null;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final speed = reading.isUsableAt(nowMs) ? reading.speedKmh : null;
    _vehicleSpeedWasUsable = speed != null;
    _speedSeries.add(reading.receivedAtUtcMillis, speed);
    _can?.observeVehicleSpeed(
      speedKmh: speed,
      nowMs: nowMs,
      motionTimestampNanos: reading.motionTimestampNanos,
    );
    if (mounted) setState(() {});
  }

  void _expireVehicleSpeedIfNeeded() {
    final reading = _vehicleSpeedReading;
    if (!_vehicleSpeedWasUsable || reading == null) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (reading.isUsableAt(nowMs)) return;
    _vehicleSpeedWasUsable = false;
    _can?.observeVehicleSpeed(
      speedKmh: null,
      nowMs: nowMs,
      motionTimestampNanos: reading.motionTimestampNanos,
    );
  }

  void _seedVehicleSpeed(LiveTripCanState state) {
    final reading = _vehicleSpeedReading;
    if (reading == null) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final speed = reading.isUsableAt(nowMs) ? reading.speedKmh : null;
    _vehicleSpeedWasUsable = speed != null;
    state.observeVehicleSpeed(
      speedKmh: speed,
      nowMs: nowMs,
      motionTimestampNanos: reading.motionTimestampNanos,
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final display = TripSessionDisplay.fromSession(widget.session, loc);
    final elapsed = _sessionElapsed;

    return Scaffold(
      backgroundColor: AutomotiveColors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ValueListenableBuilder<int>(
              valueListenable: _live.fastTick,
              builder: (context, _, _) => TripDetailHeader(
                display: display,
                title: loc.liveTripTitle,
                frameCount: _live.sampleCount,
                loading: _live.connecting,
                onRefresh: _refresh,
                chips: _headerChips(loc, display),
              ),
            ),
            ValueListenableBuilder<int>(
              valueListenable: _live.fastTick,
              builder: (context, _, _) => Column(children: _banners(loc)),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(AutomotiveSpacing.marginScreen),
                child: LayoutBuilder(
                  builder: (context, constraints) =>
                      constraints.maxWidth >= _wideBreakpoint
                      ? _wideBody(loc, elapsed)
                      : _narrowBody(loc, elapsed),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _headerChips(AppLocalizations loc, TripSessionDisplay display) {
    return [
      LivePulse(
        label: loc.liveTripStatusLive,
        active: _live.sampleCount > 0 && _live.isAlive,
      ),
      const SizedBox(width: AutomotiveSpacing.x1),
      TechnicalChip(label: loc.liveTripBus, value: _busLabel(loc)),
      const SizedBox(width: AutomotiveSpacing.x1),
      TechnicalChip(label: loc.detailStatus, value: display.status),
    ];
  }

  String _busLabel(AppLocalizations loc) {
    if (_live.connecting) return '...';
    if (_live.state == null) return 'OFF';
    if (!_live.isAlive) return loc.liveTripBadgeStale;
    return '${_live.hz ?? 60} Hz';
  }

  List<Widget> _banners(AppLocalizations loc) {
    if (_vehicleSpeedError != null) {
      return [
        LiveTripBanner(
          message: loc.liveTripVehicleSpeedUnavailable,
          color: AutomotiveColors.warning,
        ),
      ];
    }
    if (_live.error != null) {
      return [
        LiveTripBanner(
          message: _live.error.toString(),
          color: AutomotiveColors.error,
        ),
      ];
    }
    if (!_live.connecting && _live.state == null) {
      return [
        LiveTripBanner(
          message: loc.liveTripCanOffline,
          color: AutomotiveColors.warning,
        ),
      ];
    }
    if (!_live.isAlive && _live.state != null) {
      return [
        LiveTripBanner(
          message: loc.canLiveStale,
          color: AutomotiveColors.error,
        ),
      ];
    }
    return const <Widget>[];
  }

  Widget _wideBody(AppLocalizations loc, Duration? elapsed) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 400, child: _heroPanel(loc, elapsed)),
        const SizedBox(width: AutomotiveSpacing.gutter),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _liveChart(loc, _LiveChart.speed)),
              const SizedBox(height: AutomotiveSpacing.gutter),
              Expanded(child: _liveChart(loc, _LiveChart.power)),
              const SizedBox(height: AutomotiveSpacing.gutter),
              Expanded(child: _liveChart(loc, _LiveChart.current)),
            ],
          ),
        ),
        const SizedBox(width: AutomotiveSpacing.gutter),
        SizedBox(width: 330, child: _railPanel(loc)),
      ],
    );
  }

  Widget _narrowBody(AppLocalizations loc, Duration? elapsed) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _heroPanel(loc, elapsed),
        const SizedBox(height: AutomotiveSpacing.x2),
        _railPanel(loc, expand: false),
        const SizedBox(height: AutomotiveSpacing.x2),
        SizedBox(height: 240, child: _liveChart(loc, _LiveChart.speed)),
        const SizedBox(height: AutomotiveSpacing.x2),
        SizedBox(height: 240, child: _liveChart(loc, _LiveChart.power)),
        const SizedBox(height: AutomotiveSpacing.x2),
        SizedBox(height: 240, child: _liveChart(loc, _LiveChart.current)),
      ],
    );
  }

  Widget _heroPanel(AppLocalizations loc, Duration? elapsed) {
    return TechnicalPanel(
      child: ValueListenableBuilder<int>(
        valueListenable: _live.fastTick,
        builder: (context, _, _) {
          final can = _can;
          final speed = _vehicleSpeedKmh;
          final soc = can?.socPercent;
          final ecoSnapshot = can?.ecoCoach ?? const EcoCoachSnapshot.empty();
          final ecoTimestamp = Duration(
            milliseconds: DateTime.now().millisecondsSinceEpoch,
          );
          final ecoReasons = ecoSnapshot.reasonWindows
              .map(
                (window) => LiveEcoCoachReason(
                  window: window,
                  label: _ecoReason(loc, window.reason),
                ),
              )
              .toList(growable: false);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              LiveHeroReadout(
                key: const ValueKey('live_trip_duration'),
                label: loc.tripDetailDuration,
                value: formatDuration(elapsed),
                unit: '',
                fontSize: 40,
              ),
              const Divider(height: AutomotiveSpacing.x3),
              LiveHeroReadout(
                label: loc.liveTripSpeed,
                value: _fixed(speed, 0),
                unit: loc.unitKmh,
                fontSize: 64,
                badges: [
                  LiveSourceBadge(
                    label: loc.liveTripSourceVhal,
                    trust: LiveTrust.calibrated,
                    stale: _vehicleSpeedReading != null && speed == null,
                  ),
                ],
              ),
              const Divider(height: AutomotiveSpacing.x3),
              LiveSocEquation(
                key: const ValueKey('live_trip_soc_equation'),
                label: loc.liveTripSoc,
                startLabel: loc.liveTripSocStart,
                deltaLabel: loc.liveTripSocChange,
                currentLabel: loc.liveTripSocCurrent,
                startValue: _percent(widget.session.startSoc.displayValue),
                deltaValue: socDeltaLabel(
                  widget.session.startSoc.displayValue,
                  soc,
                ),
                currentValue: _percent(soc),
                badges: [
                  ?_canSourceBadge(
                    loc,
                    LiveTripCanNames.soc,
                    LiveTrust.calibrated,
                  ),
                ],
                deltaPositive:
                    widget.session.startSoc.displayValue == null || soc == null
                    ? null
                    : soc >= widget.session.startSoc.displayValue!,
              ),
              const Divider(height: AutomotiveSpacing.x3),
              LiveEcoCoachPanel(
                snapshot: ecoSnapshot,
                title: loc.liveTripEcoCoach,
                reasons: ecoReasons,
                timestamp: ecoTimestamp,
                observingLabel: loc.liveTripEcoObserving,
                accelerationLabel: loc.liveTripEcoAcceleration,
                jerkLabel: loc.liveTripEcoJerk,
                cyclesLabel: loc.liveTripEcoCycles,
                betaLabel: loc.liveTripEcoBeta,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _railPanel(AppLocalizations loc, {bool expand = true}) {
    final content = ValueListenableBuilder<int>(
      valueListenable: _live.fastTick,
      builder: (context, _, _) {
        final rows = _railRows(loc);
        return expand
            ? ListView(padding: EdgeInsets.zero, children: rows)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: rows,
              );
      },
    );
    return TechnicalPanel(
      padding: const EdgeInsets.symmetric(vertical: AutomotiveSpacing.x1_5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AutomotiveSpacing.x1_5,
            ),
            child: SectionHeader(
              icon: Icons.sensors,
              label: loc.liveTripSectionInstant,
            ),
          ),
          const SizedBox(height: AutomotiveSpacing.x1),
          if (expand) Expanded(child: content) else content,
        ],
      ),
    );
  }

  List<Widget> _railRows(AppLocalizations loc) {
    final can = _can;
    LiveSourceBadge? badge(String name, LiveTrust trust) =>
        _canSourceBadge(loc, name, trust);
    final pedalRaw = can?.pedalRaw;
    final brakePressed = can?.brakePressed;
    final packVolts = can?.packVoltage;
    final packCurrent = can?.packCurrentA;
    final currentMeasured = can?.packCurrent.isMeasured ?? false;
    final drivePower = can?.drivePowerKw;
    final roadIncline = can?.roadInclinePercent;
    return [
      LiveRailMetric(
        label: loc.liveTripDrivePower,
        value: drivePower == null
            ? '--'
            : '${drivePower.toStringAsFixed(1)} ${loc.chartPowerUnit}',
        badge: badge(LiveTripCanNames.drivePower, LiveTrust.calibrated),
      ),
      LiveRailMetric(
        label: loc.liveTripRoadIncline,
        value: roadIncline == null
            ? '--'
            : '${roadIncline.toStringAsFixed(1)} ${loc.unitPercent}',
        badge: badge(LiveTripCanNames.roadIncline, LiveTrust.calibrated),
      ),
      LiveRailMetric(
        label: loc.liveTripPedal,
        value: pedalRaw?.toString() ?? '--',
        badge: badge(LiveTripCanNames.pedal, LiveTrust.raw),
        barFraction: can?.pedalFraction,
        barColor: AutomotiveColors.secondary,
      ),
      LiveRailMetric(
        label: loc.liveTripBrake,
        value: brakePressed == null
            ? '--'
            : brakePressed
            ? loc.liveTripBrakeOn
            : loc.liveTripBrakeOff,
        badge: badge(LiveTripCanNames.brake, LiveTrust.calibrated),
        valueColor: brakePressed == true
            ? AutomotiveColors.critical
            : AutomotiveColors.onSurface,
      ),
      LiveRailMetric(
        label: loc.liveTripRegenTorque,
        value: can?.regenTorqueRaw?.toString() ?? '--',
        badge: badge(LiveTripCanNames.regenTorque, LiveTrust.raw),
      ),
      LiveRailMetric(
        label: loc.liveTripRegenLevel,
        value: can?.regenLevel?.toString() ?? '--',
        badge: badge(LiveTripCanNames.regenLevel, LiveTrust.raw),
      ),
      LiveRailMetric(
        label: loc.chartPackVoltage,
        value: packVolts == null
            ? '--'
            : '${packVolts.toStringAsFixed(1)} ${loc.chartVoltageUnit}',
        badge: badge(LiveTripCanNames.packVolts, LiveTrust.calibrated),
      ),
      LiveRailMetric(
        label: loc.chartPackCurrent,
        value: packCurrent == null
            ? '--'
            : '${packCurrent.toStringAsFixed(1)} ${loc.chartCurrentUnit}',
        badge: packCurrent == null
            ? badge(LiveTripCanNames.packCurrent, LiveTrust.raw)
            : currentMeasured
            ? badge(LiveTripCanNames.packCurrent, LiveTrust.calibrated)
            : LiveSourceBadge(
                label: loc.liveChargeBadgeEstimate,
                trust: LiveTrust.raw,
              ),
      ),
      LiveRailMetric(
        label: loc.liveTripCanSpeedRaw,
        value: can?.speedRaw?.toString() ?? '--',
        badge: badge(LiveTripCanNames.speed, LiveTrust.raw),
      ),
      LiveRailMetric(
        label: loc.liveTripAverageConsumption,
        value: can?.averageConsumptionRaw?.toString() ?? '--',
        badge: badge(LiveTripCanNames.averageConsumption, LiveTrust.raw),
      ),
      LiveRailMetric(
        label: loc.liveTripAverageConsumption1,
        value: can?.averageConsumption1Raw?.toString() ?? '--',
        badge: badge(LiveTripCanNames.averageConsumption1, LiveTrust.raw),
      ),
      LiveRailMetric(
        label: loc.liveTripTotalOdometerCandidate,
        value: can?.totalOdometerRaw?.toString() ?? '--',
        badge: badge(LiveTripCanNames.totalOdometer, LiveTrust.raw),
      ),
      LiveRailMetric(
        label: loc.liveTripPollAge,
        value: _live.pollAge == null
            ? '--'
            : '${_live.pollAge!.inMilliseconds} ms',
        badge: LiveSourceBadge(
          label: loc.liveTripBus,
          trust: _live.isAlive ? LiveTrust.calibrated : null,
          stale: !_live.isAlive,
        ),
      ),
    ];
  }

  String _ecoReason(AppLocalizations loc, EcoCoachReason? reason) =>
      switch (reason) {
        null || EcoCoachReason.observing => loc.liveTripEcoObserving,
        EcoCoachReason.stopped => loc.liveTripEcoReasonStopped,
        EcoCoachReason.efficientDemand => loc.liveTripEcoReasonEfficient,
        EcoCoachReason.highDemand => loc.liveTripEcoReasonDemand,
        EcoCoachReason.abruptAcceleration => loc.liveTripEcoReasonAcceleration,
        EcoCoachReason.abruptJerk => loc.liveTripEcoReasonJerk,
        EcoCoachReason.coasting => loc.liveTripEcoReasonCoasting,
        EcoCoachReason.regenerating => loc.liveTripEcoReasonRegen,
        EcoCoachReason.accelerateThenBrake => loc.liveTripEcoReasonCycle,
      };

  Widget _liveChart(AppLocalizations loc, _LiveChart kind) {
    return ValueListenableBuilder<int>(
      valueListenable: _live.chartTick,
      builder: (context, _, _) {
        final buffer = switch (kind) {
          _LiveChart.speed => _speedSeries,
          _LiveChart.power => _powerSeries,
          _LiveChart.current => _currentSeries,
        };
        final spots = buffer.spots();
        final trailing = Text(
          loc.liveRoadcastWindowSeconds(_historyWindow.inSeconds),
          style: AutomotiveTextStyles.unitLabel.copyWith(
            color: AutomotiveColors.onSurfaceVariant,
            fontSize: 11,
          ),
        );
        return switch (kind) {
          _LiveChart.speed => TraceChart(
            title: loc.tripChartSpeed,
            emptyMessage: loc.tripChartNotEnough,
            spots: spots,
            color: AutomotiveColors.tertiary,
            minY: 0,
            maxY: paddedMaxY(spots, 20, 220),
            minX: buffer.minX,
            maxX: buffer.maxX,
            leftReservedSize: 44,
            yLabelDecimals: 0,
            showXAxis: false,
            horizontalDivisions: 3,
            dense: true,
            trailing: trailing,
          ),
          _LiveChart.power => TraceChart(
            title: loc.liveTripChartPower,
            emptyMessage: loc.liveTripChartPowerNotEnough,
            spots: spots,
            color: AutomotiveColors.warning,
            minY: math.min(-1, paddedMinY(spots, -300, 300)),
            maxY: math.max(1, paddedMaxY(spots, 10, 300)),
            minX: buffer.minX,
            maxX: buffer.maxX,
            leftReservedSize: 46,
            yLabelDecimals: 0,
            showXAxis: false,
            horizontalDivisions: 3,
            showZeroLine: true,
            dense: true,
            trailing: trailing,
          ),
          _LiveChart.current => TraceChart(
            title: loc.chartPackCurrent,
            emptyMessage: loc.chartWaitingCurrent,
            spots: spots,
            color: AutomotiveColors.warning,
            minY: math.min(-1, paddedMinY(spots, -500, 500)),
            maxY: math.max(1, paddedMaxY(spots, 10, 500)),
            minX: buffer.minX,
            maxX: buffer.maxX,
            leftReservedSize: 46,
            yLabelDecimals: 0,
            showXAxis: false,
            horizontalDivisions: 3,
            showZeroLine: true,
            dense: true,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_can?.packCurrent.needsEstimateBadge ?? false) ...[
                  StatusBadge(
                    label: loc.liveChargeBadgeEstimate,
                    color: AutomotiveColors.outline,
                    fontSize: 9,
                  ),
                  const SizedBox(width: AutomotiveSpacing.x1),
                ],
                trailing,
              ],
            ),
          ),
        };
      },
    );
  }

  LiveSourceBadge? _canSourceBadge(
    AppLocalizations loc,
    String name,
    LiveTrust trust,
  ) {
    final canId = _live.frameIds[name];
    if (canId == null) return null;
    return LiveSourceBadge(
      label: loc.liveTripSourceCan(
        '0x${canId.toRadixString(16).toUpperCase()}',
      ),
      trust: trust,
    );
  }
}

enum _LiveChart { speed, power, current }

String _fixed(double? value, int decimals) =>
    value == null ? '--' : value.toStringAsFixed(decimals);

String _percent(double? value) =>
    value == null ? '--' : '${value.toStringAsFixed(1)}%';
