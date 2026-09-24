import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:capy_energy/l10n/app_localizations.dart';

import '../core/efficiency_unit.dart';
import '../core/telemetry_api.dart';
import '../core/telemetry_format.dart' show formatDuration;
import '../core/telemetry_scope.dart';
import '../design_system/design_system.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late final TelemetryApi _api = TelemetryScope.of(context);
  String _range = '7d';

  /// The read this screen is. The range is read from the field at call time, so
  /// a switch changes the field and asks again; the answer to the range the
  /// reader left is dropped when it lands.
  late final TelemetryQuery<HistorySummaryReading> _history = TelemetryQuery(
    read: _readHistory,
    debugLabel: 'HistoryScreen',
  );

  /// The window, read as one list and reduced here.
  ///
  /// The store answers three questions and this is the first of them; the
  /// timeline and the totals are a fold over the rows it returns, not a
  /// fourth question for the car to answer.
  Future<HistorySummaryReading> _readHistory() async {
    final range = _range;
    final now = DateTime.now();
    final start = historyRangeStart(range, now);
    final page = await _api.listSessions(
      filter: SessionFilter(fromUtcMillis: start.millisecondsSinceEpoch),
      page: const PageRequest(limit: 500),
    );
    return HistorySummaryReading.fromSessions(
      range: range,
      start: start,
      end: now,
      records: page.sessions,
      weekdayLabels: _weekdayLabels,
    );
  }

  /// Three letters per day, in the order `DateTime.weekday % 7` produces.
  static const _weekdayLabels = [
    'SUN',
    'MON',
    'TUE',
    'WED',
    'THU',
    'FRI',
    'SAT',
  ];

  @override
  void initState() {
    super.initState();
    _history.addListener(_onQueryChanged);
    unawaited(_history.refresh(showLoading: true));
  }

  @override
  void dispose() {
    _history.removeListener(_onQueryChanged);
    _history.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    if (mounted) setState(() {});
  }

  void _selectRange(String range) {
    if (_range == range) return;
    HapticFeedback.selectionClick();
    setState(() => _range = range);
    unawaited(_history.ask());
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final history = _history.state;
    final result = history.value;
    return ColoredBox(
      color: AutomotiveColors.background,
      child: Column(
        children: [
          ScreenHeaderBar(
            title: loc.appBarTitle,
            subtitle: loc.historyHeaderSubtitle,
            trailing: [
              TechnicalChip(
                label: loc.historyRangeChip,
                value: _range.toUpperCase(),
              ),
              const SizedBox(width: AutomotiveSpacing.x1),
              TechnicalChip(
                label: loc.historySessionsChip,
                value: (result?.metrics.sessionCount ?? 0).toString(),
              ),
              const SizedBox(width: AutomotiveSpacing.x2),
              RefreshIconButton(
                tooltip: loc.historyRefreshTooltip,
                loading: history.isLoading,
                onPressed: () {
                  HapticFeedback.selectionClick();
                  unawaited(_history.refresh(showLoading: true));
                },
              ),
            ],
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(AutomotiveSpacing.marginScreen),
              children: [
                _TitleRow(range: _range, onRangeSelected: _selectRange),
                const SizedBox(height: AutomotiveSpacing.x3),
                if (history.isFirstLoad)
                  TechnicalPanel(child: const LoadingPanel(height: 160))
                else if (history.errorMessage != null)
                  ErrorPanel(
                    message: history.errorMessage!,
                    icon: Icons.error_outline,
                  )
                else if (result == null)
                  EmptyStatePanel(message: loc.historyEmptyPanel)
                else ...[
                  _SummaryGrid(metrics: result.metrics),
                  const SizedBox(height: AutomotiveSpacing.x3),
                  _TimelinePanel(days: result.timelineDays),
                  const SizedBox(height: AutomotiveSpacing.x3),
                  _SessionLogPanel(sessions: result.sessions),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TitleRow extends StatelessWidget {
  const _TitleRow({required this.range, required this.onRangeSelected});

  final String range;
  final ValueChanged<String> onRangeSelected;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 760;
        return Wrap(
          spacing: AutomotiveSpacing.x2,
          runSpacing: AutomotiveSpacing.x2,
          crossAxisAlignment: WrapCrossAlignment.end,
          alignment: WrapAlignment.spaceBetween,
          children: [
            SizedBox(
              width: compact
                  ? constraints.maxWidth
                  : constraints.maxWidth * 0.42,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    loc.historyPageTitle,
                    style: AutomotiveTextStyles.headlineLg.copyWith(
                      color: AutomotiveColors.onSurface,
                    ),
                  ),
                  const SizedBox(height: AutomotiveSpacing.x0_5),
                  Text(
                    loc.historyPageDesc,
                    style: AutomotiveTextStyles.bodyMd.copyWith(
                      color: AutomotiveColors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            SegmentedFilter<String>(
              segmentHeight: 40,
              color: AutomotiveColors.surfaceContainer,
              options: [
                FilterOption('today', loc.rangeToday.toUpperCase()),
                FilterOption('24h', loc.range24h.toUpperCase()),
                FilterOption('7d', loc.range7d.toUpperCase()),
                FilterOption('30d', loc.range30d.toUpperCase()),
              ],
              selected: range,
              onSelected: onRangeSelected,
            ),
          ],
        );
      },
    );
  }
}

class _SummaryGrid extends StatelessWidget {
  const _SummaryGrid({required this.metrics});

  final HistoryWindowMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final distance = metrics.totalTripDistanceKm;
    final distanceUnit = distance != null
        ? loc.historyDistanceUnitOdometer
        : loc.historyDistanceUnitMissing;
    final cards = [
      _SummaryMetric(
        icon: Icons.route,
        label: loc.historyTrips,
        value: metrics.tripCount.toString(),
        unit: loc.historyTripsUnit,
        color: AutomotiveColors.tertiary,
      ),
      _SummaryMetric(
        icon: Icons.ev_station,
        label: loc.historyCharges,
        value: metrics.chargeCount.toString(),
        unit: loc.historyChargesUnit,
        color: AutomotiveColors.secondary,
      ),
      _SummaryMetric(
        icon: Icons.social_distance,
        label: loc.historyDistance,
        value: _formatNumber(distance, decimals: 1),
        unit: 'km $distanceUnit',
        color: AutomotiveColors.onSurface,
      ),
      _SummaryMetric(
        icon: Icons.bolt,
        label: loc.historyEfficiency,
        value: _formatNumber(metrics.averageEfficiencyWhPerKm, decimals: 0),
        unit: loc.historyEfficiencyUnit,
        color: AutomotiveColors.onSurface,
      ),
      _SummaryMetric(
        icon: Icons.battery_charging_full,
        label: loc.historySocDelta,
        value: _formatSigned(metrics.socDeltaPercent, decimals: 1),
        unit: loc.historySocDeltaUnit,
        color: AutomotiveColors.onSurface,
      ),
      _SummaryMetric(
        icon: Icons.energy_savings_leaf,
        label: loc.historyRegen,
        value: _formatNumber(metrics.regenRecoveredKwh, decimals: 2),
        unit: loc.historyEnergyUnit,
        color: AutomotiveColors.secondary,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 980
            ? 3
            : constraints.maxWidth >= 640
            ? 2
            : 1;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: cards.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: AutomotiveSpacing.gutter,
            mainAxisSpacing: AutomotiveSpacing.gutter,
            mainAxisExtent: 132,
          ),
          itemBuilder: (context, index) => cards[index],
        );
      },
    );
  }
}

class _SummaryMetric extends StatelessWidget {
  const _SummaryMetric({
    required this.icon,
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final String unit;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return TechnicalPanel(
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              border: Border.all(color: color.withValues(alpha: 0.28)),
              borderRadius: AutomotiveRadii.baseRadius,
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: AutomotiveSpacing.x2),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AutomotiveTextStyles.labelCaps.copyWith(
                    color: AutomotiveColors.outline,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: AutomotiveSpacing.x1),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AutomotiveTextStyles.headlineLg.copyWith(
                          color: color,
                          fontFamily: AutomotiveFonts.mono,
                        ),
                      ),
                    ),
                    const SizedBox(width: AutomotiveSpacing.x1),
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          unit,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AutomotiveTextStyles.unitLabel.copyWith(
                            color: AutomotiveColors.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TimelinePanel extends StatelessWidget {
  const _TimelinePanel({required this.days});

  final List<HistoryTimelineDay> days;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return TechnicalPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                loc.timelineTitle,
                style: AutomotiveTextStyles.labelCaps.copyWith(
                  color: AutomotiveColors.outline,
                ),
              ),
              const Spacer(),
              LegendDot(
                color: AutomotiveColors.tertiary,
                label: loc.timelineTrip,
              ),
              const SizedBox(width: AutomotiveSpacing.x2),
              LegendDot(
                color: AutomotiveColors.secondary,
                label: loc.timelineCharge,
              ),
            ],
          ),
          const SizedBox(height: AutomotiveSpacing.x3),
          if (days.isEmpty)
            _InlineEmpty(message: loc.timelineEmpty)
          else
            for (final day in days) ...[
              _TimelineDayRow(day: day),
              const SizedBox(height: AutomotiveSpacing.x1_5),
            ],
          const SizedBox(height: AutomotiveSpacing.x1),
          const _TimelineAxis(),
        ],
      ),
    );
  }
}

