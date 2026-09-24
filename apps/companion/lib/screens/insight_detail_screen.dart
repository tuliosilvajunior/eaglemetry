import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../l10n/app_localizations.dart';
import 'history_format.dart';

/// Translates an [InsightPhrase] decided by `telemetry_core` to localized text.
String insightPhraseText(
  InsightPhrase phrase,
  AppLocalizations loc,
) => switch (phrase) {
  InsightPhraseSubjectUnusable() => loc.insightSubjectUnusable,
  InsightPhraseNotEnoughData(:final count) => loc.insightNotEnoughData(count),
  InsightPhraseNotDistinguishable(:final count) =>
    loc.insightNotDistinguishable(count),
  InsightPhraseUsedLess(:final difference, :final count) =>
    loc.insightTripUsedLess(difference, count),
  InsightPhraseUsedMore(:final difference, :final count) =>
    loc.insightTripUsedMore(difference, count),
  InsightPhraseVariantNotEnough(:final count) => loc.insightVariantNotEnough(
    count,
  ),
  InsightPhraseVariantNotDistinguishable(:final place, :final count) =>
    loc.insightVariantNotDistinguishable(place, count),
  InsightPhraseVariantUsedLess(:final difference, :final place, :final count) =>
    loc.insightVariantUsedLess(difference, place, count),
  InsightPhraseVariantUsedMore(:final difference, :final place, :final count) =>
    loc.insightVariantUsedMore(difference, place, count),
};

/// Translates an [InsightExclusion] to localized explanation copy.
String insightExclusionText(
  InsightExclusion exclusion,
  int count,
  AppLocalizations loc,
) => switch (exclusion) {
  InsightExclusion.neverRecorded => loc.insightExclusionNeverRecorded(count),
  InsightExclusion.noMinuteBuckets => loc.insightExclusionNoMinuteBuckets(
    count,
  ),
  InsightExclusion.signContradiction => loc.insightExclusionSignContradiction(
    count,
  ),
  InsightExclusion.unconfirmedSign => loc.insightExclusionUnconfirmedSign(
    count,
  ),
  InsightExclusion.tooShort => loc.insightExclusionTooShort(count),
  InsightExclusion.notClosed => loc.insightExclusionNotClosed(count),
  InsightExclusion.versionMismatch => loc.insightExclusionVersionMismatch(
    count,
  ),
  InsightExclusion.outsideWindow => loc.insightExclusionOutsideWindow(count),
  InsightExclusion.notOnRoute => loc.insightExclusionNotOnRoute(count),
  InsightExclusion.otherVariant => loc.insightExclusionOtherVariant(count),
};

/// Detail screen for a named route insight.
///
/// Displays:
/// - Claim & Baseline Hero Card comparing energy efficiency with confidence and separate exclusions.
/// - Considered trips included in the reference comparison sample.
/// - Route trend showing Wh/km across all trips of this route over time.
class InsightDetailScreen extends StatefulWidget {
  const InsightDetailScreen({
    required this.route,
    required this.source,
    this.now,
    super.key,
  });

  final NamedRoute route;
  final HistoricalTelemetrySource source;
  final DateTime? now;

  @override
  State<InsightDetailScreen> createState() => _InsightDetailScreenState();
}

