import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/efficiency_unit.dart';
import '../../core/telemetry_api.dart';
import '../../core/telemetry_scope.dart';
import '../../core/telemetry_format.dart';
import '../../design_system/design_system.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/telemetry_map_panel.dart';
import 'trip_session_display.dart';

class TripSessionDetailScreen extends StatefulWidget {
  const TripSessionDetailScreen({required this.session, super.key});

  final SessionRecord session;

  @override
  State<TripSessionDetailScreen> createState() =>
      _TripSessionDetailScreenState();
}

class _TripSessionDetailScreenState extends State<TripSessionDetailScreen> {
  static const double _wideBreakpoint = 1500;

  late final TelemetryApi _api = TelemetryScope.of(context);
  _TripFrameSeries _series = _TripFrameSeries.empty;
  bool _loading = true;
  String? _error;
  int _totalCount = 0;

  @override
  void initState() {
    super.initState();
    _loadFrames();
  }

  Future<void> _loadFrames() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final stored = await _api.getSession(widget.session.id);
      final series = await _api.getSeries(widget.session.id);
      final reading = TripDetailReading(
        session: stored?.session ?? widget.session,
        series: series,
        events: stored?.events ?? const [],
        lastPricedCharge: await lastPricedChargeBefore(
          _api.store,
          (stored?.session ?? widget.session).startedAtUtcMillis,
        ),
        track: stored?.track,
      );
      if (!mounted) return;
      setState(() {
        _series = _TripFrameSeries.fromDetail(reading);
        _totalCount = series.samples.values.fold(
          0,
          (sum, points) => sum + points.length,
        );
        _loading = false;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '${error.code}: ${error.message ?? 'bridge error'}';
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final display = TripSessionDisplay.fromSession(widget.session, loc);
    // Native tripSessionDetailMap owns the energy/efficiency math (session
    // odometer preferred, SOC confidence gate applied); display it as-is.
    final estimatedDistance = _series.speedEstimatedDistanceKm;
    final odometerDistance =
        _series.odometerDistanceKm ??
        sessionReadingDistance(widget.session).displayValue;
    return Scaffold(
      backgroundColor: AutomotiveColors.background,
      body: SafeArea(
        child: Column(
          children: [
            TripDetailHeader(
              display: display,
              frameCount: _totalCount,
              loading: _loading,
              onRefresh: _loadFrames,
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(AutomotiveSpacing.marginScreen),
                child: _loading
                    ? const Center(child: LoadingPanel())
                    : _error != null
                    ? Center(child: ErrorPanel(message: _error!))
                    : LayoutBuilder(
                        builder: (context, constraints) =>
                            constraints.maxWidth >= _wideBreakpoint
                            ? _wideBody(
                                loc,
                                display,
                                odometerDistance,
                                estimatedDistance,
                              )
                            : _narrowBody(
                                loc,
                                display,
                                odometerDistance,
                                estimatedDistance,
                              ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _wideBody(
    AppLocalizations loc,
    TripSessionDisplay display,
    double? odometerDistance,
    double? estimatedDistance,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 520,
          child: ListView(
            padding: EdgeInsets.zero,
            children: _summaryColumn(
              loc,
              display,
              odometerDistance,
              estimatedDistance,
            ),
          ),
        ),
        const SizedBox(width: AutomotiveSpacing.gutter),
        Expanded(flex: 3, child: _tripCharts(loc)),
        const SizedBox(width: AutomotiveSpacing.gutter),
        SizedBox(width: 360, child: _mapPanel(loc)),
      ],
    );
  }

  Widget _narrowBody(
    AppLocalizations loc,
    TripSessionDisplay display,
    double? odometerDistance,
    double? estimatedDistance,
  ) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        ..._summaryColumn(loc, display, odometerDistance, estimatedDistance),
        const SizedBox(height: AutomotiveSpacing.x2),
        SizedBox(height: 960, child: _tripCharts(loc)),
        const SizedBox(height: AutomotiveSpacing.x2),
        SizedBox(height: 360, child: _mapPanel(loc)),
      ],
    );
  }

  List<Widget> _summaryColumn(
    AppLocalizations loc,
    TripSessionDisplay display,
    double? odometerDistance,
    double? estimatedDistance,
  ) {
    final measuredDistance =
        odometerDistance?.takeIfAtLeast(0.01) ??
        estimatedDistance?.takeIfAtLeast(0.01);
    return [
      _TripOverviewPanel(
        display: display,
        odometerDistance: odometerDistance,
        estimatedDistance: estimatedDistance,
        startAmbientTempC: _series.startAmbientTempC,
        endAmbientTempC: _series.endAmbientTempC,
      ),
      const SizedBox(height: AutomotiveSpacing.x2),
      _TripCostPanel(
        costPerKwh: _series.lastChargeCostPerKwh,
        currency: _series.lastChargeCostCurrency,
        estimatedCost: _series.estimatedTripCost,
        usesSocEstimate: _series.measuredAgreesWithSoc != true,
      ),
      const SizedBox(height: AutomotiveSpacing.x2),
      _MeasuredTripEnergyPanel(
        packWh: _series.measuredPackWh,
        tractionWh: _series.measuredTractionWh,
        regeneratedWh: _series.measuredRegeneratedWh,
        auxiliaryWh: _series.measuredAuxiliaryWh,
        agreesWithSoc: _series.measuredAgreesWithSoc,
        measuredWhPerKm: _series.measuredWhPerKm,
        distanceKm: measuredDistance,
      ),
    ];
  }

  Widget _mapPanel(AppLocalizations loc) => TelemetryMapPanel(
    title: loc.tripMapRoute,
    emptyMessage: loc.tripMapNoGps,
    points: _series.mapPreviewPoints,
    totalPointCount: _series.gpsPointCount,
    expanded: true,
    onExpand: _series.mapPreviewPoints.isEmpty ? null : _openExpandedMap,
  );

  Widget _tripCharts(AppLocalizations loc) {
    final chartTypes = _TripChartType.values;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < chartTypes.length; index++) ...[
          Expanded(
            child: _tripChart(
              loc,
              chartTypes[index],
              dense: true,
              onExpand: _hasTripChartData(chartTypes[index])
                  ? () => _openExpandedChart(chartTypes[index])
                  : null,
            ),
          ),
          if (index != chartTypes.length - 1)
            const SizedBox(height: AutomotiveSpacing.x2),
        ],
      ],
    );
  }

