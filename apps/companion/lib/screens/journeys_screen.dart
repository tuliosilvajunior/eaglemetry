import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../l10n/app_localizations.dart';
import '../sync/journey_store.dart';
import 'history_format.dart';
import 'journey_detail_screen.dart';
import 'journey_editor_sheet.dart';

/// The Journeys destination: lists named real-world events that group trips
/// and charges by time window.
class JourneysScreen extends StatefulWidget {
  const JourneysScreen({
    required this.store,
    required this.source,
    required this.journeyStore,
    super.key,
  });

  final TelemetryStore store;
  final HistoricalTelemetrySource source;
  final JourneyStore journeyStore;

  @override
  State<JourneysScreen> createState() => _JourneysScreenState();
}

class _JourneysScreenState extends State<JourneysScreen> {
  late final TelemetryQuery<List<({Journey journey, JourneyReading reading})>>
  _query = TelemetryQuery(
    read: _loadJourneys,
    refreshOn: widget.source.annotationsChanged().where(
      (change) => change.journeys,
    ),
    debugLabel: 'JourneysScreen.journeys',
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

  Future<List<({Journey journey, JourneyReading reading})>>
  _loadJourneys() async {
    final journeys = await widget.journeyStore.journeys();
    final items = <({Journey journey, JourneyReading reading})>[];
    for (final journey in journeys) {
      final sessions = await journeySessions(widget.store, journey);
      final reading = foldJourneySessions(sessions);
      items.add((journey: journey, reading: reading));
    }
    return items;
  }

  Future<void> _createJourney() async {
    final created = await showJourneyEditorSheet(
      context: context,
      store: widget.store,
      journeyStore: widget.journeyStore,
    );
    if (created != null && mounted) {
      _query.refresh();
    }
  }

  void _openDetail(Journey journey) {
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => JourneyDetailScreen(
              journey: journey,
              store: widget.store,
              source: widget.source,
              journeyStore: widget.journeyStore,
            ),
          ),
        )
        .then((_) => _query.refresh());
  }

  Widget _empty(AppLocalizations l10n, AppThemeColors colors) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.x6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              l10n.journeysEmptyTitle,
              style: AppText.cardTitle.copyWith(color: colors.ink),
            ),
            const SizedBox(height: AppSpacing.x2),
            Text(
              l10n.journeysEmptyDesc,
              textAlign: TextAlign.center,
              style: AppText.body.copyWith(color: colors.inkMuted),
            ),
            const SizedBox(height: AppSpacing.x4),
            SizedBox(
              width: 200,
              child: SoftActionTile(
                label: l10n.journeysNew,
                icon: Icons.add,
                centered: true,
                onPressed: _createJourney,
              ),
            ),
          ],
        ),
      ),
    );
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
    final items = state.value;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.x6,
            AppSpacing.x6,
            AppSpacing.x4,
            AppSpacing.x4,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                l10n.journeysTitle,
                style: AppText.cardTitle.copyWith(color: colors.ink),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                color: colors.ink,
                tooltip: l10n.journeysNew,
                onPressed: _createJourney,
              ),
            ],
          ),
        ),
        Expanded(
          child: items == null
              ? _placeholder(state, l10n, colors)
              : items.isEmpty
              ? _empty(l10n, colors)
              : RefreshIndicator(
                  onRefresh: _query.refresh,
                  color: colors.energy.focus,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.x6,
                      0,
                      AppSpacing.x6,
                      AppSpacing.x6,
                    ),
                    itemCount: items.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: AppSpacing.x3),
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final journey = item.journey;
                      final reading = item.reading;

                      return _JourneyCard(
                        journey: journey,
                        reading: reading,
                        onTap: () => _openDetail(journey),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

class _JourneyCard extends StatelessWidget {
  const _JourneyCard({
    required this.journey,
    required this.reading,
    required this.onTap,
  });

  final Journey journey;
  final JourneyReading reading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    final distance = reading.distanceKm.displayValue;
    final netEnergy = reading.netKwh.displayValue;

    return Material(
      color: colors.surface,
      borderRadius: AppRadii.mdRadius,
      child: InkWell(
        borderRadius: AppRadii.mdRadius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.x4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      journey.name,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.bodyStrong.copyWith(color: colors.ink),
                    ),
                  ),
                  if (netEnergy != null && netEnergy > 0)
                    Text(
                      '${formatEnergy(netEnergy)} kWh',
                      style: AppText.label.copyWith(color: colors.energy.draw),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.x1),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      formatDateRange(
                        journey.startedAtUtcMillis,
                        journey.endedAtUtcMillis,
                      ),
                      overflow: TextOverflow.ellipsis,
                      style: AppText.label.copyWith(color: colors.inkMuted),
                    ),
                  ),
                  Text(
                    l10n.journeySessionsCount(
                      reading.tripCount,
                      reading.chargeCount,
                    ),
                    style: AppText.label.copyWith(color: colors.inkMuted),
                  ),
                ],
              ),
              if (distance != null && distance > 0) ...[
                const SizedBox(height: AppSpacing.x2),
                Row(
                  children: [
                    Icon(
                      Icons.directions_car_outlined,
                      size: 16,
                      color: colors.inkMuted,
                    ),
                    const SizedBox(width: AppSpacing.x1),
                    Text(
                      '${formatDistance(distance)} km',
                      style: AppText.label.copyWith(color: colors.ink),
                    ),
                    if (reading.deliveredKwh.displayValue != null &&
                        reading.deliveredKwh.displayValue! > 0) ...[
                      const SizedBox(width: AppSpacing.x3),
                      Icon(Icons.bolt, size: 16, color: colors.energy.gain),
                      const SizedBox(width: AppSpacing.x1),
                      Text(
                        '${formatEnergy(reading.deliveredKwh.displayValue)} kWh',
                        style: AppText.label.copyWith(
                          color: colors.energy.gain,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
              if (journey.note != null && journey.note!.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.x2),
                Text(
                  journey.note!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.label.copyWith(color: colors.inkSubtle),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
