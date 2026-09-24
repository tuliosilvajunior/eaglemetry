import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../capy_ui.dart';

/// Where a chart's axis ends above a peak reading of [peak].
///
/// An axis that stops exactly on the tallest column puts that column against
/// the edge of the plot, which reads as a value that ran out of chart rather
/// than as the peak of the window. The scale therefore clears the peak — and
/// lands on a round number while it is at it, because the top guide is
/// labelled and a reader has to be able to hold the number. A peak of `1.0`
/// gives `1.2`, not `1.15`.
///
/// Returns `1` for a window with nothing in it, which still needs a scale to
/// draw an axis against.
double energyAxisTop(double peak) {
  if (!peak.isFinite || peak <= 0) return 1;
  final magnitude = math
      .pow(10, (math.log(peak) / math.ln10).floor())
      .toDouble();
  const steps = [1.0, 1.2, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0];
  for (final step in steps) {
    final candidate = step * magnitude;
    if (candidate >= peak * _energyAxisHeadroom) return candidate;
  }
  // Past the last step the next decade begins, and its first usable stop is
  // the one that still clears the peak.
  return 12 * magnitude;
}

/// How far the top guide clears the tallest column before it is rounded up.
const _energyAxisHeadroom = 1.1;

/// Visual state of one [EnergyBarChart] column.
enum EnergyBarState {
  /// Measured, and plotted in the chart's own colour.
  actual,

  /// Not yet measured.
  projected,

  /// The single bar marking "now" inside a run of [projected] bars.
  now,

  /// Measured, but reporting that nothing is happening — a charge idling at
  /// its limit. Drawn neutral so it reads apart from the bars that moved.
  held,

  /// Not measured — reconstructed from a gated estimate, such as the
  /// overnight sleep-gap reconstruction on the "Since power on" line. Shares
  /// [held]'s neutral colour: both tell the reader "this bar is not a fresh
  /// reading," which is the one thing that matters for a glance at the chart.
  estimated,
}

/// One signed interval in an [EnergyBarChart].
@immutable
class EnergyBar {
  const EnergyBar({
    required this.value,
    this.base = 0,
    this.mid = 0,
    this.counter = 0,
    this.state = EnergyBarState.actual,
    this.id,
  });

  /// What makes this the *same* column across rebuilds, such as a record with
  /// the start and width of the interval it plots.
  final Object? id;

  /// Signed value of the main segment, in the caller's plotted unit.
  final double value;

  /// Signed stacked segment at the zero end.
  ///
  /// When [base] and [value] have the same sign, the main segment continues
  /// after the base. When their signs differ, both segments start at zero.
  final double base;

  /// Second stacked segment, between [base] and [value].
  ///
  /// It exists so a caller can name part of what would otherwise be one
  /// undifferentiated foot, without moving that part into [value]: the stack
  /// still totals the same column, and the reader can see which share of it was
  /// attributed. Follows [base]'s sign rule — a segment that disagrees with the
  /// column's direction is dropped rather than drawn backwards.
  final double mid;

  /// A third segment drawn from zero, independent of [value] and [base].
  ///
  /// It exists because one interval can carry a reading on each side of zero at
  /// once: a drive minute both spends energy and recovers some, and both are
  /// true of the same minute. Stacking regeneration into [value] would net the
  /// two into a single smaller bar and lose the fact that either happened.
  ///
  /// Signed by the caller and colored by its own sign, like [value] — pass a
  /// negative number to draw below the axis. Kept out of the [base] stack so it
  /// starts at zero rather than continuing another segment.
  final double counter;

  final EnergyBarState state;

  @override
  bool operator ==(Object other) =>
      other is EnergyBar &&
      sameChartValue(other.value, value) &&
      sameChartValue(other.base, base) &&
      sameChartValue(other.mid, mid) &&
      sameChartValue(other.counter, counter) &&
      other.state == state &&
      other.id == id;

  @override
  int get hashCode =>
      Object.hash(value.isNaN ? null : value, base, mid, counter, state, id);
}

/// Signed height of the stack under the main segment.
///
/// Only the segments that agree with the column's direction count. One that
/// disagrees is a reading the stack cannot use — a residual that came out
/// negative says the measurement is unusable, not that the bar grows downward.
double _stackBelow(EnergyBar bar) {
  final lead = bar.value != 0
      ? bar.value
      : bar.mid != 0
      ? bar.mid
      : bar.base;
  if (lead == 0) return 0;
  var total = 0.0;
  if (bar.base != 0 && bar.base.sign == lead.sign) total += bar.base;
  if (bar.mid != 0 && bar.mid.sign == lead.sign) total += bar.mid;
  return total;
}

/// Where the whole stacked column ends, which is where a marker sits.
double _barEnd(EnergyBar bar) {
  final below = _stackBelow(bar);
  return bar.value == 0 ? below : bar.value + below;
}

/// Equality for a plotted value, where `NaN` means "this interval has no
/// measurement".
///
/// Two missing intervals are the same chart, but `NaN != NaN` under IEEE
/// semantics. Comparing raw doubles would therefore report every chart with a
/// gap as changed on each rebuild, defeating [CustomPainter.shouldRepaint] and
/// repainting on every telemetry tick.
bool sameChartValue(double a, double b) => a == b || (a.isNaN && b.isNaN);

/// [listEquals] for plotted values, using [sameChartValue] per element.
bool sameChartValues(List<double> a, List<double> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!sameChartValue(a[i], b[i])) return false;
  }
  return true;
}

/// Bucket width encoded in an [EnergyBar.id] when the id is a 2- or 3-field
/// record. Call sites encode the interval as the last field: (start, width)
/// or (session, start, width). The chart derives its grid identity from this
/// rather than a caller-supplied key.
Object? _bucketWidthOf(Object? id) {
  switch (id) {
    case (Object? _, Object? _, Object? w):
      return w;
    case (Object? _, Object? w):
      return w;
    default:
      return null;
  }
}

Object _gridKeyFor(EnergyBarChart chart) {
  Object? bucketWidth;
  for (final bar in chart.bars) {
    bucketWidth = _bucketWidthOf(bar.id);
    if (bucketWidth != null) break;
  }
  return Object.hash(chart.profile, bucketWidth);
}

/// Where a reference curve meets the value baseline.
///
/// An anchor is drawn geometry, not a sample. It is placed on the outer edge of
/// the first or last column — the instant the plotted window opens or closes,
/// which is before the first measurement and after the last — and joins the
/// adjacent real sample. That is what lets a curve leave and return to zero
/// without a caller having to overwrite the measurement in the edge column,
/// which would make the drawn curve disagree with its own tooltip.
///
/// An end is only anchored when the sample beside it is present; the curve is
/// never extended across a gap where nothing was measured.
enum ChartOverlayAnchor {
  none,
  start,
  end,
  both;

  bool get _anchorsStart => this == start || this == both;
  bool get _anchorsEnd => this == end || this == both;
}

/// How a column that already exists reaches a new reading.
///
/// The duration and the curve are paired on purpose, and the caller cannot mix
/// them: a long travel on an eased curve is the one combination that looks
/// worse than no motion at all. An eased curve is fastest at its start, so a
/// reading that redirects it mid-travel makes the column surge, slow, and
/// surge again — one pulse per reading instead of a rise.
@immutable
class ChartGrowth {
  const ChartGrowth._(this.duration, this.curve);

