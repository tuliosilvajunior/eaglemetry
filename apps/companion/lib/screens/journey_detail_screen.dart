import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../l10n/app_localizations.dart';
import '../sync/journey_store.dart';
import 'charge_detail_screen.dart';
import 'history_format.dart';
import 'history_screen.dart';
import 'journey_editor_sheet.dart';
import 'trip_detail_screen.dart';

/// The detail of one named [Journey].
///
/// Shows its aggregated reading ([foldJourneySessions]) and lists all trips
/// and charges that started inside the journey's time window.
class JourneyDetailScreen extends StatefulWidget {
  const JourneyDetailScreen({
    required this.journey,
    required this.store,
    required this.source,
    required this.journeyStore,
    super.key,
  });

  final Journey journey;
  final TelemetryStore store;
  final HistoricalTelemetrySource source;
  final JourneyStore journeyStore;

  @override
  State<JourneyDetailScreen> createState() => _JourneyDetailScreenState();
}

class _JourneyDetailScreenState extends State<JourneyDetailScreen> {
  late Journey _journey = widget.journey;

  late final TelemetryQuery<
    ({Journey journey, List<SessionRecord> sessions, JourneyReading reading})
  >
  _query = TelemetryQuery(
    read: _loadDetails,
    refreshOn: widget.source.annotationsChanged().where(
      (change) => change.journeys,
    ),
    debugLabel: 'JourneyDetailScreen.details',
  );

  @override
  void initState() {
    super.initState();
    _query
      ..addListener(_onChanged)
      ..refresh();
  }

