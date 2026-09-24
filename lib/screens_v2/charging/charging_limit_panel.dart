import 'package:flutter/material.dart';

import '../../core/charge_climate_warning.dart';
import '../../core/telemetry_api.dart';
import '../../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';
import '../charge_cost_editor.dart';
import 'charging_constants.dart';
import 'charging_graph_panel.dart';

/// The middle card: level slider (if external charge control is enabled) or graph,
/// with the climate warning above it.
class ChargingLimitPanel extends StatelessWidget {
  const ChargingLimitPanel({
    required this.climateWarning,
    required this.climateKw,
    required this.chargingPowerKw,
    required this.session,
    required this.detail,
    required this.recentHistory,
    required this.defaultCostPerKwh,
    required this.chargeCostCurrency,
    required this.savingCost,
    required this.onCostChanged,
    required this.graphLoading,
    required this.graphFailed,
    required this.graphSelection,
    required this.graphDismissed,
    required this.onGraphSelected,
    this.externalChargeControlEnabled = false,
    this.tab = ChargePanelTab.level,
    this.onTabSelected,
    this.target = 80.0,
    this.onTargetChanged,
    this.onTargetDraggingChanged,
    this.onPresetSelected,
    this.currentSoc,
    this.isCharging = false,
    this.projectedRangeKm,
    this.dragging = false,
    super.key,
  });

  final bool externalChargeControlEnabled;
  final ChargePanelTab tab;
  final ValueChanged<ChargePanelTab>? onTabSelected;
  final double target;
  final ValueChanged<double>? onTargetChanged;
  final ValueChanged<bool>? onTargetDraggingChanged;
  final ValueChanged<int>? onPresetSelected;
  final double? currentSoc;
  final bool isCharging;
  final double? projectedRangeKm;
  final bool dragging;

  /// How much of the charging rate the climate package is taking.
  final ChargeClimateWarning climateWarning;

  /// The rate behind that reading, for the banner to state. Null whenever
  /// [climateWarning] is `none`, because nothing is then being claimed.
  final double? climateKw;

  final double? chargingPowerKw;

  final SessionRecord? session;
  final ChargeDetailReading? detail;
  final RecentTripEfficiency? recentHistory;
  final double? defaultCostPerKwh;
  final String chargeCostCurrency;

  /// True while a price write is in flight. The keypad stays shut until the
  /// collector has answered, so two prices cannot race for one session.
  final bool savingCost;

  final ValueChanged<MoneyKeypadResult<ChargeCostField>> onCostChanged;
  final bool graphLoading;
  final bool graphFailed;
  final int? graphSelection;

  /// See `ChargingV2ScreenState`'s graph-dismissed flag.
  final bool graphDismissed;
  final ValueChanged<int?> onGraphSelected;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final showBanner = climateWarning.isWarning && climateKw != null;

