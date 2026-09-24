/// The Signal Lab, tabs `INSPECTOR` and `SCOPE`.
///
/// Stage 4 of the Signal Lab plan. This is a debug-only engineering
/// surface: it is reached from the v2 settings screen and only once
/// [DeveloperToolsGate] is unlocked.
///
/// Table-first, like the Trace screen it stands beside. Its job is to say what
/// each signal is doing right now, and a card grid cannot show three hundred
/// rows against one another.
library;

import 'package:flutter/material.dart';

import '../core/signal_lab.dart';
import '../core/signal_lab_controller.dart';
import '../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';

enum SignalLabTab { inspector, scope }

class SignalLabScreen extends StatefulWidget {
  const SignalLabScreen({required this.controller, super.key});

  final SignalLabController controller;

  @override
  State<SignalLabScreen> createState() => _SignalLabScreenState();
}

class _SignalLabScreenState extends State<SignalLabScreen> {
  final TextEditingController _search = TextEditingController();
  SignalLabTab _tab = SignalLabTab.inspector;
  Set<SignalTier> _tiers = const <SignalTier>{};

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
    widget.controller.start();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    // The screen started the polling, so the screen stops it. Disposing the
    // controller belongs to whoever built it; leaving the timer running behind
    // a closed route would sample the bus for a table nobody is looking at.
    widget.controller.stop();
    _search.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final controller = widget.controller;
    final rows = controller.rows;
    final counts = countByTier(rows);
    final filtered = filterSignalRows(
      rows,
      SignalFilter(query: _search.text, tiers: _tiers),
    );

    return Scaffold(
      backgroundColor: AppThemeColors.of(context).canvas,
      body: SafeArea(
        child: Padding(
          padding: AppSpacing.screenPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(
                title: loc.signalLabTitle,
                subtitle: loc.signalLabCounts(
                  counts[SignalTier.fresh] ?? 0,
                  counts[SignalTier.published] ?? 0,
                  counts[SignalTier.never] ?? 0,
                ),
                tab: _tab,
                onTab: (value) => setState(() => _tab = value),
                onClose: () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(height: AppSpacing.x4),
              Expanded(
                child: AppCard(
                  padding: const EdgeInsets.all(AppSpacing.x4),
                  child: switch (_tab) {
                    SignalLabTab.inspector => _InspectorTab(
                      rows: filtered,
                      controller: controller,
                      search: _search,
                      tiers: _tiers,
                      onTiers: (value) => setState(() => _tiers = value),
                      onSearch: () => setState(() {}),
                    ),
                    SignalLabTab.scope => _ScopeTab(controller: controller),
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.subtitle,
    required this.tab,
    required this.onTab,
    required this.onClose,
  });

  final String title;
  final String subtitle;
  final SignalLabTab tab;
  final ValueChanged<SignalLabTab> onTab;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Row(
      children: [
        IconButton(
          onPressed: onClose,
          icon: const Icon(Icons.arrow_back),
          color: AppThemeColors.of(context).ink,
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
        ),
        const SizedBox(width: AppSpacing.x2),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: AppText.cardTitle,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                subtitle,
                style: AppText.caption,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.x4),
        TextTabBar<SignalLabTab>(
          items: [
            TabItem(
              value: SignalLabTab.inspector,
              label: loc.signalLabTabInspector,
            ),
            TabItem(value: SignalLabTab.scope, label: loc.signalLabTabScope),
          ],
          selected: tab,
          onSelected: onTab,
        ),
      ],
    );
  }
}

class _InspectorTab extends StatelessWidget {
  const _InspectorTab({
    required this.rows,
    required this.controller,
    required this.search,
    required this.tiers,
    required this.onTiers,
    required this.onSearch,
  });

  final List<SignalRow> rows;
  final SignalLabController controller;
  final TextEditingController search;
  final Set<SignalTier> tiers;
  final ValueChanged<Set<SignalTier>> onTiers;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: AppSizes.minTouchTarget,
                child: TextField(
                  controller: search,
                  onChanged: (_) => onSearch(),
                  style: AppText.body,
                  decoration: InputDecoration(
                    hintText: loc.signalLabSearchHint,
                    hintStyle: AppText.label,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    filled: true,
                    fillColor: AppThemeColors.of(context).control,
                    border: const OutlineInputBorder(
                      borderRadius: AppRadii.smRadius,
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.x4),
            _TierFilter(selected: tiers, onChanged: onTiers),
            const SizedBox(width: AppSpacing.x4),
            SizedBox(
              width: 200,
              child: SoftActionTile(
                icon: Icons.restart_alt,
                label: loc.signalLabResetSession,
                height: AppSizes.minTouchTarget,
                onPressed: controller.resetSession,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.x4),
        if (!controller.isAlive)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.x3),
            child: Text(
              loc.signalLabDisconnected,
              style: AppText.label.copyWith(
                color: AppThemeColors.of(context).energy.critical,
              ),
            ),
          ),
        Expanded(
          child: rows.isEmpty
              ? Center(child: Text(loc.signalLabEmpty, style: AppText.label))
              : _SignalTable(rows: rows, controller: controller),
        ),
      ],
    );
  }
}

class _TierFilter extends StatelessWidget {
  const _TierFilter({required this.selected, required this.onChanged});

