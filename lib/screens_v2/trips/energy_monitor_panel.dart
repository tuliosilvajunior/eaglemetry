import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../../core/efficiency_unit.dart';
import '../../core/energy_monitor_controller.dart';
import '../../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';
import '../charts/trip_energy_bar_chart.dart';

/// The `Energy use` card: the chart, its window selector and the trip stats.
///
/// Everything it draws comes from [EnergyMonitorController]; it holds no series
/// of its own, so the bars, the axis and the stats can never disagree about
/// which stretch of driving is on screen.
class EnergyUsePanel extends StatelessWidget {
  const EnergyUsePanel({
    required this.controller,
    required this.selectedIndex,
    required this.onSelected,
    super.key,
  });

  final EnergyMonitorController controller;

  /// Bar the reader has pinned, or null. Held by the screen so it survives the
  /// once-a-second rebuild the live poll causes.
  final int? selectedIndex;
  final ValueChanged<int?> onSelected;

  /// Card width below which the track control cannot share the header row.
  ///
  /// The control is as wide as its two localized labels, so the number is set
  /// by the longest of them: 429 px in Portuguese against 283 in English. With
  /// the info button and the title's own minimum beside it, anything narrower
  /// than this leaves the header overflowing rather than merely tight, and the
  /// control drops to its own row above the plot. The car is 1920 px wide and
  /// never reaches that fallback; the test viewports do.
  static const double _headerTrackMinWidth = 700;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final showTrack = controller.hasParkedData;
        final trackInHeader =
            showTrack && constraints.maxWidth >= _headerTrackMinWidth;
        final control = showTrack
            ? TrackSegmentedControl<EnergyTrack>(
                selected: controller.track,
                onSelected: controller.selectTrack,
                items: [
                  TabItem(value: EnergyTrack.drive, label: loc.energyModeDrive),
                  TabItem(
                    value: EnergyTrack.parked,
                    label: loc.energyModeParked,
                  ),
                ],
              )
            : null;
        return _buildCard(context, loc, control, trackInHeader: trackInHeader);
      },
    );
  }

  Widget _buildCard(
    BuildContext context,
    AppLocalizations loc,
    Widget? control, {
    required bool trackInHeader,
  }) {
    return AppCard(
      title: loc.energyUseTitle,
      // The control rides in the header rather than above the plot, so the
      // chart keeps the full height of the card. It sits inside the header's
      // right-aligned slot, which is what puts it beside the info button
      // instead of across from the title.
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Only when the window holds parked minutes. A toggle with a dead
          // option is worse than no toggle.
          if (trackInHeader && control != null) ...[
            control,
            const SizedBox(width: AppSpacing.x3),
          ],
          InfoIconButton(onPressed: () {}, tooltip: loc.energyUseAbout),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!trackInHeader && control != null) ...[
            Align(alignment: Alignment.centerRight, child: control),
            const SizedBox(height: AppSpacing.x4),
          ],
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // The bar budget is a property of the room on screen, so the
                // bucket width is resolved here rather than being decided
                // before the layout is known.
                final series = controller.seriesForChartWidth(
                  constraints.maxWidth,
                  capacity: AppSizes.chartBarProfile.slotsIn(
                    constraints.maxWidth - AppSizes.chartAxisGutter,
                  ),
                );
                return _EnergyChart(
                  series: series,
                  track: controller.track,
                  // The chart's growth has to match the cadence that feeds it,
                  // and the controller is the only thing that knows it.
                  readingPeriod: controller.livePollInterval,
                  loading: controller.isLoading,
                  failed: controller.hasFailed,
                  selectedIndex: selectedIndex,
                  onSelected: onSelected,
                );
              },
            ),
          ),
          const SizedBox(height: AppSpacing.x4),
          _EnergyFooter(controller: controller),
        ],
      ),
    );
  }
}

class _EnergyFooter extends StatelessWidget {
  const _EnergyFooter({required this.controller});

  final EnergyMonitorController controller;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    // "Since power on" spans trips, charges and parked stretches at once, so
    // the drive figures below — questions about one trip's own movement —
    // do not apply. The ledger is the row that does.
    if (controller.window == EnergyWindow.sincePowerOn) {
      return _LedgerFooter(controller: controller);
    }
    // The drive figures are questions about movement. Under parked bars they
    // would all read `--`, which looks like a broken screen rather than like a
    // question that does not apply, so that track is scored by its own row.
    if (controller.track.isParked) {
      return _ParkedFooter(controller: controller);
    }
    final stats = controller.selectedStats;
    final efficiency = stats?.measuredKmPerKwh;
    final distance = stats?.distanceKm;
    final averageSpeed = stats?.averageSpeedKmh;
    final estimatedCost = stats?.estimatedCost;
    final currencySymbol = chargeCurrencySymbolForLocale(
      Localizations.localeOf(context).toLanguageTag(),
      fallbackCurrency: stats?.costCurrency ?? 'BRL',
    );