class _InsightDetailScreenState extends State<InsightDetailScreen> {
  late final TelemetryQuery<
    ({
      NamedRoute route,
      InsightRead read,
      List<InsightPlace> places,
      InsightRouteIndex index,
      List<InsightTrip> allTrips,
      List<InsightTrip> routeTrips,
    })
  >
  _query = TelemetryQuery(
    read: _loadInsight,
    refreshOn: widget.source.sessionChanges().where((change) => change.trips),
    debugLabel: 'InsightDetailScreen.load',
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
    ({
      NamedRoute route,
      InsightRead read,
      List<InsightPlace> places,
      InsightRouteIndex index,
      List<InsightTrip> allTrips,
      List<InsightTrip> routeTrips,
    })
  >
  _loadInsight() async {
    final placesResult = await widget.source.insightPlaces();
    final places = placesResult.places;

    final tripsResult = await widget.source.insightTrips(null);
    final allTrips = tripsResult.trips;

    final index = InsightRouteIndex.build(allTrips, places);
    final currentRoute = index.routes
        .where(
          (r) =>
              r.from.id == widget.route.from.id &&
              r.to.id == widget.route.to.id,
        )
        .firstOrNull;
    final routeTrips = currentRoute == null
        ? const <InsightTrip>[]
        : ([...currentRoute.trips]..sort(
            (a, b) =>
                (a.endedAtUtcMillis ?? 0).compareTo(b.endedAtUtcMillis ?? 0),
          ));

    final now = widget.now ?? DateTime.now();
    final read =
        (widget.route.trips.isEmpty
                ? InsightSelection.none()
                : primaryInsight(
                    subject: widget.route.trips.first,
                    corpus: allTrips,
                    index: index,
                    now: now,
                  ))
            .primary;

    return (
      route: widget.route,
      read: read,
      places: places,
      index: index,
      allTrips: allTrips,
      routeTrips: routeTrips,
    );
  }

  Widget _claimHeroCard({
    required InsightRead read,
    required AppLocalizations l10n,
    required AppThemeColors colors,
  }) {
    final insight = read.insight;

    if (insight == null) {
      final message = insightPhraseText(
        insightPhrase(read, placeName: widget.route.to.name),
        l10n,
      );

      return AppCard(
        title: l10n.insightClaimTitle,
        badge: StatusBadge(
          icon: Icons.hourglass_empty,
          color: colors.inkSubtle,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.insightConfidenceInsufficient,
              style: AppText.cardTitle.copyWith(color: colors.inkMuted),
            ),
            const SizedBox(height: AppSpacing.x2),
            Text(message, style: AppText.body.copyWith(color: colors.inkMuted)),
            const SizedBox(height: AppSpacing.x4),
            _supportSection(read.support, l10n, colors),
          ],
        ),
      );
    }

    final diff = insight.magnitude.displayValue ?? 0.0;
    final isMoreEfficient = diff < 0;
    final claimSentence = insightPhraseText(
      insightPhrase(read, placeName: widget.route.to.name),
      l10n,
    );

    final isSupported = insight.confidence == InsightConfidence.supported;
    final statusColor = isSupported
        ? (isMoreEfficient ? colors.energy.gain : colors.energy.draw)
        : colors.inkMuted;

    final baselineName = switch (insight.baseline) {
      InsightBaseline.ownAverage30d => l10n.insightBaseline30d,
      InsightBaseline.otherVariantSameRoute => l10n.insightBaselineVariant,
    };

