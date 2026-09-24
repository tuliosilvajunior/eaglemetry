import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/telemetry_api.dart';
import '../../core/telemetry_scope.dart';
import '../../core/telemetry_format.dart';
import '../../screens_v2/charge_cost_editor.dart';
import '../../design_system/design_system.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/charge_cost_cryptex.dart';
import '../../widgets/telemetry_map_panel.dart';
import 'charge_detail_header.dart';
import 'charging_session_display.dart';

/// Tela de uma carga **encerrada**.
///
/// A faixa de métricas que ficava no topo saiu. Ela empilhava onze leituras e um
/// botão numa única linha de cartões de largura fixa, gastando a parte mais visível
/// de uma tela de 1080p com o que menos se lê — e empurrando as curvas, que são o
/// motivo de abrir esta tela, para o rodapé.
///
/// No lugar: uma coluna de resumo à esquerda, agrupada pelo que a pessoa está
/// perguntando (quanto entrou, quanto custou, em que condições), e as curvas ocupando
/// o resto. O custo virou um cartão clicável — a ação está no número que ela edita,
/// não num botão que precisava de rótulo próprio.
class ChargeSessionDetailScreen extends StatefulWidget {
  const ChargeSessionDetailScreen({required this.session, super.key});

  final SessionRecord session;

  @override
  State<ChargeSessionDetailScreen> createState() =>
      _ChargeSessionDetailScreenState();
}

class _ChargeSessionDetailScreenState extends State<ChargeSessionDetailScreen> {
  /// Abaixo disto o resumo e as curvas não cabem lado a lado sem espremer as duas.
  static const double _wideBreakpoint = 1180;

  late final TelemetryApi _api = TelemetryScope.of(context);
  late SessionRecord _session;
  ChargeDetailReading? _detail;

