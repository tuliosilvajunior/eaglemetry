import 'dart:math' as math;

import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../l10n/app_localizations.dart';
import '../sync/sqflite_store.dart';
import 'history_format.dart';

/// One recorded drive or charge, read from the store this phone holds.
///
/// The reduction is the shared one: [TripDetailReading] and
/// [ChargeDetailReading] are what the car app draws too, so a figure here and
/// the same figure on the head unit come from one reduction rather than from
/// two that agree today.
///
/// A drive and a charge share the chrome — one store, one reading, the same
/// loading and error bodies, the battery span, the events timeline and the
/// per-interval chart plumbing — and differ in every card that states a
/// measurement. Those cards belong to [TripDetailScreen] and
/// [ChargeDetailScreen], not here behind a flag.
abstract class SessionDetailScreen extends StatefulWidget {
  const SessionDetailScreen({
    required this.store,
    required this.session,
    this.source,
    super.key,
  });

  /// The three questions. The screen asks the second and the third.
  final TelemetryStore store;

  /// The row the list handed over. The screen re-reads it from the store, so
  /// this carries the identity and whatever a closed row already holds.
  final SessionRecord session;

  /// The historical telemetry source for places and annotations, if available.
  final HistoricalTelemetrySource? source;
}

/// The state one detail screen runs.
///
/// [D] is the reading the screen draws. The read itself is one template: the
/// record and the series are asked together because the bars and the balance
/// describe the same session, so a screen that took them separately could
/// paint one of them against a session the other does not describe.
abstract class SessionDetailState<
  W extends SessionDetailScreen,
  D extends Object