  Widget _tripChart(
    AppLocalizations loc,
    _TripChartType type, {
    required bool dense,
    VoidCallback? onExpand,
  }) {
    final powerSpots = [..._series.packPowerSpots, ..._series.drivePowerSpots];
    final expandTooltip = loc.tripChartExpandTooltip;
    return switch (type) {
      _TripChartType.speed => TraceChart(
        title: loc.tripChartSpeed,
        emptyMessage: loc.tripChartNotEnough,
        spots: _series.speedSpots,
        color: AutomotiveColors.secondary,
        minY: 0,
        maxY: paddedMaxY(_series.speedSpots, 20, 180),
        leftReservedSize: 44,
        yLabelDecimals: 0,
        trailing: _pointCountLabel(_series.speedSpots.length, loc),
        dense: dense,
        onExpand: onExpand,
        expandTooltip: expandTooltip,
      ),
      _TripChartType.power => TraceChart(
        title: loc.tripChartPower,
        emptyMessage: _series.measuredAgreesWithSoc == false
            ? loc.tripChartPowerDisagrees
            : loc.tripChartPowerNotEnough,
        spots: _series.packPowerSpots,
        secondarySpots: _series.drivePowerSpots,
        color: AutomotiveColors.warning,
        secondaryColor: AutomotiveColors.tertiary,
        minY: paddedMinY(powerSpots, -500, 0),
        maxY: paddedMaxY(powerSpots, 0, 500),
        leftReservedSize: 48,
        yLabelDecimals: 0,
        showZeroLine: true,
        showArea: false,
        dense: dense,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            LegendDot(
              color: AutomotiveColors.warning,
              label: loc.tripChartPackPower,
            ),
            const SizedBox(width: AutomotiveSpacing.x1),
            LegendDot(
              color: AutomotiveColors.tertiary,
              label: loc.tripChartDrivePower,
            ),
          ],
        ),
        onExpand: onExpand,
        expandTooltip: expandTooltip,
      ),
      _TripChartType.soc => TraceChart(
        title: loc.tripChartSoc,
        emptyMessage: loc.tripChartSocNotEnough,
        spots: _series.socSpots,
        color: AutomotiveColors.batteryPositive,
        minY: paddedMinY(_series.socSpots, 0, 100),
        maxY: paddedMaxY(_series.socSpots, 10, 100),
        leftReservedSize: 44,
        yLabelDecimals: 1,
        trailing: _pointCountLabel(_series.socSpots.length, loc),
        dense: dense,
        onExpand: onExpand,
        expandTooltip: expandTooltip,
      ),
      _TripChartType.elevation => TraceChart(
        title: loc.tripChartElevationDistance,
        emptyMessage: loc.tripChartElevationDistanceNotEnough,
        spots: _series.elevationDistanceSpots,
        color: AutomotiveColors.tertiary,
        minY: paddedMinY(_series.elevationDistanceSpots, -500, 10000),
        maxY: paddedMaxY(_series.elevationDistanceSpots, 10, 10000),
        leftReservedSize: 54,
        yLabelDecimals: 0,
        trailing: _pointCountLabel(_series.elevationDistanceSpots.length, loc),
        xLabelFormatter: _distanceTick,
        minimumXInterval: 0.1,
        dense: dense,
        onExpand: onExpand,
        expandTooltip: expandTooltip,
      ),
    };
  }

  bool _hasTripChartData(_TripChartType type) {
    return switch (type) {
      _TripChartType.speed => _series.speedSpots.length >= 2,
      _TripChartType.power =>
        _series.packPowerSpots.length >= 2 ||
            _series.drivePowerSpots.length >= 2,
      _TripChartType.soc => _series.socSpots.length >= 2,
      _TripChartType.elevation => _series.elevationDistanceSpots.length >= 2,
    };
  }

  String _tripChartTitle(AppLocalizations loc, _TripChartType type) {
    return switch (type) {
      _TripChartType.speed => loc.tripChartSpeed,
      _TripChartType.power => loc.tripChartPower,
      _TripChartType.soc => loc.tripChartSoc,
      _TripChartType.elevation => loc.tripChartElevationDistance,
    };
  }

  Widget _pointCountLabel(int count, AppLocalizations loc) {
    return Text(
      loc.tripChartPointCount(count),
      style: AutomotiveTextStyles.unitLabel.copyWith(
        color: AutomotiveColors.onSurfaceVariant,
        fontSize: 12,
      ),
    );
  }

  void _openExpandedMap() {
    final loc = AppLocalizations.of(context)!;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ExpandedTripMapScreen(
          title: loc.tripMapRoute,
          emptyMessage: loc.tripMapNoGps,
          points: _series.mapExpandedPoints,
          totalPointCount: _series.gpsPointCount,
        ),
      ),
    );
  }

  void _openExpandedChart(_TripChartType type) {
    final loc = AppLocalizations.of(context)!;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ExpandedTripChartScreen(
          title: _tripChartTitle(loc, type),
          chart: _tripChart(loc, type, dense: false),
        ),
      ),
    );
  }
}

