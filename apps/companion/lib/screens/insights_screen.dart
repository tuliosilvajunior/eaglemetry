import 'dart:math' as math;

import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../l10n/app_localizations.dart';
import '../settings/nominatim_opt_in_store.dart';
import 'history_format.dart';
import 'insight_detail_screen.dart';
import 'places_screen.dart';

/// The Insights destination: pairs of named places, each with its recorded
/// directions.
class InsightsScreen extends StatefulWidget {
  const InsightsScreen({
    required this.store,
    required this.source,
    this.nominatimOptIn,
    this.onOpenSettings,
    super.key,
  });

  final TelemetryStore store;
  final HistoricalTelemetrySource source;
  final NominatimOptInStore? nominatimOptIn;
  final VoidCallback? onOpenSettings;

  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  late final TelemetryQuery<InsightRouteIndex> _query = TelemetryQuery(
    read: () async {
      final placesResult = await widget.source.insightPlaces();
      final tripsResult = await widget.source.insightTrips(null);
      return InsightRouteIndex.build(tripsResult.trips, placesResult.places);
    },
    refreshOn: widget.source.sessionChanges().where((change) => change.trips),
    debugLabel: 'InsightsScreen.routes',
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

  Future<void> _showInfo(AppLocalizations l10n) {
    return showFloatingSurface<void>(
      context: context,
      barrierLabel: l10n.insightsInfoTitle,
      pageBuilder: (context, animation, secondaryAnimation) => _InfoDialog(
        title: l10n.insightsInfoTitle,
        body: l10n.insightsInfoBody,
        closeLabel: l10n.insightsInfoClose,
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    final state = _query.state;
    final routes = state.value?.routes;

    if (routes == null) {
      if (state.error != null) {
        return _message(l10n.historyFailed('${state.error}'), colors);
      }
      return const Center(child: CircularProgressIndicator());
    }

    if (routes.isEmpty) {
      return RefreshIndicator(
        onRefresh: _query.refresh,
        color: colors.energy.focus,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.x6),
          children: [
            _Actions(
              source: widget.source,
              nominatimOptIn: widget.nominatimOptIn,
              onOpenSettings: widget.onOpenSettings,
              onInfo: () => _showInfo(l10n),
              infoTooltip: l10n.insightsInfoTitle,
            ),
            const SizedBox(height: AppSpacing.x4),
            AppCard(
              title: l10n.insightsNoRoutesTitle,
              child: Text(
                l10n.insightsNoRoutesBody,
                style: AppText.body.copyWith(color: colors.inkMuted),
              ),
            ),
          ],
        ),
      );
    }

    final groups = groupRoutesByPair(routes);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.x6,
            AppSpacing.x4,
            AppSpacing.x6,
            0,
          ),
          child: _Actions(
            source: widget.source,
            nominatimOptIn: widget.nominatimOptIn,
            onOpenSettings: widget.onOpenSettings,
            onInfo: () => _showInfo(l10n),
            infoTooltip: l10n.insightsInfoTitle,
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _query.refresh,
            color: colors.energy.focus,
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.x6,
                AppSpacing.x4,
                AppSpacing.x6,
                AppSpacing.x6,
              ),
              itemCount: groups.length,
              separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.x3),
              itemBuilder: (context, index) {
                return _RouteGroupCard(
                  group: groups[index],
                  l10n: l10n,
                  colors: colors,
                  source: widget.source,
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// One place pair as a card, with a direction switch when both directions are
/// recorded.
///
/// The card opens the selected direction's detail only when that direction has
/// enough measured trips; otherwise it is muted and says how many more the
/// comparisons need. The measured line always states the exact split so the
/// "missing" count never looks like a contradiction of the trip total.
class _RouteGroupCard extends StatefulWidget {
  const _RouteGroupCard({
    required this.group,
    required this.l10n,
    required this.colors,
    required this.source,
  });

  final RouteGroup group;
  final AppLocalizations l10n;
  final AppThemeColors colors;
  final HistoricalTelemetrySource source;

  @override
  State<_RouteGroupCard> createState() => _RouteGroupCardState();
}

class _RouteGroupCardState extends State<_RouteGroupCard> {
  late int _selected = 0;

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final l10n = widget.l10n;
    final colors = widget.colors;
    final directions = group.directions;
    final route = directions[_selected.clamp(0, directions.length - 1)];
    final distance = route.averageDistanceKm;
    final efficiency = route.averageWhPerKm;
    final eligible = route.isComparable;

    return GestureDetector(
      onTap: () {
        if (!eligible) return;
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                InsightDetailScreen(route: route, source: widget.source),
          ),
        );
      },
      child: AppCard(
        title: '${group.a.displayName} ↔ ${group.b.displayName}',
        trailing: eligible
            ? Icon(Icons.chevron_right, size: 20, color: colors.inkSubtle)
            : Icon(Icons.lock_outline, size: 18, color: colors.inkSubtle),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (group.hasBothDirections) ...[
              Row(
                children: [
                  for (var i = 0; i < directions.length; i++)
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(
                          right: i == directions.length - 1 ? 0 : AppSpacing.x2,
                        ),
                        child: SoftActionTile(
                          key: Key('route-direction-$i'),
                          label:
                              '${directions[i].from.displayName} → ${directions[i].to.displayName}',
                          selected: i == _selected,
                          onPressed: () => setState(() => _selected = i),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.x4),
            ],
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Row(
                    children: [
                      if (distance != null)
                        Text(
                          '${formatDistance(distance)} km',
                          style: AppText.body.copyWith(color: colors.inkMuted),
                        ),
                      if (distance != null && efficiency != null)
                        Text(
                          ' · ',
                          style: AppText.body.copyWith(color: colors.inkSubtle),
                        ),
                      if (efficiency != null)
                        Text(
                          '${formatWhPerKm(efficiency)} Wh/km',
                          style: AppText.body.copyWith(color: colors.inkMuted),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.x2),
                Text(
                  l10n.insightMeasuredOf(route.measuredCount, route.count),
                  style: AppText.bodyStrong.copyWith(
                    color: eligible ? colors.energy.focus : colors.inkMuted,
                  ),
                ),
              ],
            ),

            if (!eligible) ...[
              const SizedBox(height: AppSpacing.x2),
              Text(
                l10n.insightRouteMissingTrips(route.missingTrips),
                style: AppText.label.copyWith(color: colors.inkMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The pair heading and the info button that explains the feature.
class _Actions extends StatelessWidget {
  const _Actions({
    required this.source,
    this.nominatimOptIn,
    this.onOpenSettings,
    this.onInfo,
    this.infoTooltip,
  });

  final HistoricalTelemetrySource source;
  final NominatimOptInStore? nominatimOptIn;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onInfo;
  final String? infoTooltip;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _PlacesButton(
            source: source,
            nominatimOptIn: nominatimOptIn,
            onOpenSettings: onOpenSettings,
          ),
        ),
        const SizedBox(width: AppSpacing.x3),
        InfoIconButton(tooltip: infoTooltip, onPressed: onInfo),
      ],
    );
  }
}

class _InfoDialog extends StatelessWidget {
  const _InfoDialog({
    required this.title,
    required this.body,
    required this.closeLabel,
  });

  final String title;
  final String body;
  final String closeLabel;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final safePadding = MediaQuery.paddingOf(context);
    final available =
        MediaQuery.sizeOf(context).width -
        safePadding.horizontal -
        AppSpacing.x12;

    return Center(
      child: SizedBox(
        key: const Key('insights-info-dialog'),
        width: math.min(available, 420),
        child: Material(
          color: colors.surface,
          borderRadius: AppRadii.xlRadius,
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.7,
            ),
            child: SingleChildScrollView(
              padding: AppSpacing.cardPadding,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    style: AppText.cardTitle.copyWith(color: colors.ink),
                  ),
                  const SizedBox(height: AppSpacing.x3),
                  Text(
                    body,
                    style: AppText.body.copyWith(color: colors.inkMuted),
                  ),
                  const SizedBox(height: AppSpacing.x6),
                  SoftActionTile(
                    label: closeLabel,
                    centered: true,
                    onPressed: () => Navigator.of(context).pop(),
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

class _PlacesButton extends StatelessWidget {
  const _PlacesButton({
    required this.source,
    this.nominatimOptIn,
    this.onOpenSettings,
  });

  final HistoricalTelemetrySource source;
  final NominatimOptInStore? nominatimOptIn;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return SoftActionTile(
      key: const Key('insights-places-button'),
      label: 'Consultar locais',
      icon: Icons.place,
      onPressed: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PlacesScreen(
              source: source,
              nominatimOptIn: nominatimOptIn,
              onOpenSettings: onOpenSettings,
            ),
          ),
        );
      },
    );
  }
}
