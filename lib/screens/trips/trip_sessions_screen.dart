import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/can_bridge_api.dart';
import '../../core/can_bridge_models.dart';
import '../../core/live_trip_can.dart';
import '../../core/live_vehicle_speed.dart';
import '../../core/telemetry_api.dart';
import '../../core/telemetry_scope.dart';
import '../../core/telemetry_format.dart';
import '../../design_system/design_system.dart';
import '../../l10n/app_localizations.dart';
import 'live_trip_detail_screen.dart';
import 'live_trip_panels.dart';
import 'trip_event_card.dart';
import 'trip_session_detail_screen.dart';
import 'trip_session_display.dart';

class TripSessionsScreen extends StatefulWidget {
  const TripSessionsScreen({super.key});

  @override
  State<TripSessionsScreen> createState() => _TripSessionsScreenState();
}

class _TripSessionsScreenState extends State<TripSessionsScreen> {
  static const Duration _liveSampleInterval = Duration(seconds: 1);
  static const Duration _canRetryInterval = Duration(seconds: 15);
  static final List<String> _listCanSignals = LiveTripCanNames.watchlist
      .where(
        (name) =>
            name != LiveTripCanNames.speed &&
            name != LiveTripCanNames.speedInvalid,
      )
      .toList(growable: false);

  late final TelemetryApi _api = TelemetryScope.of(context);
  final LiveVehicleSpeedApi _vehicleSpeedApi = const LiveVehicleSpeedApi();
  late final TelemetryQuery<SessionListPage> _trips = TelemetryQuery(
    read: () => _api.listSessions(
      filter: const SessionFilter(kind: SessionKind.trip),
      page: const PageRequest(limit: 50),
    ),
    interval: const Duration(seconds: 5),
    debugLabel: 'TripSessionsScreen',
    // The car says when a trip is written or closed, so a parked car costs no
    // reads at all. The 5s tick runs only while a trip is open, because that
    // row's SOC and odometer come from frames rather than from a session write.
    refreshOn: _api.sessionChanges().where((change) => change.trips),
  );
  Timer? _clockTimer;
  Timer? _liveTimer;
  final ValueNotifier<int> _liveTick = ValueNotifier<int>(0);
  CanBridge? _bridge;
  LiveTripCanState? _can;
  StreamSubscription<LiveVehicleSpeedReading>? _vehicleSpeedSubscription;
  LiveVehicleSpeedReading? _vehicleSpeedReading;
  bool _canConnecting = false;
  DateTime? _canAttemptAt;

