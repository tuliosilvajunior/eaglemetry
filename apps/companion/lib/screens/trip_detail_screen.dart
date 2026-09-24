import 'dart:math' as math;

import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../l10n/app_localizations.dart';
import 'history_format.dart';
import 'session_detail_screen.dart';

/// One recorded drive, read from the store this phone holds.
///
/// The route, the terrain and the energy split are a drive's facts; a charge
/// draws none of them, and its cards live on [ChargeDetailScreen].
class TripDetailScreen extends SessionDetailScreen {
  const TripDetailScreen({
    required super.store,
    required super.session,
    super.source,
    super.key,
  });

  @override
  State<TripDetailScreen> createState() => _TripDetailScreenState();
}

class _TripDetailScreenState
    extends SessionDetailState<TripDetailScreen, TripDetailReading> {
  @override
  TripDetailReading reading(
    SessionRecord record,
    TelemetrySeries series,
    List<TelemetryEventRecord> events, {
    TrackRow? track,
  }) => TripDetailReading(
    session: record,
    series: series,
    events: events,
    track: track,
  );

  @override
  List<Widget> cards(
    TripDetailReading detail,
    AppLocalizations l10n,
    AppThemeColors colors,
  ) => [
    // Everything below is hidden when the car did not measure it. A card
    // drawn empty says the drive had no energy in it; an absent card says
    // this phone cannot answer, which is the truth.
    _mapCard(detail, l10n, colors),
    const SizedBox(height: AppSpacing.x4),
    MetricMosaic(columns: 3, tiles: _tripTiles(detail, l10n)),
    ...maybeCard(batteryCard(l10n)),
    ...maybeCard(_energyBalanceCard(detail, l10n, colors)),
    ...maybeCard(_perMinuteCard(l10n, colors)),
    ...maybeCard(_terrainCard(detail, l10n, colors)),
    ...maybeCard(eventsCard(l10n, colors)),
  ];

  /// The route, or a line saying the drive carries no fix.
  ///
  /// A trip with GPS off is an ordinary trip, so the absence gets a sentence
  /// rather than an empty map that reads as a fault.
  Widget _mapCard(
    TripDetailReading detail,
    AppLocalizations l10n,
    AppThemeColors colors,
  ) {
    final source = detail.routePoints(expanded: mapExpanded);
    final points = [
      for (final point in source)
        RouteMapPoint(
          latitude: point.latitude,
          longitude: point.longitude,
          speedKmh: point.speedKmh,
        ),
    ];
    if (points.isEmpty) {
      return AppCard(
        title: l10n.historyRoute,
        child: Text(
          l10n.historyNoRoute,
          style: AppText.body.copyWith(color: colors.inkMuted),
        ),
      );
    }
    return mapWindow(points: points, l10n: l10n);
  }

  /// What the drive spent, and what came back, on one scale.
  ///
  /// Three magnitudes rather than a ring or a pill, and that is the reading
  /// rather than a style: recovered energy is measured against the energy
  /// drawn, not carved out of it, so it has no slice of a whole. Put beside
  /// traction and the auxiliary remainder on a common scale it can be compared
  /// with them, which is the question a driver asks.
  ///
  /// The footnote is the pack integral, which is the three put back together
  /// — traction, less what regeneration returned, plus everything else the car
  /// ran. It is a measurement, not a fourth quantity.
  Widget? _energyBalanceCard(
    TripDetailReading detail,
    AppLocalizations l10n,
    AppThemeColors colors,
  ) {
    final traction = detail.measuredTractionWh;
    final auxiliary = detail.measuredAuxiliaryWh;
    final climate = detail.measuredClimateWh;
    final regenerated = detail.measuredRegeneratedWh;
    final net = detail.measuredPackWh;
    if (traction == null ||
        auxiliary == null ||
        regenerated == null ||
        net == null) {
      return null;
    }
    if (traction + auxiliary <= 0) return null;

    final hasClimate = climate != null && climate > 0.5;
    final otherAux = hasClimate
        ? (auxiliary - climate).clamp(0.0, double.infinity)
        : auxiliary;

    return AppCard(
      title: l10n.historyEnergyBalance,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MagnitudeBars(
            bars: [
              MagnitudeBar(
                value: traction,
                label: l10n.historyTraction,
                valueLabel: l10n.historyWh(formatWh(traction)),
                color: colors.energy.draw,
              ),
              MagnitudeBar(
                value: regenerated,
                label: l10n.historyRecovered,
                valueLabel: l10n.historyWh(formatWh(regenerated)),
                color: colors.energy.gain,
              ),
              if (hasClimate) ...[
                MagnitudeBar(
                  value: climate,
                  label: l10n.historyClimate,
                  valueLabel: l10n.historyWh(formatWh(climate)),
                  color: colors.energy.focus,
                ),
                MagnitudeBar(
                  value: otherAux,
                  label: l10n.historyAuxiliary,
                  valueLabel: l10n.historyWh(formatWh(otherAux)),
                  color: colors.inkSubtle,
                ),
              ] else
                MagnitudeBar(
                  value: auxiliary,
                  label: l10n.historyAuxiliary,
                  valueLabel: l10n.historyWh(formatWh(auxiliary)),
                  color: colors.inkSubtle,
                ),
            ],
            footnote: l10n.historyNetConsumed(formatEnergy(net / 1000)),
          ),
        ],
      ),
    );
  }

  /// The drive by interval: what the pack gave, against what came back.
  ///
  /// Regeneration is drawn below the axis rather than subtracted from the
  /// column above it, because a minute that spent 300 Wh and recovered 100 is
  /// not the same minute as one that spent 200.
  ///
  /// The column is a minute only while the minutes fit. A long drive holds
  /// more of them than a phone is wide, and a chart that kept the minute would
  /// have to drop the columns that did not fit — it would answer for the start
  /// of the drive and say nothing about the rest. Widening the column instead
  /// keeps the whole drive on screen, and it is a sum of the stored minutes,
  /// never a second integral.
  Widget? _perMinuteCard(AppLocalizations l10n, AppThemeColors colors) {
    final minutes = [
      for (final bucket in buckets)
        if (bucket.integratedSeconds > 0) bucket,
    ];
    if (minutes.isEmpty) return null;

    return intervalChartCard(
      l10n,
      colors,
      title: l10n.historyPerMinute,
      minutes: minutes,
      chart: (columns, width, origin) {
        // One scale for both directions, as the two are only worth drawing
        // together if they can be compared. An axis that fitted each side to
        // its own peak would make a 100 Wh recovery look like a 300 Wh spend.
        final peak = columns
            .map((bucket) => math.max(bucket.drawnWh, bucket.regeneratedWh))
            .reduce(math.max);
        if (peak <= 0) return const SizedBox.shrink();
        final scale = energyAxisTop(peak);

        return EnergyBarChart(
          selectedIndex: selectedMinute,
          onSelected: selectMinute,
          xTicks: timeXTicks(columns, width, origin: origin),
          tooltipBuilder: (context, index) {
            final bucket = columns[index];
            return ChartTooltip(
              // No caret of its own. The chart draws one that points at the
              // column, and the bubble's default carries a second under the
              // panel that points at nothing.
              side: ChartTooltipSide.none,
              title: columnLabel(bucket, origin),
              value: formatWh(bucket.drawnWh),
              unit: 'Wh',
              rows: [
                if (bucket.climateWh > 0.5)
                  ChartTooltipRow(
                    label:
                        '${l10n.historyClimate} '
                        '${l10n.historyWh(formatWh(bucket.climateWh))}',
                  ),
                // Named, because the numeral above is the spend and a second
                // bare figure under it would read as a correction of it.
                ChartTooltipRow(
                  label:
                      '${l10n.historyRecovered} '
                      '${l10n.historyWh(formatWh(bucket.regeneratedWh))}',
                ),
              ],
            );
          },
          bars: [
            for (final bucket in columns)
              EnergyBar(
                id: bucket.start,
                value: bucket.drawnWh,
                // `counter`, not `base`. A base segment follows the column's
                // direction and a part that disagrees with it is dropped, so
                // regeneration passed there vanishes without a word. The
                // counter is the field for an interval that both spends and
                // recovers.
                counter: -bucket.regeneratedWh,
              ),
          ],
          // The axis has to be stated on both sides of zero. Two guides make
          // a scale, and with the lower one at zero every counter column
          // falls below the plot floor and is clipped away.
          ticks: [
            ChartTick(value: scale, label: scale.round().toString()),
            const ChartTick(value: 0, label: '0'),
            // The magnitude, with no sign: below the rule already means
            // recovered, and a minus there reads as negative energy.
            ChartTick(value: -scale, label: scale.round().toString()),
          ],
          positiveColor: colors.energy.draw,
          negativeColor: colors.energy.gain,
        );
      },
    );
  }

  /// The hill the drive happened over.
  ///
  /// Temperature is not drawn here: `Session` carries one distinct value of
  /// it across a drive (ADR-0010), so it is the `historyTemperature` tile in
  /// [_tripTiles], not a series. See issue 181.
  Widget? _terrainCard(
    TripDetailReading detail,
    AppLocalizations l10n,
    AppThemeColors colors,
  ) {
    final altitude = traceSeries(detail.altitudeSeries);
    if (altitude == null) return null;

    return AppCard(
      title: l10n.historyTerrain,
      child: labelled(
        l10n.historyAltitude,
        colors,
        SeriesTrace(
          points: altitude.points,
          minLabel: '${altitude.low.round()} m',
          maxLabel: '${altitude.high.round()} m',
          color: colors.ink,
          semanticsLabel: l10n.historyAltitude,
        ),
      ),
    );
  }

  List<MosaicTile> _tripTiles(TripDetailReading detail, AppLocalizations l10n) {
    final session = widget.session;
    return [
      MosaicTile(
        caption: l10n.historyDuration,
        value: formatDuration(detail.durationMillis),
      ),
      MosaicTile(
        caption: l10n.historyDistance,
        value: formatDistance(detail.distanceKm),
        unit: 'km',
      ),
      MosaicTile(
        caption: l10n.historySoc,
        value: formatSocRange(
          session.startSoc.displayValue,
          session.endSoc.displayValue,
        ),
      ),
      MosaicTile(
        caption: l10n.historyConsumed,
        value: formatEnergy(detail.netEnergyKwh),
        unit: 'kWh',
      ),
      MosaicTile(
        caption: l10n.historyRegenerated,
        value: formatEnergy(detail.regeneratedKwh),
        unit: 'kWh',
      ),
      MosaicTile(
        caption: l10n.historyEfficiency,
        value: formatWhPerKm(detail.efficiencyWhPerKm),
        unit: 'Wh/km',
      ),
      MosaicTile(
        caption: l10n.historyClimb,
        value: formatAltitudeGain(detail.altitudeGainM),
        unit: 'm',
      ),
      MosaicTile(
        caption: l10n.historyTemperature,
        value: formatTemperature(detail.meanAmbientTempC),
        unit: '°C',
      ),
    ];
  }
}