  /// The column travels to the reading and stops before the next one arrives.
  ///
  /// The right choice when readings are far apart, or arrive at no fixed rate.
  /// Each reading reads as its own step, and the column is never wrong about
  /// the value it plots once it settles.
  static const settle = ChartGrowth._(
    AppMotion.chartBarGrowth,
    AppMotion.curve,
  );

  /// One travel lasts until the next reading, so the column climbs without
  /// pausing and each reading redirects a travel that is still running.
  ///
  /// [period] is how often the caller supplies a reading. Only the caller knows
  /// it. Passing the period itself is what removes the pause: the column is
  /// still moving toward the last reading when the next one lands, and it
  /// settles into a constant climb one reading behind the data.
  ///
  /// Two costs come with it. The column carries a steady lag of about one
  /// reading, so it reads slightly low for as long as the series keeps moving —
  /// safe for a value that only accumulates, wrong for one that can fall. And
  /// an uneven reading is an uneven speed, because a bigger step covers more
  /// ground in the same time.
  const ChartGrowth.chase(Duration period)
    : duration = period,
      curve = Curves.linear;

  /// Time one travel takes, before a later reading redirects it.
  final Duration duration;

  /// Shape of that travel. Linear for a chase, so the speed on each side of a
  /// redirection matches and the join cannot be seen.
  final Curve curve;

  @override
  bool operator ==(Object other) =>
      other is ChartGrowth &&
      other.duration == duration &&
      other.curve == curve;

  @override
  int get hashCode => Object.hash(duration, curve);
}

/// Preferred side for the selected-value tooltip.
///
/// [auto] tries the right side first and changes to the left side when the
/// complete tooltip and its caret do not fit.
enum ChartTooltipPosition { auto, left, right }

/// One horizontal chart rule and its pre-formatted y-axis label.
@immutable
class ChartTick {
  const ChartTick({required this.value, required this.label});

  final double value;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is ChartTick && other.value == value && other.label == label;

  @override
  int get hashCode => Object.hash(value, label);
}

/// One pre-formatted label on the horizontal axis.
///
/// [position] is the fraction of the complete time domain, from 0 to 1.
@immutable
class ChartXTick {
  const ChartXTick({required this.position, required this.label})
    : assert(position >= 0 && position <= 1);

  final double position;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is ChartXTick && other.position == position && other.label == label;

  @override
  int get hashCode => Object.hash(position, label);
}

/// Builds the three reference time anchors over the first 80% of a domain.
///
/// The caller owns localization through [labelBuilder]. The chart only shares
/// the normalized positions with its fixed slot grid.
List<ChartXTick> buildChartXTimeTicks({
  required DateTime domainStart,
  required Duration bucketWidth,
  required int slotCount,
  required String Function(DateTime value) labelBuilder,
}) {
  if (slotCount <= 0) return const [];
  final domainMicros = bucketWidth.inMicroseconds * slotCount;
  return [
    for (final position in const [0.0, 0.4, 0.8])
      ChartXTick(
        position: position,
        label: labelBuilder(
          domainStart.add(
            Duration(microseconds: (domainMicros * position).round()),
          ),
        ),
      ),
  ];
}

/// Builds the same three reference anchors as [buildChartXTimeTicks], but in
/// minutes elapsed since the first slot instead of wall-clock time.
///
/// A series that still waits for its boot's clock anchor draws its bars in
/// slot order — the order is measured, the wall stamps are not — so the axis
/// must count slots, never read stamps. The caller owns localization through
/// [labelBuilder], exactly like the wall-clock variant.
List<ChartXTick> buildChartXRelativeTicks({
  required Duration bucketWidth,
  required int slotCount,
  required String Function(int minutes) labelBuilder,
}) {
  if (slotCount <= 0) return const [];
  final domainMinutes =
      bucketWidth.inMicroseconds * slotCount / Duration.microsecondsPerMinute;
  return [
    for (final position in const [0.0, 0.4, 0.8])
      ChartXTick(
        position: position,
        label: labelBuilder((domainMinutes * position).round()),
      ),
  ];
}

/// Signed pill-column chart for energy use and charging projections.
///
/// The caller supplies plotted values and all visible text. The component owns
/// value animation, bar geometry, selection, marker placement, and tooltip
/// clamping. It does not format numbers or units.
///
/// Actual positive and negative values use separate series colors. Projected
/// and now columns keep the same geometry and use [AppChartColors.projected]
/// and [AppChartColors.nowMarker]. An optional [overlay] draws a straight,
/// round-joined reference curve over the columns.
///
/// Selection is controlled: [selectedIndex] determines what is shown, and
/// [onSelected] reports taps and drags to the screen. Marker positions do not
/// tween between columns.
class EnergyBarChart extends StatefulWidget {
  const EnergyBarChart({
    required this.bars,
    required this.ticks,
    this.slotCount,
    this.profile = AppSizes.chartBarProfile,
    this.positiveColor,
    this.negativeColor,
    this.baseColor,
    this.midColor,
    this.xTicks = const [],
    this.overlay,
    this.overlayAnchor = ChartOverlayAnchor.none,
    this.selectedIndex,
    this.onSelected,
    this.tooltipBuilder,
    this.tooltipPosition = ChartTooltipPosition.auto,
    this.cornerCaption,
    this.duration = AppMotion.base,
    this.growth = ChartGrowth.settle,
    this.animate = true,
    this.semanticsLabel,
    super.key,
  }) : assert(slotCount == null || slotCount >= bars.length);

  final List<EnergyBar> bars;
  final List<ChartTick> ticks;

  /// Number of fixed-width time slots in the complete visible domain.
  ///
  /// [bars] occupy the leading slots. A larger value reserves an empty tail
  /// without inventing zero-valued readings. Callers that need leading or
  /// internal gaps put `NaN` bars in those positions.
  final int? slotCount;

  /// The slot grid this chart draws on: bar width and the gap between bars.
  /// The bucket count in [bars] must have been chosen against the same profile,
  /// which is what `profile.slotsIn` is for.
  final ChartBarProfile profile;

  /// The four series colours. Null takes the theme's ramp, which is what a
  /// consumption chart is drawn in unless a caller has a reason to differ.
  final Color? positiveColor;
  final Color? negativeColor;
  final Color? baseColor;

  /// Color of the second stacked segment. The middle tint of the same ramp as
  /// [baseColor], never a second hue: the stack is one quantity divided into
  /// named shares, and a different hue would say it is a different kind of
  /// reading.
  final Color? midColor;

  /// Pre-formatted horizontal-axis labels in time order.
  final List<ChartXTick> xTicks;

  /// Reference-curve samples in the same plotted unit as [bars].
  ///
  /// Samples span from the first column to the last actual column. They are
  /// joined with straight segments. The component does not interpolate extra
  /// samples.
  ///
  /// Every entry is plotted as given. A missing interval is `double.nan`, which
  /// breaks the curve rather than bridging it. Callers must not overwrite a
  /// real sample to shape the curve's entry or exit — see [overlayAnchor].
  final List<double>? overlay;