>
    extends State<W> {
  D? _detail;
  Object? _error;
  bool _loading = true;

  /// The places known to this phone.
  List<InsightPlace> _places = const [];

  /// The minutes of the session, folded from the intervals this phone holds.
  ///
  /// Empty when the car published no integration, which is the ordinary case
  /// for anything recorded before the daemon did it. The cards that read them
  /// are hidden then, rather than drawn empty.
  List<EnergyBucket> _buckets = const [];

  /// The events that occurred during this session.
  ///
  /// Hidden when the session holds no events.
  List<TelemetryEventRecord> _events = const [];

  /// Whether the map card is drawn large or small.
  bool _mapExpanded = false;

  /// Whether the map window is expanded, which is also how far a route is
  /// decimated: the large window draws the finer route.
  bool get mapExpanded => _mapExpanded;

  /// The places known to this phone.
  List<InsightPlace> get places => _places;

  /// The column the reader opened on the per-interval chart, or null.
  ///
  /// It is an index into the plotted list rather than a bucket, because that
  /// list has the zeroes and the unmeasured minutes removed.
  int? _selectedMinute;

  int? get selectedMinute => _selectedMinute;

  List<EnergyBucket> get buckets => _buckets;

  List<TelemetryEventRecord> get events => _events;

  /// The reading this screen drew, once the read has landed.
  D? get detail => _detail;

  void selectMinute(int? index) {
    setState(() => _selectedMinute = index);
  }

  void toggleMapExpanded() {
    setState(() => _mapExpanded = !_mapExpanded);
  }

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void didUpdateWidget(covariant W oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.id != widget.session.id) {
      _loading = true;
      reload();
    }
  }

  /// Builds the reading from the row, the series, the events, and optional track.
  D reading(
    SessionRecord record,
    TelemetrySeries series,
    List<TelemetryEventRecord> events, {
    TrackRow? track,
  });

  /// The cards that make up the screen.
  List<Widget> cards(D detail, AppLocalizations l10n, AppThemeColors colors);

  /// Prompts the user to name a place at ([latitude], [longitude]).
  Future<void> namePlace({
    required double latitude,
    required double longitude,
    String? existingPlaceId,
    String? currentName,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final name = await showNamePlaceDialog(
      context: context,
      title: l10n.insightPlaceTitle,
      hintText: l10n.insightPlaceHint,
      saveLabel: l10n.insightPlaceSave,
      cancelLabel: l10n.insightPlaceCancel,
      barrierLabel: l10n.insightPlaceTitle,
      initialName: currentName,
    );
    if (name == null || name.trim().isEmpty) return;
    final trimmed = name.trim();
    if (widget.source != null) {
      await widget.source!.saveInsightPlace(
        id: existingPlaceId,
        name: trimmed,
        latitude: latitude,
        longitude: longitude,
      );
    } else if (widget.store is SqfliteStore) {
      final db = (widget.store as SqfliteStore).db;
      final now = DateTime.now().millisecondsSinceEpoch;
      final id = existingPlaceId ?? 'phone-place-$now';
      await db.upsertPlace(id, now, kAnnotationOriginPhone, {
        'id': id,
        'name': trimmed,
        'latitude': latitude,
        'longitude': longitude,
        'radiusM': kInsightPlaceRadiusM,
        'createdAtUtcMillis': now,
        'updatedAtUtcMillis': now,
        'origin': kAnnotationOriginPhone,
        'deletedAtUtcMillis': null,
      });
    }
    if (!mounted) return;
    await reload();
  }

  /// Reads the session again and rebuilds every card on the answer.
  Future<void> reload() async {
    try {
      // Read as one question. The bars and the balance describe the same
      // session, so a screen that took them separately could paint one of them
      // against a session the other does not describe.
      final stored = await widget.store.session(widget.session.id);
      final series = await widget.store.series(widget.session.id);
      final record = stored?.session ?? widget.session;
      final events = stored?.events ?? const <TelemetryEventRecord>[];
      final detail = reading(record, series, events, track: stored?.track);
      final buckets = [
        for (final interval in series.intervals)
          EnergyBucket.fromInterval(interval),
      ];

      List<InsightPlace> places = const [];
      if (widget.source != null) {
        final res = await widget.source!.insightPlaces();
        places = res.places;
      } else if (widget.store is SqfliteStore) {
        final rows = await (widget.store as SqfliteStore).db.allPlaces();
        places = [
          for (final row in rows)
            if (row['deletedAtUtcMillis'] == null)
              InsightPlace(
                id: (row['id'] as String?) ?? '',
                name: (row['name'] as String?) ?? '',
                latitude: (row['latitude'] as num?)?.toDouble() ?? 0,
                longitude: (row['longitude'] as num?)?.toDouble() ?? 0,
                radiusM:
                    (row['radiusM'] as num?)?.toDouble() ??
                    kInsightPlaceRadiusM,
                autoName: row['autoName'] as String?,
                autoNameUpdatedAtUtcMillis:
                    (row['autoNameUpdatedAtUtcMillis'] as num?)?.toInt(),
                autoNameSource: row['autoNameSource'] as String?,
              ),
        ];
      }

      if (!mounted) return;
      setState(() {
        _detail = detail;
        _buckets = buckets;
        _events = events;
        _places = places;
        _selectedMinute = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        backgroundColor: colors.canvas,
        foregroundColor: colors.ink,
        elevation: 0,
        title: Text(
          formatDateTime(widget.session.startedAtUtcMillis),
          style: AppText.cardTitle.copyWith(color: colors.ink),
        ),
      ),
      body: _body(l10n, colors),
    );
  }

  Widget _body(AppLocalizations l10n, AppThemeColors colors) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.x6),
          child: Text(
            l10n.historyFailed('$_error'),
            textAlign: TextAlign.center,
            style: AppText.body.copyWith(color: colors.inkMuted),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.x6),
      children: cards(_detail!, l10n, colors),
    );
  }

  /// A card, with the gap above it, or nothing at all.
  ///
  /// The gap belongs to the card rather than to the list, so a hidden card
  /// leaves no space behind to mark where it would have been.
  List<Widget> maybeCard(Widget? card) =>
      card == null ? const [] : [const SizedBox(height: AppSpacing.x4), card];

  /// The window both maps are drawn through, and the one place the two sizes
  /// are stated. Small by default, tall while expanded, with the expand button
  /// wired to [SessionDetailState] state so a drive and a charge behave the
  /// same way.
  Widget mapWindow({
    required List<RouteMapPoint> points,
    required AppLocalizations l10n,
  }) => SizedBox(
    height: _mapExpanded ? 460 : 260,
    child: RouteMapCard(
      points: points,
      expanded: _mapExpanded,
      expandLabel: l10n.historyMapExpand,
      collapseLabel: l10n.historyMapCollapse,
      onToggleExpanded: () => setState(() => _mapExpanded = !_mapExpanded),
    ),
  );

  /// Where the battery started and where it ended.
  ///
  /// Hidden without both ends. One end alone cannot be drawn as a span, and
  /// drawing it against an assumed other end would invent the reading.
  Widget? batteryCard(AppLocalizations l10n) {
    final start = widget.session.startSoc.displayValue;
    final end = widget.session.endSoc.displayValue;
    if (start == null || end == null) return null;
    return AppCard(
      title: l10n.historyBattery,
      child: SocSpanBar(
        startPercent: start,
        endPercent: end,
        startLabel: '${start.round()}%',
        endLabel: '${end.round()}%',
        semanticsLabel: formatSocRange(start, end),
      ),
    );
  }

  /// The timeline of events that occurred during this session.
  ///
  /// Hidden when the session holds no events.
  Widget? eventsCard(AppLocalizations l10n, AppThemeColors colors) {
    if (_events.isEmpty) return null;

    return AppCard(
      title: l10n.historyEvents,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < _events.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.x3),
            _eventRow(_events[i], l10n, colors),
          ],
        ],
      ),
    );
  }

  Widget _eventRow(
    TelemetryEventRecord event,
    AppLocalizations l10n,
    AppThemeColors colors,
  ) {
    final type = event.type;
    final timeMillis = event.occurredAtUtcMillis;
    final signalId = event.signalKey;
    final value = event.value;
    final prevValue = event.previousValue;

    final label = _formatEventType(type, signalId, value, prevValue, l10n);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 8,
          height: 8,
          margin: const EdgeInsets.only(top: 6, right: AppSpacing.x3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _eventColor(type, colors),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: AppText.body.copyWith(
                  color: colors.ink,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (timeMillis > 0)
                Text(
                  formatDateTime(timeMillis),
                  style: AppText.caption.copyWith(color: colors.inkMuted),
                ),
            ],
          ),
        ),
      ],
    );
  }

  String _formatEventType(
    String type,
    String? signalId,
    String? value,
    String? prevValue,
    AppLocalizations l10n,
  ) {
    return switch (type) {
      'TRIP_ARMED' => l10n.eventTripArmed,
      'TRIP_STARTED' => l10n.eventTripStarted,
      'TRIP_PENDING_END' => l10n.eventTripPendingEnd,
      'TRIP_CANCELLED' => l10n.eventTripCancelled,
      'TRIP_ENDED' => l10n.eventTripEnded,
      'TRIP_RECOVERED' => l10n.eventTripRecovered,
      'CHARGE_PLUG_CONNECTED' => l10n.eventChargePlugConnected,
      'CHARGE_STARTED' => l10n.eventChargeStarted,
      'CHARGE_LIMIT_REACHED' => l10n.eventChargeLimitReached,
      'CHARGE_ENDED' => l10n.eventChargeEnded,
      'CHARGE_PLUG_DISCONNECTED' => l10n.eventChargePlugDisconnected,
      'CHARGE_RECOVERED' => l10n.eventChargeRecovered,
      'SIGNAL_UPDATED' =>
        signalId != null
            ? (prevValue != null && value != null
                  ? '$signalId: $prevValue → $value'
                  : (value != null ? '$signalId: $value' : signalId))
            : type,
      _ => type,
    };
  }

  Color _eventColor(String type, AppThemeColors colors) {
    return switch (type) {
      'TRIP_STARTED' || 'CHARGE_STARTED' => colors.energy.gain,
      'CHARGE_LIMIT_REACHED' => colors.energy.focus,
      'TRIP_ENDED' || 'CHARGE_ENDED' => colors.energy.draw,
      'TRIP_CANCELLED' || 'SIGNAL_ERROR' => colors.energy.warning,
      _ => colors.inkSubtle,
    };
  }

  /// The height both interval charts are drawn at. Stated, because the chart
  /// is no longer the card's only child and a `Column` gives it no height to
  /// fall back on.
  static const chartHeight = 260.0;

  /// The widest column the reader gets, and the narrowest one that fits.
  ///
  /// The steps are whole divisions of the hour so a column keeps a name a
  /// reader can say. Nothing wider than the half hour is offered: past that
  /// the chart stops describing the session and becomes one figure for it, and
  /// the energy balance card above already answers that question.
  static Duration columnWidth(
    List<EnergyBucket> minutes,
    double available, {
    DateTime? origin,
  }) {
    const steps = [1, 2, 5, 10, 15, 30];
    final plot = available - AppSizes.chartAxisGutter;
    final fits = math.max(1, AppSizes.chartBarProfile.slotsIn(plot));
    for (final step in steps) {
      final width = Duration(minutes: step);
      if (reduceEnergyBuckets(minutes, width, origin: origin).length <= fits) {
        return width;
      }
    }
    return const Duration(minutes: 30);
  }

  /// A column names the span it covers, not the instant it starts at, once it
  /// is wider than a minute.
  ///
  /// The stamp is a label, never a span: the reduction placed the column by
  /// its ordinal against [origin], so the label is only printed when the clock
  /// is plausible for this session — otherwise the column names its position
  /// instead of a clock time the session does not own.
  String columnLabel(EnergyBucket bucket, DateTime? origin) {
    final plausible =
        origin != null &&
        (bucket.start.difference(origin).abs() < const Duration(hours: 1));
    final start = plausible
        ? formatClock(bucket.start.millisecondsSinceEpoch)
        : _positionLabel(bucket, origin);
    if (bucket.width <= EnergyBucket.oneMinute) return start;
    final end = plausible
        ? formatClock(bucket.end.millisecondsSinceEpoch)
        : _positionLabel(
            EnergyBucket(
              start: bucket.end,
              width: EnergyBucket.oneMinute,
              tractionWh: 0,
              regeneratedWh: 0,
              auxiliaryWh: 0,
              integratedSeconds: 0,
            ),
            origin,
          );
    return '$start-$end';
  }

  static String _positionLabel(EnergyBucket bucket, DateTime? origin) {
    if (origin == null) return formatClock(bucket.start.millisecondsSinceEpoch);
    final minute = bucket.start.difference(origin).inMinutes;
    return minute <= 0 ? 'start' : '+${minute}m';
  }

  /// Where in the session a column sits, without having to open one.
  List<ChartXTick> timeXTicks(
    List<EnergyBucket> columns,
    Duration width, {
    DateTime? origin,
  }) => buildChartXTimeTicks(
    domainStart: origin ?? columns.first.start,
    bucketWidth: width,
    slotCount: columns.length,
    labelBuilder: (value) => formatClock(value.millisecondsSinceEpoch),
  );

  /// The card both kinds draw an interval chart into.
  ///
  /// Picks the widest whole-minute column that fits ([columnWidth]), reduces
  /// the minutes to those columns, and hands them to [chart] at [chartHeight]
  /// over the caption naming the width. The caption is always drawn: the title
  /// names no interval any more, because the width follows the screen, and a
  /// column that holds five minutes and says nothing is read as one.
  ///
  /// [origin] is the session's first minute. Reduction aligns columns to it
  /// (never to clock boundaries), so a minute the clock lied about stays
  /// beside its neighbours instead of drawing fourteen months away — the same
  /// ordinal placement the stores use. The column labels are honest about the
  /// same lie: implausible stamps name positions (`+2m`) instead of clock
  /// times the session does not own.
  ///
  /// A reduced column survives when the car integrated it; [keepColumn] drops
  /// any further ones — the charge screen refuses a column that delivered
  /// nothing.
  Widget? intervalChartCard(
    AppLocalizations l10n,
    AppThemeColors colors, {
    required String title,
    required List<EnergyBucket> minutes,
    required Widget Function(
      List<EnergyBucket> columns,
      Duration width,
      DateTime origin,
    )
    chart,
    bool Function(EnergyBucket bucket)? keepColumn,
  }) {
    if (minutes.isEmpty) return null;
    final origin = minutes.first.start;
    return AppCard(
      title: title,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = columnWidth(
            minutes,
            constraints.maxWidth,
            origin: origin,
          );
          final columns = [
            for (final bucket in reduceEnergyBuckets(
              minutes,
              width,
              origin: origin,
            ))
              if (bucket.integratedSeconds > 0 &&
                  (keepColumn == null || keepColumn(bucket)))
                bucket,
          ];
          if (columns.isEmpty) return const SizedBox.shrink();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: chartHeight,
                child: chart(columns, width, origin),
              ),
              const SizedBox(height: AppSpacing.x2),
              Text(
                l10n.historyPerColumn(width.inMinutes),
                style: AppText.caption.copyWith(color: colors.inkSubtle),
              ),
            ],
          );
        },
      ),
    );
  }

  /// A series ready to draw, or null when the car reported nothing usable.
  ///
  /// The positions are the reading's own place along the session, so a session
  /// with a gap in the middle draws the gap where it happened rather than
  /// closing it up.
  ({List<SeriesTracePoint> points, double low, double high})? traceSeries(
    List<TelemetrySeriesPoint> series,
  ) {
    if (series.length < 2) return null;
    final values = [
      for (final point in series)
        if (point.y.isFinite) point.y,
    ];
    if (values.isEmpty) return null;
    final first = series.first.x;
    final span = series.last.x - first;
    if (span <= 0) return null;
    return (
      points: [
        for (final point in series)
          SeriesTracePoint(
            position: (point.x - first) / span,
            value: point.y.isFinite ? point.y : null,
          ),
      ],
      low: values.reduce(math.min),
      high: values.reduce(math.max),
    );
  }

  /// A caption over a trace, because two traces on one card need names.
  Widget labelled(String label, AppThemeColors colors, Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(label, style: AppText.label.copyWith(color: colors.inkMuted)),
      const SizedBox(height: AppSpacing.x2),
      child,
    ],
  );
}
