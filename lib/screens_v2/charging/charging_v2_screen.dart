import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/charge_climate_warning.dart';
import '../../core/range_estimate_controller.dart';
import '../../core/telemetry_api.dart';
import '../../core/telemetry_scope.dart';
import '../../core/vehicle_state_controller.dart';
import '../../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';
import '../charge_cost_editor.dart';
import 'charging_constants.dart';
import 'charging_energy_panel.dart';
import 'charging_format.dart';
import 'charging_limit_panel.dart';
import 'charging_session_panel.dart';

// TODO(v2-shell): Still on `ThreeColumnLayout`. `CarplayHomeV2Screen` is on
// `ExpandableCardStage`; this screen has no mock precedent validating a
// staged layout for it, so it was left as-is rather than inventing one.

/// The session the screen is showing, with the detail read for it.
///
/// One value rather than two fields, because the pair is only meaningful
/// together: a detail beside a session it does not describe is a wrong answer,
/// not an old one.
@immutable
class ChargeDetailPage {
  const ChargeDetailPage({required this.session, required this.detail});

  /// The car has recorded no charge session at all.
  static const empty = ChargeDetailPage(session: null, detail: null);

  final SessionRecord? session;
  final ChargeDetailReading? detail;
}

class ChargingV2Screen extends StatefulWidget {
  const ChargingV2Screen({
    required this.title,
    this.session,
    this.vehicleStateController,
    this.telemetryApi,
    this.rangeEstimateController,
    super.key,
  });

  final String title;
  final SessionRecord? session;

  final VehicleStateController? vehicleStateController;
  final TelemetryApi? telemetryApi;

  /// Injected range controller; tests pass one backed by a fake API so the
  /// platform channel is never touched. Defaults to the shared instance.
  final RangeEstimateController? rangeEstimateController;

  @override
  State<ChargingV2Screen> createState() => _ChargingV2ScreenState();
}

class _ChargingV2ScreenState extends State<ChargingV2Screen> {
  late final VehicleStateController _vehicleState =
      widget.vehicleStateController ?? VehicleStateController.instance;
  late final TelemetryApi _telemetryApi =
      widget.telemetryApi ?? TelemetryScope.of(context);
  late final RangeEstimateController _rangeEstimate =
      widget.rangeEstimateController ?? RangeEstimateController.instance;

  /// The session on screen and its detail, read as one question.
  ///
  /// They are one query because they are drawn as one thing: a graph built from
  /// a detail that answers for a different session than the header names is not
  /// a slower answer, it is a wrong one.
  ///
  /// The car says when a charge is written, closed, merged or priced, so a
  /// session that ends while this screen is open no longer waits for a tick.
  late final TelemetryQuery<ChargeDetailPage> _detail = TelemetryQuery(
    read: _readChargeDetail,
    interval: chargeDetailLiveInterval,
    debugLabel: 'ChargingV2Screen.detail',
    refreshOn: _telemetryApi.sessionChanges().where((change) => change.charges),
  );

  /// The open charge's climate minutes, for the climate-share warning.
  ///
  /// Memory only on the native side, so this costs no database work. It runs
  /// on the same tick as the detail and is stopped by the same rule: a charge
  /// that is not running cannot be spending anything on climate now.
  late final TelemetryQuery<LiveEnergyBucketsResult> _chargeClimate =
      TelemetryQuery(
        read: _telemetryApi.getLiveChargeEnergyBuckets,
        interval: chargeDetailLiveInterval,
        debugLabel: 'ChargingV2Screen.chargeClimate',
      );

  /// The last warning level, so the hysteresis in
  /// `readChargeClimateWarning` has something to hold against.
  ChargeClimateWarning _climateWarning = ChargeClimateWarning.none;

  /// The charge-cost defaults.
  late final TelemetryQuery<TelemetrySettingsResult> _settings = TelemetryQuery(
    read: _telemetryApi.getTelemetrySettings,
    interval: _slowRefreshInterval,
    debugLabel: 'ChargingV2Screen.settings',
  );