    return AppCard(
      title: l10n.insightClaimTitle,
      badge: StatusBadge(
        icon: isSupported ? Icons.check : Icons.info_outline,
        color: statusColor,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Delta Callout & Confidence Badge
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '${diff < 0 ? '-' : (diff > 0 ? '+' : '')}${diff.abs().toStringAsFixed(1)}',
                  style: AppText.metricXl.copyWith(
                    color: isSupported ? statusColor : colors.ink,
                  ),
                ),
                const SizedBox(width: AppSpacing.x2),
                Text(
                  'Wh/km',
                  style: AppText.unitLg.copyWith(color: colors.inkMuted),
                ),
                const SizedBox(width: AppSpacing.x4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.x3,
                    vertical: AppSpacing.x1,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: AppRadii.fullRadius,
                  ),
                  child: Text(
                    isSupported
                        ? l10n.insightConfidenceSupported
                        : l10n.insightConfidenceDistinguishable,
                    style: AppText.label.copyWith(
                      color: statusColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.x3),

          // Main Claim Copy
          Text(
            claimSentence,
            style: AppText.bodyStrong.copyWith(color: colors.ink),
          ),
          const SizedBox(height: AppSpacing.x4),

          Divider(color: colors.divider, thickness: 1),
          const SizedBox(height: AppSpacing.x3),

          // Baseline & Comparison Breakdown
          Row(
            children: [
              Icon(Icons.tune_rounded, size: 16, color: colors.inkMuted),
              const SizedBox(width: AppSpacing.x2),
              Text(
                l10n.insightBaselineTitle,
                style: AppText.label.copyWith(color: colors.inkMuted),
              ),
              const SizedBox(width: AppSpacing.x2),
              Expanded(
                child: Text(
                  baselineName,
                  textAlign: TextAlign.end,
                  style: AppText.label.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x3),

          // Comparison Tiles (Measured vs Reference)
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(AppSpacing.x3),
                  decoration: BoxDecoration(
                    color: colors.canvas,
                    borderRadius: AppRadii.smRadius,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.insightMeasured,
                        style: AppText.label.copyWith(color: colors.inkMuted),
                      ),
                      const SizedBox(height: AppSpacing.x1),
                      Text(
                        '${formatWhPerKm(insight.subject.displayValue)} Wh/km',
                        style: AppText.bodyStrong.copyWith(color: colors.ink),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.x3),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(AppSpacing.x3),
                  decoration: BoxDecoration(
                    color: colors.canvas,
                    borderRadius: AppRadii.smRadius,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.insightReference,
                        style: AppText.label.copyWith(color: colors.inkMuted),
                      ),
                      const SizedBox(height: AppSpacing.x1),
                      Text(
                        '${formatWhPerKm(insight.reference.displayValue)} Wh/km',
                        style: AppText.bodyStrong.copyWith(color: colors.ink),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x4),

          // Support & Exclusions info
          _supportSection(insight.support, l10n, colors),
        ],
      ),
    );
  }

  Widget _supportSection(
    InsightSupport support,
    AppLocalizations l10n,
    AppThemeColors colors,
  ) {
    final activeExclusions = [
      for (final entry in support.excluded.entries)
        if (entry.value > 0) entry,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.analytics_outlined, size: 15, color: colors.inkSubtle),
            const SizedBox(width: AppSpacing.x2),
            Expanded(
              child: Text(
                l10n.insightSupportSample(support.considered),
                style: AppText.label.copyWith(color: colors.inkMuted),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (activeExclusions.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.x2),
          for (final entry in activeExclusions) ...[
            const SizedBox(height: AppSpacing.x1),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    Icons.remove_circle_outline,
                    size: 14,
                    color: colors.inkSubtle,
                  ),
                ),
                const SizedBox(width: AppSpacing.x2),
                Expanded(
                  child: Text(
                    insightExclusionText(entry.key, entry.value, l10n),
                    style: AppText.label.copyWith(color: colors.inkMuted),
                  ),
                ),
              ],
            ),
          ],
        ],
      ],
    );
  }

  /// The ranked list of this route's measured trips, most efficient first.
  ///
  /// This is the primary answer: which run was the best. It makes no
  /// statistical claim — the claim card below still speaks only when the
  /// numbers support it.
  Widget _rankingCard({
    required NamedRoute route,
    required AppLocalizations l10n,
    required AppThemeColors colors,
  }) {
    final ranking = route.rankingByEfficiency;
    final best = ranking.isEmpty ? null : ranking.first.$2;

    return AppCard(
      title: l10n.insightRankingTitle,
      subtitle: l10n.insightRouteTrips(ranking.length),
      child: ranking.isEmpty
          ? Text(
              l10n.insightNoRouteTrips,
              style: AppText.body.copyWith(color: colors.inkMuted),
            )
          : Column(
              children: [
                for (var i = 0; i < ranking.length; i++) ...[
                  if (i > 0)
                    Divider(color: colors.divider, height: AppSpacing.x4),
                  _rankRow(
                    position: i + 1,
                    entry: ranking[i],
                    bestWhPerKm: best!,
                    l10n: l10n,
                    colors: colors,
                  ),
                ],
              ],
            ),
    );
  }

  Widget _rankRow({
    required int position,
    required (InsightTrip trip, double whPerKm) entry,
    required double bestWhPerKm,
    required AppLocalizations l10n,
    required AppThemeColors colors,
  }) {
    final trip = entry.$1;
    final whPerKm = entry.$2;
    final isBest = position == 1;
    final delta = whPerKm - bestWhPerKm;

    final dateStr = formatDateTime(trip.endedAtUtcMillis);
    final distanceStr = trip.distanceKm != null
        ? '${formatDistance(trip.distanceKm)} km'
        : null;
    final subtitle = distanceStr != null ? '$dateStr · $distanceStr' : dateStr;
    final accent = isBest ? colors.energy.gain : colors.inkMuted;

    return Row(
      children: [
        SizedBox(
          width: AppSpacing.x6,
          child: Text(
            '$position',
            style: AppText.bodyStrong.copyWith(
              color: isBest ? accent : colors.inkMuted,
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      isBest ? l10n.insightRankingBest : subtitle,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body.copyWith(
                        color: isBest ? accent : colors.ink,
                        fontWeight: isBest ? FontWeight.w600 : null,
                      ),
                    ),
                  ),
                  if (isBest) ...[
                    const SizedBox(width: AppSpacing.x1),
                    Icon(Icons.emoji_events, size: 16, color: accent),
                  ],
                ],
              ),
              if (isBest)
                Text(
                  subtitle,
                  style: AppText.label.copyWith(color: colors.inkMuted),
                ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.x2),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '${formatWhPerKm(whPerKm)} Wh/km',
              style: AppText.bodyStrong.copyWith(
                color: isBest ? accent : colors.ink,
              ),
            ),
            if (!isBest && delta > 0)
              Text(
                '+${delta.toStringAsFixed(1)}',
                style: AppText.label.copyWith(color: colors.inkMuted),
              ),
          ],
        ),
      ],
    );
  }

  Widget _tripListCard({
    required String title,
    required String subtitle,
    required List<InsightTrip> trips,
    required String emptyMessage,
    required AppThemeColors colors,
  }) {
    return AppCard(
      title: title,
      subtitle: subtitle,
      child: trips.isEmpty
          ? Text(
              emptyMessage,
              style: AppText.body.copyWith(color: colors.inkMuted),
            )
          : Column(
              children: [
                for (var i = 0; i < trips.length; i++) ...[
                  if (i > 0)
                    Divider(color: colors.divider, height: AppSpacing.x4),
                  _tripRow(trip: trips[i], colors: colors),
                ],
              ],
            ),
    );
  }

  Widget _tripRow({required InsightTrip trip, required AppThemeColors colors}) {
    final whPerKm =
        (trip.canPackWh != null &&
            trip.distanceKm != null &&
            trip.distanceKm! > 0)
        ? trip.canPackWh! / trip.distanceKm!
        : null;

    final dateStr = formatDateTime(trip.endedAtUtcMillis);
    final distanceStr = trip.distanceKm != null
        ? '${formatDistance(trip.distanceKm)} km'
        : null;
    final subtitle = distanceStr != null ? '$dateStr · $distanceStr' : dateStr;

    return Row(
      children: [
        Icon(Icons.directions_car_outlined, size: 16, color: colors.inkSubtle),
        const SizedBox(width: AppSpacing.x2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(subtitle, style: AppText.body.copyWith(color: colors.ink)),
              if (trip.meanAmbientTempC != null)
                Text(
                  '${formatTemperature(trip.meanAmbientTempC)} °C',
                  style: AppText.label.copyWith(color: colors.inkMuted),
                ),
            ],
          ),
        ),
        Text(
          '${formatWhPerKm(whPerKm)} Wh/km',
          style: AppText.bodyStrong.copyWith(color: colors.ink),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    final state = _query.state;
    final data = state.value;

    final consideredTrips = data == null || data.route.trips.isEmpty
        ? const <InsightTrip>[]
        : consideredTripsForInsight(
            read: data.read,
            subject: data.route.trips.first,
            corpus: data.allTrips,
            index: data.index,
            now: widget.now ?? DateTime.now(),
          );

    final routeTrips = data?.routeTrips ?? const <InsightTrip>[];

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
              '${widget.route.from.name} → ${widget.route.to.name}',
              overflow: TextOverflow.ellipsis,
              style: AppText.cardTitle.copyWith(color: colors.ink),
            ),
            Text(
              '${l10n.insightRouteTrips(widget.route.count)}'
              '${widget.route.averageDistanceKm != null ? " · ${formatDistance(widget.route.averageDistanceKm)} km" : ""}',
              style: AppText.label.copyWith(color: colors.inkMuted),
            ),
          ],
        ),
      ),
      body: data == null
          ? (state.error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.x6),
                      child: Text(
                        l10n.historyFailed('${state.error}'),
                        style: AppText.body.copyWith(color: colors.inkMuted),
                      ),
                    ),
                  )
                : const Center(child: CircularProgressIndicator()))
          : RefreshIndicator(
              onRefresh: _query.refresh,
              color: colors.energy.focus,
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.x6),
                children: [
                  _rankingCard(route: widget.route, l10n: l10n, colors: colors),
                  const SizedBox(height: AppSpacing.x4),
                  _claimHeroCard(read: data.read, l10n: l10n, colors: colors),
                  const SizedBox(height: AppSpacing.x4),
                  _tripListCard(
                    title: l10n.insightConsideredTripsTitle,
                    subtitle: l10n.insightSupportSample(consideredTrips.length),
                    trips: consideredTrips,
                    emptyMessage: l10n.insightNoConsideredTrips,
                    colors: colors,
                  ),
                  const SizedBox(height: AppSpacing.x4),
                  _tripListCard(
                    title: l10n.insightRouteTrendTitle,
                    subtitle: l10n.insightRouteTrips(routeTrips.length),
                    trips: routeTrips,
                    emptyMessage: l10n.insightNoRouteTrips,
                    colors: colors,
                  ),
                ],
              ),
            ),
    );
  }
}