  @override
  void initState() {
    super.initState();
    _trips.addListener(_onTripsChanged);
    _trips.start();
    // Live durations are recomputed against DateTime.now() on build; this
    // UI-only tick keeps the clock counting between the 5s data refreshes.
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_hasLiveSession) setState(() {});
    });
  }

  @override
  void dispose() {
    _trips.removeListener(_onTripsChanged);
    _trips.dispose();
    _clockTimer?.cancel();
    _liveTimer?.cancel();
    unawaited(_vehicleSpeedSubscription?.cancel());
    _bridge?.dispose();
    _liveTick.dispose();
    super.dispose();
  }

  /// The rows behind the screen, or none while the first read is out. A failed
  /// read keeps the previous rows: an unreachable bridge is not an empty car.
  List<SessionRecord> get _sessions =>
      _trips.value?.sessions ?? const <SessionRecord>[];

  void _onTripsChanged() {
    if (!mounted) return;
    setState(() {});
    // Whether the bus is sampled follows from the rows, so it is re-decided on
    // every answer rather than only where a read happens to be written. The
    // tick follows the same fact: nothing open, nothing to poll for.
    _syncLiveSampling();
    _trips.setPolling(_liveSession != null);
  }

  SessionRecord? get _liveSession {
    for (final session in _sessions) {
      if (isLiveTripStatus(session.status)) return session;
    }
    return null;
  }

  bool get _hasLiveSession => _liveSession != null;

  void _syncLiveSampling() {
    final wanted = _liveSession != null;
    if (wanted && _liveTimer == null) {
      _connectCan();
      _startVehicleSpeed();
      _liveTimer = Timer.periodic(_liveSampleInterval, (_) => _sampleCan());
    } else if (!wanted && _liveTimer != null) {
      _liveTimer?.cancel();
      _liveTimer = null;
      _bridge?.dispose();
      _bridge = null;
      _can = null;
      final speedSubscription = _vehicleSpeedSubscription;
      _vehicleSpeedSubscription = null;
      _vehicleSpeedReading = null;
      unawaited(speedSubscription?.cancel());
    }
  }

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
    _vehicleSpeedSubscription = _vehicleSpeedApi.stream().listen(
      (reading) {
        _vehicleSpeedReading = reading;
        _liveTick.value++;
      },
      onError: (Object _, StackTrace _) {
        _vehicleSpeedReading = null;
        _liveTick.value++;
      },
    );
  }

  Future<void> _connectCan() async {
    if (_canConnecting) return;
    final last = _canAttemptAt;
    if (last != null && DateTime.now().difference(last) < _canRetryInterval) {
      return;
    }
    _canConnecting = true;
    _canAttemptAt = DateTime.now();
    try {
      final bridge = await CanBridge.connect(signals: _listCanSignals);
      final entries = bridge?.entries ?? const <RoadcastSchemaEntry>[];
      if (!mounted) {
        bridge?.dispose();
        return;
      }
      _bridge?.dispose();
      _bridge = bridge;
      _can = bridge == null ? null : LiveTripCanState(entries: entries);
      _canConnecting = false;
      _liveTick.value++;
    } on Object {
      _canConnecting = false;
    }
  }

  void _sampleCan() {
    final bridge = _bridge;
    final can = _can;
    if (bridge == null || can == null) {
      _connectCan();
      return;
    }
    if (!bridge.isAlive) {
      bridge.dispose();
      _bridge = null;
      _can = null;
      _liveTick.value++;
      _connectCan();
      return;
    }
    can.observe(bridge.sample(), DateTime.now().millisecondsSinceEpoch);
    _liveTick.value++;
  }

  /// Formatted rows keyed by session id. A session's labels only change when
  /// the row itself changes, so [SessionRecord.updatedAtUtcMillis] acts as
  /// the cache stamp: the 5s refresh and the 1s live clock tick reuse the
  /// strings instead of reformatting every visible and off-screen row.
  final Map<String, TripSessionDisplay> _displayCache = {};
  AppLocalizations? _displayCacheLoc;

  List<TripSessionDisplay> _displayRows(
    Iterable<SessionRecord> sessions,
    AppLocalizations loc,
  ) {
    if (!identical(loc, _displayCacheLoc)) {
      _displayCache.clear();
      _displayCacheLoc = loc;
    }
    final rows = <TripSessionDisplay>[];
    for (final session in sessions) {
      final cached = _displayCache[session.id];
      rows.add(
        cached != null &&
                cached.session.updatedAtUtcMillis == session.updatedAtUtcMillis
            ? cached
            : _displayCache[session.id] = TripSessionDisplay.fromSession(
                session,
                loc,
              ),
      );
    }
    if (_displayCache.length > rows.length) {
      final live = {for (final row in rows) row.id};
      _displayCache.removeWhere((id, _) => !live.contains(id));
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final trips = _trips.state;
    final result = trips.value;
    final totalCount = result?.totalCount ?? 0;
    final error = trips.errorMessage;
    final live = _liveSession;
    final historySessions = live == null
        ? _sessions
        : _sessions.where((session) => session.id != live.id);
    final rows = _displayRows(historySessions, loc);

    return ColoredBox(
      color: AutomotiveColors.background,
      child: Column(
        children: [
          ScreenHeaderBar(
            title: loc.appBarTitle,
            subtitle: loc.tripHeaderSubtitle,
            trailing: [
              TechnicalChip(
                label: loc.tripDbRows,
                value: totalCount.toString(),
              ),
              const SizedBox(width: AutomotiveSpacing.x2),
              RefreshIconButton(
                tooltip: loc.tripRefreshTooltip,
                loading: trips.isLoading,
                onPressed: () {
                  HapticFeedback.selectionClick();
                  unawaited(_trips.refresh(showLoading: true));
                },
              ),
            ],
          ),
          Expanded(
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    AutomotiveSpacing.marginScreen,
                    AutomotiveSpacing.marginScreen,
                    AutomotiveSpacing.marginScreen,
                    0,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      children: [
                        if (live != null) ...[
                          _LiveTripRow(
                            session: live,
                            can: _can,
                            speedKmh: () => _vehicleSpeedKmh,
                            tick: _liveTick,
                            onOpen: () => _openLiveSession(live),
                          ),
                          const SizedBox(height: AutomotiveSpacing.x4),
                        ],
                        _PageIntro(
                          error: error,
                          hasRows: rows.isNotEmpty || live != null,
                          totalCount: totalCount,
                        ),
                        const SizedBox(height: AutomotiveSpacing.x3),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AutomotiveSpacing.marginScreen,
                  ),
                  sliver: trips.isLoading
                      ? const SliverToBoxAdapter(child: LoadingPanel())
                      : error != null
                      ? SliverToBoxAdapter(child: ErrorPanel(message: error))
                      : rows.isEmpty
                      ? SliverToBoxAdapter(
                          child: EmptyStatePanel(
                            message: live != null
                                ? loc.tripNoCompletedSessions
                                : totalCount > 0
                                ? loc.tripEmptyLatest
                                : loc.tripEmptyNone,
                          ),
                        )
                      : SliverList.separated(
                          itemCount: rows.length,
                          itemBuilder: (context, index) {
                            final row = rows[index];
                            return TripEventCard(
                              key: ValueKey<String>(row.id),
                              row: row,
                              onTap: () {
                                HapticFeedback.selectionClick();
                                Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => row.isActive
                                        ? LiveTripDetailScreen(
                                            session: row.session,
                                          )
                                        : TripSessionDetailScreen(
                                            session: row.session,
                                          ),
                                  ),
                                );
                              },
                            );
                          },
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: AutomotiveSpacing.x2),
                        ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    AutomotiveSpacing.marginScreen,
                    AutomotiveSpacing.x4,
                    AutomotiveSpacing.marginScreen,
                    AutomotiveSpacing.marginScreen,
                  ),
                  sliver: const SliverToBoxAdapter(child: _DetailHint()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _openLiveSession(SessionRecord session) {
    HapticFeedback.selectionClick();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LiveTripDetailScreen(session: session),
      ),
    );
  }
}

class _LiveTripRow extends StatelessWidget {
  const _LiveTripRow({
    required this.session,
    required this.can,
    required this.speedKmh,
    required this.tick,
    required this.onOpen,
  });

  final SessionRecord session;
  final LiveTripCanState? can;
  final double? Function() speedKmh;
  final ValueNotifier<int> tick;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final startedAt = dateTimeFromMillis(session.startedAtUtcMillis);
    final elapsed =
        durationFromMillis(session.durationMillis) ??
        boundedDurationBetween(
          startedAt,
          null,
          maximum: const Duration(hours: 48),
        );

    return TechnicalPanel(
      borderColor: AutomotiveColors.secondary.withValues(alpha: 0.65),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onOpen,
          borderRadius: AutomotiveRadii.mdRadius,
          child: Padding(
            padding: const EdgeInsets.all(AutomotiveSpacing.x1),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    LivePulse(
                      label: loc.liveTripRowTitle,
                      active: isLiveTripStatus(session.status),
                    ),
                    const SizedBox(width: AutomotiveSpacing.x2),
                    Expanded(
                      child: Text(
                        '${statusLabel(session.status, loc)} · '
                        '${formatDuration(elapsed)}',
                        overflow: TextOverflow.ellipsis,
                        style: AutomotiveTextStyles.unitLabel.copyWith(
                          color: AutomotiveColors.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    TechnicalButton(
                      icon: Icons.open_in_full,
                      label: loc.liveTripOpen,
                      onPressed: onOpen,
                      accentIcon: true,
                    ),
                  ],
                ),
                const SizedBox(height: AutomotiveSpacing.x2),
                ValueListenableBuilder<int>(
                  valueListenable: tick,
                  builder: (context, _, _) {
                    final liveSpeedKmh = speedKmh();
                    return Wrap(
                      spacing: AutomotiveSpacing.x4,
                      runSpacing: AutomotiveSpacing.x2,
                      children: [
                        SizedBox(
                          width: 170,
                          child: MetricReadout(
                            label: loc.liveTripSpeed,
                            value: liveSpeedKmh == null
                                ? '--'
                                : '${liveSpeedKmh.toStringAsFixed(0)} '
                                      '${loc.unitKmh}',
                            accent: true,
                          ),
                        ),
                        SizedBox(
                          width: 150,
                          child: MetricReadout(
                            label: loc.liveTripSoc,
                            value: can?.socPercent == null
                                ? socRangeLabel(
                                    session.startSoc.displayValue,
                                    session.endSoc.displayValue,
                                  )
                                : '${can!.socPercent!.toStringAsFixed(1)} %',
                          ),
                        ),
                        SizedBox(
                          width: 180,
                          child: MetricReadout(
                            label: loc.liveTripDrivePower,
                            value: can?.drivePowerKw == null
                                ? '--'
                                : '${can!.drivePowerKw!.toStringAsFixed(1)} '
                                      '${loc.chartPowerUnit}',
                          ),
                        ),
                        SizedBox(
                          width: 150,
                          child: MetricReadout(
                            label: loc.tripDetailDuration,
                            value: formatDuration(elapsed),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PageIntro extends StatelessWidget {
  const _PageIntro({
    required this.error,
    required this.hasRows,
    required this.totalCount,
  });

  final String? error;
  final bool hasRows;
  final int totalCount;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final source = error != null
        ? loc.bridgeErrorStatus
        : hasRows
        ? loc.roomTripSessions
        : totalCount > 0
        ? loc.dbCountMismatch
        : loc.noTripRows;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                loc.tripPageTitle,
                style: AutomotiveTextStyles.headlineLg.copyWith(
                  color: AutomotiveColors.onSurface,
                ),
              ),
              const SizedBox(height: AutomotiveSpacing.x0_5),
              Text(
                source,
                overflow: TextOverflow.ellipsis,
                style: AutomotiveTextStyles.unitLabel.copyWith(
                  color: AutomotiveColors.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: AutomotiveSpacing.x2),
          decoration: BoxDecoration(
            color: AutomotiveColors.surfaceContainerHigh,
            border: Border.all(color: AutomotiveColors.technicalBorder),
            borderRadius: AutomotiveRadii.baseRadius,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.route, color: AutomotiveColors.secondary, size: 18),
              const SizedBox(width: AutomotiveSpacing.x1),
              Text(
                loc.tripHistoryBadge,
                style: AutomotiveTextStyles.labelCaps.copyWith(
                  color: AutomotiveColors.onSurface,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DetailHint extends StatelessWidget {
  const _DetailHint();

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.all(AutomotiveSpacing.x4),
      decoration: BoxDecoration(
        border: Border.all(
          color: AutomotiveColors.outlineVariant,
          style: BorderStyle.solid,
        ),
        borderRadius: AutomotiveRadii.lgRadius,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.analytics_outlined,
            color: AutomotiveColors.onSurfaceVariant,
            size: 32,
          ),
          const SizedBox(width: AutomotiveSpacing.x2),
          Flexible(
            child: Text(
              loc.tripDetailHint,
              overflow: TextOverflow.ellipsis,
              style: AutomotiveTextStyles.bodyMd.copyWith(
                color: AutomotiveColors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
