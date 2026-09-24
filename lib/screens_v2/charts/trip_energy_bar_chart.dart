import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';
import '../energy_bucket_tooltip.dart';
import 'energy_state_band.dart';

/// The pack's energy per interval: what it gave out, stacked, with
/// regeneration hanging below the axis because it is measured against the
/// column rather than being a slice of it.
///
/// Shared by the live energy monitor and a finished drive's history chart.
/// The host decides empty states, growth, and whether the car was parked —
/// this widget only maps buckets onto [EnergyBarChart].
class TripEnergyBarChart extends StatelessWidget {
  const TripEnergyBarChart({
    required this.buckets,
    this.selectedIndex,
    this.onSelected,
    this.parked = false,
    this.labels,
    this.estimated,
    this.openIndex,
    this.growth,
    this.slotWidth,
    this.empty,
    this.semanticsLabel,
    this.timeUnsynced = false,
    super.key,
  });

  final List<EnergyBucket> buckets;
  final int? selectedIndex;
  final ValueChanged<int?>? onSelected;
  final bool parked;
  final List<ContinuousLabel>? labels;
  final List<bool>? estimated;
  final int? openIndex;
  final ChartGrowth? growth;
  final Duration? slotWidth;
  final Widget? empty;
  final String? semanticsLabel;

  /// Time-authority T6: the series still waits for the boot's anchor. The
  /// bars draw exactly as usual — they are ordinal — but a chip says the
  /// axis time is not synced yet, instead of claiming a confident wall time.
  final bool timeUnsynced;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    if (buckets.isEmpty) {
      return empty ??
          Center(child: Text(loc.v2HistoryChartEmpty, style: AppText.caption));
    }

    var peak = 0.0;
    var trough = 0.0;
    for (final bucket in buckets) {
      peak = peak > bucket.drawnWh ? peak : bucket.drawnWh;
      final counterWh = bucket.regeneratedWh + bucket.deliveredWh;
      trough = trough > counterWh ? trough : counterWh;
    }
    final bottom = trough <= 0 ? 0.0 : energyAxisTop(trough / 1000);
    // A window that has only charged or regenerated so far has no draw of its
    // own yet, so `peak` reads zero and `energyAxisTop` falls back to its
    // "nothing recorded" default of one kWh — a scale with no relation to the
    // counter's own size, which draws a real reading as a sliver against the
    // axis. Mirror the counter's scale instead, so the two sides balance.
    final top = peak > 0
        ? energyAxisTop(peak / 1000)
        : (bottom > 0 ? bottom : energyAxisTop(0));
    final labels = this.labels;
    final width = slotWidth ?? buckets.first.width;
    final chart = EnergyBarChart(
      slotCount: buckets.length,
      semanticsLabel: semanticsLabel ?? loc.energyChartSemantics,
      selectedIndex: selectedIndex,
      onSelected: onSelected,
      growth: growth ?? ChartGrowth.settle,
      tooltipBuilder: (context, index) {
        final bucket = buckets[index];
        // A minute the car reported nothing for has no reading to open. It is
        // drawn as a gap, and it must not answer a tap with an empty bubble.
        if (bucket.isEmpty) return const SizedBox.shrink();
        final label = labels?[index];
        // While the series waits for the boot's anchor, slot order is the
        // only honest position: minutes since the series start, never stamps.
        return EnergyBucketTooltip(
          bucket: bucket,
          open: index == openIndex,
          isParked: label == null ? parked : label == ContinuousLabel.parked,
          stateLabel: label,
          estimated: estimated?[index] ?? false,
          relativeStartMinutes: timeUnsynced ? (width * index).inMinutes : null,
          relativeEndMinutes: timeUnsynced
              ? (width * (index + 1)).inMinutes
              : null,
        );
      },
      xTicks: timeUnsynced
          ? buildChartXRelativeTicks(
              bucketWidth: width,
              slotCount: buckets.length,
              labelBuilder: (minutes) => loc.energyAxisRelativeMinutes(minutes),
            )
          : buildChartXTimeTicks(
              domainStart: buckets.first.start,
              bucketWidth: width,
              slotCount: buckets.length,
              labelBuilder: (value) => _chartTimeLabel(context, value),
            ),
      ticks: [
        ChartTick(value: top, label: top.toStringAsFixed(2)),
        ChartTick(value: top / 2, label: (top / 2).toStringAsFixed(2)),
        const ChartTick(value: 0, label: '0.00'),
        if (bottom > 0)
          ChartTick(value: -bottom, label: '+${bottom.toStringAsFixed(2)}'),
      ],
      bars: [
        for (var i = 0; i < buckets.length; i++)
          _bar(
            buckets[i],
            labels == null ? parked : labels[i] == ContinuousLabel.parked,
            estimated?[i] ?? false,
          ),
      ],
    );

    final body = labels == null
        ? chart
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: chart),
              const SizedBox(height: AppSpacing.x2),
              EnergyStateBand(
                labels: labels,
                estimated: estimated,
                slotWidth: slotWidth ?? buckets.first.width,
              ),
            ],
          );
    if (!timeUnsynced) return body;
    // The pending mark never replaces the bars: the consumer keeps working
    // without a trusted time, and says so on the same screen as the data.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const _TimeNotSyncedChip(),
        const SizedBox(height: AppSpacing.x2),
        Flexible(child: body),
      ],
    );
  }

  EnergyBar _bar(EnergyBucket bucket, bool isParked, bool isEstimated) {
    if (bucket.isEmpty) {
      return EnergyBar(
        id: (bucket.start, bucket.width),
        value: double.nan,
        base: double.nan,
        mid: double.nan,
        counter: double.nan,
      );
    }
    final state = isEstimated
        ? EnergyBarState.estimated
        : EnergyBarState.actual;
    final energy = readEnergyComposition([bucket]);
    // Regeneration and a charger's delivered energy are the same thing to the
    // reader — the pack gaining charge — so they share the one counter slot
    // below the axis rather than needing a second green trace.
    final counter = -(bucket.regeneratedWh + bucket.deliveredWh) / 1000;
    if (isParked) {
      return EnergyBar(
        id: (bucket.start, bucket.width),
        value: 0,
        base: energy.system / 1000,
        mid: energy.climate / 1000,
        counter: counter,
        state: state,
      );
    }
    return EnergyBar(
      id: (bucket.start, bucket.width),
      value: bucket.tractionWh / 1000,
      base: energy.system / 1000,
      mid: energy.climate / 1000,
      counter: counter,
      state: state,
    );
  }
}

/// Time-authority T6: the "time not synced" mark. An amber caption, never a
/// second chart and never an empty state — the bars above carry the measured
/// energy, and this line says the axis time still waits for the boot's anchor.
class _TimeNotSyncedChip extends StatelessWidget {
  const _TimeNotSyncedChip();

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.schedule,
          size: AppSizes.iconSm,
          color: AppThemeColors.of(context).energy.warning,
        ),
        const SizedBox(width: AppSpacing.x1),
        Flexible(
          child: Text(
            loc.v2TimeNotSynced,
            style: AppText.label.copyWith(
              color: AppThemeColors.of(context).energy.warning,
            ),
          ),
        ),
      ],
    );
  }
}

String _chartTimeLabel(BuildContext context, DateTime value) {
  return MaterialLocalizations.of(context).formatTimeOfDay(
    TimeOfDay.fromDateTime(value),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
}
