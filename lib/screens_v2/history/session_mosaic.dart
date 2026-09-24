import 'package:flutter/material.dart';

import '../../core/efficiency_unit.dart';
import '../../core/telemetry_api.dart';
import '../../core/telemetry_format.dart';
import '../../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';
import '../charge_cost_editor.dart';
import 'history_format.dart';

/// The readings of one recorded session, as a wall of tiles.
///
/// Two constructors, one for each kind of session, because a drive and a charge
/// do not answer the same questions: a drive has distance and efficiency, a
/// charge has the power it came in at. Everything they *do* share — when it
/// started, how long it took, what the SOC and the outside temperature did —
/// is built by [_commonTiles] so the two walls read alike.
///
/// It assembles itself: give it the session and it decides which readings
/// exist, formats them, and orders them. A reading the car never reported still
/// gets its tile, showing `--` — a wall whose tiles moved around depending on
/// what was recorded would be unreadable across two sessions, and an absent
/// reading is itself worth seeing.
class SessionMosaic extends StatelessWidget {
  const SessionMosaic.trip({required TripDetailReading reading, super.key})
    : _trip = reading,
      _charge = null,
      defaultCostPerKwh = null,
      onCostPressed = null,
      costEditLabel = null;

  const SessionMosaic.charge({
    required ChargeDetailReading reading,
    this.defaultCostPerKwh,
    this.onCostPressed,
    this.costEditLabel,
    super.key,
  }) : assert(onCostPressed == null || costEditLabel != null),
       _charge = reading,
       _trip = null;

  final TripDetailReading? _trip;
  final ChargeDetailReading? _charge;

  /// What an unpriced charge costs per kWh, from Settings. Only a fallback: a
  /// session that carries its own rate or its own receipt uses that.
  final double? defaultCostPerKwh;

  /// Opens the price editor for this charge. Null keeps the cost a reading —
  /// which is what a drive's wall always is, because a drive is priced by the
  /// charge before it and not on its own.
  final void Function(BuildContext cellContext)? onCostPressed;

  /// Localized action name for the cost tile. Required with [onCostPressed].
  final String? costEditLabel;