  /// Whether the reference curve runs down to the value baseline at the plot
  /// edges. Defaults to [ChartOverlayAnchor.none].
  final ChartOverlayAnchor overlayAnchor;

  final int? selectedIndex;
  final ValueChanged<int?>? onSelected;

  /// Builds the selected reading. The chart places and clamps the result.
  final IndexedWidgetBuilder? tooltipBuilder;

  /// Side used for the selected reading. [ChartTooltipPosition.auto] changes
  /// sides when the complete callout does not fit.
  final ChartTooltipPosition tooltipPosition;

  /// Localized caption drawn inside the top-right corner of the plot.
  final String? cornerCaption;

  final Duration duration;

  /// How a column that already exists reaches a new reading.
  ///
  /// Defaults to [ChartGrowth.settle]. A screen fed at a steady rate can pass
  /// [ChartGrowth.chase] with that rate instead.
  final ChartGrowth growth;

  /// Set false to render the final state immediately.
  final bool animate;

  /// Localized chart description for assistive technology.
  final String? semanticsLabel;

  @override
  State<EnergyBarChart> createState() => _EnergyBarChartState();
}

class _EnergyBarChartState extends State<EnergyBarChart>
    with SingleTickerProviderStateMixin {
  static const _fallbackHeight = 300.0;

  // The series colours the caller did not name. Read from the theme, so an
  // expressive palette recolours the bars without every caller passing four
  // arguments it has no opinion about.
  AppEnergyRamp get _ramp => AppThemeColors.of(context).energy;

  Color get _positiveColor => widget.positiveColor ?? _ramp.draw;

  Color get _negativeColor => widget.negativeColor ?? _ramp.gain;

  Color get _baseColor => widget.baseColor ?? _ramp.drawSubtle;

  Color get _midColor => widget.midColor ?? _ramp.drawSoft;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late List<EnergyBar> _fromBars;
  late List<double> _fromOverlay;
  late List<int?> _entryOrders;
  late int _entryCount;

  /// Span the controller covers, which is the longer of the entrance wave and
  /// one growth. Both progressions are mapped against it, so each keeps its own
  /// duration no matter what else runs in the same pass.
  late Duration _total;

  /// Bars and curve as the last frame drew them.
  ///
  /// A new reading normally arrives before the previous animation ends. Taking
  /// the start of the next tween from `oldWidget` instead would send every bar
  /// back to where the last update began, which reads as a flash.
  List<EnergyBar>? _shownBars;
  List<double>? _shownOverlay;
  final _tooltipPlacement = _TooltipPlacement();
  bool _hideSelectionUntilCleared = false;
  bool _selectionClearScheduled = false;

  @override
  void initState() {
    super.initState();
    _fromBars = _zeroed(widget.bars);
    _fromOverlay = List<double>.filled(widget.overlay?.length ?? 0, 0);
    final entries = _entranceOrders(widget.bars);
    _entryOrders = entries.orders;
    _entryCount = entries.count;
    _total = _waveDuration(widget.duration, _entryCount);
    _controller.value = 1;
    if (widget.animate) {
      _controller.duration = _total;
      _controller.forward(from: 0);
    }
  }

  @override
  void didUpdateWidget(EnergyBarChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    _clearSelectionAfterDataReset(oldWidget);
    final barsChanged = !listEquals(oldWidget.bars, widget.bars);
    // NaN-tolerant, for the same reason `EnergyBar.==` is: a curve with a gap
    // would otherwise restart its animation on every rebuild.
    final overlayChanged = !sameChartValues(
      oldWidget.overlay ?? const [],
      widget.overlay ?? const [],
    );
    final gridChanged = _gridKeyFor(oldWidget) != _gridKeyFor(widget);
    if (!barsChanged && !overlayChanged && !gridChanged) return;

    if (widget.animate && gridChanged) {
      _fromBars = _zeroed(widget.bars);
      _fromOverlay = List<double>.filled(widget.overlay?.length ?? 0, 0);
      // The grid the last frame drew no longer describes these columns.
      _shownBars = null;
      _shownOverlay = null;
      final entries = _entranceOrders(widget.bars);
      _entryOrders = entries.orders;
      _entryCount = entries.count;
      _run(_waveDuration(widget.duration, _entryCount));
      return;
    }

    final entries = _incrementalEntrance(
      _shownBars ?? oldWidget.bars,
      widget.bars,
    );
    _fromBars = entries.fromBars;
    _fromOverlay = _shownOverlay ?? oldWidget.overlay ?? const [];
    _entryOrders = entries.orders;
    _entryCount = entries.count;

    final grows = entries.grows || overlayChanged;
    if (widget.animate && (_entryCount > 0 || grows)) {
      final wave = _entryCount > 0
          ? _waveDuration(widget.duration, _entryCount)
          : Duration.zero;
      final growth = grows ? widget.growth.duration : Duration.zero;
      _run(wave > growth ? wave : growth);
    } else {
      _fromBars = widget.bars;
      _fromOverlay = widget.overlay ?? const [];
      _total = widget.duration;
      _controller.value = 1;
    }
  }

  void _run(Duration total) {
    _total = total;
    _controller.duration = total;
    _controller.forward(from: 0);
  }

  void _clearSelectionAfterDataReset(EnergyBarChart oldWidget) {
    final index = widget.selectedIndex;
    if (index == null) {
      _hideSelectionUntilCleared = false;
      return;
    }

    final oldHasIndex = index >= 0 && index < oldWidget.bars.length;
    final newHasIndex = index >= 0 && index < widget.bars.length;
    final oldId = oldHasIndex ? oldWidget.bars[index].id : null;
    final newId = newHasIndex ? widget.bars[index].id : null;
    final identityChanged = (oldId != null || newId != null) && oldId != newId;
    final readingRemoved =
        !newHasIndex ||
        !_hasReading(index, widget.bars, widget.overlay ?? const []);
    final gridChanged = _gridKeyFor(oldWidget) != _gridKeyFor(widget);
    final reset = gridChanged || identityChanged || readingRemoved;
    if (!reset) return;

    _hideSelectionUntilCleared = true;
    if (_selectionClearScheduled) return;
    _selectionClearScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _selectionClearScheduled = false;
      if (!mounted || widget.selectedIndex == null) return;
      widget.onSelected?.call(null);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static List<EnergyBar> _zeroed(List<EnergyBar> bars) => [
    for (final bar in bars) _zeroedBar(bar),
  ];

  /// A column at the axis, keeping everything that is not animated.
  static EnergyBar _zeroedBar(EnergyBar bar) =>
      EnergyBar(value: 0, state: bar.state, id: bar.id);

  /// Gives measured columns their left-to-right order in a complete entrance.
  static ({List<int?> orders, int count}) _entranceOrders(List<EnergyBar> to) {
    var count = 0;
    final orders = <int?>[];
    for (final bar in to) {
      orders.add(_barHasVisibleReading(bar) ? count++ : null);
    }
    return (orders: orders, count: count);
  }

  /// Starts a newly measured column at zero, and every other column where it
  /// currently stands.
  ///
  /// A column is matched to its predecessor by [EnergyBar.id], so a column
  /// keeps its own start value even when the grid slides under it. A column
  /// that only reports a larger reading therefore travels to it instead of
  /// arriving there on the next frame, which is what makes a live bucket read
  /// as one bar that grows rather than as a bar that jumps.
  ///
  /// [grows] reports whether any column has to travel at all. It is what keeps
  /// a rebuild that changed nothing numeric from running the controller.
  static ({List<EnergyBar> fromBars, List<int?> orders, int count, bool grows})
  _incrementalEntrance(List<EnergyBar> from, List<EnergyBar> to) {
    final byId = <Object, EnergyBar>{
      for (final bar in from)
        if (bar.id != null) bar.id!: bar,
    };
    var count = 0;
    var grows = false;
    final fromBars = <EnergyBar>[];
    final orders = <int?>[];
    for (var index = 0; index < to.length; index++) {
      final bar = to[index];
      final previous = bar.id == null
          ? (index < from.length ? from[index] : null)
          : byId[bar.id];
      final enters =
          _barHasVisibleReading(bar) &&
          (previous == null || !_barHasVisibleReading(previous));
      final start = enters ? _zeroedBar(bar) : (previous ?? bar);
      grows = grows || (!enters && !_sameBarValues(start, bar));
      fromBars.add(start);
      orders.add(enters ? count++ : null);
    }
    return (fromBars: fromBars, orders: orders, count: count, grows: grows);
  }

  static bool _sameBarValues(EnergyBar a, EnergyBar b) =>
      sameChartValue(a.value, b.value) &&
      sameChartValue(a.base, b.base) &&
      sameChartValue(a.mid, b.mid) &&
      sameChartValue(a.counter, b.counter);

  static Duration _waveDuration(Duration entrance, int count) =>
      entrance + AppMotion.chartBarStagger * math.max(0, count - 1);

  static bool _barHasVisibleReading(EnergyBar bar) =>
      (bar.value.isFinite && bar.value != 0) ||
      (bar.base.isFinite && bar.base != 0) ||
      (bar.mid.isFinite && bar.mid != 0) ||
      (bar.counter.isFinite && bar.counter != 0);

  static List<EnergyBar> _lerpBars(
    List<EnergyBar> from,
    List<EnergyBar> to,
    double t, {
    List<int?> entryOrders = const [],
    Duration entryDuration = AppMotion.base,
    Duration total = AppMotion.base,
    ChartGrowth growth = ChartGrowth.settle,
  }) {
    if (t >= 1) return to;
    if (t <= 0) return from;
    final length = math.max(from.length, to.length);
    return [
      for (var i = 0; i < length; i++)
        () {
          final a = i < from.length ? from[i] : null;
          final b = i < to.length ? to[i] : null;
          final metadata = b ?? a!;
          final entryOrder = i < entryOrders.length ? entryOrders[i] : null;
          final barT = entryOrder == null
              ? _growthProgress(t, total, growth)
              : _entryProgress(t, entryOrder, entryDuration, total);
          return EnergyBar(
            value: _lerpChartValue(a?.value ?? 0, b?.value ?? 0, barT),
            base: _lerpChartValue(a?.base ?? 0, b?.base ?? 0, barT),
            mid: _lerpChartValue(a?.mid ?? 0, b?.mid ?? 0, barT),
            // Dropping this tweened the counter to zero for the whole
            // animation and snapped it back at the end, which on a live series
            // restarting every second read as the regeneration bars flashing.
            counter: _lerpChartValue(a?.counter ?? 0, b?.counter ?? 0, barT),
            state: metadata.state,
            id: metadata.id,
          );
        }(),
    ];
  }

  /// Progress of one entering column, in its own time.
  ///
  /// [total] is the span the controller covers, which is not this column's
  /// span: the wave staggers the columns, and a growth can run in the same
  /// pass and outlast the wave. Reading `t` directly would stretch every
  /// entrance to whatever else the controller happens to be driving.
  static double _entryProgress(
    double t,
    int order,
    Duration entrance,
    Duration total,
  ) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    if (entrance.inMicroseconds <= 0) return 1;
    final elapsed = t * total.inMicroseconds;
    final delay = order * AppMotion.chartBarStagger.inMicroseconds;
    if (elapsed <= delay) return 0;
    final local = ((elapsed - delay) / entrance.inMicroseconds).clamp(0.0, 1.0);
    final eased = AppMotion.curve.transform(local);
    // The sine is zero at both ends. Near the end it lifts the bar only a few
    // percent above its target, then gives the exact value back at t = 1.
    return eased + AppMotion.chartBarBounce * local * math.sin(math.pi * local);
  }

  /// Progress of a column that already exists and reports a new reading.
  ///
  /// Mapped against [total] for the same reason [_entryProgress] is. It carries
  /// no stagger, because nothing is arriving in order, and no bounce: an
  /// overshoot on a reading that keeps rising reads as an unsteady bar rather
  /// than as a bar that settles.
  static double _growthProgress(double t, Duration total, ChartGrowth growth) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    if (growth.duration.inMicroseconds <= 0) return 1;
    final local = (t * total.inMicroseconds / growth.duration.inMicroseconds)
        .clamp(0.0, 1.0);
    return growth.curve.transform(local);
  }

  static List<double> _lerpValues(
    List<double> from,
    List<double> to,
    double t,
  ) {
    if (t >= 1) return to;
    if (t <= 0) return from;
    final length = math.max(from.length, to.length);
    return [
      for (var i = 0; i < length; i++)
        _lerpChartValue(
          i < from.length ? from[i] : 0,
          i < to.length ? to[i] : 0,
          t,
        ),
    ];
  }

  static double _lerpChartValue(double from, double to, double t) {
    // `NaN` is absence, not a numeric endpoint. A disappearing reading becomes
    // absent immediately; a newly measured one grows from the axis.
    if (!to.isFinite) return to;
    return lerpDouble(from.isFinite ? from : 0, to, t)!;
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final shouldAnimate = widget.animate && !reduceMotion;
    final direction = Directionality.of(context);

    return Semantics(
      label: widget.semanticsLabel,
      container: widget.semanticsLabel != null,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final slotCount = widget.slotCount ?? widget.bars.length;
          final naturalWidth =
              AppSizes.chartAxisGutter + widget.profile.contentWidth(slotCount);
          final width = constraints.hasBoundedWidth
              ? constraints.maxWidth
              : naturalWidth;
          final height = constraints.hasBoundedHeight
              ? constraints.maxHeight
              : _fallbackHeight;

          return SizedBox(
            width: width,
            height: height,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final t = shouldAnimate ? _controller.value : 1.0;
                final bars = _lerpBars(
                  _fromBars,
                  widget.bars,
                  t,
                  entryOrders: _entryOrders,
                  entryDuration: widget.duration,
                  total: _total,
                  growth: widget.growth,
                );
                // The curve rides the wave while columns are still arriving, so
                // the two stay together; on its own it travels as a growth.
                final overlay = _lerpValues(
                  _fromOverlay,
                  widget.overlay ?? const [],
                  _entryCount > 0
                      ? t
                      : _growthProgress(t, _total, widget.growth),
                );
                _shownBars = bars;
                _shownOverlay = overlay;
                final geometry = _ChartGeometry(
                  size: Size(width, height),
                  bars: bars,
                  slotCount: slotCount,
                  profile: widget.profile,
                  ticks: widget.ticks,
                  overlay: overlay,
                );

                return TapRegion(
                  // A reading the user opened is dismissed by touching
                  // anything that is not this chart — another card, the page
                  // behind it, a second chart on the same screen. The tooltip
                  // is drawn inside this region, so touching the reading
                  // itself does not close it.
                  //
                  // `WidgetsApp` installs the `TapRegionSurface` this needs,
                  // so every instance of the chart gets the behavior without
                  // its screen having to lay a barrier under it.
                  onTapOutside: (_) => _dismiss(),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (details) =>
                        _select(details.localPosition, geometry),
                    onHorizontalDragStart: (details) =>
                        _select(details.localPosition, geometry),
                    onHorizontalDragUpdate: (details) =>
                        _select(details.localPosition, geometry),
                    child: Stack(
                      clipBehavior: Clip.hardEdge,
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _EnergyBarPainter(
                              bars: bars,
                              ticks: widget.ticks,
                              xTicks: widget.xTicks,
                              overlay: overlay,
                              overlayAnchor: widget.overlayAnchor,
                              geometry: geometry,
                              positiveColor: _positiveColor,
                              negativeColor: _negativeColor,
                              baseColor: _baseColor,
                              midColor: _midColor,
                              cornerCaption: widget.cornerCaption,
                              textDirection: direction,
                              captionBackgroundColor: colors.surface,
                              gridColor: colors.chartGrid,
                              axisLabelColor: colors.chartAxisLabel,
                              projectedColor: colors.chartProjected,
                              heldColor: colors.chartHeld,
                              nowMarkerColor: colors.chartNowMarker,
                              overlayColor: colors.chartOverlay,
                            ),
                          ),
                        ),
                        ..._overlayMarkers(geometry, overlay),
                        ..._selection(geometry, bars),
                      ],
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  void _select(Offset position, _ChartGeometry geometry) {
    if (widget.bars.isEmpty) return;
    // The axis gutter and the margins are not the plot. A touch that lands
    // there is a touch beside the chart, and it closes an open reading rather
    // than doing nothing — the same answer the reader gets for touching
    // anywhere else off the columns.
    if (!geometry.plot.contains(position)) {
      _dismiss();
      return;
    }
    final index = geometry.nearestIndex(position.dx);
    if (!_hasReading(index, widget.bars, widget.overlay ?? const [])) return;
    _hideSelectionUntilCleared = false;
    widget.onSelected?.call(index);
  }

  /// Closes the open reading, if one is open.
  ///
  /// Silent when nothing is selected: an outside touch is reported for every
  /// tap anywhere in the app, and a chart with nothing open must not call its
  /// screen back — and rebuild it — on each one.
  void _dismiss() {
    if (widget.selectedIndex == null) return;
    widget.onSelected?.call(null);
  }

  List<Widget> _overlayMarkers(_ChartGeometry geometry, List<double> overlay) {
    final colors = AppThemeColors.of(context);
    if (overlay.isEmpty) return const [];
    // A marker points at a measurement. On a missing edge sample the plotted
    // y is NaN, which `dotOffset` propagates into a dot parked at the foot of
    // the column — a reading that was never taken, drawn as if it were zero.
    final hasFirst = overlay.first.isFinite;
    final hasLast = overlay.last.isFinite;
    if (!hasFirst && !hasLast) return const [];
    final first = geometry.overlayPoint(0, overlay.length, overlay.first);
    final last = geometry.overlayPoint(
      overlay.length - 1,
      overlay.length,
      overlay.last,
    );

    Widget marker(Offset point, Color center) => Positioned(
      left: point.dx - AppSizes.chartOverlayDot / 2,
      top: geometry.plot.top,
      child: ChartPinAnnotation(
        height: geometry.plot.height,
        dotOffset: geometry.dotOffset(point.dy),
        color: center,
        ringColor: colors.ink,
        ruleWidth: 0,
        dotSize: AppSizes.chartOverlayDot,
      ),
    );

    if (overlay.length == 1) return [marker(first, _positiveColor)];
    return [
      if (hasFirst) marker(first, colors.surface),
      if (hasLast) marker(last, _positiveColor),
    ];
  }

  List<Widget> _selection(_ChartGeometry geometry, List<EnergyBar> bars) {
    final colors = AppThemeColors.of(context);
    final index = widget.selectedIndex;
    if (_hideSelectionUntilCleared) return const [];
    if (index == null || index < 0 || index >= bars.length) return const [];
    if (!_hasReading(index, bars, widget.overlay ?? const [])) return const [];

    final overlay = widget.overlay ?? const <double>[];
    final hasOverlayReading = index < overlay.length && overlay[index].isFinite;
    final point = hasOverlayReading
        ? geometry.overlayPoint(index, overlay.length, overlay[index])
        : Offset(
            geometry.xForIndex(index),
            geometry
                .yForValue(_barEnd(bars[index]))
                .clamp(geometry.plot.top, geometry.plot.bottom),
          );
    final widgets = <Widget>[
      Positioned(
        left: point.dx - AppSizes.chartSelectionDot / 2,
        top: geometry.plot.top,
        child: ChartPinAnnotation(
          height: geometry.plot.height,
          dotOffset: geometry.dotOffset(point.dy),
          color: colors.surface,
          ringColor: colors.ink,
          ruleWidth: 0,
          dotSize: AppSizes.chartSelectionDot,
        ),
      ),
    ];

    final builder = widget.tooltipBuilder;
    if (builder != null) {
      widgets.add(
        Positioned.fill(
          child: IgnorePointer(
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    key: const ValueKey('energy-chart-tooltip-caret'),
                    painter: _TooltipCaretPainter(
                      anchor: point,
                      placement: _tooltipPlacement,
                      color: colors.inverseSurface,
                    ),
                  ),
                ),
                Positioned.fill(
                  child: CustomSingleChildLayout(
                    delegate: _TooltipLayoutDelegate(
                      anchor: point,
                      plot: geometry.plot,
                      markerRadius: AppSizes.chartSelectionDot / 2,
                      preference: widget.tooltipPosition,
                      placement: _tooltipPlacement,
                    ),
                    child: builder(context, index),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return widgets;
  }

  static bool _hasReading(
    int index,
    List<EnergyBar> bars,
    List<double> overlay,
  ) {
    final bar = bars[index];
    return bar.value.isFinite ||
        bar.base.isFinite ||
        bar.mid.isFinite ||
        bar.counter.isFinite ||
        (index < overlay.length && overlay[index].isFinite);
  }
}

@immutable
class _ChartGeometry {
  _ChartGeometry({
    required this.size,
    required this.bars,
    required this.slotCount,
    required this.profile,
    required this.ticks,
    required this.overlay,
  }) : _range = _axisRange(bars: bars, ticks: ticks, overlay: overlay);

  final Size size;
  final List<EnergyBar> bars;
  final int slotCount;
  final ChartBarProfile profile;

  double get barWidth => profile.width;
  final List<ChartTick> ticks;
  final List<double> overlay;

  Rect get plot => Rect.fromLTRB(
    AppSizes.chartAxisGutter,
    AppSizes.chartOverlayDot / 2,
    size.width,
    math.max(
      AppSizes.chartOverlayDot / 2,
      size.height - AppSizes.chartLabelBand,
    ),
  );

  double get contentWidth => profile.contentWidth(slotCount);

  // Slot zero is the start of the time domain. Unused room belongs at the end
  // so a live series grows from left to right and a historical series can keep
  // leading gaps without its timestamps moving.
  double get contentLeft => plot.left;

  double xForIndex(int index) =>
      contentLeft + barWidth / 2 + index * profile.pitch;

  double xForTickFraction(double position) {
    final fraction = position.clamp(0.0, 1.0);
    if (fraction >= 1 || slotCount <= 0) return plot.right;
    final pitch = profile.pitch;
    // A fraction whose slot index is integral lands on that bar's centre. The
    // domain endpoint is the boundary after the final bar.
    return (contentLeft + barWidth / 2 + fraction * slotCount * pitch)
        .clamp(plot.left, plot.right)
        .toDouble();
  }

  int nearestIndex(double dx) {
    if (bars.length <= 1) return 0;
    final raw = (dx - contentLeft - barWidth / 2) / profile.pitch;
    return raw.round().clamp(0, bars.length - 1);
  }

  /// Plotted range, resolved once per frame.
  ///
  /// [yForValue] reads it for every segment of every column, and it depends on
  /// nothing that changes within a frame. Recomputing it per call rebuilt and
  /// reduced a list proportional to the column count on each read, which made
  /// one paint quadratic in the number of columns.
  final ({double min, double max}) _range;

  double get minValue => _range.min;

  double get maxValue => _range.max;

  static ({double min, double max}) _axisRange({
    required List<EnergyBar> bars,
    required List<ChartTick> ticks,
    required List<double> overlay,
  }) {
    final values = _axisValues(bars: bars, ticks: ticks, overlay: overlay);
    final min = values.reduce(math.min);
    final max = values.reduce(math.max);
    // A flat series still needs a range to divide by.
    return min == max ? (min: min - 1, max: max + 1) : (min: min, max: max);
  }

  /// Whether the caller named the scale itself, rather than leaving it to the
  /// readings. Two distinct guides are a scale; one is a line on someone
  /// else's.
  static bool _axisIsStatedByTicks(List<ChartTick> ticks) {
    final values = {
      for (final tick in ticks)
        if (tick.value.isFinite) tick.value,
    };
    return values.length >= 2;
  }

  static List<double> _axisValues({
    required List<EnergyBar> bars,
    required List<ChartTick> ticks,
    required List<double> overlay,
  }) {
    if (_axisIsStatedByTicks(ticks)) {
      return [
        for (final tick in ticks)
          if (tick.value.isFinite) tick.value,
        0,
      ];
    }

    return [
      0,
      for (final bar in bars) ...[
        if (bar.value.isFinite) bar.value,
        if (bar.base.isFinite) bar.base,
        if (bar.mid.isFinite) bar.mid,
        // The counter sits on its own side of zero, so the axis has to reach it
        // or a regenerating minute would be clipped against the plot floor.
        if (bar.counter.isFinite) bar.counter,
        // The stack top, which is above every one of its parts.
        if (bar.value.isFinite && bar.base.isFinite && bar.mid.isFinite)
          _barEnd(bar),
      ],
      for (final value in overlay)
        if (value.isFinite) value,
    ];
  }

  double yForValue(double value) {
    final fraction = (value - minValue) / (maxValue - minValue);
    return plot.bottom - fraction * plot.height;
  }

  double dotOffset(double y) =>
      plot.height <= 0 ? 0 : ((y - plot.top) / plot.height).clamp(0.0, 1.0);

  int get lastActualIndex {
    for (var i = bars.length - 1; i >= 0; i--) {
      if (bars[i].state == EnergyBarState.actual) return i;
    }
    return math.max(0, bars.length - 1);
  }

  Offset overlayPoint(int index, int count, double value) {
    if (bars.isEmpty) return Offset(plot.left, yForValue(value));
    final start = xForIndex(0);
    final end = xForIndex(lastActualIndex);
    final fraction = count <= 1 ? 1.0 : index / (count - 1);
    return Offset(lerpDouble(start, end, fraction)!, yForValue(value));
  }

  /// Baseline point on the leading edge of the first column, or the trailing
  /// edge of the last actual one — the boundaries of the plotted window, which
  /// sit outside the span any sample occupies.
  Offset overlayAnchorPoint({required bool atStart}) {
    final x = bars.isEmpty
        ? (atStart ? plot.left : plot.right)
        : (atStart
              ? xForIndex(0) - barWidth / 2
              : xForIndex(lastActualIndex) + barWidth / 2);
    return Offset(x, yForValue(0));
  }
}

/// One drawn rectangle of a column, resolved before anything is painted.
///
/// The grid needs the columns before it can be cut around them, so the layout
/// of a bar and the painting of it are two steps rather than one.
@immutable
class _BarSegment {
  const _BarSegment(this.shape, this.color);

  final RRect shape;
  final Color color;
}

class _EnergyBarPainter extends CustomPainter {
  const _EnergyBarPainter({
    required this.bars,
    required this.ticks,
    required this.xTicks,
    required this.overlay,
    required this.overlayAnchor,
    required this.geometry,
    required this.positiveColor,
    required this.negativeColor,
    required this.baseColor,
    required this.midColor,
    required this.cornerCaption,
    required this.captionBackgroundColor,
    required this.textDirection,
    required this.gridColor,
    required this.axisLabelColor,
    required this.projectedColor,
    required this.heldColor,
    required this.nowMarkerColor,
    required this.overlayColor,
  });

  final List<EnergyBar> bars;
  final List<ChartTick> ticks;
  final List<ChartXTick> xTicks;
  final List<double> overlay;
  final ChartOverlayAnchor overlayAnchor;
  final _ChartGeometry geometry;
  final Color positiveColor;
  final Color negativeColor;
  final Color baseColor;
  final Color midColor;
  final String? cornerCaption;
  final Color captionBackgroundColor;
  final TextDirection textDirection;
  final Color gridColor;
  final Color axisLabelColor;
  final Color projectedColor;
  final Color heldColor;
  final Color nowMarkerColor;
  final Color overlayColor;

  @override
  void paint(Canvas canvas, Size size) {
    // The columns are laid out before anything is drawn, because the grid is
    // cut around them: a guide has to know where the bars are before it can
    // stop short of one.
    final columns = [
      for (var i = 0; i < bars.length; i++) ..._layoutBar(i, bars[i]),
    ];

    _drawAxes(canvas, columns);

    canvas.save();
    canvas.clipRect(geometry.plot);
    for (final segment in columns) {
      canvas.drawRRect(segment.shape, Paint()..color = segment.color);
    }
    _drawOverlay(canvas);
    canvas.restore();

    _drawLabels(canvas);
    _drawCaption(canvas);
  }

  /// The guides, cut around every column they run into.
  ///
  /// A guide is context, so it passes behind the data rather than across it. A
  /// line drawn through a column reads as part of the column; one that stops a
  /// clear distance short of it reads as the scale it is. The ends are round,
  /// so what the eye sees is `==) | | (==` — the guide retreating from the bar,
  /// not a bar sitting in a broken line.
  ///
  /// Only the columns a guide actually meets cut it. A bar that never reaches
  /// this value is not in the way of it.
  void _drawAxes(Canvas canvas, List<_BarSegment> columns) {
    final paint = Paint()
      ..color = gridColor
      ..strokeWidth = AppSizes.chartGridStroke
      ..strokeCap = StrokeCap.round;
    // A round cap reaches half a stroke past the point it is drawn to, so the
    // span gives that back and the clearance stays the clearance.
    final overshoot = AppSizes.chartGridStroke / 2;

    for (final tick in ticks) {
      if (!tick.value.isFinite) continue;
      final y = geometry.yForValue(tick.value);

      final blocked = <({double from, double to})>[
        for (final segment in columns)
          if (y >= segment.shape.top - AppSizes.chartGridHalo &&
              y <= segment.shape.bottom + AppSizes.chartGridHalo)
            (
              from: segment.shape.left - AppSizes.chartGridHalo,
              to: segment.shape.right + AppSizes.chartGridHalo,
            ),
      ]..sort((a, b) => a.from.compareTo(b.from));

      var cursor = geometry.plot.left;
      void span(double to) {
        final from = cursor + overshoot;
        final end = to - overshoot;
        if (end > from) canvas.drawLine(Offset(from, y), Offset(end, y), paint);
      }

      for (final gap in blocked) {
        if (gap.from > cursor) span(gap.from);
        cursor = math.max(cursor, gap.to);
      }
      if (cursor < geometry.plot.right) span(geometry.plot.right);
    }
  }

  void _drawLabels(Canvas canvas) {
    final style = AppText.caption.copyWith(color: axisLabelColor);
    for (final tick in ticks) {
      if (!tick.value.isFinite) continue;
      final painter = TextPainter(
        text: TextSpan(text: tick.label, style: style),
        textDirection: textDirection,
        maxLines: 1,
      )..layout(maxWidth: AppSizes.chartAxisGutter - AppSpacing.x3);
      painter.paint(
        canvas,
        Offset(
          geometry.plot.left - AppSpacing.x2 - painter.width,
          geometry.yForValue(tick.value) - painter.height / 2,
        ),
      );
    }

    for (final layout in _xLabelLayouts(style)) {
      layout.painter.paint(canvas, layout.offset);
    }
  }

  List<({TextPainter painter, Offset offset})> _xLabelLayouts(TextStyle style) {
    final candidates = [
      for (final tick in xTicks)
        if (tick.label.isNotEmpty) tick,
    ]..sort((a, b) => a.position.compareTo(b.position));
    return [for (final tick in candidates) _layoutXTick(tick, style)];
  }

  ({TextPainter painter, Offset offset}) _layoutXTick(
    ChartXTick tick,
    TextStyle style,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: tick.label, style: style),
      textDirection: textDirection,
      maxLines: 1,
      ellipsis: '…',
      textAlign: TextAlign.start,
    )..layout(maxWidth: geometry.plot.width);
    final anchor = geometry.xForTickFraction(tick.position);
    final idealLeft = switch (tick.position) {
      <= 0 => anchor,
      >= 1 => anchor - painter.width,
      _ => anchor - painter.width / 2,
    };
    final left = idealLeft
        .clamp(
          geometry.plot.left,
          math.max(geometry.plot.left, geometry.plot.right - painter.width),
        )
        .toDouble();
    return (
      painter: painter,
      offset: Offset(left, geometry.plot.bottom + AppSpacing.x2),
    );
  }

  void _drawCaption(Canvas canvas) {
    final caption = cornerCaption;
    if (caption == null || caption.isEmpty) return;
    final painter = TextPainter(
      text: TextSpan(
        text: caption,
        style: AppText.caption.copyWith(color: axisLabelColor),
      ),
      textDirection: textDirection,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: math.max(0, geometry.plot.width - AppSpacing.x4));
    // Top-right, not bottom-right: bars grow from the baseline, so the bottom
    // corner is the one place the plot is never empty. The plate underneath
    // keeps the caption readable in the sessions that do reach up here.
    final origin = Offset(
      geometry.plot.right - painter.width - AppSpacing.x2,
      geometry.plot.top + AppSpacing.x2,
    );
    final plate = Rect.fromLTWH(
      origin.dx,
      origin.dy,
      painter.width,
      painter.height,
    ).inflate(AppSpacing.x1);
    canvas.drawRRect(
      RRect.fromRectAndRadius(plate, const Radius.circular(AppSpacing.x1)),
      Paint()..color = captionBackgroundColor.withValues(alpha: 0.85),
    );
    painter.paint(canvas, origin);
  }

  List<_BarSegment> _layoutBar(int index, EnergyBar bar) {
    if (!bar.value.isFinite || !bar.base.isFinite || !bar.mid.isFinite) {
      return const [];
    }
    final drawn = <_BarSegment>[];
    final x = geometry.xForIndex(index);
    final override = switch (bar.state) {
      EnergyBarState.actual => null,
      EnergyBarState.projected => projectedColor,
      EnergyBarState.held => heldColor,
      EnergyBarState.estimated => heldColor,
      EnergyBarState.now => nowMarkerColor,
    };

    final zeroY = geometry.yForValue(0);

    if (bar.counter.isFinite && bar.counter != 0) {
      final direction = bar.counter > 0 ? -1.0 : 1.0;
      drawn.add(
        _segment(
          x,
          zeroY + direction * AppSizes.chartZeroGap,
          geometry.yForValue(bar.counter),
          direction,
          override ?? (bar.counter > 0 ? positiveColor : negativeColor),
        ).segment,
      );
    }

    // A stacked segment only counts when it agrees with the column's
    // direction. Anything else is not the foot of this column: a residual that
    // came out negative says the measurement is unusable, not that the bar
    // grows downward, so it is dropped and what is above starts from the axis
    // in its place.
    final lead = bar.value != 0
        ? bar.value
        : bar.mid != 0
        ? bar.mid
        : bar.base;
    final baseStacks = bar.base != 0 && lead != 0 && bar.base.sign == lead.sign;
    final midStacks = bar.mid != 0 && lead != 0 && bar.mid.sign == lead.sign;

    final direction = lead > 0 ? -1.0 : 1.0;
    // Stacking is resolved in pixels, not in values: a segment held at the
    // minimum length no longer ends where its value says, and the segment above
    // has to start where the one below actually finished or the column would
    // overlap itself.
    var cursor = zeroY + direction * AppSizes.chartZeroGap;
    var stacked = 0.0;

    if (baseStacks) {
      stacked += bar.base;
      final laid = _segment(
        x,
        cursor,
        geometry.yForValue(stacked),
        direction,
        override ?? baseColor,
        // Flat wherever the column continues, so the parts read as one bar.
        roundEnd: !midStacks && bar.value == 0,
      );
      drawn.add(laid.segment);
      cursor = laid.endY;
    }

    if (midStacks) {
      stacked += bar.mid;
      final laid = _segment(
        x,
        cursor,
        geometry.yForValue(stacked),
        direction,
        override ?? midColor,
        roundStart: !baseStacks,
        roundEnd: bar.value == 0,
      );
      drawn.add(laid.segment);
      cursor = laid.endY;
    }

    if (bar.value == 0) return drawn;
    final color = override ?? (bar.value > 0 ? positiveColor : negativeColor);
    drawn.add(
      _segment(
        x,
        cursor,
        geometry.yForValue(stacked + bar.value),
        direction,
        color,
        roundStart: !baseStacks && !midStacks,
      ).segment,
    );
    return drawn;
  }

  /// One segment of a column, in pixels, and the y it actually ended at.
  ///
  /// [direction] is the way the column grows on screen: `-1` up, `+1` down. It
  /// is passed rather than derived, because a segment held at the minimum
  /// length can be asked to run backwards from where the one below it finished,
  /// and only the caller knows which way the column is meant to go.
  ///
  /// A segment shorter than the configured bar width is drawn at that
  /// length, extending away from [startY]. Growing away from the start rather
  /// than around a midpoint is what keeps a tiny reading on its own side of the
  /// zero rule: centring it there let the cap reach back across the axis, which
  /// put a green regeneration dot and a pale foot on top of the baseline.
  ///
  /// Rounding is per end: the outer end of a column is capped, and the join
  /// between two stacked segments is left square so they meet as one bar.
  ({_BarSegment segment, double endY}) _segment(
    double x,
    double startY,
    double endY,
    double direction,
    Color color, {
    bool roundStart = true,
    bool roundEnd = true,
  }) {
    final reach = (endY - startY) * direction;
    final length = math.max(reach, geometry.barWidth);
    final resolvedEnd = startY + direction * length;

    final rect = Rect.fromLTRB(
      x - geometry.barWidth / 2,
      math.min(startY, resolvedEnd),
      x + geometry.barWidth / 2,
      math.max(startY, resolvedEnd),
    );
    final radius = Radius.circular(geometry.barWidth / 2);
    final startIsTop = startY <= resolvedEnd;
    final roundTop = startIsTop ? roundStart : roundEnd;
    final roundBottom = startIsTop ? roundEnd : roundStart;
    return (
      segment: _BarSegment(
        RRect.fromRectAndCorners(
          rect,
          topLeft: roundTop ? radius : Radius.zero,
          topRight: roundTop ? radius : Radius.zero,
          bottomLeft: roundBottom ? radius : Radius.zero,
          bottomRight: roundBottom ? radius : Radius.zero,
        ),
        color,
      ),
      endY: resolvedEnd,
    );
  }

  void _drawOverlay(Canvas canvas) {
    if (overlay.isEmpty) return;
    final path = Path();
    var hasPoint = false;

    void addPoint(Offset point) {
      if (hasPoint) {
        path.lineTo(point.dx, point.dy);
      } else {
        path.moveTo(point.dx, point.dy);
        hasPoint = true;
      }
    }

    // An anchor is only drawn against a present sample. Anchoring past a
    // missing edge interval would draw a descent that was never measured.
    if (overlayAnchor._anchorsStart && overlay.first.isFinite) {
      addPoint(geometry.overlayAnchorPoint(atStart: true));
    }
    for (var i = 0; i < overlay.length; i++) {
      final value = overlay[i];
      if (!value.isFinite) {
        hasPoint = false;
        continue;
      }
      addPoint(geometry.overlayPoint(i, overlay.length, value));
    }
    if (overlayAnchor._anchorsEnd && overlay.last.isFinite) {
      addPoint(geometry.overlayAnchorPoint(atStart: false));
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = overlayColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = AppSizes.chartOverlayStroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_EnergyBarPainter old) =>
      !listEquals(old.bars, bars) ||
      !listEquals(old.ticks, ticks) ||
      !listEquals(old.xTicks, xTicks) ||
      !sameChartValues(old.overlay, overlay) ||
      old.overlayAnchor != overlayAnchor ||
      old.geometry.size != geometry.size ||
      old.geometry.profile != geometry.profile ||
      old.positiveColor != positiveColor ||
      old.negativeColor != negativeColor ||
      old.baseColor != baseColor ||
      old.midColor != midColor ||
      old.gridColor != gridColor ||
      old.axisLabelColor != axisLabelColor ||
      old.projectedColor != projectedColor ||
      old.heldColor != heldColor ||
      old.nowMarkerColor != nowMarkerColor ||
      old.overlayColor != overlayColor ||
      old.cornerCaption != cornerCaption ||
      old.captionBackgroundColor != captionBackgroundColor ||
      old.textDirection != textDirection;
}

class _TooltipPlacement {
  Rect? childRect;
  bool onRight = true;
}

class _TooltipLayoutDelegate extends SingleChildLayoutDelegate {
  const _TooltipLayoutDelegate({
    required this.anchor,
    required this.plot,
    required this.markerRadius,
    required this.preference,
    required this.placement,
  });

  final Offset anchor;
  final Rect plot;
  final double markerRadius;
  final ChartTooltipPosition preference;
  final _TooltipPlacement placement;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(plot.size);

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const caret = AppSizes.tooltipCaret;
    final rightLeft = anchor.dx + markerRadius + caret;
    final leftLeft = anchor.dx - markerRadius - caret - childSize.width;
    final fitsRight = rightLeft + childSize.width <= plot.right;
    final fitsLeft = leftLeft >= plot.left;
    final availableRight = plot.right - anchor.dx;
    final availableLeft = anchor.dx - plot.left;
    final onRight = switch (preference) {
      ChartTooltipPosition.right => true,
      ChartTooltipPosition.left => false,
      ChartTooltipPosition.auto =>
        fitsRight || (!fitsLeft && availableRight >= availableLeft),
    };
    var left = onRight ? rightLeft : leftLeft;
    left = left.clamp(
      plot.left,
      math.max(plot.left, plot.right - childSize.width),
    );

    var top = anchor.dy - childSize.height / 2;
    top = top.clamp(
      plot.top,
      math.max(plot.top, plot.bottom - childSize.height),
    );
    placement
      ..onRight = onRight
      ..childRect = Rect.fromLTWH(left, top, childSize.width, childSize.height);
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(_TooltipLayoutDelegate oldDelegate) =>
      oldDelegate.anchor != anchor ||
      oldDelegate.plot != plot ||
      oldDelegate.markerRadius != markerRadius ||
      oldDelegate.preference != preference;
}

class _TooltipCaretPainter extends CustomPainter {
  const _TooltipCaretPainter({
    required this.anchor,
    required this.placement,
    required this.color,
  });

  final Offset anchor;
  final _TooltipPlacement placement;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final body = placement.childRect;
    if (body == null || body.isEmpty) return;

    const halfWidth = AppSizes.tooltipCaretWidth / 2;
    final minY = body.top + AppRadii.md + halfWidth;
    final maxY = body.bottom - AppRadii.md - halfWidth;
    final baseY = minY <= maxY
        ? anchor.dy.clamp(minY, maxY).toDouble()
        : body.center.dy;
    final tipX = placement.onRight
        ? anchor.dx + AppSizes.chartSelectionDot / 2
        : anchor.dx - AppSizes.chartSelectionDot / 2;
    // The base overlaps the body by one pixel. The body paints after the caret
    // and covers the join, so antialiasing cannot leave a light seam.
    final baseX = placement.onRight ? body.left + 1 : body.right - 1;
    final path = Path()
      ..moveTo(baseX, baseY - halfWidth)
      ..lineTo(tipX, anchor.dy)
      ..lineTo(baseX, baseY + halfWidth)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_TooltipCaretPainter oldDelegate) => true;
}
