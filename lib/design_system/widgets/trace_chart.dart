import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../automotive_colors.dart';
import '../automotive_spacing.dart';
import '../automotive_typography.dart';

/// Time-series line chart surface used by trip/charge detail and live trip
/// views.
///
/// Unifies the previously duplicated `_TraceChart` and `_LiveTraceChart`.
/// Pass [height] for a fixed-height panel (history detail) or omit it when the
/// chart must expand inside a flex parent (live trip). Use [trailing] for the
/// header annotation (e.g. sample count or window label).
class TraceChart extends StatelessWidget {
  const TraceChart({
    required this.title,
    required this.emptyMessage,
    required this.spots,
    required this.color,
    required this.minY,
    required this.maxY,
    required this.leftReservedSize,
    required this.yLabelDecimals,
    this.secondarySpots = const [],
    this.secondaryColor,
    this.height,
    this.trailing,
    this.onExpand,
    this.expandTooltip,
    this.showXAxis = true,
    this.horizontalDivisions = 4,
    this.showZeroLine = false,
    this.minX,
    this.maxX,
    this.isCurved = false,
    this.showArea = true,
    this.xLabelFormatter,
    this.minimumXInterval = 10,
    this.animationDuration = const Duration(milliseconds: 150),
    this.dense = false,
    super.key,
  });

  final String title;
  final String emptyMessage;
  final List<FlSpot> spots;
  final Color color;
  final double minY;
  final double maxY;
  final double leftReservedSize;
  final int yLabelDecimals;
  final List<FlSpot> secondarySpots;
  final Color? secondaryColor;
  final double? height;
  final Widget? trailing;
  final VoidCallback? onExpand;
  final String? expandTooltip;
  final bool showXAxis;
  final int horizontalDivisions;
  final bool showZeroLine;
  final double? minX;
  final double? maxX;
  final bool isCurved;
  final bool showArea;
  final String Function(double value)? xLabelFormatter;
  final double minimumXInterval;
  final Duration animationDuration;

  /// Cabeçalho e margens menores, para quando vários gráficos dividem uma faixa
  /// estreita — três lado a lado na tela ao vivo não cabem com o título de 24 px.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final effectiveMinX = minX ?? 0.0;
    final primaryMaxX = spots.isEmpty ? 0.0 : spots.last.x;
    final secondaryMaxX = secondarySpots.isEmpty ? 0.0 : secondarySpots.last.x;
    final inferredMaxX = primaryMaxX > secondaryMaxX
        ? primaryMaxX
        : secondaryMaxX;
    final effectiveMaxX =
        maxX ?? inferredMaxX.clamp(1.0, double.infinity).toDouble();
    final effectiveMinY = minY >= maxY ? 0.0 : minY;
    final effectiveMaxY = minY >= maxY ? 1.0 : maxY;

