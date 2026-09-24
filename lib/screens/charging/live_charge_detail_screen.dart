import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/live_charge_can.dart';
import '../../core/live_roadcast_runtime.dart';
import '../../core/telemetry_api.dart';
import '../../core/telemetry_format.dart';
import '../../design_system/design_system.dart';
import '../../l10n/app_localizations.dart';
import '../trips/live_trip_panels.dart';
import 'charge_detail_header.dart';
import 'charging_session_display.dart';

/// Live charging surface backed exclusively by Roadcast through Dart FFI.
///
/// Session metadata is immutable navigation context. All changing measurements
/// come from the native Roadcast RAM cache at 60 Hz and the three traces stay in
/// fixed-size Dart RAM buffers for at most 30 seconds. This screen performs no
/// EventChannel subscription, MethodChannel snapshot or Room query.
class LiveChargeDetailScreen extends StatefulWidget {
  const LiveChargeDetailScreen({required this.session, super.key});

  final SessionRecord session;

  @override
  State<LiveChargeDetailScreen> createState() => _LiveChargeDetailScreenState();
}

class _LiveChargeDetailScreenState extends State<LiveChargeDetailScreen>
    with WidgetsBindingObserver {
  static const Duration _historyWindow = Duration(seconds: 30);
  static const double _wideBreakpoint = 1180;

  final RollingSignalBuffer _powerSeries = RollingSignalBuffer(
    window: _historyWindow,
  );
  final RollingSignalBuffer _currentSeries = RollingSignalBuffer(
    window: _historyWindow,
  );
  final RollingSignalBuffer _socSeries = RollingSignalBuffer(
    window: _historyWindow,
  );

  late final LiveRoadcastRuntime<LiveChargeCanState> _live;
  late final Duration? _initialSessionElapsed;
  late final Stopwatch _sessionStopwatch;
  Timer? _clockTimer;

  bool get _isCharging => widget.session.status.toUpperCase() == 'CHARGING';
  bool get _isDc => isDcChargePlugType(widget.session.plugType);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialSessionElapsed =
        durationFromMillis(sessionReadingDurationMillis(widget.session)) ??
        boundedDurationBetween(
          dateTimeFromMillis(
            widget.session.chargeStartedAtUtcMillis ??
                widget.session.startedAtUtcMillis,
          ),
          null,
          maximum: const Duration(days: 31),
        );
    _sessionStopwatch = Stopwatch()..start();
    _live = LiveRoadcastRuntime<LiveChargeCanState>(
      watchlist: LiveChargeCanNames.watchlist,
      createState: (entries) =>
          LiveChargeCanState(entries: entries, retainActivityHistory: false),
      onConnected: (_) => _clearHistory(),
      observeSample: (state, reading, nowMillis) {
        state.observe(reading, nowMillis);
        state.observeCurrentZero(charging: _isCharging);
        final input = state.inputReadings(isDc: _isDc);
        _powerSeries.add(nowMillis, input.powerKw);
        _currentSeries.add(nowMillis, input.currentA);
        _socSeries.add(nowMillis, state.socPercent);
      },
    );
    _start();
  }

  void _start() {
    unawaited(_live.start());
    _clockTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _stop() {
    _clockTimer?.cancel();
    _clockTimer = null;
    _live.stop();
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
    _live.dispose();
    super.dispose();
  }

  void _clearHistory() {
    _powerSeries.clear();
    _currentSeries.clear();
    _socSeries.clear();
  }

  void _refresh() {
    HapticFeedback.selectionClick();
    _clearHistory();
    unawaited(_live.reconnect());
  }

  LiveChargeCanState? get _can => _live.isAlive ? _live.state : null;

  Duration? get _sessionElapsed => _initialSessionElapsed == null
      ? null
      : _initialSessionElapsed + _sessionStopwatch.elapsed;

  LiveChargeInputReadings? get _inputReadings {
    final can = _can;
    return can?.inputReadings(isDc: _isDc);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final display = ChargingSessionDisplay.fromSession(widget.session, loc);
    final elapsed = _sessionElapsed;

    return Scaffold(
      backgroundColor: AutomotiveColors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ValueListenableBuilder<int>(
              valueListenable: _live.fastTick,
              builder: (context, _, _) => ChargeDetailHeader(
                title: loc.liveChargeTitle,
                shortId: display.shortId,
                loading: _live.connecting,
                onRefresh: _refresh,
                chips: _headerChips(loc, display, elapsed),
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

  List<Widget> _headerChips(
    AppLocalizations loc,
    ChargingSessionDisplay display,
    Duration? elapsed,
  ) {
    return [
      LivePulse(
        label: loc.liveTripStatusLive,
        active: _live.sampleCount > 0 && _live.isAlive,
      ),
      const SizedBox(width: AutomotiveSpacing.x1),
      TechnicalChip(label: loc.detailDuration, value: formatDuration(elapsed)),
      const SizedBox(width: AutomotiveSpacing.x1),
      TechnicalChip(label: loc.liveTripBus, value: _busLabel(loc)),
      const SizedBox(width: AutomotiveSpacing.x1),
      TechnicalChip(label: loc.detailPlug, value: display.plugLabel),
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
          message: loc.liveChargeCanOffline,
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
        SizedBox(width: 400, child: _heroPanel(loc)),
        const SizedBox(width: AutomotiveSpacing.gutter),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sessionContextPanel(loc, elapsed),
              const SizedBox(height: AutomotiveSpacing.gutter),
              Expanded(child: _liveChart(loc, _LiveChargeChart.power)),
              const SizedBox(height: AutomotiveSpacing.gutter),
              Expanded(child: _liveChart(loc, _LiveChargeChart.current)),
              const SizedBox(height: AutomotiveSpacing.gutter),
              Expanded(child: _liveChart(loc, _LiveChargeChart.soc)),
            ],
          ),
        ),
        const SizedBox(width: AutomotiveSpacing.gutter),
        SizedBox(width: 360, child: _railPanel(loc)),
      ],
    );
  }

  Widget _narrowBody(AppLocalizations loc, Duration? elapsed) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _heroPanel(loc),
        const SizedBox(height: AutomotiveSpacing.x2),
        _sessionContextPanel(loc, elapsed),
        const SizedBox(height: AutomotiveSpacing.x2),
        _railPanel(loc, expand: false),
        const SizedBox(height: AutomotiveSpacing.x2),
        SizedBox(height: 240, child: _liveChart(loc, _LiveChargeChart.power)),
        const SizedBox(height: AutomotiveSpacing.x2),
        SizedBox(height: 240, child: _liveChart(loc, _LiveChargeChart.current)),
        const SizedBox(height: AutomotiveSpacing.x2),
        SizedBox(height: 240, child: _liveChart(loc, _LiveChargeChart.soc)),
      ],
    );
  }

  Widget _heroPanel(AppLocalizations loc) {
    return TechnicalPanel(
      child: ValueListenableBuilder<int>(
        valueListenable: _live.fastTick,
        builder: (context, _, _) {
          final can = _can;
          final inputPower = _inputReadings?.powerKw;
          final soc = can?.socPercent;
          final current = can?.packCurrentA;
          final currentMeasured = can?.packCurrent.isMeasured ?? false;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              LiveHeroReadout(
                label: loc.liveChargeInputPower,
                value: _fixed(inputPower, 2),
                unit: loc.chartPowerUnit,
                fontSize: 60,
                valueColor: AutomotiveColors.secondary,
                badges: [
                  if (_isDc)
                    LiveSourceBadge(
                      label: loc.liveTripBadgeDerived,
                      trust: currentMeasured
                          ? LiveTrust.derived
                          : LiveTrust.raw,
                    )
                  else
                    ?_canSourceBadge(
                      loc,
                      LiveChargeCanNames.obcInputVolts,
                      LiveTrust.derived,
                    ),
                ],
              ),
              const Divider(height: AutomotiveSpacing.x3),
              LiveHeroReadout(
                label: loc.liveTripSoc,
                value: _fixed(soc, 1),
                unit: '%',
                fontSize: 48,
                valueColor: AutomotiveColors.batteryPositive,
                badges: [
                  ?_canSourceBadge(
                    loc,
                    LiveChargeCanNames.soc,
                    LiveTrust.calibrated,
                  ),
                ],
                barFraction: soc == null ? null : soc / 100,
                barColor: AutomotiveColors.batteryPositive,
              ),
              const Divider(height: AutomotiveSpacing.x3),
              LiveHeroReadout(
                label: loc.liveChargePackCurrent,
                value: _fixed(current, 1),
                unit: loc.chartCurrentUnit,
                fontSize: 48,
                valueColor: AutomotiveColors.warning,
                badges: [
                  if (!currentMeasured)
                    LiveSourceBadge(
                      label: loc.liveChargeBadgeEstimate,
                      trust: LiveTrust.raw,
                    ),
                  ?_canSourceBadge(
                    loc,
                    LiveChargeCanNames.packCurrent,
                    currentMeasured ? LiveTrust.calibrated : LiveTrust.raw,
                  ),
                ],
              ),
              const Divider(height: AutomotiveSpacing.x3),
              LiveHeroReadout(
                label: loc.liveChargeObcEfficiency,
                value: _isDc || can?.obcEfficiency == null
                    ? '--'
                    : (can!.obcEfficiency! * 100).toStringAsFixed(1),
                unit: '%',
                fontSize: 48,
                valueColor: _efficiencyColor(_isDc ? null : can?.obcEfficiency),
                badges: [
                  if (!_isDc)
                    LiveSourceBadge(
                      label: loc.liveTripBadgeDerived,
                      trust: currentMeasured
                          ? LiveTrust.derived
                          : LiveTrust.raw,
                    ),
                ],
                barFraction: _isDc ? null : can?.obcEfficiency?.clamp(0.0, 1.0),
                barColor: _efficiencyColor(_isDc ? null : can?.obcEfficiency),
                note: _isDc || can?.obcLossKw == null
                    ? null
                    : loc.liveChargeLoss(can!.obcLossKw!.toStringAsFixed(2)),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _sessionContextPanel(AppLocalizations loc, Duration? elapsed) {
    return ValueListenableBuilder<int>(
      valueListenable: _live.fastTick,
      builder: (context, _, _) => TechnicalPanel(
        padding: const EdgeInsets.symmetric(
          horizontal: AutomotiveSpacing.x3,
          vertical: AutomotiveSpacing.x2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            SectionHeader(icon: Icons.bolt, label: loc.liveChargeSectionTotals),
            const SizedBox(height: AutomotiveSpacing.x1_5),
            Wrap(
              spacing: AutomotiveSpacing.x4,
              runSpacing: AutomotiveSpacing.x2,
              children: [
                SizedBox(
                  width: 150,
                  child: MetricReadout(
                    label: loc.detailDuration,
                    value: formatDuration(elapsed),
                  ),
                ),
                SizedBox(
                  width: 190,
                  child: MetricReadout(
                    label: loc.detailSocRange,
                    value: socRangeLabel(
                      widget.session.startSoc.displayValue,
                      _can?.socPercent,
                    ),
                  ),
                ),
                SizedBox(
                  width: 140,
                  child: MetricReadout(
                    label: loc.detailSocDelta,
                    value: socDeltaLabel(
                      widget.session.startSoc.displayValue,
                      _can?.socPercent,
                    ),
                    accent: true,
                  ),
                ),
              ],
            ),
          ],
        ),
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
    final input = _inputReadings;
    final currentMeasured = can?.packCurrent.isMeasured ?? false;
    final packTrust = currentMeasured ? LiveTrust.derived : LiveTrust.raw;
    final observedZero = can?.currentZero.zero;
    final offsetError = can?.currentZero.offsetErrorA;
    return [
      LiveRailMetric(
        label: loc.liveChargeCurrentRaw,
        value: can?.packCurrentRaw?.toString() ?? '--',
        badge: _canSourceBadge(
          loc,
          LiveChargeCanNames.packCurrent,
          LiveTrust.raw,
        ),
      ),
      if (!currentMeasured) ...[
        LiveRailMetric(
          label: loc.liveChargeCurrentScale,
          value: loc.liveChargeCurrentScaleValue,
        ),
        LiveRailMetric(
          label: loc.liveChargeZeroAssumed,
          value: kBattCurrentAssumedZero.toString(),
          badge: LiveSourceBadge(
            label: loc.liveChargeBadgeEstimate,
            trust: LiveTrust.raw,
          ),
        ),
        LiveRailMetric(
          label: loc.liveChargeZeroObserved,
          value: observedZero == null
              ? loc.liveChargeZeroWaiting
              : '${observedZero.toStringAsFixed(1)} '
                    '(${loc.liveChargeZeroSamples(can!.currentZero.sampleCount)})',
        ),
        LiveRailMetric(
          label: loc.liveChargeZeroOffset,
          value: offsetError == null
              ? '--'
              : '${offsetError >= 0 ? '+' : ''}'
                    '${offsetError.toStringAsFixed(2)} ${loc.chartCurrentUnit}',
          valueColor: offsetError != null && offsetError.abs() > 0.5
              ? AutomotiveColors.warning
              : null,
        ),
      ],
      LiveRailMetric(
        label: loc.liveChargeObcInputVolts,
        value: input?.voltageV == null
            ? '--'
            : '${input!.voltageV!.toStringAsFixed(1)} '
                  '${loc.chartVoltageUnit}',
        badge: _canSourceBadge(
          loc,
          _isDc
              ? LiveChargeCanNames.packVolts
              : LiveChargeCanNames.obcInputVolts,
          LiveTrust.calibrated,
        ),
      ),
      LiveRailMetric(
        label: loc.liveChargeObcInputCurrent,
        value: input?.currentA == null
            ? '--'
            : '${input!.currentA!.toStringAsFixed(1)} '
                  '${loc.chartCurrentUnit}',
        badge: _canSourceBadge(
          loc,
          _isDc
              ? LiveChargeCanNames.packCurrent
              : LiveChargeCanNames.obcInputCurrent,
          _isDc && !currentMeasured ? LiveTrust.raw : LiveTrust.calibrated,
        ),
      ),
      LiveRailMetric(
        label: _isDc ? loc.liveChargeInputPower : loc.liveChargeWallPower,
        value: input?.powerKw == null
            ? '--'
            : '${input!.powerKw!.toStringAsFixed(2)} '
                  '${loc.chartPowerUnit}',
        badge: LiveSourceBadge(
          label: loc.liveTripBadgeDerived,
          trust: _isDc ? packTrust : LiveTrust.derived,
        ),
      ),
      if (!_isDc) ...[
        LiveRailMetric(
          label: loc.chartPackVoltage,
          value: can?.packVoltageV == null
              ? '--'
              : '${can!.packVoltageV!.toStringAsFixed(1)} '
                    '${loc.chartVoltageUnit}',
          badge: _canSourceBadge(
            loc,
            LiveChargeCanNames.packVolts,
            LiveTrust.calibrated,
          ),
        ),
        LiveRailMetric(
          label: loc.liveChargePackPower,
          value: can?.packPowerKw == null
              ? '--'
              : '${can!.packPowerKw!.abs().toStringAsFixed(2)} '
                    '${loc.chartPowerUnit}',
          badge: LiveSourceBadge(
            label: loc.liveTripBadgeDerived,
            trust: packTrust,
          ),
        ),
        LiveRailMetric(
          label: loc.liveChargeObcState,
          value: can?.obcStateRaw?.toString() ?? '--',
          badge: _canSourceBadge(
            loc,
            LiveChargeCanNames.obcState,
            LiveTrust.raw,
          ),
        ),
      ],
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
      if (!currentMeasured)
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AutomotiveSpacing.x1_5,
            AutomotiveSpacing.x2,
            AutomotiveSpacing.x1_5,
            AutomotiveSpacing.x1,
          ),
          child: Text(
            loc.liveChargeZeroNote,
            style: AutomotiveTextStyles.bodyMd.copyWith(
              color: AutomotiveColors.onSurfaceVariant,
              fontSize: 11,
            ),
          ),
        ),
    ];
  }

  Widget _liveChart(AppLocalizations loc, _LiveChargeChart kind) {
    return ValueListenableBuilder<int>(
      valueListenable: _live.chartTick,
      builder: (context, _, _) {
        final buffer = switch (kind) {
          _LiveChargeChart.power => _powerSeries,
          _LiveChargeChart.current => _currentSeries,
          _LiveChargeChart.soc => _socSeries,
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
          _LiveChargeChart.power => TraceChart(
            title: loc.liveChargeChartPower,
            emptyMessage: loc.liveChargeChartNotEnough,
            spots: spots,
            color: AutomotiveColors.secondary,
            minY: 0,
            maxY: paddedMaxY(spots, 2, 400),
            minX: buffer.minX,
            maxX: buffer.maxX,
            leftReservedSize: 48,
            yLabelDecimals: 1,
            showXAxis: false,
            horizontalDivisions: 3,
            dense: true,
            trailing: trailing,
          ),
          _LiveChargeChart.current => TraceChart(
            title: loc.liveChargeChartCurrent,
            emptyMessage: loc.liveChargeChartNotEnough,
            spots: spots,
            color: AutomotiveColors.warning,
            minY: paddedMinY(spots, -600, 600),
            maxY: paddedMaxY(spots, 5, 600),
            minX: buffer.minX,
            maxX: buffer.maxX,
            leftReservedSize: 48,
            yLabelDecimals: 0,
            showXAxis: false,
            horizontalDivisions: 3,
            dense: true,
            trailing: trailing,
          ),
          _LiveChargeChart.soc => TraceChart(
            title: loc.liveChargeChartSoc,
            emptyMessage: loc.liveChargeChartNotEnough,
            spots: spots,
            color: AutomotiveColors.batteryPositive,
            minY: paddedMinY(spots, 0, 100),
            maxY: paddedMaxY(spots, 5, 100),
            minX: buffer.minX,
            maxX: buffer.maxX,
            leftReservedSize: 48,
            yLabelDecimals: 1,
            showXAxis: false,
            horizontalDivisions: 3,
            dense: true,
            trailing: trailing,
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

enum _LiveChargeChart { power, current, soc }

String _fixed(double? value, int decimals) =>
    value == null ? '--' : value.toStringAsFixed(decimals);

Color _efficiencyColor(double? efficiency) {
  if (efficiency == null) return AutomotiveColors.onSurface;
  if (efficiency > 1.0) return AutomotiveColors.error;
  if (efficiency < 0.7) return AutomotiveColors.warning;
  return AutomotiveColors.secondary;
}