  /// How far the car has been going lately, reduced from the last week of
  /// drives. It is the same question the history list asks, with a date filter.
  late final TelemetryQuery<RecentTripEfficiency> _history = TelemetryQuery(
    read: _readRecentEfficiency,
    interval: _slowRefreshInterval,
    debugLabel: 'ChargingV2Screen.history',
  );

  Future<RecentTripEfficiency> _readRecentEfficiency() async {
    final since = DateTime.now().subtract(const Duration(days: 7));
    final page = await _telemetryApi.listSessions(
      filter: SessionFilter(
        kind: SessionKind.trip,
        fromUtcMillis: since.millisecondsSinceEpoch,
      ),
      page: const PageRequest(limit: 200),
    );
    return RecentTripEfficiency.fromSessions(page.sessions);
  }

  /// The session the current graph selection belongs to.
  String? _selectionSessionId;
  int? _graphSelection;
  bool _graphDismissed = false;
  bool _savingChargeCost = false;
  ChargePanelTab _chargePanelTab = ChargePanelTab.level;
  double _draftChargeTarget = 80.0;
  bool _draggingChargeTarget = false;
  ChargeControlState _chargeControlState = const ChargeControlState();
  StreamSubscription<int>? _chargeTargetSub;
  StreamSubscription<ChargeControlState>? _chargeControlSub;

  /// Cadence for the reads that do not follow the charge.
  static const _slowRefreshInterval = Duration(minutes: 5);

  @override
  void initState() {
    super.initState();
    _detail.addListener(_onDetailChanged);
    _vehicleState.addListener(_syncDetailPolling);
    _settings.addListener(_onSettingsChanged);
    _chargeTargetSub = _telemetryApi.chargeTargetSocChanges().listen((target) {
      if (mounted && !_draggingChargeTarget) {
        setState(() => _draftChargeTarget = target.toDouble());
      }
    });
    _chargeControlSub = _telemetryApi.chargeControlStateChanges().listen((
      state,
    ) {
      if (!mounted) return;
      final wasOk = _chargeControlState.lastCommandOk;
      setState(() => _chargeControlState = state);
      // A refused command used to be silent, and the screen kept the value the
      // user asked for. Say what the car said instead.
      if (wasOk && !state.lastCommandOk) {
        _showChargeControlFailure(state.lastError);
      }
    });
    _loadChargeControlState();
    _detail.start();
    _chargeClimate.start();
    _settings.start();
    _history.start();
  }