    final chart = Container(
      padding: dense
          ? AutomotiveSpacing.compactPanelPadding
          : AutomotiveSpacing.panelPadding,
      decoration: BoxDecoration(
        color: AutomotiveColors.surfaceContainer,
        border: Border.all(color: AutomotiveColors.outlineVariant),
        borderRadius: AutomotiveRadii.lgRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              // O título cede espaço em vez de empurrar a anotação para fora: o
              // mesmo gráfico aparece sozinho num painel largo e em trio numa faixa.
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      (dense
                              ? AutomotiveTextStyles.bodyLg
                              : AutomotiveTextStyles.headlineMd)
                          .copyWith(color: AutomotiveColors.onSurface),
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: AutomotiveSpacing.x1),
                trailing!,
              ],
              if (onExpand != null) ...[
                const SizedBox(width: AutomotiveSpacing.x1),
                SizedBox(
                  width: 44,
                  height: 44,
                  child: IconButton(
                    tooltip: expandTooltip,
                    onPressed: onExpand,
                    icon: Icon(Icons.open_in_full),
                    color: AutomotiveColors.secondary,
                  ),
                ),
              ],
            ],
          ),
          SizedBox(height: dense ? AutomotiveSpacing.x1 : AutomotiveSpacing.x2),
          Expanded(
            child: spots.length < 2 && secondarySpots.length < 2
                ? Center(
                    child: Text(
                      emptyMessage,
                      style: AutomotiveTextStyles.unitLabel.copyWith(
                        color: AutomotiveColors.onSurfaceVariant,
                      ),
                    ),
                  )
                : LineChart(
                    LineChartData(
                      minX: effectiveMinX,
                      maxX: effectiveMaxX,
                      minY: effectiveMinY,
                      maxY: effectiveMaxY,
                      extraLinesData: ExtraLinesData(
                        extraLinesOnTop: true,
                        horizontalLines:
                            showZeroLine &&
                                effectiveMinY < 0 &&
                                effectiveMaxY > 0
                            ? [
                                HorizontalLine(
                                  y: 0,
                                  color: AutomotiveColors.onSurfaceVariant
                                      .withValues(alpha: 0.9),
                                  strokeWidth: 2,
                                ),
                              ]
                            : const <HorizontalLine>[],
                      ),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        horizontalInterval:
                            ((effectiveMaxY - effectiveMinY) /
                                    horizontalDivisions)
                                .clamp(1.0, 100.0),
                        getDrawingHorizontalLine: (_) => FlLine(
                          color: AutomotiveColors.outlineVariant.withValues(
                            alpha: 0.55,
                          ),
                          strokeWidth: 1,
                        ),
                      ),
                      titlesData: FlTitlesData(
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: leftReservedSize,
                            getTitlesWidget: (value, meta) => Text(
                              value.toStringAsFixed(yLabelDecimals),
                              style: AutomotiveTextStyles.unitLabel.copyWith(
                                color: AutomotiveColors.onSurfaceVariant,
                                fontSize: 10,
                              ),
                            ),
                          ),
                        ),
                        bottomTitles: showXAxis
                            ? AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  reservedSize: 26,
                                  // Interval derived from the visible span so
                                  // the axis never exceeds 5 tick labels;
                                  // clamping to a fixed max interval flooded
                                  // long sessions with dozens of labels.
                                  interval:
                                      ((effectiveMaxX - effectiveMinX) / 4)
                                          .clamp(
                                            minimumXInterval,
                                            double.infinity,
                                          ),
                                  getTitlesWidget: (value, meta) => Text(
                                    xLabelFormatter?.call(value) ??
                                        _durationTick(value),
                                    style: AutomotiveTextStyles.unitLabel
                                        .copyWith(
                                          color:
                                              AutomotiveColors.onSurfaceVariant,
                                          fontSize: 10,
                                        ),
                                  ),
                                ),
                              )
                            : const AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                        topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                      ),
                      borderData: FlBorderData(
                        show: true,
                        border: Border.all(
                          color: AutomotiveColors.outlineVariant,
                        ),
                      ),
                      lineTouchData: const LineTouchData(enabled: false),
                      lineBarsData: [
                        if (spots.isNotEmpty)
                          LineChartBarData(
                            spots: spots,
                            color: color,
                            barWidth: 2,
                            isCurved: isCurved,
                            isStrokeCapRound: true,
                            dotData: const FlDotData(show: false),
                            belowBarData: BarAreaData(
                              show: showArea,
                              color: color.withValues(alpha: 0.10),
                            ),
                          ),
                        if (secondarySpots.isNotEmpty)
                          LineChartBarData(
                            spots: secondarySpots,
                            color: secondaryColor ?? color,
                            barWidth: 2,
                            isCurved: isCurved,
                            isStrokeCapRound: true,
                            dotData: const FlDotData(show: false),
                            belowBarData: BarAreaData(show: false),
                          ),
                      ],
                    ),
                    duration: animationDuration,
                  ),
          ),
        ],
      ),
    );

    if (height != null) {
      return SizedBox(height: height, child: chart);
    }
    return chart;
  }
}

String _durationTick(double seconds) {
  final rounded = seconds.round();
  final minutes = rounded ~/ 60;
  final remainingSeconds = rounded % 60;
  if (minutes <= 0) return '${remainingSeconds}s';
  final hours = minutes ~/ 60;
  final remainingMinutes = minutes % 60;
  if (hours <= 0) return '${minutes}m';
  return remainingMinutes == 0 ? '${hours}h' : '${hours}h${remainingMinutes}m';
}