  final Set<SignalTier> selected;
  final ValueChanged<Set<SignalTier>> onChanged;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final labels = <SignalTier, String>{
      SignalTier.fresh: loc.signalLabTierFresh,
      SignalTier.published: loc.signalLabTierPublished,
      SignalTier.never: loc.signalLabTierNever,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final tier in SignalTier.values) ...[
          if (tier != SignalTier.values.first)
            const SizedBox(width: AppSpacing.x2),
          _TierChip(
            label: labels[tier]!,
            color: tierColor(tier, AppThemeColors.of(context)),
            selected: selected.contains(tier),
            onPressed: () {
              final next = Set<SignalTier>.from(selected);
              if (!next.remove(tier)) next.add(tier);
              onChanged(next);
            },
          ),
        ],
      ],
    );
  }
}

class _TierChip extends StatelessWidget {
  const _TierChip({
    required this.label,
    required this.color,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return InkWell(
      onTap: onPressed,
      borderRadius: AppRadii.fullRadius,
      child: Container(
        height: AppSizes.minTouchTarget,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
        decoration: BoxDecoration(
          color: selected ? colors.selectionFill : colors.control,
          borderRadius: AppRadii.fullRadius,
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: AppSpacing.x2),
            Text(
              label,
              style: AppText.label.copyWith(
                color: selected ? colors.onSelection : colors.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Colour for a tier. Never-published is the muted one on purpose: it is the
/// absence of a signal, not a fault in one.
Color tierColor(SignalTier tier, AppThemeColors colors) => switch (tier) {
  SignalTier.fresh => colors.energy.gain,
  SignalTier.published => colors.energy.warning,
  SignalTier.never => colors.inkSubtle,
};

/// Column widths, summed by [_kTableWidth] so the table can never claim a width
/// its columns do not fill.
const List<double> _kColumnWidths = <double>[
  320, // signal
  96, // frame
  104, // raw
  132, // value
  72, // unit
  96, // age
  120, // tier
  200, // session min/max
  96, // trace
];

final double _kTableWidth = _kColumnWidths.reduce((a, b) => a + b);

class _SignalTable extends StatelessWidget {
  const _SignalTable({required this.rows, required this.controller});

  final List<SignalRow> rows;
  final SignalLabController controller;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth > _kTableWidth
            ? constraints.maxWidth
            : _kTableWidth;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _HeaderRow(
                  labels: <String>[
                    loc.signalLabColumnSignal,
                    loc.signalLabColumnFrame,
                    loc.signalLabColumnRaw,
                    loc.signalLabColumnValue,
                    loc.signalLabColumnUnit,
                    loc.signalLabColumnAge,
                    loc.signalLabColumnTier,
                    loc.signalLabColumnRange,
                    loc.signalLabTrace,
                  ],
                  width: width,
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: rows.length,
                    itemExtent: 48,
                    itemBuilder: (context, index) => _SignalTableRow(
                      row: rows[index],
                      width: width,
                      traced: controller.isTraced(rows[index].name),
                      onTrace: () => _toggle(context, rows[index].name),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _toggle(BuildContext context, String name) {
    if (controller.toggleTrace(name)) return;
    final loc = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(loc.signalLabScopeFull)));
  }
}

/// Lays cells out at [_kColumnWidths], giving any extra width to the name.
List<Widget> _cells(List<Widget> children, double width) {
  final extra = width - _kTableWidth;
  return <Widget>[
    for (var i = 0; i < children.length; i++)
      SizedBox(
        width: _kColumnWidths[i] + (i == 0 && extra > 0 ? extra : 0),
        child: children[i],
      ),
  ];
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.labels, required this.width});

  final List<String> labels;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppThemeColors.of(context).divider),
        ),
      ),
      child: Row(
        children: _cells([
          for (final label in labels)
            Text(
              label,
              style: AppText.caption,
              overflow: TextOverflow.ellipsis,
            ),
        ], width),
      ),
    );
  }
}

