import 'package:flutter/material.dart';

import '../../core/telemetry_api.dart';
import '../../core/telemetry_format.dart';
import '../../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';
import '../charge_cost_editor.dart';
import '../energy_session_panel.dart';
import '../charts/charge_session_chart.dart';
import '../charts/trip_energy_bar_chart.dart';
import '../insight_route_line.dart';
import '../own_average_insight.dart';
import 'history_cycle_timeline.dart';
import 'history_detail_page.dart';
import 'session_mosaic.dart';

/// What the cost tile needs to become an editor: the fallback rate, whether a
/// write is already in flight, and where the typed amount goes.
@immutable
class HistoryChargeCostEditor {
  const HistoryChargeCostEditor({
    required this.defaultCostPerKwh,
    required this.saving,
    required this.onSubmitted,
  });

  final double? defaultCostPerKwh;
  final bool saving;
  final ValueChanged<MoneyKeypadResult<ChargeCostField>> onSubmitted;
}

/// The open session with the whole stage to itself.
///
/// Deliberately does not scroll. The stage gives a card exactly the height it
/// has and no more, and the drag that closes this card owns the vertical axis —
/// a scrollable in here would compete with it for the same gesture.
class HistoryDetailFullscreen extends StatefulWidget {
  const HistoryDetailFullscreen({
    required this.page,
    required this.costEditor,
    super.key,
  });

  final HistoryDetailPage page;

  /// A drive is priced by the charge before it, so only a charge's wall grows
  /// a pencil. This is carried for both and used by one.
  final HistoryChargeCostEditor costEditor;

  @override
  State<HistoryDetailFullscreen> createState() =>
      _HistoryDetailFullscreenState();
}

class _HistoryDetailFullscreenState extends State<HistoryDetailFullscreen> {
  /// Whether the reader has asked the map for more room.
  ///
  /// It lives here rather than in the map card because the space has to come
  /// from somewhere, and only this layout knows what gives it up: the ring
  /// above it. The card asks; this answers.
  bool _mapExpanded = false;

  /// Which column of the session chart the reader has open, if any.
  ///
  /// Held here rather than inside the chart for the same reason the map's state
  /// is: this is the one object that survives a refresh and knows when the
  /// session under it has actually changed.
  int? _selectedBar;

  /// How the height is split: three quarters of charts over one quarter of
  /// readings.
  ///
  /// Fixed, and it stays fixed while the map grows. Nothing on the left moves:
  /// the map takes its room from the ring stacked above it in the same column.
  static const _chartFlex = 3;
  static const _readingsFlex = 1;

  /// The right-hand column's share of the width — the ring's column, which the
  /// map shares and then takes over.
  static const _sideFlex = 1;
  static const _mainFlex = 3;

