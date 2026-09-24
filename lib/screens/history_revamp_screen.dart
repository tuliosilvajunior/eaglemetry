import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/telemetry_api.dart';
import '../core/telemetry_scope.dart';
import '../design_system/design_system.dart';
import '../l10n/app_localizations.dart';
import 'history_vehicle_timeline.dart';

class HistoryRevampScreen extends StatefulWidget {
  const HistoryRevampScreen({super.key});

  @override
  State<HistoryRevampScreen> createState() => _HistoryRevampScreenState();
}

class _HistoryRevampScreenState extends State<HistoryRevampScreen> {
  late final TelemetryApi _api = TelemetryScope.of(context);
  final _scrollController = ScrollController();
  String _range = '7d';
  HistorySummaryReading? _result;
  bool _loading = true;
  String? _error;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool showLoading = true}) async {
    final generation = ++_loadGeneration;
    final range = _range;
    if (showLoading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final now = DateTime.now();
      final start = historyRangeStart(range, now);
      final page = await _api.listSessions(
        filter: SessionFilter(fromUtcMillis: start.millisecondsSinceEpoch),
        page: const PageRequest(limit: 500),
      );
      final result = HistorySummaryReading.fromSessions(
        range: range,
        start: start,
        end: now,
        records: page.sessions,
        weekdayLabels: const ['SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'],
      );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _result = result;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  void _selectRange(String range) {
    if (_range == range) return;
    HapticFeedback.selectionClick();
    setState(() => _range = range);
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return ColoredBox(
      color: AutomotiveColors.background,
      child: Column(
        children: [
          ScreenHeaderBar(
            title: loc.appBarTitle,
            subtitle: loc.historyHeaderSubtitle,
          ),
          Expanded(
            child: ListView(
              controller: _scrollController,
              primary: false,
              padding: const EdgeInsets.all(AutomotiveSpacing.marginScreen),
              children: [
                _TitleRow(range: _range, onRangeSelected: _selectRange),
                const SizedBox(height: AutomotiveSpacing.x3),
                _HistoryColumns(
                  result: _result,
                  loading: _loading,
                  error: _error,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryColumns extends StatelessWidget {
  const _HistoryColumns({
    required this.result,
    required this.loading,
    required this.error,
  });

  final HistorySummaryReading? result;
  final bool? loading;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 860;
        final currentResult = result;
        final left = error != null
            ? ErrorPanel(message: error!)
            : loading == true && currentResult == null
            ? const TechnicalPanel(child: LoadingPanel(height: 360))
            : currentResult == null
            ? EmptyStatePanel(message: loc.historyEmptyPanel)
            : HistoryVehicleTimeline(
                sessions: currentResult.sessions,
                rangeStartUtcMillis: currentResult.startUtcMillis,
                rangeEndUtcMillis: currentResult.endUtcMillis,
              );
        final right = const _HistoryPlaceholderPanel(
          icon: Icons.analytics_outlined,
          title: 'RESUMO',
          subtitle: 'Placeholder dos insights e metricas principais.',
        );

        if (compact) {
          return Column(
            children: [
              left,
              const SizedBox(height: AutomotiveSpacing.x2),
              right,
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 3, child: left),
            const SizedBox(width: AutomotiveSpacing.gutter),
            Expanded(flex: 2, child: right),
          ],
        );
      },
    );
  }
}

class _HistoryPlaceholderPanel extends StatelessWidget {
  const _HistoryPlaceholderPanel({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return TechnicalPanel(
      child: SizedBox(
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: AutomotiveColors.secondary, size: 22),
                const SizedBox(width: AutomotiveSpacing.x1),
                Text(
                  title,
                  style: AutomotiveTextStyles.labelCaps.copyWith(
                    color: AutomotiveColors.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AutomotiveSpacing.x2),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AutomotiveColors.surfaceContainerHigh,
                  border: Border.all(color: AutomotiveColors.technicalBorder),
                  borderRadius: AutomotiveRadii.baseRadius,
                ),
                child: Center(
                  child: Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: AutomotiveTextStyles.bodyMd.copyWith(
                      color: AutomotiveColors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
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
