import 'package:flutter/material.dart';

import '../../core/charge_graph_data.dart';
import '../../core/telemetry_api.dart';
import '../../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';

/// A charge session as SOC columns with measured power as the curve over them.
///
/// Shared by the live charging graph and a past charge in History. The host
/// decides the plotted window, whether the session is still climbing, and
/// which chrome sits around the plot — this widget only builds the chart.
class ChargeSessionChart extends StatelessWidget {
  const ChargeSessionChart({
    required this.detail,
    required this.sessionId,
    this.duration,
    this.windowStart,
    this.selectedIndex,
    this.onSelected,
    this.growth,
    this.overlayAnchor = ChartOverlayAnchor.both,
    this.cornerCaption,
    this.showXTicks = false,
    this.fallbackToLatest = false,
    this.dismissed = false,
    this.empty,
    super.key,
  });

  final ChargeDetailReading detail;
  final String sessionId;

  /// The plug-in window the columns cover. Null leaves the window to the
  /// series — a live session that has not unplugged yet.
  final Duration? duration;

  /// Clock time the plotted window opens. Tooltips and x-ticks are offsets
  /// from it. Null hides the clock row rather than inventing a start.
  final DateTime? windowStart;

  final int? selectedIndex;
  final ValueChanged<int?>? onSelected;

  /// Live charging chases the next detail poll. A closed session settles.
  final ChartGrowth? growth;

  final ChartOverlayAnchor overlayAnchor;
  final String? cornerCaption;

  /// The live graph labels the domain. History does not: its card already
  /// names when the session was.
  final bool showXTicks;

  /// When true and [selectedIndex] is null, the newest column is selected.
  /// Closing a reading is [dismissed], not a null index — a live charge
  /// resting on its latest column is not "nothing chosen".
  final bool fallbackToLatest;
  final bool dismissed;

  final Widget? empty;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return LayoutBuilder(
      builder: (context, constraints) {
        // One profile serves both the bucket count and the drawing, so the
        // two cannot disagree.
        const profile = AppSizes.chartDenseBarProfile;
        final capacity = profile.slotsIn(
          constraints.maxWidth - AppSizes.chartAxisGutter,
        );
        final graph = buildChargeGraphData(
          detail: detail,
          duration: duration,
          capacity: capacity,
        );
        if (graph.isEmpty) {
          return empty ??
              Center(
                child: Text(loc.v2HistoryChartEmpty, style: AppText.caption),
              );
        }
        final lastIndex = graph.buckets.length - 1;
        final activeSelection = dismissed
            ? null
            : fallbackToLatest
            ? (selectedIndex ?? lastIndex).clamp(0, lastIndex)
            : selectedIndex;
        final start = windowStart;
        return EnergyBarChart(
          positiveColor: AppThemeColors.of(context).energy.gain,
          growth: growth ?? ChartGrowth.settle,
          slotCount: capacity,
          profile: profile,
          semanticsLabel: loc.v2ChargeGraphSemantics,
          selectedIndex: activeSelection,
          onSelected: onSelected,
          cornerCaption: cornerCaption,
          overlayAnchor: overlayAnchor,
          xTicks: showXTicks && start != null
              ? _xTicks(context, start, graph, capacity)
              : const [],
          tooltipBuilder: (context, index) {
            final bucket = graph.buckets[index];
            return ChartTooltip(
              side: ChartTooltipSide.none,
              value: bucket.socPercent?.toStringAsFixed(1) ?? '--',
              unit: bucket.socPercent == null ? null : loc.unitPercent,
              rows: [
                ChartTooltipRow(
                  label: bucket.powerKw == null
                      ? '-- ${loc.unitKw}'
                      : '${bucket.powerKw!.toStringAsFixed(1)} ${loc.unitKw}',
                ),
                if (start != null)
                  ChartTooltipRow(label: _bucketWindow(context, start, bucket)),
              ],
            );
          },
          bars: [
            for (final bucket in graph.buckets)
              EnergyBar(
                id: (sessionId, bucket.startSeconds, graph.intervalSeconds),
                value: bucket.socPercent ?? double.nan,
                state: bucket.isHeld
                    ? EnergyBarState.held
                    : EnergyBarState.actual,
              ),
          ],
          ticks: [
            for (final tick in graph.powerTicksKw)
              ChartTick(
                value: chargePowerPlotValue(
                  tick,
                  ceilingKw: graph.axisMaximumKw,
                ),
                label: loc.v2ChargeGraphPowerTick(tick.round()),
              ),
          ],
          overlay: [
            for (final bucket in graph.buckets)
              bucket.powerKw == null
                  ? double.nan
                  : chargePowerPlotValue(
                      bucket.powerKw!,
                      ceilingKw: graph.axisMaximumKw,
                    ),
          ],
        );
      },
    );
  }

  List<ChartXTick> _xTicks(
    BuildContext context,
    DateTime start,
    ChargeGraphData graph,
    int slotCount,
  ) {
    if (slotCount <= 0) return const [];
    return buildChartXTimeTicks(
      domainStart: start,
      bucketWidth: Duration(seconds: graph.intervalSeconds),
      slotCount: slotCount,
      labelBuilder: (value) => _chartTimeLabel(context, value),
    );
  }

  String _bucketWindow(
    BuildContext context,
    DateTime start,
    ChargeGraphBucket bucket,
  ) {
    final from = start.add(
      Duration(milliseconds: (bucket.startSeconds * 1000).round()),
    );
    final to = start.add(
      Duration(milliseconds: (bucket.endSeconds * 1000).round()),
    );
    return '${_chartTimeLabel(context, from)}–${_chartTimeLabel(context, to)}';
  }
}

String _chartTimeLabel(BuildContext context, DateTime value) {
  return MaterialLocalizations.of(context).formatTimeOfDay(
    TimeOfDay.fromDateTime(value),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
}