class _SignalTableRow extends StatelessWidget {
  const _SignalTableRow({
    required this.row,
    required this.width,
    required this.traced,
    required this.onTrace,
  });

  final SignalRow row;
  final double width;
  final bool traced;
  final VoidCallback onTrace;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final muted = row.tier == SignalTier.never;
    final colors = AppThemeColors.of(context);
    final nameStyle = AppText.body.copyWith(
      color: muted ? colors.inkSubtle : colors.ink,
    );

    return Container(
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.divider)),
      ),
      child: Row(
        children: _cells([
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: tierColor(row.tier, colors),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: AppSpacing.x2),
              Expanded(
                child: Text(
                  row.name,
                  style: nameStyle,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!row.calibrated && row.tier != SignalTier.never)
                Tooltip(
                  message: loc.signalLabUncalibratedHint,
                  child: Text(
                    loc.signalLabUncalibrated,
                    style: AppText.caption.copyWith(
                      color: AppThemeColors.of(context).energy.warning,
                    ),
                  ),
                ),
              if (!row.valid && row.tier != SignalTier.never)
                Padding(
                  padding: const EdgeInsets.only(left: AppSpacing.x2),
                  child: Text(
                    loc.signalLabInvalid,
                    style: AppText.caption.copyWith(
                      color: AppThemeColors.of(context).energy.critical,
                    ),
                  ),
                ),
            ],
          ),
          Text('0x${row.canId.toRadixString(16)}', style: AppText.label),
          Text(row.raw?.toString() ?? '--', style: AppText.body),
          Text(_formatValue(row.physical), style: AppText.body),
          Text(row.unit, style: AppText.label),
          Text(_formatAge(row.age), style: AppText.label),
          Text(_tierLabel(loc, row.tier), style: AppText.label),
          Text(
            row.sessionMin == null || row.sessionMax == null
                ? '--'
                : '${_formatValue(row.sessionMin)} / '
                      '${_formatValue(row.sessionMax)}'
                      '${row.sessionIsCount ? ' ${loc.signalLabRawCounts}' : ''}',
            style: AppText.label,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              onPressed: row.tier == SignalTier.never ? null : onTrace,
              icon: Icon(
                traced ? Icons.show_chart : Icons.add_chart,
                color: traced
                    ? AppThemeColors.of(context).energy.focus
                    : colors.inkMuted,
              ),
              tooltip: loc.signalLabTrace,
            ),
          ),
        ], width),
      ),
    );
  }
}

String _tierLabel(AppLocalizations loc, SignalTier tier) => switch (tier) {
  SignalTier.fresh => loc.signalLabTierFresh,
  SignalTier.published => loc.signalLabTierPublished,
  SignalTier.never => loc.signalLabTierNever,
};

String _formatValue(double? value) {
  if (value == null) return '--';
  if (!value.isFinite) return '--';
  final magnitude = value.abs();
  if (magnitude >= 1000) return value.toStringAsFixed(0);
  if (magnitude >= 10) return value.toStringAsFixed(1);
  return value.toStringAsFixed(3);
}

String _formatAge(Duration? age) {
  if (age == null) return '--';
  if (age.inSeconds >= 60) return '${age.inMinutes} min';
  if (age.inMilliseconds >= 1000) return '${age.inSeconds} s';
  return '${age.inMilliseconds} ms';
}

class _ScopeTab extends StatelessWidget {
  const _ScopeTab({required this.controller});

  final SignalLabController controller;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final traces = controller.traces;

