import 'package:capy_companion/screens/charge_detail_screen.dart';
import 'package:capy_companion/screens/trip_detail_screen.dart';
import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../l10n/app_localizations.dart';
import 'companion_shell.dart';
import 'history_format.dart';

/// Which record the list is showing.
enum HistoryTab { trips, charges }

/// What this phone pulled from the car, as a list.
///
/// It asks a [TelemetryStore] — the local SQLite archive, through
/// `SqfliteStore` — and not a `TelemetryApi`. The api picks between the vehicle
/// channel and the mock, and the phone has neither: there is one store here,
/// and it is the archive. The source beside it carries only the push: a sync
/// run says when it wrote something.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({
    required this.store,
    required this.source,
    required this.tab,
    super.key,
  });

  /// The three questions. The list asks the first of them.
  final TelemetryStore store;

  /// The push side: the archive says when a sync run wrote something.
  final HistoricalTelemetrySource source;

  /// Which record this destination lists. It is fixed by the shell, not chosen
  /// here: trips and charges are two destinations on the phone, and a switch
  /// inside one of them would be a second way to reach the other.
  final HistoryTab tab;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  /// The page a phone list draws. The store pages, so this is a real limit
  /// rather than a hint.
  static const _pageLimit = 100;

  late final TelemetryQuery<List<TripSessionEntry>> _trips = TelemetryQuery(
    read: () async {
      final page = await widget.store.listSessions(
        filter: const SessionFilter(kind: SessionKind.trip),
        page: const PageRequest(limit: _pageLimit),
      );
      final placesResult = await widget.source.insightPlaces();
      final tripsResult = await widget.source.insightTrips(null);
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
    // No poll. Nothing writes to this store except a sync run, and that run
    // announces itself; a tick here would ask a question nobody changed the
    // answer to.
    refreshOn: widget.source.sessionChanges().where((change) => change.trips),
    debugLabel: 'HistoryScreen.trips',
  );

  late final TelemetryQuery<SessionListPage> _charges = TelemetryQuery(
    read: () => widget.store.listSessions(
      filter: const SessionFilter(kind: SessionKind.charge),
      page: const PageRequest(limit: _pageLimit),
    ),
    refreshOn: widget.source.sessionChanges().where((change) => change.charges),
    debugLabel: 'HistoryScreen.charges',
  );

  /// The one query this destination asks. Building both would put a read on
  /// the archive for a list nobody is looking at.
  TelemetryQuery<Object> get _query =>
      widget.tab == HistoryTab.trips ? _trips : _charges;

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

  void _open(Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ScreenTitle(
          widget.tab == HistoryTab.trips
              ? l10n.historyTrips
              : l10n.historyCharges,
        ),
        Expanded(
          child: switch (widget.tab) {
            HistoryTab.trips => _tripList(l10n, colors),
            HistoryTab.charges => _chargeList(l10n, colors),
          },
        ),
      ],
    );
  }

  Widget _tripList(AppLocalizations l10n, AppThemeColors colors) {
    return TripsBody(
      state: _trips.state,
      capabilities: SurfaceCapabilities.of(context),
      emptyMessage: l10n.historyEmpty,
      onRetry: () => _trips.refresh(),
      onSelectTrip: (trip) => _open(
        TripDetailScreen(
          store: widget.store,
          session: trip.session,
          source: widget.source,
        ),
      ),
    );
  }

  Widget _chargeList(AppLocalizations l10n, AppThemeColors colors) {
    final state = _charges.state;
    final result = state.value;
    if (result == null) return _placeholder(state, l10n, colors);
    if (result.sessions.isEmpty) {
      return _message(l10n.historyEmpty, colors);
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.x6,
        0,
        AppSpacing.x6,
        AppSpacing.x6,
      ),
      itemCount: result.sessions.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.x3),
      itemBuilder: (context, index) {
        final session = result.sessions[index];
        return SessionRow(
          title: formatDateTime(session.startedAtUtcMillis),
          meta: formatDuration(sessionReadingDurationMillis(session)),
          energy: sessionRowEnergy(
            l10n,
            sessionReadingDeliveredKwh(session).displayValue,
          ),
          soc: formatSocRange(
            session.startSoc.displayValue,
            session.endSoc.displayValue,
          ),
          onPressed: () => _open(
            ChargeDetailScreen(
              store: widget.store,
              session: session,
              source: widget.source,
            ),
          ),
        );
      },
    );
  }

  /// A read with no answer yet. An error keeps its own line, because an
  /// unreachable store and an empty history are different facts.
  Widget _placeholder(
    Loadable<Object?> state,
    AppLocalizations l10n,
    AppThemeColors colors,
  ) {
    if (state.error != null) {
      return _message(l10n.historyFailed('${state.error}'), colors);
    }
    return const Center(child: CircularProgressIndicator());
  }

  Widget _message(String text, AppThemeColors colors) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.x6),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: AppText.body.copyWith(color: colors.inkMuted),
        ),
      ),
    );
  }
}

/// The energy figure for a row, or null when nothing measured it.
String? sessionRowEnergy(AppLocalizations l10n, double? kwh) =>
    kwh == null || kwh <= 0 ? null : l10n.historyRowEnergy(formatEnergy(kwh));

/// One session in the list, as four readings on two lines.
class SessionRow extends StatelessWidget {
  const SessionRow({
    required this.title,
    required this.meta,
    required this.energy,
    required this.soc,
    required this.onPressed,
    super.key,
  });

  final String title;
  final String meta;
  final String? energy;
  final String soc;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Material(
      color: colors.surface,
      borderRadius: AppRadii.mdRadius,
      child: InkWell(
        borderRadius: AppRadii.mdRadius,
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.x4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.bodyStrong.copyWith(color: colors.ink),
                    ),
                  ),
                  if (energy case final energy?)
                    Text(
                      energy,
                      style: AppText.label.copyWith(color: colors.energy.draw),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.x1),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      meta,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.label.copyWith(color: colors.inkMuted),
                    ),
                  ),
                  Text(
                    soc,
                    style: AppText.label.copyWith(color: colors.inkMuted),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
