import 'package:flutter/material.dart';

import '../../core/telemetry_api.dart';
import '../../core/telemetry_format.dart';

import '../../core/telemetry_scope.dart';
import '../../l10n/app_localizations.dart';
import '../../screens/charging/charging_session_display.dart'
    show chargePlugLabel;
import 'package:capy_ui/capy_ui.dart';
import '../places/places_screen.dart';
import 'history_constants.dart';

/// The drives the car has recorded, newest first.
class TripHistoryPane extends StatefulWidget {
  const TripHistoryPane({
    this.telemetryApi,
    this.selectedId,
    this.onSelected,
    super.key,
  });

  final TelemetryApi? telemetryApi;
  final String? selectedId;
  final ValueChanged<SessionRecord>? onSelected;

  @override
  State<TripHistoryPane> createState() => _TripHistoryPaneState();
}

class _TripHistoryPaneState extends State<TripHistoryPane> {
  late final TelemetryApi _api =
      widget.telemetryApi ?? TelemetryScope.of(context);

  late final TelemetryQuery<List<TripSessionEntry>> _query = TelemetryQuery(
    read: () async {
      final page = await _api.listSessions(
        filter: const SessionFilter(kind: SessionKind.trip),
        page: const PageRequest(limit: historyLimit),
      );
      final placesResult = await _api.getInsightPlaces();
      final tripsResult = await _api.getInsightTrips();
      final tripBySession = {for (final t in tripsResult.trips) t.id: t};

      return [
        for (final session in page.sessions)
          assembleTripSessionEntry(
            session: session,
            places: placesResult.places,
            startLatitude: tripBySession[session.id]?.startLatitude,
            startLongitude: tripBySession[session.id]?.startLongitude,
            endLatitude: tripBySession[session.id]?.endLatitude,
            endLongitude: tripBySession[session.id]?.endLongitude,
            path: tripBySession[session.id]?.path,
          ),
      ];
    },
    interval: historyFallbackInterval,
    debugLabel: 'HistoryV2Screen.trips',
    refreshOn: _api.sessionChanges().where((change) => change.trips),
  );

  @override
  void initState() {
    super.initState();
    _query.addListener(_onChanged);
    _query.start();
  }

  @override
  void dispose() {
    _query.removeListener(_onChanged);
    _query.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.x4,
            AppSpacing.x4,
            AppSpacing.x4,
            AppSpacing.x2,
          ),
          child: SoftActionTile(
            key: const Key('history-places-button'),
            label: 'Consultar locais',
            icon: Icons.place,
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const PlacesScreen()),
              );
            },
          ),
        ),
        Expanded(
          child: TripsBody(
            state: _query.state,
            capabilities: SurfaceCapabilities.of(context),
            selectedTripId: widget.selectedId,
            emptyMessage: AppLocalizations.of(context)!.v2HistoryEmpty,
            onRetry: () => _query.refresh(),
            onSelectTrip: (trip) => widget.onSelected?.call(trip.session),
          ),
        ),
      ],
    );
  }
}

/// The charges the car has recorded, newest first.
class ChargeHistoryPane extends StatefulWidget {
  const ChargeHistoryPane({
    this.telemetryApi,
    this.selectedId,
    this.onSelected,
    super.key,
  });

  final TelemetryApi? telemetryApi;
  final String? selectedId;
  final ValueChanged<SessionRecord>? onSelected;

  @override
  State<ChargeHistoryPane> createState() => _ChargeHistoryPaneState();
}

class _ChargeHistoryPaneState extends State<ChargeHistoryPane> {
  late final TelemetryApi _api =
      widget.telemetryApi ?? TelemetryScope.of(context);

  late final TelemetryQuery<SessionListPage> _query = TelemetryQuery(
    read: () => _api.listSessions(
      filter: const SessionFilter(kind: SessionKind.charge),
      page: const PageRequest(limit: historyLimit),
    ),
    interval: historyFallbackInterval,
    debugLabel: 'HistoryV2Screen.charges',
    refreshOn: _api.sessionChanges().where((change) => change.charges),
  );

  @override
  void initState() {
    super.initState();
    _query.addListener(_onChanged);
    _query.start();
  }