  /// How many stored samples stand behind the charts on this screen.
  int _sampleCount = 0;
  double? _defaultChargeCostPerKwh;
  String _chargeCostCurrency = 'BRL';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _loadDetail();
  }

  /// Detalhe e configurações em paralelo: são independentes, e do outro lado da
  /// ponte as leituras agora têm mais de uma thread para atender.
  Future<void> _loadDetail() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final (stored, series, settings) = await (
        _api.getSession(_session.id),
        _api.getSeries(_session.id),
        _api.getTelemetrySettings(),
      ).wait;
      if (!mounted) return;
      setState(() {
        if (stored != null) _session = stored.session;
        _detail = ChargeDetailReading(
          session: stored?.session ?? _session,
          series: series,
          events: stored?.events ?? const [],
        );
        _sampleCount = series.samples.values.fold(
          0,
          (sum, points) => sum + points.length,
        );
        _defaultChargeCostPerKwh = settings.defaultChargeCostPerKwh;
        _chargeCostCurrency = settings.chargeCostCurrency;
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
    final display = ChargingSessionDisplay.fromSession(
      _session,
      loc,
      defaultCostPerKwh: _defaultChargeCostPerKwh,
    );

    return Scaffold(
      backgroundColor: AutomotiveColors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ChargeDetailHeader(
              title: loc.detailTitle,
              shortId: display.shortId,
              loading: _loading,
              onRefresh: _loadDetail,
              chips: [
                TechnicalChip(
                  label: loc.detailFrames,
                  value: _sampleCount.toString(),
                ),
                const SizedBox(width: AutomotiveSpacing.x1),
                TechnicalChip(label: loc.detailPlug, value: display.plugLabel),
                const SizedBox(width: AutomotiveSpacing.x1),
                TechnicalChip(label: loc.detailStatus, value: display.status),
              ],
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
                            ? _wideBody(loc, display)
                            : _narrowBody(loc, display),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _wideBody(AppLocalizations loc, ChargingSessionDisplay display) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 380,
          child: ListView(
            padding: EdgeInsets.zero,
            children: _summaryColumn(loc, display),
          ),
        ),
        const SizedBox(width: AutomotiveSpacing.gutter),
        Expanded(flex: 3, child: _ChargeDetailCharts(detail: _detail)),
        const SizedBox(width: AutomotiveSpacing.gutter),
        SizedBox(width: 340, child: _mapPanel(loc)),
      ],
    );
  }

  Widget _narrowBody(AppLocalizations loc, ChargingSessionDisplay display) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        ..._summaryColumn(loc, display),
        const SizedBox(height: AutomotiveSpacing.x2),
        SizedBox(height: 560, child: _ChargeDetailCharts(detail: _detail)),
        const SizedBox(height: AutomotiveSpacing.x2),
        SizedBox(height: 320, child: _mapPanel(loc)),
      ],
    );
  }

  Widget _mapPanel(AppLocalizations loc) => TelemetryMapPanel(
    title: loc.chargeMapLocation,
    emptyMessage: loc.chargeMapNoGps,
    points: chargeLocationPoint(_session),
    expanded: true,
    showRoute: false,
  );

  /// Resumo em três blocos, na ordem em que se pergunta: quanto entrou, quanto
  /// custou, em que condições aconteceu.
  List<Widget> _summaryColumn(
    AppLocalizations loc,
    ChargingSessionDisplay display,
  ) {
    final energyKwh = _detail?.estimatedEnergyKwh;
    final duration =
        durationFromMillis(sessionReadingDurationMillis(_session)) ??
        boundedDurationBetween(
          dateTimeFromMillis(
            _session.chargeStartedAtUtcMillis ?? _session.startedAtUtcMillis,
          ),
          dateTimeFromMillis(
            _session.plugDisconnectedAtUtcMillis ??
                _session.chargeEndedAtUtcMillis,
          ),
          maximum: const Duration(days: 31),
        );

    return [
      _EnergyHeadline(
        energyKwh: energyKwh,
        socDelta: display.socDelta,
        socRange: display.socRange,
        duration: duration,
      ),
      const SizedBox(height: AutomotiveSpacing.x2),
      _CostPanel(
        session: _session,
        energyKwh: energyKwh,
        defaultCostPerKwh: _defaultChargeCostPerKwh,
        currency: _chargeCostCurrency,
        onEdit: _editCost,
      ),
      const SizedBox(height: AutomotiveSpacing.x2),
      _PowerPanel(detail: _detail, duration: duration, energyKwh: energyKwh),
      const SizedBox(height: AutomotiveSpacing.x2),
      _ContextPanel(session: _session, display: display, duration: duration),
    ];
  }

  Future<void> _editCost() async {
    HapticFeedback.selectionClick();
    final values = await showDialog<_ChargeCostEditResult>(
      context: context,
      builder: (context) => _ChargeCostDialog(
        session: _session,
        defaultCostPerKwh: _defaultChargeCostPerKwh,
        currency: _chargeCostCurrency,
      ),
    );
    if (values == null) return;
    try {
      final result = await _api.updateChargeSessionCost(
        sessionId: _session.id,
        costPerKwh: values.costPerKwh,
        paidAmount: values.paidAmount,
        currency: values.currency,
      );
      if (!mounted) return;
      if (result.ok) {
        // The store holds the price now, so the screen re-reads it rather
        // than trusting the row it was handed.
        HapticFeedback.mediumImpact();
        unawaited(_loadDetail());
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
      HapticFeedback.heavyImpact();
    }
  }
}

/// O número pelo qual a sessão existe, no tamanho que ele merece.
class _EnergyHeadline extends StatelessWidget {
  const _EnergyHeadline({
    required this.energyKwh,
    required this.socDelta,
    required this.socRange,
    required this.duration,
  });