class TripDetailHeader extends StatelessWidget {
  const TripDetailHeader({
    super.key,
    required this.display,
    required this.frameCount,
    required this.loading,
    required this.onRefresh,
    this.showRefresh = true,
    this.title,
    this.chips,
  });

  final TripSessionDisplay display;
  final int frameCount;
  final bool loading;
  final VoidCallback onRefresh;
  final bool showRefresh;

  /// Título da barra. Omitir usa o da viagem encerrada.
  final String? title;

  /// Substitui os chips padrão (frames + status). A tela ao vivo troca por
  /// indicadores de fonte, que é o que importa enquanto a viagem corre.
  final List<Widget>? chips;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Container(
      height: AutomotiveDimensions.minTouchTarget,
      padding: const EdgeInsets.symmetric(
        horizontal: AutomotiveSpacing.marginScreen,
      ),
      decoration: BoxDecoration(
        color: AutomotiveColors.surface,
        border: Border(
          bottom: BorderSide(color: AutomotiveColors.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: AutomotiveDimensions.minTouchTarget,
            height: AutomotiveDimensions.minTouchTarget,
            child: IconButton(
              tooltip: loc.detailBack,
              onPressed: () => Navigator.of(context).pop(),
              icon: Icon(Icons.arrow_back),
              color: AutomotiveColors.onSurface,
            ),
          ),
          const SizedBox(width: AutomotiveSpacing.x1),
          Text(
            title ?? loc.tripDetailTitle,
            style: AutomotiveTextStyles.labelCaps.copyWith(
              color: AutomotiveColors.onSurface,
            ),
          ),
          const SizedBox(width: AutomotiveSpacing.x2),
          Flexible(
            child: Text(
              display.shortId,
              overflow: TextOverflow.ellipsis,
              style: AutomotiveTextStyles.unitLabel.copyWith(
                color: AutomotiveColors.onSurfaceVariant,
              ),
            ),
          ),
          const Spacer(),
          // Os chips rolam na horizontal: a tela ao vivo carrega vários e a mesma
          // barra roda em viewports menores que o 1080p do carro.
          Flexible(
            flex: 4,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                children:
                    chips ??
                    [
                      TechnicalChip(
                        label: loc.tripDetailFrames,
                        value: frameCount.toString(),
                      ),
                      const SizedBox(width: AutomotiveSpacing.x1),
                      TechnicalChip(
                        label: loc.detailStatus,
                        value: display.status,
                      ),
                    ],
              ),
            ),
          ),
          if (showRefresh) ...[
            const SizedBox(width: AutomotiveSpacing.x2),
            SizedBox(
              width: AutomotiveDimensions.minTouchTarget,
              height: AutomotiveDimensions.minTouchTarget,
              child: IconButton(
                tooltip: loc.tripDetailRefresh,
                onPressed: loading ? null : onRefresh,
                icon: loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(Icons.refresh),
                color: AutomotiveColors.secondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TripOverviewPanel extends StatelessWidget {
  const _TripOverviewPanel({
    required this.display,
    required this.odometerDistance,
    required this.estimatedDistance,
    required this.startAmbientTempC,
    required this.endAmbientTempC,
  });

  final TripSessionDisplay display;
  final double? odometerDistance;
  final double? estimatedDistance;
  final double? startAmbientTempC;
  final double? endAmbientTempC;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final headlineDistance = odometerDistance ?? estimatedDistance;
    return TechnicalPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SectionHeader(
            icon: Icons.route_outlined,
            label: loc.tripDetailSummary,
          ),
          const SizedBox(height: AutomotiveSpacing.x1_5),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                headlineDistance == null
                    ? '--'
                    : headlineDistance.toStringAsFixed(1),
                style: AutomotiveTextStyles.metricDisplay.copyWith(
                  color: AutomotiveColors.secondary,
                  fontSize: 52,
                ),
              ),
              const SizedBox(width: AutomotiveSpacing.x1),
              Text(
                loc.unitKm,
                style: AutomotiveTextStyles.unitLabel.copyWith(
                  color: AutomotiveColors.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: AutomotiveSpacing.x2),
          Wrap(
            spacing: AutomotiveSpacing.x3,
            runSpacing: AutomotiveSpacing.x2,
            children: [
              SizedBox(
                width: 120,
                child: MetricReadout(
                  label: loc.tripDetailDuration,
                  value: display.durationLabel,
                ),
              ),
              SizedBox(
                width: 170,
                child: MetricReadout(
                  label: loc.tripMetricSocRange,
                  value: display.socRange,
                ),
              ),
              SizedBox(
                width: 200,
                child: MetricReadout(
                  label: loc.tripDetailAmbientTemp,
                  value: ambientTempRangeLabel(
                    startAmbientTempC,
                    endAmbientTempC,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AutomotiveSpacing.x2),
          Divider(height: 1, color: AutomotiveColors.outlineVariant),
          const SizedBox(height: AutomotiveSpacing.x2),
          Wrap(
            spacing: AutomotiveSpacing.x3,
            runSpacing: AutomotiveSpacing.x2,
            children: [
              SizedBox(
                width: 180,
                child: MetricReadout(
                  label: loc.tripDetailOdometerDist,
                  value: distanceLabelFor(odometerDistance, loc),
                ),
              ),
              SizedBox(
                width: 200,
                child: MetricReadout(
                  label: loc.tripDetailSpeedEstDist,
                  value: distanceLabelFor(estimatedDistance, loc),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TripCostPanel extends StatelessWidget {
  const _TripCostPanel({
    required this.costPerKwh,
    required this.currency,
    required this.estimatedCost,
    required this.usesSocEstimate,
  });

  final double? costPerKwh;
  final String? currency;
  final double? estimatedCost;
  final bool usesSocEstimate;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final localeName = Localizations.localeOf(context).toLanguageTag();
    final currencyCode = currency ?? 'BRL';
    final symbol = chargeCurrencySymbolForLocale(
      localeName,
      fallbackCurrency: currencyCode,
    );
    final source = costPerKwh == null
        ? loc.tripDetailCostUnavailable
        : usesSocEstimate
        ? loc.tripDetailCostBasedOnSocAndLastCharge(
            '$symbol ${costPerKwh!.toStringAsFixed(2)}',
          )
        : loc.tripDetailCostBasedOnLastCharge(
            '$symbol ${costPerKwh!.toStringAsFixed(2)}',
          );
    return TechnicalPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SectionHeader(
            icon: Icons.payments_outlined,
            label: loc.tripDetailEstimatedCost,
          ),
          const SizedBox(height: AutomotiveSpacing.x1_5),
          Text(
            estimatedCost == null
                ? '--'
                : '$symbol ${estimatedCost!.toStringAsFixed(2)}',
            style: AutomotiveTextStyles.metricDisplay.copyWith(
              color: estimatedCost == null
                  ? AutomotiveColors.onSurfaceVariant
                  : AutomotiveColors.secondary,
              fontSize: 34,
            ),
          ),
          const SizedBox(height: AutomotiveSpacing.x1),
          Text(
            source,
            style: AutomotiveTextStyles.bodyMd.copyWith(
              color: AutomotiveColors.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _MeasuredTripEnergyPanel extends StatelessWidget {
  const _MeasuredTripEnergyPanel({
    required this.packWh,
    required this.tractionWh,
    required this.regeneratedWh,
    required this.auxiliaryWh,
    required this.agreesWithSoc,
    required this.measuredWhPerKm,
    required this.distanceKm,
  });

  final double? packWh;
  final double? tractionWh;
  final double? regeneratedWh;
  final double? auxiliaryWh;
  final bool? agreesWithSoc;
  final double? measuredWhPerKm;
  final double? distanceKm;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    if (agreesWithSoc != true) {
      return TechnicalPanel(
        padding: const EdgeInsets.symmetric(
          horizontal: AutomotiveSpacing.x2,
          vertical: AutomotiveSpacing.x1_5,
        ),
        borderColor: agreesWithSoc == false
            ? AutomotiveColors.warning
            : AutomotiveColors.outlineVariant,
        child: Row(
          children: [
            Icon(
              agreesWithSoc == false
                  ? Icons.report_outlined
                  : Icons.info_outline,
              size: 18,
              color: agreesWithSoc == false
                  ? AutomotiveColors.warning
                  : AutomotiveColors.onSurfaceVariant,
            ),
            const SizedBox(width: AutomotiveSpacing.x1),
            Expanded(
              child: Text(
                agreesWithSoc == false
                    ? loc.tripDetailMeasuredDisagrees
                    : loc.tripDetailMeasuredUnavailable,
                style: AutomotiveTextStyles.bodyMd.copyWith(
                  color: AutomotiveColors.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return TechnicalPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: SectionHeader(
                  icon: Icons.energy_savings_leaf_outlined,
                  label: loc.tripDetailEnergyAccounting,
                ),
              ),
              StatusBadge(
                label: loc.tripDetailMeasuredVerified,
                color: AutomotiveColors.secondary,
              ),
            ],
          ),
          const SizedBox(height: AutomotiveSpacing.x2),
          _EnergyLedgerHeader(),
          const SizedBox(height: AutomotiveSpacing.x1),
          _EnergyLedgerRow(
            operation: '+',
            label: loc.tripDetailMeasuredTraction,
            description: loc.tripDetailMeasuredTractionDescription,
            energyWh: tractionWh,
            whPerKm: _whPerKm(tractionWh, distanceKm),
          ),
          _EnergyLedgerRow(
            operation: '−',
            label: loc.tripDetailMeasuredRecovered,
            description: loc.tripDetailMeasuredRecoveredDescription,
            energyWh: regeneratedWh,
            whPerKm: _whPerKm(regeneratedWh, distanceKm),
          ),
          _EnergyLedgerRow(
            operation: auxiliaryWh != null && auxiliaryWh! < 0 ? '−' : '+',
            label: loc.tripDetailMeasuredAuxiliary,
            description: loc.tripDetailMeasuredAuxiliaryDescription,
            energyWh: auxiliaryWh?.abs(),
            whPerKm: _whPerKm(auxiliaryWh?.abs(), distanceKm),
            estimated: true,
          ),
          Divider(height: 1, color: AutomotiveColors.outline),
          const SizedBox(height: AutomotiveSpacing.x1),
          _EnergyLedgerRow(
            operation: '=',
            label: loc.tripDetailMeasuredPack,
            description: loc.tripDetailMeasuredPackDescription,
            energyWh: packWh,
            whPerKm: measuredWhPerKm,
            emphasize: true,
          ),
        ],
      ),
    );
  }
}

class _EnergyLedgerHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: EfficiencyUnitController.instance,
      builder: (context, _) {
        final unit = EfficiencyUnitController.instance.unit;
        return Row(
          children: [
            const SizedBox(width: 36),
            const Expanded(child: SizedBox()),
            SizedBox(
              width: 116,
              child: Text(
                'kWh',
                textAlign: TextAlign.right,
                style: AutomotiveTextStyles.labelCaps.copyWith(
                  color: AutomotiveColors.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: AutomotiveSpacing.x2),
            SizedBox(
              width: 104,
              // The whole rate column header is the unit toggle: tapping it
              // cycles EfficiencyUnitController and every row beneath
              // reformats on the same tap, since they all read the same
              // controller rather than holding their own choice.
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => EfficiencyUnitController.instance.cycle(),
                child: Text(
                  efficiencyUnitSuffix(unit, loc),
                  textAlign: TextAlign.right,
                  style: AutomotiveTextStyles.labelCaps.copyWith(
                    color: AutomotiveColors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _EnergyLedgerRow extends StatelessWidget {
  const _EnergyLedgerRow({
    required this.operation,
    required this.label,
    required this.description,
    required this.energyWh,
    required this.whPerKm,
    this.estimated = false,
    this.emphasize = false,
  });

  final String operation;
  final String label;
  final String description;
  final double? energyWh;
  final double? whPerKm;
  final bool estimated;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final valueColor = emphasize
        ? AutomotiveColors.secondary
        : AutomotiveColors.onSurface;
    return ListenableBuilder(
      listenable: EfficiencyUnitController.instance,
      builder: (context, _) => _buildRow(
        context,
        valueColor,
        EfficiencyUnitController.instance.unit,
      ),
    );
  }

  Widget _buildRow(
    BuildContext context,
    Color valueColor,
    EfficiencyUnit unit,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AutomotiveSpacing.x0_5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 36,
            child: Text(
              operation,
              style: AutomotiveTextStyles.headlineMd.copyWith(
                color: valueColor,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style: AutomotiveTextStyles.labelCaps.copyWith(
                          color: valueColor,
                        ),
                      ),
                    ),
                    if (estimated) ...[
                      const SizedBox(width: AutomotiveSpacing.x1),
                      StatusBadge(
                        label: AppLocalizations.of(
                          context,
                        )!.liveChargeBadgeEstimate,
                        color: AutomotiveColors.warning,
                        fontSize: 9,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: AutomotiveSpacing.x0_5),
                Text(
                  description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AutomotiveTextStyles.bodyMd.copyWith(
                    color: AutomotiveColors.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 116,
            child: Text(
              _ledgerEnergyValue(energyWh),
              textAlign: TextAlign.right,
              style: AutomotiveTextStyles.unitLabel.copyWith(
                color: valueColor,
                fontSize: emphasize ? 17 : 15,
              ),
            ),
          ),
          const SizedBox(width: AutomotiveSpacing.x2),
          SizedBox(
            width: 104,
            child: Text(
              formatEfficiencyWhPerKmForUnit(whPerKm, unit),
              textAlign: TextAlign.right,
              style: AutomotiveTextStyles.unitLabel.copyWith(
                color: valueColor,
                fontSize: emphasize ? 17 : 15,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _ledgerEnergyValue(double? energyWh) {
  if (energyWh == null) return '--';
  return (energyWh / 1000).toStringAsFixed(2);
}

double? _whPerKm(double? energyWh, double? distanceKm) {
  if (energyWh == null || distanceKm == null) return null;
  return energyWh / distanceKm;
}

extension on double {
  double? takeIfAtLeast(double minimum) => this >= minimum ? this : null;
}

enum _TripChartType { speed, power, soc, elevation }

class _ExpandedTripChartScreen extends StatelessWidget {
  const _ExpandedTripChartScreen({required this.title, required this.chart});

  final String title;
  final Widget chart;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AutomotiveColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _FullscreenDetailHeader(title: title, closeTooltip: loc.detailBack),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(AutomotiveSpacing.marginScreen),
                child: chart,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExpandedTripMapScreen extends StatelessWidget {
  const _ExpandedTripMapScreen({
    required this.title,
    required this.emptyMessage,
    required this.points,
    required this.totalPointCount,
  });

  final String title;
  final String emptyMessage;
  final List<TelemetryMapPoint> points;
  final int totalPointCount;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AutomotiveColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _FullscreenDetailHeader(title: title, closeTooltip: loc.detailBack),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(AutomotiveSpacing.marginScreen),
                child: TelemetryMapPanel(
                  title: title,
                  emptyMessage: emptyMessage,
                  points: points,
                  totalPointCount: totalPointCount,
                  expanded: true,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FullscreenDetailHeader extends StatelessWidget {
  const _FullscreenDetailHeader({
    required this.title,
    required this.closeTooltip,
  });

  final String title;
  final String closeTooltip;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: AutomotiveDimensions.minTouchTarget,
      padding: const EdgeInsets.symmetric(
        horizontal: AutomotiveSpacing.marginScreen,
      ),
      decoration: BoxDecoration(
        color: AutomotiveColors.surface,
        border: Border(
          bottom: BorderSide(color: AutomotiveColors.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: AutomotiveDimensions.minTouchTarget,
            height: AutomotiveDimensions.minTouchTarget,
            child: IconButton(
              tooltip: closeTooltip,
              onPressed: () => Navigator.of(context).pop(),
              icon: Icon(Icons.close_fullscreen),
              color: AutomotiveColors.onSurface,
            ),
          ),
          const SizedBox(width: AutomotiveSpacing.x2),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AutomotiveTextStyles.labelCaps.copyWith(
                color: AutomotiveColors.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TripFrameSeries {
  const _TripFrameSeries({
    required this.speedEstimatedDistanceKm,
    required this.odometerDistanceKm,
    required this.energyRegeneratedKwh,
    required this.netEnergyKwh,
    required this.efficiencyWhPerKm,
    required this.efficiencyKmPerKwh,
    required this.measuredPackWh,
    required this.measuredTractionWh,
    required this.measuredRegeneratedWh,
    required this.measuredAuxiliaryWh,
    required this.measuredAgreesWithSoc,
    required this.measuredWhPerKm,
    required this.packPowerSpots,
    required this.drivePowerSpots,
    required this.elevationDistanceSpots,
    required this.lastChargeCostPerKwh,
    required this.lastChargeCostCurrency,
    required this.estimatedTripCost,
    required this.speedSpots,
    required this.socSpots,
    required this.altitudeSpots,
    required this.startAmbientTempC,
    required this.endAmbientTempC,
    required this.mapPreviewPoints,
    required this.mapExpandedPoints,
    required this.gpsPointCount,
  });

  static const empty = _TripFrameSeries(
    speedEstimatedDistanceKm: null,
    odometerDistanceKm: null,
    energyRegeneratedKwh: null,
    netEnergyKwh: null,
    efficiencyWhPerKm: null,
    efficiencyKmPerKwh: null,
    measuredPackWh: null,
    measuredTractionWh: null,
    measuredRegeneratedWh: null,
    measuredAuxiliaryWh: null,
    measuredAgreesWithSoc: null,
    measuredWhPerKm: null,
    packPowerSpots: [],
    drivePowerSpots: [],
    elevationDistanceSpots: [],
    lastChargeCostPerKwh: null,
    lastChargeCostCurrency: null,
    estimatedTripCost: null,
    speedSpots: [],
    socSpots: [],
    altitudeSpots: [],
    startAmbientTempC: null,
    endAmbientTempC: null,
    mapPreviewPoints: [],
    mapExpandedPoints: [],
    gpsPointCount: 0,
  );

  final double? speedEstimatedDistanceKm;
  final double? odometerDistanceKm;
  final double? energyRegeneratedKwh;
  final double? netEnergyKwh;
  final double? efficiencyWhPerKm;
  final double? efficiencyKmPerKwh;
  final double? measuredPackWh;
  final double? measuredTractionWh;
  final double? measuredRegeneratedWh;
  final double? measuredAuxiliaryWh;
  final bool? measuredAgreesWithSoc;
  final double? measuredWhPerKm;
  final List<FlSpot> packPowerSpots;
  final List<FlSpot> drivePowerSpots;
  final List<FlSpot> elevationDistanceSpots;
  final double? lastChargeCostPerKwh;
  final String? lastChargeCostCurrency;
  final double? estimatedTripCost;
  final List<FlSpot> speedSpots;
  final List<FlSpot> socSpots;
  final List<FlSpot> altitudeSpots;
  final double? startAmbientTempC;
  final double? endAmbientTempC;
  final List<TelemetryMapPoint> mapPreviewPoints;
  final List<TelemetryMapPoint> mapExpandedPoints;
  final int gpsPointCount;

  factory _TripFrameSeries.fromDetail(TripDetailReading detail) {
    final measuredPowerIsUsable = detail.measuredAgreesWithSoc == true;
    final expandedRoute = detail.routePoints(expanded: true);
    return _TripFrameSeries(
      speedEstimatedDistanceKm: null,
      odometerDistanceKm: detail.distanceKm,
      energyRegeneratedKwh: detail.regeneratedKwh,
      netEnergyKwh: detail.netEnergyKwh,
      efficiencyWhPerKm: detail.efficiencyWhPerKm,
      efficiencyKmPerKwh: detail.efficiencyKmPerKwh,
      measuredPackWh: detail.measuredPackWh,
      measuredTractionWh: detail.measuredTractionWh,
      measuredRegeneratedWh: detail.measuredRegeneratedWh,
      measuredAuxiliaryWh: detail.measuredAuxiliaryWh,
      measuredAgreesWithSoc: detail.measuredAgreesWithSoc,
      measuredWhPerKm: detail.efficiencyWhPerKm,
      packPowerSpots: measuredPowerIsUsable
          ? _flSpots(detail.measuredPackPowerSeries)
          : const [],
      drivePowerSpots: measuredPowerIsUsable
          ? _flSpots(detail.measuredDrivePowerSeries)
          : const [],
      elevationDistanceSpots: _elevationDistanceSpots(expandedRoute),
      lastChargeCostPerKwh: detail.lastChargeCostPerKwh,
      lastChargeCostCurrency: detail.lastChargeCostCurrency,
      estimatedTripCost: detail.estimatedTripCost,
      speedSpots: _flSpots(detail.speedSeries),
      socSpots: _flSpots(detail.socSeries),
      altitudeSpots: _flSpots(detail.altitudeSeries),
      startAmbientTempC: detail.session.startAmbientTemp.displayValue,
      endAmbientTempC: detail.session.endAmbientTemp.displayValue,
      mapPreviewPoints: _mapPoints(detail.routePoints(expanded: false)),
      mapExpandedPoints: _mapPoints(expandedRoute),
      gpsPointCount: detail.gpsPointCount,
    );
  }
}

List<FlSpot> _flSpots(List<TelemetrySeriesPoint> points) {
  return [for (final point in points) FlSpot(point.x, point.y)];
}

List<FlSpot> _elevationDistanceSpots(List<TelemetryRoutePoint> points) {
  const maximumAccuracyM = 50.0;
  final raw = <FlSpot>[];
  TelemetryRoutePoint? previous;
  var distanceKm = 0.0;
  for (final point in points) {
    if (!_validRouteCoordinate(point) ||
        (point.accuracyM != null && point.accuracyM! > maximumAccuracyM)) {
      continue;
    }
    if (previous != null) distanceKm += _routeDistanceKm(previous, point);
    previous = point;
    final altitudeM = point.altitudeM;
    if (altitudeM == null || !altitudeM.isFinite) continue;
    raw.add(FlSpot(distanceKm, altitudeM.clamp(-500, 10000).toDouble()));
  }
  if (raw.length < 3) return raw;

  // GPS altitude is noisy. A centered five-point mean keeps the road profile
  // readable without changing the distance axis or inventing missing points.
  return [
    for (var index = 0; index < raw.length; index++)
      FlSpot(raw[index].x, _meanAltitudeAround(raw, index, radius: 2)),
  ];
}

double _meanAltitudeAround(
  List<FlSpot> spots,
  int center, {
  required int radius,
}) {
  final start = math.max(0, center - radius);
  final end = math.min(spots.length - 1, center + radius);
  var sum = 0.0;
  for (var index = start; index <= end; index++) {
    sum += spots[index].y;
  }
  return sum / (end - start + 1);
}

double _routeDistanceKm(TelemetryRoutePoint first, TelemetryRoutePoint second) {
  const earthRadiusKm = 6371.0088;
  final lat1 = _degreesToRadians(first.latitude);
  final lat2 = _degreesToRadians(second.latitude);
  final deltaLat = lat2 - lat1;
  final deltaLon = _degreesToRadians(second.longitude - first.longitude);
  final a =
      math.sin(deltaLat / 2) * math.sin(deltaLat / 2) +
      math.cos(lat1) *
          math.cos(lat2) *
          math.sin(deltaLon / 2) *
          math.sin(deltaLon / 2);
  final clampedA = a.clamp(0.0, 1.0).toDouble();
  return earthRadiusKm *
      2 *
      math.atan2(math.sqrt(clampedA), math.sqrt(1 - clampedA));
}

double _degreesToRadians(double degrees) => degrees * math.pi / 180;

bool _validRouteCoordinate(TelemetryRoutePoint point) {
  return point.latitude.isFinite &&
      point.longitude.isFinite &&
      point.latitude >= -90 &&
      point.latitude <= 90 &&
      point.longitude >= -180 &&
      point.longitude <= 180 &&
      (point.latitude != 0 || point.longitude != 0);
}

String _distanceTick(double distanceKm) {
  final decimals = distanceKm.abs() < 10 ? 1 : 0;
  return '${distanceKm.toStringAsFixed(decimals)} km';
}

List<TelemetryMapPoint> _mapPoints(List<TelemetryRoutePoint> points) {
  return [
    for (final point in points)
      TelemetryMapPoint(
        latitude: point.latitude,
        longitude: point.longitude,
        altitudeM: point.altitudeM,
        accuracyM: point.accuracyM,
        speedKmh: point.speedKmh,
      ),
  ];
}