  @override
  void dispose() {
    _query.removeListener(_onChanged);
    _query.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return HistoryList(
      state: _query.state,
      countOf: (result) => result.sessions.length,
      rowBuilder: (context, index) {
        final session = _query.value!.sessions[index];
        final plugged = dateTimeFromMillis(session.startedAtUtcMillis);
        return HistoryRow(
          title: plugged == null ? '--' : formatTripListDateTime(plugged),
          status: statusLabel(session.status, loc),
          selected: session.id == widget.selectedId,
          onTap: () => widget.onSelected?.call(session),
          facts: [
            chargePlugLabel(session.plugType, loc),
            energyLabel(sessionReadingDeliveredKwh(session).displayValue),
            socRangeLabel(
              session.startSoc.displayValue,
              session.endSoc.displayValue,
            ),
          ],
        );
      },
    );
  }
}

/// The three states a history pane can be in, drawn the one way.
///
/// A failed read keeps the last good list under the message, because an
/// unreachable bridge is not an empty car.
///
/// The rows are lazy, and they wait for the shell's entrance gate. Both are
/// about the same frame: a tab roll has two destinations on screen at once and
/// lays out each of them on every frame of it, so a list that builds all fifty
/// of its rows there is built fifty times over — and the roll is exactly when
/// the reader is watching. Lazy costs the visible handful instead of the
/// whole page; the gate moves even that to after the roll has landed. Neither
/// delays the read, which starts as soon as the tab is touched.
class HistoryList<T> extends StatelessWidget {
  const HistoryList({
    required this.state,
    required this.countOf,
    required this.rowBuilder,
    this.emptyLabel,
    super.key,
  });

  final Loadable<T> state;
  final int Function(T value) countOf;
  final Widget Function(BuildContext context, int index) rowBuilder;

  /// What an empty list says. Defaults to the session-list copy; a cycle list
  /// passes its own, because an empty battery record is not an empty trip log.
  final String? emptyLabel;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);

    if (state.isFirstLoad) {
      return const Center(child: CircularProgressIndicator());
    }

    final value = state.value;
    final message = state.errorMessage;
    final count = value == null ? 0 : countOf(value);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (message != null) ...[
          // Amber is semantic and is deliberately not a themed neutral, so it
          // comes from the plain palette in both themes.
          Text(
            message,
            style: AppText.label.copyWith(
              color: AppThemeColors.of(context).energy.warning,
            ),
          ),
          const SizedBox(height: AppSpacing.x4),
        ],
        if (count == 0)
          Padding(
            padding: AppSpacing.cardPadding,
            child: Text(
              emptyLabel ?? loc.v2HistoryEmpty,
              style: AppText.body.copyWith(color: colors.inkSubtle),
            ),
          )
        else
          // The default placeholder is the right one here: the list fills the
          // slot either way, so the gate opening moves nothing around it.
          Expanded(
            child: EntranceGate.guard(
              context,
              () => ListView.builder(itemCount: count, itemBuilder: rowBuilder),
            ),
          ),
      ],
    );
  }
}

/// One recorded session: when it was, what it ended as, and three facts.
class HistoryRow extends StatelessWidget {
  const HistoryRow({
    required this.title,
    required this.status,
    required this.facts,
    required this.selected,
    this.onTap,
    super.key,
  });

  final String title;
  final String status;
  final List<String> facts;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final foreground = selected ? colors.onSelection : colors.ink;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.x2),
      child: Material(
        color: selected ? colors.selectionFill : colors.surface,
        borderRadius: AppRadii.mdRadius,
        animationDuration: AppMotion.fast,
        child: InkWell(
          onTap: onTap,
          borderRadius: AppRadii.mdRadius,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: AppSizes.minTouchTarget,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.x4,
                vertical: AppSpacing.x3,
              ),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: AppText.bodyStrong.copyWith(color: foreground),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          status,
                          style: AppText.label.copyWith(
                            color: selected ? foreground : colors.inkSubtle,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  for (final fact in facts)
                    Expanded(
                      flex: 2,
                      child: Text(
                        fact,
                        style: AppText.body.copyWith(color: foreground),
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