    const middleStatWidth = 120.0;
    const costStatWidth = 120.0;
    const minimumGap = AppSpacing.x4;
    const minimumContentWidth =
        AppSizes.energyWindowFieldWidth +
        middleStatWidth * 3 +
        costStatWidth +
        minimumGap * 4;

    return ListenableBuilder(
      listenable: EfficiencyUnitController.instance,
      builder: (context, _) => _buildRow(
        context,
        loc,
        efficiency: efficiency,
        distance: distance,
        averageSpeed: averageSpeed,
        estimatedCost: estimatedCost,
        currencySymbol: currencySymbol,
        middleStatWidth: middleStatWidth,
        costStatWidth: costStatWidth,
        minimumGap: minimumGap,
        minimumContentWidth: minimumContentWidth,
      ),
    );
  }

  Widget _buildRow(
    BuildContext context,
    AppLocalizations loc, {
    required double? efficiency,
    required double? distance,
    required double? averageSpeed,
    required double? estimatedCost,
    required String currencySymbol,
    required double middleStatWidth,
    required double costStatWidth,
    required double minimumGap,
    required double minimumContentWidth,
  }) {
    final unit = EfficiencyUnitController.instance.unit;
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = math.max(
          constraints.maxWidth,
          minimumContentWidth,
        );
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: contentWidth,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _WindowSelector(controller: controller),
                SizedBox(
                  width: middleStatWidth,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => EfficiencyUnitController.instance.cycle(),
                    child: StatColumn(
                      value: formatEfficiencyForUnit(efficiency, unit),
                      unit: efficiencyUnitSuffix(unit, loc),
                      caption: loc.energyStatEfficiency,
                    ),
                  ),
                ),
                SizedBox(
                  width: middleStatWidth,
                  child: StatColumn(
                    value: distance?.toStringAsFixed(1) ?? '--',
                    unit: loc.unitKm,
                    caption: loc.energyStatDistance,
                  ),
                ),
                SizedBox(
                  width: middleStatWidth,
                  child: StatColumn(
                    value: averageSpeed?.round().toString() ?? '--',
                    unit: loc.unitKmh,
                    caption: loc.energyStatSpeed,
                  ),
                ),
                SizedBox(
                  width: costStatWidth,
                  child: StatColumn(
                    value: estimatedCost == null
                        ? '--'
                        : '$currencySymbol ${estimatedCost.toStringAsFixed(2)}',
                    caption: loc.energyStatCost,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The parked track's own stats row.
///
/// The window selector stays: the reader is looking at the same stretch of
/// clock either way, and losing the selector on one track would make the two
/// answer over different spans.
class _ParkedFooter extends StatelessWidget {
  const _ParkedFooter({required this.controller});

  final EnergyMonitorController controller;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final stats = controller.parkedStats;
    final currencySymbol = chargeCurrencySymbolForLocale(
      Localizations.localeOf(context).toLanguageTag(),
      fallbackCurrency: stats?.costCurrency ?? 'BRL',
    );

    const statWidth = 120.0;
    const minimumGap = AppSpacing.x4;
    const minimumContentWidth =
        AppSizes.energyWindowFieldWidth + statWidth * 4 + minimumGap * 4;

    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = math.max(
          constraints.maxWidth,
          minimumContentWidth,
        );
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: contentWidth,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _WindowSelector(controller: controller),
                SizedBox(
                  width: statWidth,
                  child: StatColumn(
                    value: stats?.averageDrainW?.round().toString() ?? '--',
                    unit: loc.unitWatt,
                    caption: loc.energyStatParkedDrain,
                  ),
                ),
                SizedBox(
                  width: statWidth,
                  child: StatColumn(
                    value: stats?.totalEnergyKwh?.toStringAsFixed(2) ?? '--',
                    unit: loc.unitKwh,
                    caption: loc.energyStatParkedTotal,
                  ),
                ),
                SizedBox(
                  width: statWidth,
                  child: StatColumn(
                    // Absent rather than zero when the split was not measured
                    // whole. The reader is never told the heater drew nothing
                    // over minutes nobody measured.
                    value: stats?.climateShareKwh?.toStringAsFixed(2) ?? '--',
                    unit: loc.unitKwh,
                    caption: loc.energyStatParkedClimate,
                  ),
                ),
                SizedBox(
                  width: statWidth,
                  child: StatColumn(
                    value: stats?.estimatedCost == null
                        ? '--'
                        : '$currencySymbol '
                              '${stats!.estimatedCost!.toStringAsFixed(2)}',
                    caption: loc.energyStatCost,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// "Since power on"'s own footer: what the pack gained, what it spent, and
/// the balance — the plain ledger a bar chart's flattened axis cannot answer.
/// See issue 199/210.
class _LedgerFooter extends StatelessWidget {
  const _LedgerFooter({required this.controller});

  final EnergyMonitorController controller;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final stats = controller.ledgerStats;

    // Wider than the other footers' 120: a signed balance and an arrow SOC
    // range both run a little longer than "8.88 kWh".
    const statWidth = 132.0;
    const minimumGap = AppSpacing.x4;
    const minimumContentWidth =
        AppSizes.energyWindowFieldWidth + statWidth * 4 + minimumGap * 4;

    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = math.max(
          constraints.maxWidth,
          minimumContentWidth,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: contentWidth,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _WindowSelector(controller: controller),
                    SizedBox(
                      width: statWidth,
                      child: StatColumn(
                        // Unsigned: "In" already says the direction, the way
                        // the parked footer's own totals carry no sign
                        // either.
                        value: stats == null
                            ? '--'
                            : (stats.inWh / 1000).toStringAsFixed(2),
                        unit: loc.unitKwh,
                        caption: loc.energyLedgerIn,
                      ),
                    ),
                    SizedBox(
                      width: statWidth,
                      child: StatColumn(
                        value: stats == null
                            ? '--'
                            : (stats.outWh / 1000).toStringAsFixed(2),
                        unit: loc.unitKwh,
                        caption: loc.energyLedgerOut,
                      ),
                    ),
                    SizedBox(
                      width: statWidth,
                      child: StatColumn(
                        // `toStringAsFixed` already carries the minus sign
                        // for a net loss; a gain needs no plus to be told
                        // apart from one, and a leading "+" is one character
                        // this column does not have the room for.
                        value: stats == null
                            ? '--'
                            : (stats.balanceWh / 1000).toStringAsFixed(2),
                        unit: loc.unitKwh,
                        caption: loc.energyLedgerBalance,
                      ),
                    ),
                    SizedBox(
                      width: statWidth,
                      child: StatColumn(
                        value:
                            stats == null ||
                                (stats.startSoc == null && stats.endSoc == null)
                            ? '--'
                            : '${stats.startSoc?.round() ?? '--'}→'
                                  '${stats.endSoc?.round() ?? '--'}',
                        unit: loc.unitPercent,
                        caption: loc.energyLedgerSoc,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (stats?.includesEstimate ?? false)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.x1),
                child: Text(
                  loc.energyLedgerIncludesEstimate,
                  style: AppText.caption.copyWith(
                    color: AppThemeColors.of(context).inkSubtle,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _EnergyChart extends StatelessWidget {
  const _EnergyChart({
    required this.series,
    required this.track,
    required this.readingPeriod,
    required this.loading,
    required this.failed,
    required this.selectedIndex,
    required this.onSelected,
  });

  final EnergyChartSeries series;
  final EnergyTrack track;

  /// How often the live poll delivers a new reading into the open bucket.
  final Duration readingPeriod;

  final bool loading;
  final bool failed;
  final int? selectedIndex;
  final ValueChanged<int?> onSelected;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;

    // Three empty states, never the same one. A read that failed is a broken
    // pool; an empty window is a car that did not drive; loading is neither.
    if (failed) return _ChartMessage(text: loc.energyChartFailed);
    if (loading && series.isEmpty) {
      return _ChartMessage(text: loc.energyChartLoading);
    }
    if (series.isEmpty) {
      return _ChartMessage(
        text: track.isParked
            ? loc.energyChartEmptyParked
            : loc.energyChartEmpty,
      );
    }

    return TripEnergyBarChart(
      buckets: series.buckets,
      selectedIndex: selectedIndex,
      onSelected: onSelected,
      parked: track.isParked,
      labels: series.labels,
      estimated: series.estimated,
      openIndex: series.openIndex,
      timeUnsynced: series.timePending,
      growth: track.isParked
          ? ChartGrowth.settle
          : ChartGrowth.chase(readingPeriod),
      slotWidth: series.width,
    );
  }
}

class _ChartMessage extends StatelessWidget {
  const _ChartMessage({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(text, style: AppText.caption, textAlign: TextAlign.center),
    );
  }
}

class _WindowSelector extends StatelessWidget {
  const _WindowSelector({required this.controller});

  final EnergyMonitorController controller;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return DropdownField<EnergyWindow>(
      value: controller.window,
      width: AppSizes.energyWindowFieldWidth,
      barrierLabel: loc.energyWindowSelector,
      onChanged: controller.selectWindow,
      options: [
        for (final window in controller.availableWindows)
          DropdownOption(value: window, label: energyWindowLabel(loc, window)),
      ],
    );
  }
}

/// The selector's labels. Kept beside the panel so a new window cannot be added
/// to the enum without a localized name being chosen for it.
String energyWindowLabel(AppLocalizations loc, EnergyWindow window) {
  return switch (window) {
    EnergyWindow.currentDrive => loc.energyWindowCurrentDrive,
    EnergyWindow.sincePowerOn => loc.energyWindowSincePowerOn,
    EnergyWindow.last15Minutes => loc.energyWindowLast15Minutes,
    EnergyWindow.lastHour => loc.energyWindowLastHour,
    EnergyWindow.last8Hours => loc.energyWindowLast8Hours,
  };
}