  /// Cells across.
  ///
  /// Chosen from the arithmetic, not by eye: both walls come to fourteen cells,
  /// and seven columns is what packs fourteen into **two** rows. The card is a
  /// quarter of the screen tall, so a third row would leave each tile too short
  /// to read its own numeral. Adding a reading here means either taking one out
  /// or accepting the third row — which is `DESIGN.md`'s rule that a cramped
  /// layout loses content rather than padding.
  static const _columns = 7;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    // The efficiency hero tile reads EfficiencyUnitController directly
    // (see _tripTiles), so this listens rather than taking the unit as a
    // parameter — the same global choice a tap anywhere else in the app
    // changes.
    return ListenableBuilder(
      listenable: EfficiencyUnitController.instance,
      builder: (context, _) => MetricMosaic(
        tiles: _tiles(loc, AppThemeColors.of(context)),
        columns: _columns,
      ),
    );
  }

  List<MosaicTile> _tiles(AppLocalizations loc, AppThemeColors colors) {
    final trip = _trip;
    if (trip != null) return _tripTiles(loc, trip, colors);
    return _chargeTiles(loc, _charge!, colors);
  }

  /// When it happened and what the pack did — the readings every session has.
  List<MosaicTile> _commonTiles(
    AppLocalizations loc, {
    required int? startMillis,
    required int? endMillis,
    required int? durationMillis,
    required double? startSoc,
    required double? endSoc,
    required double? startTempC,
    required double? endTempC,
  }) {
    return [
      MosaicTile(
        caption: loc.v2HistoryStart,
        value: historyClock(startMillis),
        icon: Icons.play_arrow,
      ),
      // Between the two times it sits between, so the three read as one
      // sentence: from here, for this long, to there.
      MosaicTile(
        caption: loc.v2HistoryDuration,
        value: formatDuration(
          durationMillis == null
              ? null
              : Duration(milliseconds: durationMillis),
        ),
        icon: Icons.schedule,
      ),
      MosaicTile(
        caption: loc.v2HistoryEnd,
        value: historyClock(endMillis),
        icon: Icons.stop,
      ),
      MosaicTile(
        caption: loc.v2HistorySoc,
        value: socRangeLabel(startSoc, endSoc),
        icon: Icons.battery_full,
        span: MosaicTileSpan.wide,
      ),
      MosaicTile(
        caption: loc.v2HistoryTemperature,
        value: ambientTempRangeLabel(startTempC, endTempC),
        icon: Icons.thermostat,
        span: MosaicTileSpan.wide,
      ),
    ];
  }

  List<MosaicTile> _tripTiles(
    AppLocalizations loc,
    TripDetailReading detail,
    AppThemeColors colors,
  ) {
    final session = detail.session;
    final distanceKm = detail.distanceKm;
    return [
      // The headline is what the drive cost, in whichever of the three units
      // EfficiencyUnitController holds — that is the question a driver asks
      // at the end of a drive, however they prefer to ask it.
      MosaicTile(
        caption: loc.v2HistoryEfficiency,
        value: formatEfficiencyForUnit(
          detail.efficiencyKmPerKwh,
          EfficiencyUnitController.instance.unit,
        ),
        unit: detail.efficiencyKmPerKwh == null
            ? null
            : efficiencyUnitSuffix(EfficiencyUnitController.instance.unit, loc),
        icon: Icons.eco,
        accent: colors.energy.gain,
        span: MosaicTileSpan.hero,
      ),
      MosaicTile(
        caption: loc.v2HistoryDistance,
        value: distanceKm == null ? '--' : distanceKm.toStringAsFixed(1),
        unit: distanceKm == null ? null : loc.unitKm,
        icon: Icons.route,
      ),
      MosaicTile(
        caption: loc.v2HistoryAltitude,
        value: altitudeGainLabel(detail.altitudeGainM),
        icon: Icons.terrain,
      ),
      ..._commonTiles(
        loc,
        startMillis: session.startedAtUtcMillis,
        endMillis: session.endedAtUtcMillis,
        durationMillis: detail.durationMillis,
        startSoc: session.startSoc.displayValue,
        endSoc: session.endSoc.displayValue,
        startTempC: session.startAmbientTemp.displayValue,
        endTempC: session.endAmbientTemp.displayValue,
      ),
      MosaicTile(
        caption: loc.v2HistoryCost,
        value: detail.estimatedTripCost == null
            ? '--'
            : detail.estimatedTripCost!.toStringAsFixed(2),
        unit: detail.lastChargeCostCurrency,
        icon: Icons.payments,
      ),
    ];
  }

  List<MosaicTile> _chargeTiles(
    AppLocalizations loc,
    ChargeDetailReading detail,
    AppThemeColors colors,
  ) {
    final session = detail.session;
    final energyKwh = detail.estimatedEnergyKwh;
    // The receipt when there is one, and the rate times the energy when there
    // is not — the same figure the charging screen states for this session, so
    // one charge does not have two prices on two screens.
    final cost = chargeEstimatedCost(
      energyKwh: energyKwh,
      costPerKwh: session.costPerKwh ?? defaultCostPerKwh,
      paidAmount: session.paidAmount,
    );
    final symbol = chargeCurrencySymbolForLocale(
      loc.localeName,
      fallbackCurrency: chargeCostCurrencyOf(session, fallback: 'BRL'),
    );
    return [
      MosaicTile(
        caption: loc.v2HistoryEnergyAdded,
        value: energyKwh == null ? '--' : energyKwh.toStringAsFixed(2),
        unit: energyKwh == null ? null : loc.unitKwh,
        icon: Icons.battery_charging_full,
        accent: colors.energy.gain,
        span: MosaicTileSpan.hero,
      ),
      MosaicTile(
        caption: loc.v2HistoryAvgPower,
        value: detail.averagePowerKw == null
            ? '--'
            : detail.averagePowerKw!.toStringAsFixed(1),
        unit: detail.averagePowerKw == null ? null : loc.unitKw,
        icon: Icons.speed,
      ),
      MosaicTile(
        caption: loc.v2HistoryPeakPower,
        value: detail.peakPowerKw == null
            ? '--'
            : detail.peakPowerKw!.toStringAsFixed(1),
        unit: detail.peakPowerKw == null ? null : loc.unitKw,
        icon: Icons.trending_up,
      ),
      ..._commonTiles(
        loc,
        // The plug going in is when the session started for the reader; the
        // charge itself may begin later, and the graph beside this shows that
        // gap.
        startMillis: session.startedAtUtcMillis,
        endMillis:
            session.plugDisconnectedAtUtcMillis ??
            session.chargeEndedAtUtcMillis,
        durationMillis: detail.durationMillis,
        startSoc: session.startSoc.displayValue,
        endSoc: session.endSoc.displayValue,
        startTempC: session.startAmbientTemp.displayValue,
        endTempC: session.endAmbientTemp.displayValue,
      ),
      MosaicTile(
        caption: loc.v2HistoryCost,
        value: chargeAmountLabel(
          cost,
          symbol: symbol,
          decimalSeparator: chargeDecimalSeparatorForLocale(loc.localeName),
        ),
        icon: Icons.payments,
        onPressed: onCostPressed,
        editLabel: costEditLabel,
      ),
    ];
  }
}