    final Widget cardBody;
    // Two conditions, and both must hold. The switch says the reader asked
    // for control; the callback says there is somewhere for a command to go.
    if (externalChargeControlEnabled && onTargetChanged != null) {
      cardBody = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextTabBar<ChargePanelTab>(
                  items: [
                    TabItem(
                      value: ChargePanelTab.level,
                      label: loc.v2ChargeLimitLevel,
                    ),
                    TabItem(
                      value: ChargePanelTab.graph,
                      label: loc.v2ChargeLimitGraph,
                    ),
                  ],
                  selected: tab,
                  onSelected: onTabSelected ?? (_) {},
                ),
              ),
              const _ChargeLimitInformationButton(),
            ],
          ),
          const SizedBox(height: AppSpacing.x4),
          Expanded(
            child: tab == ChargePanelTab.level
                ? _LevelContent(
                    target: target,
                    currentSoc: currentSoc,
                    isCharging: isCharging,
                    chargingPowerKw: chargingPowerKw,
                    projectedRangeKm: projectedRangeKm,
                    // The knob is live only when the owner gave a way to
                    // write the target. Without one there is nothing to
                    // move it to, so it reads rather than accepts input.
                    enabled: onTargetChanged != null,
                    dragging: dragging,
                    onTargetChanged: onTargetChanged ?? (_) {},
                    onTargetDraggingChanged: onTargetDraggingChanged ?? (_) {},
                    onPresetSelected: onPresetSelected ?? (_) {},
                  )
                : ChargeGraphPanel(
                    session: session,
                    detail: detail,
                    recentHistory: recentHistory,
                    defaultCostPerKwh: defaultCostPerKwh,
                    chargeCostCurrency: chargeCostCurrency,
                    savingCost: savingCost,
                    onCostChanged: onCostChanged,
                    loading: graphLoading,
                    failed: graphFailed,
                    selectedIndex: graphSelection,
                    dismissed: graphDismissed,
                    onSelected: onGraphSelected,
                  ),
          ),
        ],
      );
    } else {
      cardBody = ChargeGraphPanel(
        session: session,
        detail: detail,
        recentHistory: recentHistory,
        defaultCostPerKwh: defaultCostPerKwh,
        chargeCostCurrency: chargeCostCurrency,
        savingCost: savingCost,
        onCostChanged: onCostChanged,
        loading: graphLoading,
        failed: graphFailed,
        selectedIndex: graphSelection,
        dismissed: graphDismissed,
        onSelected: onGraphSelected,
      );
    }

    final card = AppCard(child: cardBody);
    if (!showBanner) return card;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ChargeClimateWarningBanner(
          level: climateWarning,
          climateKw: climateKw!,
          chargingPowerKw: chargingPowerKw,
        ),
        const SizedBox(height: AppSpacing.x4),
        Expanded(child: card),
      ],
    );
  }
}

/// The climate-share warning, in the words the driver reads.
class _ChargeClimateWarningBanner extends StatelessWidget {
  const _ChargeClimateWarningBanner({
    required this.level,
    required this.climateKw,
    required this.chargingPowerKw,
  });

  final ChargeClimateWarning level;
  final double climateKw;
  final double? chargingPowerKw;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final climate = climateKw.toStringAsFixed(1);
    final message = switch (level) {
      ChargeClimateWarning.outweighs => loc.v2ChargeClimateWarningOutweighs(
        climate,
      ),
      _ => loc.v2ChargeClimateWarningHigh(
        climate,
        (chargingPowerKw ?? 0).toStringAsFixed(1),
      ),
    };
    return BreathingWarningBanner(
      icon: Icons.thermostat,
      title: loc.v2ChargeClimateWarningTitle,
      message: message,
      color: level == ChargeClimateWarning.outweighs
          ? AppThemeColors.of(context).energy.critical
          : AppThemeColors.of(context).energy.warning,
    );
  }
}

class _LevelContent extends StatelessWidget {
  const _LevelContent({
    required this.target,
    required this.currentSoc,
    required this.isCharging,
    required this.chargingPowerKw,
    required this.projectedRangeKm,
    required this.enabled,
    required this.dragging,
    required this.onTargetChanged,
    required this.onTargetDraggingChanged,
    required this.onPresetSelected,
  });

  final double target;
  final double? currentSoc;
  final bool isCharging;
  final double? chargingPowerKw;
  final double? projectedRangeKm;
  final bool enabled;