class _TimelineDayRow extends StatelessWidget {
  const _TimelineDayRow({required this.day});

  final HistoryTimelineDay day;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Row(
      children: [
        SizedBox(
          width: 48,
          child: Text(
            _localizedDayLabel(day.label, loc),
            textAlign: TextAlign.right,
            style: AutomotiveTextStyles.unitLabel.copyWith(
              color: day.blocks.isEmpty
                  ? AutomotiveColors.outline
                  : AutomotiveColors.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(width: AutomotiveSpacing.x2),
        Expanded(
          child: SizedBox(
            height: 32,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return DecoratedBox(
                  decoration: BoxDecoration(
                    color: AutomotiveColors.surfaceContainerHigh,
                    borderRadius: AutomotiveRadii.smRadius,
                    border: Border.all(color: AutomotiveColors.technicalBorder),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      for (final block in day.blocks)
                        Positioned(
                          left:
                              block.startFraction.clamp(0, 1) *
                              constraints.maxWidth,
                          width:
                              ((block.endFraction - block.startFraction).clamp(
                                        0.0,
                                        1.0,
                                      ) *
                                      constraints.maxWidth)
                                  .clamp(2.0, constraints.maxWidth),
                          top: 0,
                          bottom: 0,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: _blockColor(block.type),
                              borderRadius: AutomotiveRadii.smRadius,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _TimelineAxis extends StatelessWidget {
  const _TimelineAxis();

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Row(
      children: [
        const SizedBox(width: 64),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children:
                [
                      loc.timelineTick0000,
                      loc.timelineTick0600,
                      loc.timelineTick1200,
                      loc.timelineTick1800,
                      loc.timelineTick2359,
                    ]
                    .map(
                      (label) => Text(
                        label,
                        style: AutomotiveTextStyles.unitLabel.copyWith(
                          color: AutomotiveColors.outline,
                          fontSize: 10,
                        ),
                      ),
                    )
                    .toList(growable: false),
          ),
        ),
      ],
    );
  }
}

class _SessionLogPanel extends StatelessWidget {
  const _SessionLogPanel({required this.sessions});

  final List<HistorySessionRow> sessions;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return TechnicalPanel(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(AutomotiveSpacing.x3),
            child: Text(
              loc.sessionLogTitle,
              style: AutomotiveTextStyles.labelCaps.copyWith(
                color: AutomotiveColors.onSurface,
              ),
            ),
          ),
          Divider(height: 1, color: AutomotiveColors.outlineVariant),
          if (sessions.isEmpty)
            Padding(
              padding: const EdgeInsets.all(AutomotiveSpacing.x3),
              child: _InlineEmpty(message: loc.sessionLogEmpty),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                return ListenableBuilder(
                  listenable: EfficiencyUnitController.instance,
                  builder: (context, _) {
                    final unit = EfficiencyUnitController.instance.unit;
                    return SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minWidth: constraints.maxWidth,
                        ),
                        child: DataTable(
                          headingRowColor: WidgetStateProperty.all(
                            AutomotiveColors.surfaceContainerLowest,
                          ),
                          dataRowMinHeight: 56,
                          dataRowMaxHeight: 64,
                          headingTextStyle: AutomotiveTextStyles.labelCaps
                              .copyWith(
                                color: AutomotiveColors.outline,
                                fontSize: 11,
                              ),
                          dataTextStyle: AutomotiveTextStyles.bodyMd.copyWith(
                            color: AutomotiveColors.onSurface,
                          ),
                          columns: [
                            DataColumn(
                              label: Text(loc.sessionLogHeaderSession),
                            ),
                            DataColumn(label: Text(loc.sessionLogHeaderStart)),
                            DataColumn(
                              label: Text(loc.sessionLogHeaderDuration),
                            ),
                            DataColumn(label: Text(loc.sessionLogHeaderSoc)),
                            DataColumn(
                              // Charge rows show kWh in this same column, so
                              // the header states the generic column name
                              // rather than the trip-only unit; tapping still
                              // cycles it, since the toggle is one control for
                              // the whole app regardless of which column shows
                              // it.
                              label: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () =>
                                    EfficiencyUnitController.instance.cycle(),
                                child: Text(loc.sessionLogHeaderEnergy),
                              ),
                            ),
                            DataColumn(label: Text(loc.sessionLogHeaderStatus)),
                          ],
                          rows: sessions
                              .map((s) => _sessionRow(s, loc, unit))
                              .toList(growable: false),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
        ],
      ),
    );
  }

  DataRow _sessionRow(
    HistorySessionRow session,
    AppLocalizations loc,
    EfficiencyUnit unit,
  ) {
    final isCharge = session.type == 'CHARGE';
    final color = isCharge
        ? AutomotiveColors.secondary
        : AutomotiveColors.tertiary;
    final subtitle = session.reason == null || session.reason!.isEmpty
        ? session.id
        : '${session.id} / ${session.reason}';
    return DataRow(
      cells: [
        DataCell(
          Row(
            children: [
              Icon(
                isCharge ? Icons.ev_station : Icons.directions_car,
                color: color,
                size: 20,
              ),
              const SizedBox(width: AutomotiveSpacing.x1),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isCharge ? loc.sessionTypeCharging : loc.sessionTypeTrip,
                    style: AutomotiveTextStyles.bodyMd.copyWith(
                      color: AutomotiveColors.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(
                    width: 220,
                    child: Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AutomotiveTextStyles.unitLabel.copyWith(
                        color: AutomotiveColors.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        DataCell(Text(_formatDateTime(session.startUtcMillis))),
        DataCell(Text(_formatDuration(session.durationMillis))),
        DataCell(Text(_formatSoc(session))),
        DataCell(
          Text(
            isCharge
                ? '${_formatNumber(session.energyKwh, decimals: 2)} kWh'
                : formatEfficiencyWhPerKmForUnit(
                    session.efficiencyWhPerKm,
                    unit,
                  ),
          ),
        ),
        DataCell(
          StatusBadge(label: session.status.toUpperCase(), color: color),
        ),
      ],
    );
  }
}

class _InlineEmpty extends StatelessWidget {
  const _InlineEmpty({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Text(
      message,
      style: AutomotiveTextStyles.bodyMd.copyWith(
        color: AutomotiveColors.onSurfaceVariant,
      ),
    );
  }
}

Color _blockColor(String type) {
  return type == 'CHARGE'
      ? AutomotiveColors.secondary
      : AutomotiveColors.tertiary;
}

String _formatNumber(double? value, {required int decimals}) {
  if (value == null) return '--';
  return value.toStringAsFixed(decimals);
}

String _formatSigned(double? value, {required int decimals}) {
  if (value == null) return '--';
  final prefix = value > 0 ? '+' : '';
  return '$prefix${value.toStringAsFixed(decimals)}';
}

String _formatSoc(HistorySessionRow session) {
  final start = _formatNumber(session.socStart, decimals: 1);
  final end = _formatNumber(session.socEnd, decimals: 1);
  final delta = _formatSigned(session.socDeltaPercent, decimals: 1);
  return '$start -> $end ($delta%)';
}

String _formatDateTime(int millis) {
  if (millis <= 0) return '--';
  final date = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${_two(date.month)}/${_two(date.day)} ${_two(date.hour)}:${_two(date.minute)}';
}

String _formatDuration(int millis) {
  if (millis <= 0) return '--';
  return formatDuration(Duration(milliseconds: millis));
}

String _two(int value) => value.toString().padLeft(2, '0');

String _localizedDayLabel(String label, AppLocalizations loc) {
  switch (label.toUpperCase()) {
    case 'MON':
      return loc.dayMon;
    case 'TUE':
      return loc.dayTue;
    case 'WED':
      return loc.dayWed;
    case 'THU':
      return loc.dayThu;
    case 'FRI':
      return loc.dayFri;
    case 'SAT':
      return loc.daySat;
    case 'SUN':
      return loc.daySun;
    default:
      return label;
  }
}
