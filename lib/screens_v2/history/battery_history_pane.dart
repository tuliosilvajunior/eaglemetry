import 'package:flutter/material.dart';

import '../../core/efficiency_unit.dart';
import '../../core/telemetry_api.dart';
import '../../core/telemetry_format.dart';
import '../../core/telemetry_scope.dart';
import '../../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';
import 'history_constants.dart';
import 'history_list.dart';

/// The batteries this car has spent, newest first.
///
/// One row is one equivalent full cycle: the distance and the money that one
/// whole battery bought. The row carries every number the cycle has, so the
/// detail beside it adds no readouts — it answers a different question, which
/// is what the battery was spent *on*.
class BatteryHistoryPane extends StatefulWidget {
  const BatteryHistoryPane({
    this.telemetryApi,
    this.selectedOrdinal,
    this.onSelected,
    super.key,
  });

  /// Seam for tests. Production passes nothing and gets the shared api through
  /// [TelemetryScope].
  final TelemetryApi? telemetryApi;

  /// The cycle whose detail is open, if any.
  final int? selectedOrdinal;

  final ValueChanged<BatteryCycleSummary>? onSelected;

  @override
  State<BatteryHistoryPane> createState() => _BatteryHistoryPaneState();
}

class _BatteryHistoryPaneState extends State<BatteryHistoryPane> {
  late final TelemetryApi _api =
      widget.telemetryApi ?? TelemetryScope.of(context);

  /// Both kinds of write move a cycle, so this listens to the whole stream.
  /// A drive fills the open bar, and pricing a charge changes what every cycle
  /// after it cost.
  late final TelemetryQuery<BatteryCyclesResult> _query = TelemetryQuery(
    read: () => _api.getBatteryCycles(limit: historyLimit),
    interval: historyFallbackInterval,
    debugLabel: 'HistoryV2Screen.cycles',
    refreshOn: _api.sessionChanges(),
  );

  @override
  void initState() {
    super.initState();
    _query.addListener(_onChanged);
    _query.start();
  }

  @override
  void dispose() {
    _query.removeListener(_onChanged);
    _query.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return HistoryList(
      state: _query.state,
      countOf: (result) => result.cycles.length,
      emptyLabel: loc.v2CycleEmpty,
      rowBuilder: (context, index) {
        final cycle = _query.value!.cycles[index];
        return _CycleRow(
          cycle: cycle,
          locale: _localeName,
          selected: cycle.ordinal == widget.selectedOrdinal,
          onTap: () => widget.onSelected?.call(cycle),
        );
      },
    );
  }

  String? get _localeName => Localizations.localeOf(context).toLanguageTag();
}

/// One battery: the bar, what the cycle covered, and what it cost.
class _CycleRow extends StatelessWidget {
  const _CycleRow({
    required this.cycle,
    required this.locale,
    required this.selected,
    this.onTap,
  });