  /// True while the user is moving the charge-limit knob.
  final bool dragging;
  final ValueChanged<double> onTargetChanged;
  final ValueChanged<bool> onTargetDraggingChanged;
  final ValueChanged<int> onPresetSelected;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final targetPercent = target.round();
    final customSelected =
        dragging || !chargeLimitNamedPresets.contains(targetPercent);
    final customTarget = customSelected ? targetPercent : 50;
    final projection = projectedRangeKm?.round().toString() ?? '--';
    return Semantics(
      enabled: enabled,
      child: IgnorePointer(
        ignoring: !enabled,
        child: AnimatedOpacity(
          duration: AppMotion.fast,
          opacity: enabled ? 1 : 0.55,
          child: Column(
            children: [
              const Spacer(),
              SizedBox(
                height:
                    AppSizes.minTouchTarget +
                    AppSpacing.x2 +
                    AppSizes.limitSliderHeight,
                child: LimitSlider(
                  value: target,
                  current: currentSoc,
                  isCharging: isCharging,
                  chargingPowerKw: chargingPowerKw,
                  currentLabel: currentSoc?.toStringAsFixed(1),
                  currentUnit: loc.unitPercent,
                  valueLabel: targetPercent.toString(),
                  valueUnit: loc.unitPercent,
                  caption: loc.v2ChargeLimitProjection(projection, loc.unitKm),
                  semanticsLabel: loc.v2ChargeLimitSemantics,
                  semanticsValue: loc.v2ChargeLimitSemanticsValue(
                    targetPercent,
                  ),
                  increasedValue: loc.v2ChargeLimitSemanticsValue(
                    (target + 5).clamp(50, 100).round(),
                  ),
                  decreasedValue: loc.v2ChargeLimitSemanticsValue(
                    (target - 5).clamp(50, 100).round(),
                  ),
                  onChanged: onTargetChanged,
                  onDraggingChanged: onTargetDraggingChanged,
                ),
              ),
              const Spacer(),
              Row(
                children: [
                  _preset(
                    value: loc.helpersChargeLimitValue(customTarget),
                    label: loc.v2ChargeLimitCustom,
                    selected: customSelected,
                    target: customTarget,
                  ),
                  _preset(
                    value: loc.helpersChargeLimitValue(chargeLimitDailyPreset),
                    label: loc.v2ChargeLimitDaily,
                    selected:
                        !dragging && targetPercent == chargeLimitDailyPreset,
                    target: chargeLimitDailyPreset,
                  ),
                  _preset(
                    value: loc.helpersChargeLimitValue(
                      chargeLimitExtendedPreset,
                    ),
                    label: loc.v2ChargeLimitExtended,
                    selected:
                        !dragging && targetPercent == chargeLimitExtendedPreset,
                    target: chargeLimitExtendedPreset,
                  ),
                  _preset(
                    value: loc.helpersChargeLimitValue(chargeLimitMaxPreset),
                    label: loc.v2ChargeLimitMax,
                    selected:
                        !dragging && targetPercent == chargeLimitMaxPreset,
                    target: chargeLimitMaxPreset,
                    last: true,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _preset({
    required String value,
    required String label,
    required bool selected,
    required int target,
    bool last = false,
  }) {
    return Expanded(
      child: Padding(
        padding: EdgeInsets.only(right: last ? 0 : AppSpacing.x3),
        child: SelectableTile(
          value: value,
          label: label,
          selected: selected,
          onPressed: () => onPresetSelected(target),
        ),
      ),
    );
  }
}

class _ChargeLimitInformationButton extends StatelessWidget {
  const _ChargeLimitInformationButton();

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return AnchoredTooltipTrigger(
      side: AnchoredTooltipSide.right,
      caretAlignment: 0.08,
      anchorInsets: const EdgeInsets.all(AppSpacing.x4),
      barrierLabel: loc.v2ChargeLimitInfoClose,
      tooltipBuilder: (context) => InformationTooltipPanel(
        title: loc.v2ChargeLimitInfoTitle,
        children: [
          InformationCard(
            value: loc.helpersChargeLimitValue(chargeLimitDailyPreset),
            description: loc.v2ChargeLimitInfoDaily,
          ),
          InformationCard(
            value: loc.helpersChargeLimitValue(chargeLimitExtendedPreset),
            description: loc.v2ChargeLimitInfoExtended,
          ),
          InformationCard(
            value: loc.helpersChargeLimitValue(chargeLimitMaxPreset),
            description: loc.v2ChargeLimitInfoMax,
          ),
        ],
      ),
      builder: (context, isOpen, open) => InfoIconButton(
        selected: isOpen,
        onPressed: open,
        tooltip: loc.v2ChargeLimitInfoTooltip,
      ),
    );
  }
}