  void _showChargeControlFailure(String? reason) {
    final loc = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(reason ?? loc.v2ChargingCommandFailed)),
      );
  }

  Future<void> _loadChargeControlState() async {
    try {
      final state = await _telemetryApi.getChargeControlState();
      if (mounted) {
        setState(() => _chargeControlState = state);
      }
    } catch (_) {}
  }

  void _onSettingsChanged() {
    final settings = _settings.value;
    if (settings != null && !_draggingChargeTarget) {
      setState(() => _draftChargeTarget = settings.chargeTargetSoc.toDouble());
    }
  }

  void _commitTargetSoc(double val) {
    final percent = val.round().clamp(50, 100);
    setState(() => _draftChargeTarget = percent.toDouble());
    unawaited(_telemetryApi.setChargeTargetSoc(percent));
  }

  @override
  void didUpdateWidget(ChargingV2Screen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session?.id != widget.session?.id) {
      setState(() {
        _graphSelection = null;
        _graphDismissed = false;
      });
      unawaited(_detail.ask());
    }
  }

  @override
  void dispose() {
    _chargeTargetSub?.cancel();
    _chargeControlSub?.cancel();
    _settings.removeListener(_onSettingsChanged);
    _vehicleState.removeListener(_syncDetailPolling);
    _detail.removeListener(_onDetailChanged);
    _detail.dispose();
    _chargeClimate.dispose();
    _settings.dispose();
    _history.dispose();
    super.dispose();
  }

  /// The session shown, and the detail drawn beside it.
  Future<ChargeDetailPage> _readChargeDetail() async {
    final session =
        widget.session ??
        (await _telemetryApi.listSessions(
          filter: const SessionFilter(kind: SessionKind.charge),
          page: const PageRequest(limit: 1),
        )).sessions.firstOrNull;
    if (session == null) return ChargeDetailPage.empty;
    final stored = await _telemetryApi.getSession(session.id);
    final series = await _telemetryApi.getSeries(session.id);
    return ChargeDetailPage(
      session: stored?.session ?? session,
      detail: ChargeDetailReading(
        session: stored?.session ?? session,
        series: series,
        events: stored?.events ?? const [],
      ),
    );
  }

  void _onDetailChanged() {
    if (!mounted) return;
    final sessionId = _detail.value?.session?.id;
    if (sessionId != _selectionSessionId) {
      _selectionSessionId = sessionId;
      _graphSelection = null;
      _graphDismissed = false;
    }
    _syncDetailPolling();
  }

  void _syncDetailPolling() {
    final session = _detail.value?.session;
    final live =
        session != null &&
        chargeSessionIsActive(session) &&
        _vehicleState.isActivelyCharging;
    _detail.setPolling(live);
    _chargeClimate.setPolling(live);
    if (!live && _climateWarning.isWarning) {
      _climateWarning = ChargeClimateWarning.none;
    }
  }

  SessionRecord? get _selectedChargeSession => _detail.value?.session;

  ChargeDetailReading? get _chargeDetail => _detail.value?.detail;

  Future<void> _saveChargeCost(
    MoneyKeypadResult<ChargeCostField> result,
  ) async {
    final session = _selectedChargeSession;
    if (session == null || _savingChargeCost) return;
    setState(() => _savingChargeCost = true);
    final update = await writeChargeCost(
      api: _telemetryApi,
      session: session,
      result: result,
      fallbackCurrency: _settings.value?.chargeCostCurrency ?? 'BRL',
    );
    if (!mounted) return;
    setState(() => _savingChargeCost = false);
    if (update != null && update.ok) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.v2ChargeCostFailed),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return SizedBox.expand(
      child: AnimatedBuilder(
        animation: Listenable.merge([
          _vehicleState,
          _rangeEstimate,
          _detail,
          _chargeClimate,
          _settings,
          _history,
        ]),
        builder: (context, _) {
          final estimate = _rangeEstimate.estimate;
          final appRangeKm = estimate?.ownRangeKm;
          final appRangeCaption = _appRangeCaption(loc, estimate);
          final chargingPowerKw = _usableChargingPowerKw(
            _vehicleState.snapshot,
          );
          _climateWarning = readChargeClimateWarning(
            buckets: _chargeClimate.value?.buckets ?? const [],
            chargingPowerKw: chargingPowerKw,
            previous: _climateWarning,
          );
          final isExternalControl =
              _settings.value?.externalChargeControlEnabled ?? false;
          final currentSoc = _usableSoc(_vehicleState.snapshot);
          final target = _draftChargeTarget;
          final projectedRangeKm = _rangeEstimate.kilometersAt(target);
          return ThreeColumnLayout(
            leading: ChargingEnergyPanel(
              vehicleRangeKm: estimate?.carRangeKm,
              vehicleRangeAvailable: estimate?.carRangeAvailable ?? false,
              appRangeKm: appRangeKm,
              appRangeCaption: appRangeCaption,
              externalChargeControlEnabled: isExternalControl,
              chargeControlState: _chargeControlState,
              isActivelyCharging: _vehicleState.isActivelyCharging,
              // With the switch off the screen hands out no way to write to
              // the car at all. Hiding the controls is not enough: a callback
              // that still exists is a control that can still fire.
              onAmperageChanged: isExternalControl
                  ? (amps) => unawaited(_telemetryApi.setChargingAmperage(amps))
                  : null,
              onForceChargingChanged: isExternalControl
                  ? (force) => unawaited(_telemetryApi.setForceCharging(force))
                  : null,
              onStopCharging: isExternalControl
                  ? () => unawaited(_telemetryApi.stopCharging())
                  : null,
            ),
            primary: ChargingLimitPanel(
              externalChargeControlEnabled: isExternalControl,
              tab: _chargePanelTab,
              onTabSelected: (tab) => setState(() => _chargePanelTab = tab),
              target: target,
              onTargetChanged: isExternalControl
                  ? (val) => setState(() => _draftChargeTarget = val)
                  : null,
              onTargetDraggingChanged: isExternalControl
                  ? (dragging) {
                      setState(() => _draggingChargeTarget = dragging);
                      if (!dragging) {
                        _commitTargetSoc(_draftChargeTarget);
                      }
                    }
                  : null,
              onPresetSelected: isExternalControl
                  ? (preset) => _commitTargetSoc(preset.toDouble())
                  : null,
              currentSoc: currentSoc,
              isCharging: _vehicleState.isActivelyCharging,
              projectedRangeKm: projectedRangeKm,
              dragging: _draggingChargeTarget,
              climateWarning: _climateWarning,
              climateKw: readChargeClimateKw(
                _chargeClimate.value?.buckets ?? const [],
              ),
              chargingPowerKw: chargingPowerKw,
              session: _selectedChargeSession,
              detail: _chargeDetail,
              recentHistory: _history.value,
              defaultCostPerKwh: _settings.value?.defaultChargeCostPerKwh,
              chargeCostCurrency: _settings.value?.chargeCostCurrency ?? 'BRL',
              savingCost: _savingChargeCost,
              onCostChanged: _saveChargeCost,
              graphLoading: _detail.state.isFirstLoad,
              graphFailed: _detail.state.isEmptyFailure,
              graphSelection: _graphSelection,
              graphDismissed: _graphDismissed,
              onGraphSelected: (index) => setState(() {
                _graphSelection = index;
                _graphDismissed = index == null;
              }),
            ),
            trailing: ChargingSessionPanel(
              session: _selectedChargeSession,
              detail: _chargeDetail,
              loading: _detail.state.isFirstLoad,
              failed: _detail.state.isEmptyFailure,
            ),
          );
        },
      ),
    );
  }

  /// Caption for the app-range value in the energy panel.
  ///
  /// A degraded cached estimate must not carry the same caption as a fully
  /// current one: its copy states that the history update is delayed. A bridge
  /// read failure is reported too, so it is never mistaken for an empty car.
  String _appRangeCaption(AppLocalizations loc, RangeEstimate? estimate) {
    if (_rangeEstimate.hasFailed && estimate != null) {
      return loc.v2RangeEstimateReadDelayed;
    }
    if (estimate == null) {
      return _rangeEstimate.hasFailed
          ? loc.v2RangeEstimateReadFailed
          : loc.v2RangeEstimateUnavailable;
    }
    if (estimate.ownRangeAvailable) return loc.v2RangeEstimateCaption;
    if (estimate.ownRangeDegraded) return loc.v2RangeEstimateDelayed;
    return loc.v2RangeEstimateUnavailable;
  }

  double? _usableSoc(TelemetrySnapshot? snapshot) {
    final reading = snapshot?.batteryPercent;
    final value = reading?.value;
    if (reading == null || !reading.ok || value == null) return null;
    if (value < 0 || value > 100) return null;
    return value;
  }

  double? _usableChargingPowerKw(TelemetrySnapshot? snapshot) {
    final charging = snapshot?.charging;
    if (charging == null || !charging.ok || charging.isCharging != true) {
      return null;
    }
    for (final value in [charging.dcPowerKw, charging.acPowerKw]) {
      if (value != null && value.isFinite && value >= 0) return value;
    }
    return null;
  }
}