  @override
  void dispose() {
    _query
      ..removeListener(_onChanged)
      ..dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<
    ({Journey journey, List<SessionRecord> sessions, JourneyReading reading})
  >
  _loadDetails() async {
    final updated = await widget.journeyStore.journey(_journey.id);
    final current = updated ?? _journey;
    _journey = current;
    final members = await journeySessions(widget.store, current);
    final reading = foldJourneySessions(members);
    return (journey: current, sessions: members, reading: reading);
  }

  Future<void> _edit() async {
    final updated = await showJourneyEditorSheet(
      context: context,
      store: widget.store,
      journeyStore: widget.journeyStore,
      existing: _journey,
    );
    if (updated != null && mounted) {
      _journey = updated;
      _query.refresh();
    }
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showConfirmDialog(
      context: context,
      title: l10n.journeyDelete,
      message: l10n.journeyDeleteConfirm,
      confirmLabel: l10n.journeyDelete,
      cancelLabel: l10n.insightPlaceCancel,
      barrierLabel: l10n.journeyDelete,
      destructive: true,
    );

    if (confirmed == true && mounted) {
      await widget.journeyStore.delete(_journey.id);
      if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  void _openSession(SessionRecord session) {
    final Widget target = switch (session.kind) {
      SessionKind.trip => TripDetailScreen(
        store: widget.store,
        session: session,
        source: widget.source,
      ),
      SessionKind.charge => ChargeDetailScreen(
        store: widget.store,
        session: session,
        source: widget.source,
      ),
      SessionKind.parked => const SizedBox.shrink(),
      SessionKind.continuous => const SizedBox.shrink(),
    };
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => target));
  }

  Widget _placeholder(
    Loadable<Object?> state,
    AppLocalizations l10n,
    AppThemeColors colors,
  ) {
    if (state.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.x6),
          child: Text(
            l10n.historyFailed('${state.error}'),
            style: AppText.body.copyWith(color: colors.inkMuted),
          ),
        ),
      );
    }
    return const Center(child: CircularProgressIndicator());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    final state = _query.state;
    final data = state.value;

    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        backgroundColor: colors.canvas,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          color: colors.ink,
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _journey.name,
              overflow: TextOverflow.ellipsis,
              style: AppText.cardTitle.copyWith(color: colors.ink),
            ),
            Text(
              formatDateRange(
                _journey.startedAtUtcMillis,
                _journey.endedAtUtcMillis,
              ),
              style: AppText.label.copyWith(color: colors.inkMuted),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            color: colors.inkMuted,
            onPressed: _edit,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            color: colors.energy.critical,
            onPressed: _delete,
          ),
        ],
      ),
      body: data == null
          ? _placeholder(state, l10n, colors)
          : RefreshIndicator(
              onRefresh: _query.refresh,
              color: colors.energy.focus,
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.x6),
                children: [
                  if (data.journey.note != null &&
                      data.journey.note!.trim().isNotEmpty) ...[
                    AppCard(
                      title: l10n.journeyNote,
                      child: Text(
                        data.journey.note!,
                        style: AppText.body.copyWith(color: colors.ink),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.x4),
                  ],

                  MetricMosaic(
                    columns: 3,
                    tiles: [
                      MosaicTile(
                        caption: l10n.historyDistance,
                        value: formatDistance(
                          data.reading.distanceKm.displayValue,
                        ),
                        unit: 'km',
                      ),
                      MosaicTile(
                        caption: l10n.historyConsumed,
                        value: formatEnergy(data.reading.netKwh.displayValue),
                        unit: 'kWh',
                      ),
                      MosaicTile(
                        caption: l10n.historyRecovered,
                        value: formatEnergy(
                          data.reading.deliveredKwh.displayValue,
                        ),
                        unit: 'kWh',
                      ),
                      MosaicTile(
                        caption: l10n.historyTrips,
                        value: '${data.reading.tripCount}',
                      ),
                      MosaicTile(
                        caption: l10n.historyCharges,
                        value: '${data.reading.chargeCount}',
                      ),
                      if (data.reading.chargesCost != null)
                        MosaicTile(
                          caption: l10n.journeyCost,
                          value: formatEnergy(data.reading.chargesCost),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.x6),

                  Text(
                    l10n.journeySessionsInWindow,
                    style: AppText.cardTitle.copyWith(color: colors.ink),
                  ),
                  const SizedBox(height: AppSpacing.x3),

                  if (data.sessions.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.x6,
                        ),
                        child: Text(
                          l10n.journeyNoSessionsInWindow,
                          style: AppText.body.copyWith(color: colors.inkMuted),
                        ),
                      ),
                    )
                  else
                    for (var i = 0; i < data.sessions.length; i++) ...[
                      SessionRow(
                        title: formatDateTime(
                          data.sessions[i].startedAtUtcMillis,
                        ),
                        meta: data.sessions[i].kind == SessionKind.trip
                            ? l10n.historyTripMeta(
                                formatDuration(
                                  sessionReadingDurationMillis(
                                    data.sessions[i],
                                  ),
                                ),
                                formatDistance(
                                  sessionReadingDistance(
                                    data.sessions[i],
                                  ).displayValue,
                                ),
                              )
                            : formatDuration(
                                sessionReadingDurationMillis(data.sessions[i]),
                              ),
                        energy: sessionRowEnergy(
                          l10n,
                          data.sessions[i].kind == SessionKind.trip
                              ? sessionReadingNetKwh(
                                  data.sessions[i],
                                ).displayValue
                              : sessionReadingDeliveredKwh(
                                  data.sessions[i],
                                ).displayValue,
                        ),
                        soc: formatSocRange(
                          data.sessions[i].startSoc.displayValue,
                          data.sessions[i].endSoc.displayValue,
                        ),
                        onPressed: () => _openSession(data.sessions[i]),
                      ),
                      if (i < data.sessions.length - 1)
                        _buildParkedSeparatorOrSpacer(
                          currentSession: data.sessions[i],
                          previousSession: data.sessions[i + 1],
                          l10n: l10n,
                          colors: colors,
                        )
                      else
                        const SizedBox(height: AppSpacing.x3),
                    ],
                ],
              ),
            ),
    );
  }

  Widget _buildParkedSeparatorOrSpacer({
    required SessionRecord currentSession,
    required SessionRecord previousSession,
    required AppLocalizations l10n,
    required AppThemeColors colors,
  }) {
    final previousEnd =
        previousSession.endedAtUtcMillis ??
        (previousSession.startedAtUtcMillis +
            (sessionReadingDurationMillis(previousSession) ?? 0));
    final currentStart = currentSession.startedAtUtcMillis;
    // The gap is a wall-clock difference between two sessions, which is honest
    // only while the car's clock is. A gap that exceeds the longest plausible
    // drive/charge span is a clock the TBox has not synced, not forty days of
    // parking: it draws no parked separator rather than a confident lie.
    const kMaxPlausibleGapMillis = 48 * 60 * 60 * 1000;
    final rawGapMillis = currentStart - previousEnd;
    if (rawGapMillis < 0 || rawGapMillis > kMaxPlausibleGapMillis) {
      return const SizedBox(height: AppSpacing.x3);
    }
    final gapMillis = rawGapMillis;

    if (gapMillis >= 60000) {
      final formattedDuration = formatDuration(gapMillis);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.x2),
        child: Row(
          children: [
            Expanded(child: Divider(color: colors.divider, thickness: 1)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.local_parking_rounded,
                    size: 14,
                    color: colors.inkMuted,
                  ),
                  const SizedBox(width: AppSpacing.x1),
                  Text(
                    l10n.journeyParkedDuration(formattedDuration),
                    style: AppText.label.copyWith(
                      color: colors.inkMuted,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: Divider(color: colors.divider, thickness: 1)),
          ],
        ),
      );
    }
    return const SizedBox(height: AppSpacing.x3);
  }
}