  final double? energyKwh;
  final String socDelta;
  final String socRange;
  final Duration? duration;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return TechnicalPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SectionHeader(icon: Icons.bolt, label: loc.detailEnergyEst),
          const SizedBox(height: AutomotiveSpacing.x1_5),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                energyKwh == null ? '--' : energyKwh!.toStringAsFixed(2),
                style: AutomotiveTextStyles.metricDisplay.copyWith(
                  color: AutomotiveColors.secondary,
                  fontSize: 52,
                ),
              ),
              const SizedBox(width: AutomotiveSpacing.x1),
              Text(
                loc.detailEnergyUnit,
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
                width: 150,
                child: MetricReadout(
                  label: loc.detailSocRange,
                  value: socRange,
                ),
              ),
              SizedBox(
                width: 110,
                child: MetricReadout(
                  label: loc.detailSocDelta,
                  value: socDelta,
                  accent: true,
                ),
              ),
              SizedBox(
                width: 110,
                child: MetricReadout(
                  label: loc.detailDuration,
                  value: formatDuration(duration),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Custo. O painel inteiro é o alvo de toque, porque a ação é sobre o número.
class _CostPanel extends StatelessWidget {
  const _CostPanel({
    required this.session,
    required this.energyKwh,
    required this.defaultCostPerKwh,
    required this.currency,
    required this.onEdit,
  });

  final SessionRecord session;
  final double? energyKwh;
  final double? defaultCostPerKwh;
  final String currency;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final effectiveCurrency = chargeCostCurrencyOf(session, fallback: currency);
    final perKwh = session.costPerKwh ?? defaultCostPerKwh;
    final cost = chargeCostLabel(
      energyKwh: energyKwh,
      costPerKwh: perKwh,
      paidAmount: session.paidAmount,
      currency: effectiveCurrency,
      localeName: loc.localeName,
    );
    final symbol = chargeCurrencySymbolForLocale(
      loc.localeName,
      fallbackCurrency: effectiveCurrency,
    );
    final hasCost = cost != '--';

    return TechnicalPanel(
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onEdit,
          borderRadius: AutomotiveRadii.mdRadius,
          child: Padding(
            padding: const EdgeInsets.all(AutomotiveSpacing.x1),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: SectionHeader(
                        icon: Icons.payments,
                        label: loc.chargeDetailCost,
                      ),
                    ),
                    Icon(
                      Icons.edit,
                      size: 18,
                      color: AutomotiveColors.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: AutomotiveSpacing.x1_5),
                Text(
                  cost,
                  style: AutomotiveTextStyles.metricDisplay.copyWith(
                    color: hasCost
                        ? AutomotiveColors.onSurface
                        : AutomotiveColors.onSurfaceVariant,
                    fontSize: 34,
                  ),
                ),
                const SizedBox(height: AutomotiveSpacing.x1),
                if (!hasCost)
                  Text(
                    loc.chargeDetailNoCost,
                    style: AutomotiveTextStyles.bodyMd.copyWith(
                      color: AutomotiveColors.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  )
                else
                  Wrap(
                    spacing: AutomotiveSpacing.x3,
                    runSpacing: AutomotiveSpacing.x1,
                    children: [
                      SizedBox(
                        width: 140,
                        child: MetricReadout(
                          label: loc.chargeDetailCostPerKwh,
                          value: perKwh == null
                              ? '--'
                              : '$symbol ${perKwh.toStringAsFixed(2)}',
                        ),
                      ),
                      if (session.paidAmount != null)
                        SizedBox(
                          width: 140,
                          child: MetricReadout(
                            label: loc.chargeCostPaidLabel,
                            value:
                                '$symbol ${session.paidAmount!.toStringAsFixed(2)}',
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Como a energia entrou: média, pico e as taxas por hora.
///
/// A média sozinha esconde o formato da sessão — uma perna DC de 80 kW que
/// afunilou para 12 kW tem a mesma média de uma carga AC lenta e comprida.
class _PowerPanel extends StatelessWidget {
  const _PowerPanel({
    required this.detail,
    required this.duration,
    required this.energyKwh,
  });

  final ChargeDetailReading? detail;
  final Duration? duration;
  final double? energyKwh;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final hours = duration == null ? null : duration!.inSeconds / 3600;
    final energyRate = (hours == null || hours <= 0 || energyKwh == null)
        ? null
        : energyKwh! / hours;
    final socSeries = detail?.socSeries ?? const <TelemetrySeriesPoint>[];
    final socRate = (hours == null || hours <= 0 || socSeries.length < 2)
        ? null
        : (socSeries.last.y - socSeries.first.y) / hours;

    return TechnicalPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SectionHeader(
            icon: Icons.speed,
            label: loc.chargeDetailSectionEnergy,
          ),
          const SizedBox(height: AutomotiveSpacing.x1_5),
          Wrap(
            spacing: AutomotiveSpacing.x3,
            runSpacing: AutomotiveSpacing.x2,
            children: [
              SizedBox(
                width: 150,
                child: MetricReadout(
                  label: loc.detailAvgPower,
                  value: detail?.averagePowerKw == null
                      ? '--'
                      : '${detail!.averagePowerKw!.toStringAsFixed(1)} '
                            '${loc.detailAvgPowerUnit}',
                ),
              ),
              SizedBox(
                width: 150,
                child: MetricReadout(
                  label: loc.chargeDetailPeakPower,
                  value: detail?.peakPowerKw == null
                      ? '--'
                      : '${detail!.peakPowerKw!.toStringAsFixed(1)} '
                            '${loc.detailAvgPowerUnit}',
                  accent: true,
                ),
              ),
              SizedBox(
                width: 150,
                child: MetricReadout(
                  label: loc.chargeDetailEnergyRate,
                  value: energyRate == null
                      ? '--'
                      : '${energyRate.toStringAsFixed(1)} '
                            '${loc.detailEnergyUnit}/h',
                ),
              ),
              SizedBox(
                width: 150,
                child: MetricReadout(
                  label: loc.chargeDetailSocRate,
                  value: socRate == null
                      ? '--'
                      : '${socRate >= 0 ? '+' : ''}'
                            '${socRate.toStringAsFixed(1)} '
                            '${loc.chargeDetailSocPerHour}',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Em que condições a carga aconteceu: quando, onde no hodômetro, a que
/// temperatura, e por que terminou.
class _ContextPanel extends StatelessWidget {
  const _ContextPanel({
    required this.session,
    required this.display,
    required this.duration,
  });

  final SessionRecord session;
  final ChargingSessionDisplay display;
  final Duration? duration;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final started = dateTimeFromMillis(
      session.chargeStartedAtUtcMillis ?? session.startedAtUtcMillis,
    );
    final ended = dateTimeFromMillis(
      session.plugDisconnectedAtUtcMillis ?? session.chargeEndedAtUtcMillis,
    );

    return TechnicalPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SectionHeader(
            icon: Icons.info_outline,
            label: loc.chargeDetailSectionContext,
          ),
          const SizedBox(height: AutomotiveSpacing.x1_5),
          Wrap(
            spacing: AutomotiveSpacing.x3,
            runSpacing: AutomotiveSpacing.x2,
            children: [
              SizedBox(
                width: 165,
                child: MetricReadout(
                  label: loc.chargeDetailStartedAt,
                  value: started == null ? '--' : formatDateTime(started),
                ),
              ),
              SizedBox(
                width: 165,
                child: MetricReadout(
                  label: loc.chargeDetailEndedAt,
                  value: ended == null ? '--' : formatDateTime(ended),
                ),
              ),
              SizedBox(
                width: 165,
                child: MetricReadout(
                  label: loc.detailOdometer,
                  value: chargeOdometerRange(
                    session.startOdometer.displayValue,
                    session.endOdometer.displayValue,
                  ),
                ),
              ),
              SizedBox(
                width: 165,
                child: MetricReadout(
                  label: loc.detailAmbientTemp,
                  value: ambientTempRangeLabel(
                    session.startAmbientTemp.displayValue,
                    session.endAmbientTemp.displayValue,
                  ),
                ),
              ),
              SizedBox(
                width: 345,
                child: MetricReadout(
                  label: loc.detailEndReason,
                  value: display.endReason,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChargeCostEditResult {
  const _ChargeCostEditResult({
    required this.costPerKwh,
    required this.paidAmount,
    required this.currency,
  });

  final double? costPerKwh;
  final double? paidAmount;
  final String currency;
}

class _ChargeCostDialog extends StatefulWidget {
  const _ChargeCostDialog({
    required this.session,
    required this.defaultCostPerKwh,
    required this.currency,
  });

  final SessionRecord session;
  final double? defaultCostPerKwh;
  final String currency;

  @override
  State<_ChargeCostDialog> createState() => _ChargeCostDialogState();
}

class _ChargeCostDialogState extends State<_ChargeCostDialog> {
  late double _costPerKwh;
  late double _paidAmount;

  @override
  void initState() {
    super.initState();
    _costPerKwh = (widget.session.costPerKwh ?? widget.defaultCostPerKwh ?? 0.0)
        .clamp(0.0, 99.99)
        .toDouble();
    _paidAmount = (widget.session.paidAmount ?? 0.0)
        .clamp(0.0, 9999.99)
        .toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final currencySymbol = chargeCurrencySymbolForLocale(
      loc.localeName,
      fallbackCurrency: widget.currency,
    );
    return AlertDialog(
      backgroundColor: AutomotiveColors.surfaceContainer,
      title: Text(loc.chargeCostDialogTitle),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              loc.chargeCostPerKwhLabel,
              style: AutomotiveTextStyles.labelCaps.copyWith(
                color: AutomotiveColors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AutomotiveSpacing.x1),
            ChargeCostCryptex(
              value: _costPerKwh,
              currency: currencySymbol,
              suffix: '/ kWh',
              onChanged: (value) => setState(() => _costPerKwh = value),
            ),
            const SizedBox(height: AutomotiveSpacing.x1),
            Text(
              loc.chargeCostPerKwhHint,
              style: AutomotiveTextStyles.unitLabel.copyWith(
                color: AutomotiveColors.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: AutomotiveSpacing.x3),
            Text(
              loc.chargeCostPaidLabel,
              style: AutomotiveTextStyles.labelCaps.copyWith(
                color: AutomotiveColors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AutomotiveSpacing.x1),
            ChargeCostCryptex(
              value: _paidAmount,
              currency: currencySymbol,
              integerDigits: 4,
              onChanged: (value) => setState(() => _paidAmount = value),
            ),
            const SizedBox(height: AutomotiveSpacing.x1),
            Text(
              loc.chargeCostPaidHint,
              style: AutomotiveTextStyles.unitLabel.copyWith(
                color: AutomotiveColors.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(loc.settingsCancel),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop(
              _ChargeCostEditResult(
                costPerKwh: _costPerKwh == 0 ? null : _costPerKwh,
                paidAmount: _paidAmount == 0 ? null : _paidAmount,
                currency: widget.currency,
              ),
            );
          },
          child: Text(loc.actionSave),
        ),
      ],
    );
  }
}

/// As quatro curvas da sessão.
///
/// Empilhadas, não em grade 2x2: o eixo X das quatro é o mesmo tempo, e uma sobre
/// a outra permite ler verticalmente — onde a corrente caiu, o que a potência fez,
/// como o SOC reagiu — que é a leitura que responde "por que essa carga demorou".
class _ChargeDetailCharts extends StatelessWidget {
  const _ChargeDetailCharts({required this.detail});

  final ChargeDetailReading? detail;

  static List<FlSpot> _spots(List<TelemetrySeriesPoint>? series) => [
    for (final point in series ?? const <TelemetrySeriesPoint>[])
      FlSpot(point.x, point.y),
  ];

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final charts = <Widget>[
      _chartFor(
        loc.chartChargePower,
        loc.chartPowerUnit,
        _spots(detail?.powerSeries),
        AutomotiveColors.secondary,
        loc,
      ),
      _chartFor(
        loc.chartSocTrace,
        loc.chartSocUnit,
        _spots(detail?.socSeries),
        AutomotiveColors.batteryPositive,
        loc,
      ),
      _chartFor(
        loc.chartPackVoltage,
        loc.chartVoltageUnit,
        _spots(detail?.voltageSeries),
        AutomotiveColors.tertiary,
        loc,
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < charts.length; i++) ...[
          Expanded(child: charts[i]),
          if (i != charts.length - 1)
            const SizedBox(height: AutomotiveSpacing.x2),
        ],
      ],
    );
  }

  TraceChart _chartFor(
    String title,
    String unit,
    List<FlSpot> spots,
    Color color,
    AppLocalizations loc,
  ) {
    final maxValue = spots.fold(
      0.0,
      (double max, FlSpot spot) => spot.y > max ? spot.y : max,
    );
    final minValue = spots.fold(
      double.infinity,
      (double min, FlSpot spot) => spot.y < min ? spot.y : min,
    );
    final effectiveMin = minValue.isFinite ? minValue : 0.0;
    final padding = math.max(
      (maxValue - effectiveMin) * 0.15,
      chargeMinimumPadding(unit),
    );
    final minY = math.max(0, effectiveMin - padding).floorToDouble();
    final maxY = math
        .max(minY + chargeMinimumRange(unit), maxValue + padding)
        .ceilToDouble();

    return TraceChart(
      title: title,
      emptyMessage: loc.chartNotEnough,
      spots: spots,
      color: color,
      minY: minY,
      maxY: maxY,
      leftReservedSize: 46,
      yLabelDecimals: 0,
      dense: true,
      trailing: Text(
        loc.chargeDetailSamples(spots.length),
        style: AutomotiveTextStyles.unitLabel.copyWith(
          color: AutomotiveColors.onSurfaceVariant,
          fontSize: 12,
        ),
      ),
    );
  }
}
