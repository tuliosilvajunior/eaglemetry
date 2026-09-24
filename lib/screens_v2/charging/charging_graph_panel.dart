import 'package:flutter/material.dart';

import '../../core/charge_graph_data.dart';
import '../../core/telemetry_api.dart';
import '../../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';
import '../charge_cost_editor.dart';
import '../charts/charge_session_chart.dart';
import 'charging_constants.dart';
import 'charging_format.dart';

/// Empty, loading and live states of the charge graph tab.
class ChargeGraphPanel extends StatelessWidget {
  const ChargeGraphPanel({
    required this.session,
    required this.detail,
    required this.recentHistory,
    required this.defaultCostPerKwh,
    required this.chargeCostCurrency,
    required this.savingCost,
    required this.onCostChanged,
    required this.loading,
    required this.failed,
    required this.selectedIndex,
    required this.dismissed,
    required this.onSelected,
    super.key,
  });

  final SessionRecord? session;
  final ChargeDetailReading? detail;
  final RecentTripEfficiency? recentHistory;
  final double? defaultCostPerKwh;
  final String chargeCostCurrency;

  /// True while a price write is in flight. The keypad stays shut until the
  /// collector has answered, so two prices cannot race for one session.
  final bool savingCost;

  final ValueChanged<MoneyKeypadResult<ChargeCostField>> onCostChanged;
  final bool loading;
  final bool failed;
  final int? selectedIndex;

  /// See `ChargingV2ScreenState`'s graph-dismissed flag.
  final bool dismissed;
  final ValueChanged<int?> onSelected;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (failed) {
      return ChargeGraphMessage(message: loc.v2ChargeGraphLoadFailed);
    }
    final session = this.session;
    final detail = this.detail;
    if (session == null || detail == null) {
      return ChargeGraphMessage(message: loc.v2ChargeGraphEmpty);
    }

    final graph = buildChargeGraphData(
      detail: detail,
      duration: chargeWindow(session),
    );
    if (graph.isEmpty) {
      return ChargeGraphMessage(message: loc.v2ChargeGraphNoData);
    }
    return _ChargeGraph(
      session: session,
      detail: detail,
      recentHistory: recentHistory,
      defaultCostPerKwh: defaultCostPerKwh,
      chargeCostCurrency: chargeCostCurrency,
      savingCost: savingCost,
      onCostChanged: onCostChanged,
      selectedIndex: selectedIndex,
      dismissed: dismissed,
      onSelected: onSelected,
    );
  }
}

class _ChargeGraph extends StatelessWidget {
  const _ChargeGraph({
    required this.session,
    required this.detail,
    required this.recentHistory,
    required this.defaultCostPerKwh,
    required this.chargeCostCurrency,
    required this.savingCost,
    required this.onCostChanged,
    required this.selectedIndex,
    required this.dismissed,
    required this.onSelected,
  });

  final SessionRecord session;
  final ChargeDetailReading detail;
  final RecentTripEfficiency? recentHistory;
  final double? defaultCostPerKwh;
  final String chargeCostCurrency;

  /// True while a price write is in flight. The keypad stays shut until the
  /// collector has answered, so two prices cannot race for one session.
  final bool savingCost;

  final ValueChanged<MoneyKeypadResult<ChargeCostField>> onCostChanged;
  final int? selectedIndex;

  /// See `ChargingV2ScreenState`'s graph-dismissed flag.
  final bool dismissed;
  final ValueChanged<int?> onSelected;