    if (traces.isEmpty) {
      return Center(
        child: Text(
          loc.signalLabScopeEmpty,
          style: AppText.label,
          textAlign: TextAlign.center,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            SizedBox(
              width: 200,
              child: SoftActionTile(
                icon: controller.frozen ? Icons.play_arrow : Icons.pause,
                label: controller.frozen
                    ? loc.signalLabResume
                    : loc.signalLabFreeze,
                height: AppSizes.minTouchTarget,
                onPressed: () => controller.setFrozen(!controller.frozen),
              ),
            ),
            const SizedBox(width: AppSpacing.x4),
            SizedBox(
              width: 220,
              child: SoftActionTile(
                icon: Icons.clear_all,
                label: loc.signalLabClearTraces,
                height: AppSizes.minTouchTarget,
                onPressed: controller.clearTraces,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.x4),
        Expanded(
          child: ListView.separated(
            itemCount: traces.length,
            separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.x4),
            itemBuilder: (context, index) {
              final palette = traceColors(AppThemeColors.of(context));
              return _TracePanel(
                trace: traces[index],
                color: palette[index % palette.length],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// The four trace colours, in the order the scope hands them out.
///
/// They come from the theme's ramp, so an expressive theme traces in its own
/// hues rather than in the reference green and amber.
List<Color> traceColors(AppThemeColors colors) => <Color>[
  colors.energy.focus,
  colors.energy.gain,
  colors.energy.warning,
  colors.energy.critical,
];

class _TracePanel extends StatelessWidget {
  const _TracePanel({required this.trace, required this.color});

  final ScopeTrace trace;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final minimum = trace.minimum;
    final maximum = trace.maximum;
    return SizedBox(
      height: 160,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 3,
                decoration: BoxDecoration(color: color),
              ),
              const SizedBox(width: AppSpacing.x2),
              Text(trace.name, style: AppText.bodyStrong),
              const Spacer(),
              Text(
                minimum == null || maximum == null
                    ? '--'
                    : '${_formatValue(minimum)} … ${_formatValue(maximum)}'
                          '${trace.isCount == true ? ' ${AppLocalizations.of(context)!.signalLabRawCounts}' : ''}',
                style: AppText.label,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x2),
          Expanded(
            child: CustomPaint(
              painter: _TracePainter(
                trace: trace,
                color: color,
                background: AppThemeColors.of(context).surface,
              ),
              size: Size.infinite,
            ),
          ),
        ],
      ),
    );
  }
}

/// Draws one trace, unsmoothed, on its own time axis, with gaps left open.
///
/// A missing sample breaks the line rather than joining across it. The gap is
/// the record of a signal that stopped publishing, and a continuous line there
/// would be a segment the bus never sent.
///
/// Points are placed by the time they were taken, not by their position in the
/// list. The sampler polls ten times finer than it records, so its spacing
/// wobbles, and a second it misses altogether has to leave a hole of the right
/// width instead of closing up as if the trace had been continuous.
class _TracePainter extends CustomPainter {
  _TracePainter({
    required this.trace,
    required this.color,
    required this.background,
  });

  final ScopeTrace trace;
  final Color color;

  /// The card the trace is drawn on. Passed in, because a painter has no
  /// context to read the palette from.
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);

    final values = trace.values;
    if (values.isEmpty) return;

    final minimum = trace.minimum;
    final maximum = trace.maximum;
    if (minimum == null || maximum == null) return;

    final span = (maximum - minimum).abs() < 1e-9 ? 1.0 : maximum - minimum;

    // The window ends at the newest point and reaches back its full width, so
    // the trace scrolls in real time and a partly filled window fills from the
    // right rather than stretching to fit.
    final millis = trace.millis;
    final latest = trace.latestMillis ?? 0;
    final windowMillis = trace.window.inMilliseconds;
    final start = latest - windowMillis;

    final line = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    var open = false;
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      if (value == null || !value.isFinite) {
        open = false;
        continue;
      }
      final x = windowMillis <= 0
          ? size.width
          : ((millis[i] - start) / windowMillis).clamp(0.0, 1.0) * size.width;
      final y = size.height - ((value - minimum) / span) * size.height;
      if (open) {
        path.lineTo(x, y);
      } else {
        path.moveTo(x, y);
        open = true;
      }
    }
    canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(covariant _TracePainter oldDelegate) => true;
}