  @override
  void didUpdateWidget(covariant HistoryDetailFullscreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A charge cannot expand, so a reader who opens a drive, expands its map
    // and then opens a charge must not leave the charge holding a state it has
    // no control to undo.
    if (widget.page is! HistoryTripDetailPage && _mapExpanded) {
      _mapExpanded = false;
    }
    // A column index means nothing on another session's chart, so it is
    // dropped when the session changes — and only then. A refresh of the same
    // drive must not close a reading the user is still looking at.
    if (widget.page.sessionId != oldWidget.page.sessionId) {
      _selectedBar = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = widget.page;

    // A battery is not a session: it has no chart, no route and no wall of
    // readings — the row in the list already holds every number it has. What
    // it has instead is a story, so its card is one column of it.
    if (page is HistoryCycleDetailPage) return CycleTimelineCard(page: page);

    final route = page.routePoints(expanded: _mapExpanded);

    // A drive with a recorded route is the one layout with a right-hand
    // column of its own: the ring and the map are stacked there, and the map
    // grows upward over the ring. Everything else keeps the plain two-row
    // shape — charts across the top, readings under them.
    if (page is HistoryTripDetailPage && route.isNotEmpty) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: _mainFlex,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: _chartFlex, child: _sessionChartCard(context)),
                const SizedBox(height: AppSpacing.gridGutter),
                Expanded(flex: _readingsFlex, child: _mosaicCard(context)),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.gridGutter),
          Expanded(flex: _sideFlex, child: _ringAndRoute(context, page, route)),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: _chartFlex, child: _charts(context)),
        const SizedBox(height: AppSpacing.gridGutter),
        Expanded(flex: _readingsFlex, child: _readings(context, route)),
      ],
    );
  }

  /// The drive's ring with its route under it, and the handover between them.
  ///
  /// The map is square at rest, so the column's own width is its side — which
  /// is why the two never have to agree on a second number. Growing it eats
  /// the ring above, upward, and the column keeps its width: the chart and the
  /// wall of readings beside it do not move at all.
  ///
  /// Heights are computed rather than flexed, because the handover animates
  /// and `Expanded` has no continuous flex to animate between.
  Widget _ringAndRoute(
    BuildContext context,
    HistoryTripDetailPage page,
    List<RouteMapPoint> route,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: _mapExpanded ? 1 : 0),
          duration: AppMotion.slow,
          curve: AppMotion.curve,
          builder: (context, open, _) {
            final total = constraints.maxHeight;
            final square = constraints.maxWidth;
            final map = square + (total - square) * open;
            final ring = total - map - AppSpacing.gridGutter;
            final ringClosed = total - square - AppSpacing.gridGutter;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (ring > 0) ...[
                  // The ring keeps the height it had and is clipped as the map
                  // climbs over it, rather than being squeezed through every
                  // height on its way out.
                  SizedBox(
                    height: ring,
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.topCenter,
                        minHeight: ringClosed,
                        maxHeight: ringClosed,
                        child: _ringCard(page),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.gridGutter),
                ],
                SizedBox(height: map, child: _routeCard(context, route)),
              ],
            );
          },
        );
      },
    );
  }

  Widget _charts(BuildContext context) {
    final page = widget.page;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: _mainFlex, child: _sessionChartCard(context)),
        // The ring is the drive's own energy split, the same reading the
        // energy monitor shows for a window of clock. A charge has no measured
        // split to divide into one — the car reports what went in, not where it
        // went — so its row is the chart alone rather than a ring that would
        // have to invent its slices.
        if (page is HistoryTripDetailPage) ...[
          const SizedBox(width: AppSpacing.gridGutter),
          Expanded(flex: _sideFlex, child: _ringCard(page)),
        ],
      ],
    );
  }

  Widget _sessionChartCard(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final page = widget.page;
    void select(int? index) => setState(() => _selectedBar = index);
    return AppCard(
      title: page.title(context),
      subtitle: loc.v2HistoryCollapseHint,
      child: switch (page) {
        HistoryTripDetailPage() => TripEnergyBarChart(
          buckets: page.buckets,
          selectedIndex: _selectedBar,
          onSelected: select,
          timeUnsynced: seriesTimePending(page.reading.series.intervals),
        ),
        HistoryChargeDetailPage() => ChargeSessionChart(
          detail: page.reading,
          sessionId: page.session.id,
          duration: page.window,
          windowStart: page.windowStart,
          selectedIndex: _selectedBar,
          onSelected: select,
        ),
        // A battery has no chart. Its card returns before this is reached.
        HistoryCycleDetailPage() => const SizedBox.shrink(),
      },
    );
  }

  Widget _ringCard(HistoryTripDetailPage page) {
    return EnergySessionPanel(
      buckets: page.buckets,
      loading: false,
      failed: false,
      // This column is a cell, not a page: the drive is named by the card
      // beside it and its duration is one of the readings in the mosaic under
      // it, so the header would spend a third of this card's height repeating
      // the screen back to itself.
      showTitle: false,
    );
  }

  /// The wall of readings, and — for a charge — the one position it recorded.
  ///
  /// A charge has no ring for a map to grow over and only one position to
  /// show, so its map stays square at the end of the row and has no button.
  Widget _readings(BuildContext context, List<RouteMapPoint> route) {
    if (route.isEmpty) return _mosaicCard(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _mosaicCard(context)),
        const SizedBox(width: AppSpacing.gridGutter),
        _routeCard(context, route, square: true),
      ],
    );
  }

  Widget _mosaicCard(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final page = widget.page;
    return AppCard(
      title: loc.v2HistoryFactsTitle,
      trailing: page is HistoryTripDetailPage
          ? _tripHeaderInsight(context, loc, page)
          : null,
      child: switch (page) {
        HistoryTripDetailPage() => SessionMosaic.trip(reading: page.reading),
        // A battery has no wall of readings. Its card returns before this is
        // reached.
        HistoryCycleDetailPage() => const SizedBox.shrink(),
        HistoryChargeDetailPage() => SessionMosaic.charge(
          reading: page.reading,
          defaultCostPerKwh: widget.costEditor.defaultCostPerKwh,
          costEditLabel: loc.v2ChargeCostEdit,
          // Shut while a price is being written, so two amounts cannot race
          // for one session.
          onCostPressed: widget.costEditor.saving
              ? null
              : (cellContext) => showChargeCostKeypad(
                  context: context,
                  anchorContext: cellContext,
                  session: page.session,
                  defaultCostPerKwh: widget.costEditor.defaultCostPerKwh,
                  currencySymbol: chargeCurrencySymbolForLocale(
                    loc.localeName,
                    fallbackCurrency: chargeCostCurrencyOf(
                      page.session,
                      fallback: 'BRL',
                    ),
                  ),
                  // The tile can sit at either end of the wall, so the side is
                  // decided from where it actually landed.
                  side: AnchoredTooltipSide.auto,
                  onSubmitted: widget.costEditor.onSubmitted,
                ),
        ),
      },
    );
  }

  Widget? _tripHeaderInsight(
    BuildContext context,
    AppLocalizations loc,
    HistoryTripDetailPage page,
  ) {
    final colors = AppThemeColors.of(context);
    final hasPlaces =
        page.insightSubject != null &&
        (page.routeMatch != null ||
            page.insightSubject!.startPoint != null ||
            page.insightSubject!.endPoint != null);
    final match = page.routeMatch;
    final primaryRead = page.insightSelection.primary;
    final primaryLine = insightPhraseText(
      insightPhrase(primaryRead, placeName: match?.to.name),
      loc,
    );

    if (!hasPlaces && primaryLine.isEmpty) return null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasPlaces)
          InsightTripPlaces(
            subject: page.insightSubject!,
            places: page.places,
            match: page.routeMatch,
          ),
        if (primaryLine.isNotEmpty) ...[
          if (hasPlaces) const SizedBox(height: AppSpacing.x1),
          Text(
            primaryLine,
            style: AppText.label.copyWith(color: colors.inkMuted),
            textAlign: TextAlign.end,
          ),
        ],
      ],
    );
  }

  Widget _routeCard(
    BuildContext context,
    List<RouteMapPoint> route, {
    bool square = false,
  }) {
    final loc = AppLocalizations.of(context)!;
    final page = widget.page;
    // The scale is a pure function of the same points the card is given, so
    // both can ask for it and neither has to hand it to the other — which is
    // what lets the card keep the rule that a component takes its text as a
    // parameter.
    final scale = RouteSpeedScale.fromPoints(route);
    return RouteMapCard(
      points: route,
      speedLegend: scale.hasSpeed
          ? RouteSpeedLegend(
              slowLabel: loc.mapSpeedSlow(speedKmhLabel(scale.slowestKmh, loc)),
              fastLabel: loc.mapSpeedFast(speedKmhLabel(scale.fastestKmh, loc)),
            )
          : null,
      // In the drive's column the caller has already decided the width, and
      // at rest that width *is* the square. A charge sits in a row instead,
      // where nothing has decided its width, so there the card decides.
      square: square,
      expanded: _mapExpanded,
      expandLabel: loc.v2HistoryMapExpand,
      collapseLabel: loc.v2HistoryMapCollapse,
      // A drive has a ring above it to grow over. A charge has one position,
      // and a taller strip of map around one pin says nothing more than a
      // square one — so it gets no button.
      onToggleExpanded: page is HistoryTripDetailPage
          ? () => setState(() => _mapExpanded = !_mapExpanded)
          : null,
    );
  }
}
