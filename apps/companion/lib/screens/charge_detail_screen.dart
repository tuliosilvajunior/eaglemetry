import 'dart:math' as math;

import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../l10n/app_localizations.dart';
import '../sync/sqflite_store.dart';
import 'history_format.dart';
import 'session_detail_screen.dart';

/// One recorded charge, read from the store this phone holds.
///
/// The location, the power curve and the battery traces are a charge's facts;
/// a drive draws none of them, and its cards live on [TripDetailScreen].
class ChargeDetailScreen extends SessionDetailScreen {
  const ChargeDetailScreen({
    required super.store,
    required super.session,
    super.source,
    super.key,
  });

  @override
  State<ChargeDetailScreen> createState() => _ChargeDetailScreenState();
}

class _ChargeDetailScreenState
    extends SessionDetailState<ChargeDetailScreen, ChargeDetailReading> {
  @override
  ChargeDetailReading reading(
    SessionRecord record,
    TelemetrySeries series,
    List<TelemetryEventRecord> events, {
    TrackRow? track,
  }) => ChargeDetailReading(session: record, series: series, events: events);

  @override
  List<Widget> cards(
    ChargeDetailReading detail,
    AppLocalizations l10n,
    AppThemeColors colors,
  ) {
    // Everything below is hidden when the car did not measure it. A card
    // drawn empty says the charge had no energy in it; an absent card says
    // this phone cannot answer, which is the truth.
    final location = _locationCard(l10n);
    return [
      if (location != null) ...[
        location,
        const SizedBox(height: AppSpacing.x4),
      ],
      MetricMosaic(columns: 3, tiles: _chargeTiles(detail, l10n)),
      ...maybeCard(batteryCard(l10n)),
      ...maybeCard(_energyBalanceCard(detail, l10n, colors)),
      ...maybeCard(_perMinuteCard(l10n, colors)),
      ...maybeCard(_tracesCard(detail, l10n, colors)),
      ...maybeCard(eventsCard(l10n, colors)),
    ];
  }

  /// The location of a charge, or null when the charge carries no fix.
  ///
  /// A charge is a place, not a path: the row holds where the plug went in,
  /// and the series question asks for no GPS samples beside it. The card is
  /// the drive's own map window — same sizes, same expand button — because a
  /// smaller window on one screen and a larger one on the other would be a
  /// style, not a reading.
  Widget? _locationCard(AppLocalizations l10n) {
    final lat = widget.session.startLatitude;
    final lon = widget.session.startLongitude;
    if (lat == null || lon == null || (lat == 0 && lon == 0)) {
      return null;
    }
    final point = RouteMapPoint(latitude: lat, longitude: lon);
    if (!point.isValid) return null;

    return mapWindow(points: [point], l10n: l10n);
  }

  /// Energy split for a charge: delivered to battery vs climate/conditioning.
  Widget? _energyBalanceCard(
    ChargeDetailReading detail,
    AppLocalizations l10n,
    AppThemeColors colors,
  ) {
    final batteryWh = (detail.estimatedEnergyKwh ?? 0) * 1000;
    final climateWh = (detail.climateEnergyKwh ?? 0) * 1000;
    if (batteryWh <= 0 && climateWh <= 0) return null;
    if (climateWh <= 0) return null;

    final totalWh = batteryWh + climateWh;

    return AppCard(
      title: l10n.historyEnergyBalance,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MagnitudeBars(
            bars: [
              MagnitudeBar(
                value: batteryWh,
                label: l10n.historyBattery,
                valueLabel: l10n.historyWh(formatWh(batteryWh)),
                color: colors.energy.gain,
              ),
              MagnitudeBar(
                value: climateWh,
                label: l10n.historyClimate,
                valueLabel: l10n.historyWh(formatWh(climateWh)),
                color: colors.energy.gainSoft,
              ),
            ],
            footnote: l10n.historyTotalDelivered(formatEnergy(totalWh / 1000)),
          ),
        ],
      ),
    );
  }

  /// Charging power by interval over the session.
  Widget? _perMinuteCard(AppLocalizations l10n, AppThemeColors colors) {
    final minutes = [
      for (final bucket in buckets)
        if (bucket.integratedSeconds > 0 && bucket.deliveredWh > 0) bucket,
    ];
    if (minutes.isEmpty) return null;

    return intervalChartCard(
      l10n,
      colors,
      title: l10n.historyChargingPower,
      minutes: minutes,
      chart: (columns, width, origin) {
        final peakKw = columns.map(powerKw).fold<double>(0.0, math.max);
        if (peakKw <= 0) return const SizedBox.shrink();
        final scale = energyAxisTop(peakKw);

        return EnergyBarChart(
          selectedIndex: selectedMinute,
          onSelected: selectMinute,
          xTicks: timeXTicks(columns, width, origin: origin),
          tooltipBuilder: (context, index) {
            final bucket = columns[index];
            final deliveredKwh = bucket.deliveredWh / 1000.0;
            return ChartTooltip(
              side: ChartTooltipSide.none,
              title: columnLabel(bucket, origin),
              value: powerKw(bucket).toStringAsFixed(1),
              unit: 'kW',
              rows: [
                ChartTooltipRow(
                  label:
                      '${l10n.historyEnergy}: ${deliveredKwh.toStringAsFixed(2)} kWh',
                ),
                if (bucket.climateWh > 0)
                  ChartTooltipRow(
                    label:
                        '${l10n.historyClimate}: ${formatWh(bucket.climateWh)} Wh',
                  ),
              ],
            );
          },
          bars: [
            for (final bucket in columns)
              EnergyBar(id: bucket.start, value: powerKw(bucket)),
          ],
          ticks: [
            ChartTick(value: scale, label: scale.round().toString()),
            ChartTick(value: scale / 2, label: (scale / 2).round().toString()),
            const ChartTick(value: 0, label: '0'),
          ],
          positiveColor: colors.energy.gain,
        );
      },
    );
  }

  /// Mean charging power over an interval, kW.
  ///
  /// An energy divided by the time it was measured over. The car integrated
  /// the delivered power; this states the same energy per hour instead of per
  /// minute.
  static double powerKw(EnergyBucket bucket) {
    if (bucket.integratedSeconds <= 0) return 0.0;
    return (bucket.deliveredWh / 1000.0) / (bucket.integratedSeconds / 3600.0);
  }

  /// The battery voltage and SOC traces during a charge.
  Widget? _tracesCard(
    ChargeDetailReading detail,
    AppLocalizations l10n,
    AppThemeColors colors,
  ) {
    final soc = traceSeries(detail.socSeries);
    final voltage = traceSeries(detail.voltageSeries);
    if (soc == null && voltage == null) return null;

    return AppCard(
      title: l10n.historyBattery,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (soc != null)
            labelled(
              l10n.historySoc,
              colors,
              SeriesTrace(
                points: soc.points,
                minLabel: '${soc.low.round()}%',
                maxLabel: '${soc.high.round()}%',
                color: colors.energy.gain,
                semanticsLabel: l10n.historySoc,
              ),
            ),
          if (soc != null && voltage != null)
            const SizedBox(height: AppSpacing.x4),
          if (voltage != null)
            labelled(
              l10n.historyVoltage,
              colors,
              SeriesTrace(
                points: voltage.points,
                minLabel: '${voltage.low.round()} V',
                maxLabel: '${voltage.high.round()} V',
                color: colors.energy.focus,
                semanticsLabel: l10n.historyVoltage,
              ),
            ),
        ],
      ),
    );
  }

  void _editChargeCost(BuildContext anchorContext, AppLocalizations l10n) {
    final charge = detail?.session ?? widget.session;
    final currency = charge.costCurrency ?? 'BRL';
    final symbol = chargeCurrencySymbolForLocale(
      l10n.localeName,
      fallbackCurrency: currency,
    );

    showMoneyKeypadDialog<_ChargeCostField>(
      context: context,
      anchorContext: anchorContext,
      fields: [
        MoneyKeypadField(
          value: _ChargeCostField.rate,
          label: l10n.chargeCostFieldRate,
          amount: charge.costPerKwh,
          unit: l10n.chargeCostUnitRate,
        ),
        MoneyKeypadField(
          value: _ChargeCostField.total,
          label: l10n.chargeCostFieldTotal,
          amount: charge.paidAmount,
        ),
      ],
      initialField: charge.paidAmount != null
          ? _ChargeCostField.total
          : _ChargeCostField.rate,
      currencySymbol: symbol,
      decimalSeparator: chargeDecimalSeparatorForLocale(l10n.localeName),
      title: l10n.chargeCostTitle,
      description: l10n.chargeCostDescription,
      saveLabel: l10n.moneyKeypadSave,
      clearLabel: l10n.moneyKeypadClear,
      deleteLabel: l10n.moneyKeypadDelete,
      barrierLabel: l10n.moneyKeypadClose,
      onSubmitted: (result) async {
        final newCostPerKwh = result.field == _ChargeCostField.rate
            ? result.amount
            : (result.amount == null ? null : charge.costPerKwh);
        final newPaidAmount = result.field == _ChargeCostField.total
            ? result.amount
            : (result.amount == null ? null : charge.paidAmount);

        final store = widget.store;
        if (store is SqfliteStore) {
          await store.updateChargeCost(
            sessionId: widget.session.id,
            costPerKwh: newCostPerKwh,
            paidAmount: newPaidAmount,
            currency: currency,
          );
        }

        if (!mounted) return;
        await reload();
      },
    );
  }

  List<MosaicTile> _chargeTiles(
    ChargeDetailReading detail,
    AppLocalizations l10n,
  ) {
    final charge = detail.session;
    final startLat = charge.startLatitude;
    final startLon = charge.startLongitude;
    final cost = chargeCostLabel(
      energyKwh: detail.estimatedEnergyKwh,
      costPerKwh: charge.costPerKwh,
      paidAmount: charge.paidAmount,
      currency: charge.costCurrency ?? 'BRL',
      localeName: l10n.localeName,
    );
    final ambientTemp =
        charge.meanAmbientTemp.displayValue ??
        charge.startAmbientTemp.displayValue;

    final peakPower = detail.peakPowerKw;
    final averagePower = detail.averagePowerKw;
    final peakStr = peakPower?.toStringAsFixed(1);
    final avgStr = averagePower?.toStringAsFixed(1);
    final showCombinedPower =
        peakStr != null && avgStr != null && peakStr == avgStr;

    return [
      MosaicTile(
        caption: l10n.historyStart,
        value: formatClock(charge.startedAtUtcMillis),
      ),
      MosaicTile(
        caption: l10n.historyEnd,
        value: formatClock(
          charge.plugDisconnectedAtUtcMillis ?? charge.chargeEndedAtUtcMillis,
        ),
      ),
      MosaicTile(
        caption: l10n.historyDuration,
        value: formatDuration(detail.durationMillis),
      ),
      MosaicTile(
        caption: l10n.historySoc,
        value: formatSocRange(
          charge.startSoc.displayValue,
          charge.endSoc.displayValue,
        ),
      ),
      MosaicTile(
        caption: l10n.historyEnergy,
        value: formatEnergy(detail.estimatedEnergyKwh),
        unit: 'kWh',
      ),
      if (showCombinedPower)
        MosaicTile(
          caption: l10n.historyPeakAndAverage,
          value: peakStr,
          unit: 'kW',
        )
      else ...[
        if (peakStr != null)
          MosaicTile(
            caption: l10n.historyPeakPower,
            value: peakStr,
            unit: 'kW',
          ),
        if (avgStr != null)
          MosaicTile(
            caption: l10n.historyAveragePower,
            value: avgStr,
            unit: 'kW',
          ),
        if (peakStr == null && avgStr == null)
          MosaicTile(
            caption: l10n.historyPeakPower,
            value: kNoValue,
            unit: 'kW',
          ),
      ],
      if (ambientTemp != null)
        MosaicTile(
          caption: l10n.historyTemperature,
          value: formatTemperature(ambientTemp),
          unit: '°C',
        ),
      MosaicTile(
        caption: l10n.historyChargeCost,
        value: cost,
        editLabel: l10n.historyEditCost,
        onPressed: (cellContext) => _editChargeCost(cellContext, l10n),
      ),
      if (startLat != null &&
          startLon != null &&
          (startLat != 0 || startLon != 0)) ...[
        () {
          final place = placeContaining(
            InsightPoint(startLat, startLon),
            places,
          );
          final locationName = place?.name ?? charge.startPlace;
          return MosaicTile(
            caption: l10n.historyChargeLocation,
            value: locationName ?? l10n.insightNameLocation,
            editLabel: l10n.insightNameLocation,
            onPressed: (cellContext) => namePlace(
              latitude: startLat,
              longitude: startLon,
              existingPlaceId: place?.id,
              currentName: locationName,
            ),
          );
        }(),
      ] else if (charge.startPlace case final place?)
        MosaicTile(caption: l10n.historyChargeLocation, value: place),
    ];
  }
}

enum _ChargeCostField { rate, total }