  final BatteryCycleSummary cycle;
  final String? locale;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.x3),
      child: Material(
        // The row is a card on the canvas, so its readings can sit on the
        // `control` step inside it and still be seen as tiles.
        //
        // The selected row keeps that step rather than inverting to the
        // selection fill: the bar inside it is a measurement in a fixed
        // colour, and a near-black ground under it would read as a second,
        // fuller bar. The outline says which row is open instead.
        color: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadii.mdRadius,
          side: selected
              ? BorderSide(color: colors.ink, width: 2)
              : BorderSide.none,
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: AppRadii.mdRadius,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.x4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CycleBar(
                  fillPercent: cycle.dischargePercent,
                  leadingLabel: loc.v2CycleOrdinal(cycle.ordinal),
                  valueLabel: cycle.dischargePercent.toStringAsFixed(0),
                  valueUnit: loc.unitPercent,
                  isPartial: cycle.isPartial,
                  semanticsLabel: loc.v2CycleSemantics(
                    cycle.ordinal,
                    cycle.dischargePercent.toStringAsFixed(0),
                  ),
                ),
                const SizedBox(height: AppSpacing.x3),
                _Heading(cycle: cycle),
                const SizedBox(height: AppSpacing.x3),
                _Facts(cycle: cycle, locale: locale),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// When the battery ran, and what the reader must know before trusting the
/// numbers under it.
class _Heading extends StatelessWidget {
  const _Heading({required this.cycle});

  final BatteryCycleSummary cycle;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    final start = dateTimeFromMillis(cycle.startUtcMillis);
    final end = dateTimeFromMillis(cycle.endUtcMillis);
    final span = start == null || end == null
        ? '--'
        : '${formatTripListDateTime(start)} — '
              '${formatTripListDateTime(end)}';

    return Row(
      children: [
        Expanded(
          child: Text(
            span,
            style: AppText.bodyStrong.copyWith(color: colors.ink),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        // Each note names a number the row does not print. A reader who sees a
        // dash must be able to find out why it is a dash.
        Wrap(
          spacing: AppSpacing.x2,
          children: [
            if (cycle.isOpen) _Note(label: loc.v2CycleOpen),
            if (cycle.isPartial) _Note(label: loc.v2CyclePartial),
            if (cycle.energyIncomplete) _Note(label: loc.v2CycleNoCapacity),
            if (cycle.mixedCurrency) _Note(label: loc.v2CycleMixedCurrency),
            if (!cycle.mixedCurrency && _partlyPriced)
              _Note(label: loc.v2CyclePartlyPriced(_pricedPercent)),
            if (cycle.isFrozen) _Note(label: loc.v2CycleFrozen),
          ],
        ),
      ],
    );
  }

  bool get _partlyPriced {
    final coverage = cycle.costCoverage;
    return coverage != null && coverage < 1;
  }

  String get _pricedPercent =>
      ((cycle.costCoverage ?? 0) * 100).toStringAsFixed(0);
}

class _Note extends StatelessWidget {
  const _Note({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.x3,
        vertical: AppSpacing.x1,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: AppRadii.fullRadius,
      ),
      child: Text(label, style: AppText.label.copyWith(color: colors.inkMuted)),
    );
  }
}

/// Cells across the readings mosaic. Six small tiles in three columns pack
/// into two rows, which is what keeps the list row the height of a row.
const _mosaicColumns = 3;

/// How tall one mosaic cell is in the list.
const _mosaicCellHeight = 76.0;

/// The six readings of a cycle.
///
/// Every one of them is a dash when the cycle cannot support it. That is the
/// point of the row: a floor divided into a distance would report an
/// efficiency the car never reached, and a cost that quietly leaves out the
/// unpriced energy reads as the whole bill.
class _Facts extends StatelessWidget {
  const _Facts({required this.cycle, required this.locale});

  final BatteryCycleSummary cycle;
  final String? locale;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final symbol = cycle.costCurrency == null
        ? chargeCurrencySymbolForLocale(locale)
        : chargeCurrencySymbolForLocale(
            null,
            fallbackCurrency: cycle.costCurrency!,
          );

    return ListenableBuilder(
      listenable: EfficiencyUnitController.instance,
      builder: (context, _) {
        final unit = EfficiencyUnitController.instance.unit;
        return SizedBox(
          // The mosaic fills the box it is given, and a list row has no height
          // to divide, so the row states it: two packed rows of cells, each
          // tall enough for a caption over its numeral.
          height: _mosaicCellHeight * 2 + AppSpacing.x2,
          child: MetricMosaic(
            columns: _mosaicColumns,
            tiles: [
              MosaicTile(
                caption: loc.v2CycleDistance,
                value: cycle.distanceKm > 0
                    ? cycle.distanceKm.toStringAsFixed(0)
                    : '--',
                unit: loc.unitKm,
              ),
              MosaicTile(
                caption: loc.v2CycleEnergy,
                value: _number(cycle.hasEnergy ? cycle.tripEnergyKwh : null, 1),
                unit: loc.unitKwh,
              ),
              MosaicTile(
                caption: loc.v2CycleEfficiency,
                value: formatEfficiencyForUnit(cycle.kmPerKwh, unit),
                unit: efficiencyUnitSuffix(unit, loc),
                // The tap changes the unit everywhere, so the tile carries the
                // swap mark and not the pencil: it writes nothing.
                actionIcon: Icons.swap_horiz,
                editLabel: loc.v2CycleEfficiencyUnitAction,
                onPressed: (_) => EfficiencyUnitController.instance.cycle(),
              ),
              MosaicTile(
                caption: loc.v2CycleCost,
                value: _money(cycle.cost, symbol),
              ),
              MosaicTile(
                caption: loc.v2CycleCostPerKwh,
                value: _money(cycle.averageCostPerKwh, symbol),
              ),
              MosaicTile(
                caption: loc.v2CycleCapacity,
                value: _number(cycle.measuredCapacityKwh, 1),
                unit: loc.unitKwh,
              ),
            ],
          ),
        );
      },
    );
  }

  String _number(double? value, int decimals) =>
      value == null ? '--' : value.toStringAsFixed(decimals);

  String _money(double? value, String symbol) =>
      value == null ? '--' : '$symbol ${value.toStringAsFixed(2)}';
}