  @override
  Widget build(BuildContext context) {
    final startMillis =
        session.chargeStartedAtUtcMillis ?? session.startedAtUtcMillis;
    final start = DateTime.fromMillisecondsSinceEpoch(startMillis);
    return Column(
      children: [
        Expanded(
          child: ChargeSessionChart(
            detail: detail,
            sessionId: session.id,
            duration: chargeWindow(session),
            windowStart: start,
            selectedIndex: selectedIndex,
            onSelected: onSelected,
            // One travel lasts until the next detail poll, so a running
            // session climbs without pausing between reads.
            growth: const ChartGrowth.chase(chargeDetailLiveInterval),
            overlayAnchor: chargeSessionIsActive(session)
                ? ChartOverlayAnchor.start
                : ChartOverlayAnchor.both,
            showXTicks: true,
            fallbackToLatest: true,
            dismissed: dismissed,
          ),
        ),
        const SizedBox(height: AppSpacing.x3),
        _ChargeGraphFooter(
          session: session,
          detail: detail,
          recentHistory: recentHistory,
          defaultCostPerKwh: defaultCostPerKwh,
          chargeCostCurrency: chargeCostCurrency,
          savingCost: savingCost,
          onCostChanged: onCostChanged,
        ),
      ],
    );
  }
}

class _ChargeGraphFooter extends StatelessWidget {
  const _ChargeGraphFooter({
    required this.session,
    required this.detail,
    required this.recentHistory,
    required this.defaultCostPerKwh,
    required this.chargeCostCurrency,
    required this.savingCost,
    required this.onCostChanged,
  });

  final SessionRecord session;
  final ChargeDetailReading detail;
  final RecentTripEfficiency? recentHistory;
  final double? defaultCostPerKwh;
  final String chargeCostCurrency;

  /// True while a price write is in flight. The keypad stays shut until the
  /// collector has answered, so two prices cannot race for one session.
  final bool savingCost;

  final ValueChanged<MoneyKeypadResult<ChargeCostField>> onCostChanged;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final energy =
        detail.estimatedEnergyKwh ??
        sessionReadingDeliveredKwh(session).displayValue;
    // Shares the plausibility bounds with the range panels, so this footer
    // cannot present a confident gain from an efficiency the rest of the
    // screen already treats as untrustworthy.
    final range = estimateRangeGainKm(
      history: recentHistory,
      energyKwh: energy,
    );
    final rate = session.costPerKwh ?? defaultCostPerKwh;
    final cost = chargeEstimatedCost(
      energyKwh: energy,
      costPerKwh: rate,
      paidAmount: null,
    );
    final currency = chargeCostCurrencyOf(
      session,
      fallback: chargeCostCurrency,
    );
    final symbol = chargeCurrencySymbolForLocale(
      loc.localeName,
      fallbackCurrency: currency,
    );
    final duration = chargingDuration(session, detail);
    final targetReachedAt = chargeTargetReachedAt(detail);

    // Every column carries the padding the editable one needs for its
    // surface, so the tinted stat does not sit a step below its neighbours.
    const statPadding = EdgeInsets.symmetric(
      horizontal: AppSpacing.x3,
      vertical: AppSpacing.x2,
    );
    return Row(
      children: [
        Expanded(
          child: Padding(
            padding: statPadding,
            child: StatColumn(
              value: range == null ? '--' : '+${range.round()}',
              unit: range == null ? null : loc.unitKm,
              caption: loc.v2ChargeGraphRangeGainedEstimate,
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: statPadding,
            child: StatColumn(
              value: energy == null ? '--' : '+${energy.toStringAsFixed(1)}',
              unit: energy == null ? null : loc.unitKwh,
              caption: loc.v2ChargeGraphEnergyAdded,
            ),
          ),
        ),
        Expanded(
          child: ChargeCostStat(
            session: session,
            defaultCostPerKwh: defaultCostPerKwh,
            cost: cost,
            symbol: symbol,
            saving: savingCost,
            onCostChanged: onCostChanged,
          ),
        ),
        Expanded(
          child: Padding(
            padding: statPadding,
            child: StatColumn(
              value: chargeDurationLabel(loc, duration),
              caption: loc.v2ChargeGraphDuration,
            ),
          ),
        ),
        if (targetReachedAt != null)
          Expanded(
            child: Padding(
              padding: statPadding,
              child: StatColumn(
                value: chargeTimeOfDayLabel(context, targetReachedAt),
                caption: loc.v2ChargeGraphTargetReached,
              ),
            ),
          ),
      ],
    );
  }
}
