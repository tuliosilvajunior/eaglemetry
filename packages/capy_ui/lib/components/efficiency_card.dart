import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import 'efficiency_chart.dart';
import 'metric_value.dart';

/// The efficiency card's full composition: the line, the smoothness pill
/// beside it, and the two captions that say what the numbers mean.
///
/// This exists so that no host has to lay the card out again. A screen that
/// wants driving efficiency asks for this, gives it a width and a height, and
/// gets the same reading everywhere. Before, the arrangement lived in the
/// gallery harness, and the first surface to ship the card invented its own.
///
/// ## The captions are not decoration
///
/// [referenceCaption] names what the pill measures, and [referenceDetail] the
/// window it measures over. The pill shows driving technique rather than
/// efficiency, and the two are easily confused on a card whose numeral is in
/// km/kWh, so an unlabelled pill reads as a second efficiency figure
/// disagreeing with the first. Null is for a host that has nothing to name at
/// all.
///
/// ## [smoothness] is a listenable, and that is the point
///
/// The line and the pill run at different rates: the line steps when a bucket
/// closes, the pill five times a second. Taking the reading as a
/// [ValueListenable] keeps the fast one inside its own builder, so a host that
/// updates the pill does not rebuild the line painter's element to be told it
/// has nothing to repaint. A host with a value rather than a stream can wrap it
/// in a `ValueNotifier`; a host with no pill passes null.
class EfficiencyCard extends StatelessWidget {
  const EfficiencyCard({
    required this.series,
    required this.averageCaption,
    this.smoothness,
    this.referenceCaption,
    this.referenceDetail,
    this.info,
    this.neutral,
    this.ceilingWhPerKm = 300,
    this.floorLabel,
    this.unitLabel,
    this.unit = EfficiencyUnit.kmPerKwh,
    this.unitSuffix = 'km/kWh',
    this.onCycleUnit,
    this.chartWidth = 360,
    super.key,
  });

  final EfficiencySeries series;

  /// Live driving smoothness for the pill, or null to omit it. See the class
  /// comment for why this is a listenable.
  final ValueListenable<DrivingSmoothness>? smoothness;

  /// Localized line under the average — the harness's `avg. · last 15 min`.
  final String averageCaption;

  /// Localized line naming what the pill measures. Null when there is nothing
  /// to name at all.
  final String? referenceCaption;

  /// Localized second line carrying the window the pill reads (`last 30 s`).
  ///
  /// Split from [referenceCaption] rather than sentenced with it so it sits
  /// under its own label instead of pushing the line wider.
  final String? referenceDetail;

  /// Optional explanatory affordance, drawn at the foot of the captions column
  /// beside [referenceCaption] — usually an `InfoIconButton` that opens an
  /// anchored panel.
  ///
  /// It goes at the foot rather than in a header row, because the card lives in
  /// a strip whose height is a share of the screen: a header would take a full
  /// touch target off the top and shorten the line by that much. At the foot it
  /// shares its row with a caption that is half its height, so it costs the
  /// card only what the captions were already leaving empty.
  ///
  /// The component supplies no copy and no behaviour. What the card means is
  /// the host's to write, in the host's locale.
  final Widget? info;

  /// Efficiency at which the line changes colour, in km/kWh. See
  /// [EfficiencyChart.neutral].
  final double? neutral;

  /// Bottom of the axis, in Wh/km. See [EfficiencyChart.ceilingWhPerKm].
  final double ceilingWhPerKm;

  /// Localized caption on the clip line.
  final String? floorLabel;

  /// Localized axis unit. See [EfficiencyChart.unitLabel].
  final String? unitLabel;

  /// How the large numeral is printed. The host owns the persisted choice;
  /// this card only draws it and, when [onCycleUnit] is set, offers the tap
  /// that advances it.
  final EfficiencyUnit unit;

  /// Localized suffix under the numeral, matching [unit].
  final String unitSuffix;

  /// Advances the host's unit choice. Null leaves the numeral inert.
  final VoidCallback? onCycleUnit;

  /// Width the line gets in the side-by-side arrangement.
  ///
  /// A number, not a flex factor, and that is the point: a line chart has no
  /// intrinsic width, so a card built out of flex factors can only be sized by
  /// its host — which forces every host to guess a share of itself. With a
  /// declared chart width the card asks for exactly what it needs, the captions
  /// add their own text width, and a strip can simply give it that and keep the
  /// rest.
  ///
  /// Fifteen minutes at ten seconds is 90 points, so this is four logical
  /// pixels a point. Below roughly 240 the line stops being a shape and becomes
  /// a texture.
  final double chartWidth;

  /// Width below which the captions move above the chart instead of beside it.
  ///
  /// Side by side is the intended reading, and it is what the head unit gets.
  /// The stack is for a narrow host, where a two-fifths column would be too
  /// thin to hold a number and its unit on one line — see `DESIGN.md` on
  /// shrinking a component rather than shrinking its text.
  static const _sideBySideFloor = 420.0;

  /// Ceiling on the captions column. Wide enough for the reference line in
  /// every shipped locale at two lines, narrow enough that it cannot stretch
  /// the card.
  static const _captionsWidth = 240.0;

  /// Height the card needs, in either arrangement: the captions plus a chart
  /// tall enough to read. The card does not reflow below this — it is composed
  /// against the head unit, where the shell's footer strip is a quarter of
  /// 1080. A host that gives it less overflows, and should give it less only
  /// if it has decided the card does not belong there.
  ///
  /// The figure covers an [info] affordance, whose touch target is taller than
  /// the caption it stands beside.
  static const minHeight = 200.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked =
            constraints.maxWidth.isFinite &&
            constraints.maxWidth < _sideBySideFloor;
        if (stacked) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Captions(
                series: series,
                averageCaption: averageCaption,
                referenceCaption: referenceCaption,
                referenceDetail: referenceDetail,
                info: info,
                unit: unit,
                unitSuffix: unitSuffix,
                onCycleUnit: onCycleUnit,
              ),
              const SizedBox(height: AppSpacing.x3),
              Expanded(child: _chart(withHeight: null)),
            ],
          );
        }
        return Row(
          // Min, so the card is as wide as the line plus its captions and no
          // wider. The captions column takes the card's full height, which is
          // what lets the average sit in the middle and the reference sit on
          // the floor; with `start` the column would shrink to its content and
          // the two would end up stacked at the top.
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: chartWidth,
              child: _chart(withHeight: constraints.maxHeight),
            ),
            const SizedBox(width: AppSpacing.gridGutter),
            ConstrainedBox(
              // The captions are text and would otherwise set the card's width
              // from the longest translation of the reference line.
              constraints: const BoxConstraints(maxWidth: _captionsWidth),
              child: IntrinsicWidth(
                child: _Captions(
                  series: series,
                  averageCaption: averageCaption,
                  referenceCaption: referenceCaption,
                  referenceDetail: referenceDetail,
                  info: info,
                  unit: unit,
                  unitSuffix: unitSuffix,
                  onCycleUnit: onCycleUnit,
                  filled: true,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// [EfficiencyChart] takes a fixed height, so the card measures for it. In
  /// the stacked case the chart is the flexible child and takes what the
  /// captions leave, which is why that path measures again rather than being
  /// told here.
  Widget _chart({required double? withHeight}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = withHeight ?? constraints.maxHeight;
        final smoothness = this.smoothness;
        final chart = EfficiencyChart(
          series: series,
          ceilingWhPerKm: ceilingWhPerKm,
          neutral: neutral,
          floorLabel: floorLabel,
          unitLabel: unitLabel,
          height: height.isFinite && height > 0 ? height : 148,
        );
        if (smoothness == null) return chart;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: chart),
            const SizedBox(width: AppSpacing.x4),
            // The only subtree on the fast clock. Deliberately not handed to
            // `EfficiencyChart` as its own `smoothness`, which would put the
            // line painter inside this builder.
            ValueListenableBuilder<DrivingSmoothness>(
              valueListenable: smoothness,
              builder: (context, value, _) =>
                  SmoothnessLevel(smoothness: value),
            ),
          ],
        );
      },
    );
  }
}

/// The average and what it is, then the reference the pill was measured
/// against, with the card's information affordance beside it.
///
/// Given a height ([filled]) the two separate: the average centres on the
/// chart's own middle, and the reference drops to the floor of the card. They
/// answer different questions — one is the window, the other is now — and
/// reading them as one block was what made the card hard to scan.
///
/// Both pairs stack and align to the leading edge, so a pair is only as wide
/// as its own widest line. That is what lets the whole column stay narrow
/// enough for the card to ask for its own width instead of a share of its
/// host.
class _Captions extends StatelessWidget {
  const _Captions({
    required this.series,
    required this.averageCaption,
    required this.referenceCaption,
    required this.referenceDetail,
    required this.unit,
    required this.unitSuffix,
    this.onCycleUnit,
    this.info,
    this.filled = false,
  });

  final EfficiencySeries series;
  final String averageCaption;
  final String? referenceCaption;
  final String? referenceDetail;
  final EfficiencyUnit unit;
  final String unitSuffix;
  final VoidCallback? onCycleUnit;
  final Widget? info;

  /// Whether this column has a height to spread into. False in the stacked
  /// arrangement, where it sits above the chart and takes only what it needs.
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    Widget caption(String text) => Text(
      text,
      style: AppText.caption.copyWith(color: colors.inkMuted),
      textAlign: TextAlign.start,
      overflow: TextOverflow.ellipsis,
      maxLines: 2,
    );

    final average = _Average(
      series: series,
      caption: caption(averageCaption),
      unit: unit,
      unitSuffix: unitSuffix,
      onCycleUnit: onCycleUnit,
    );
    final label = referenceCaption;
    final detail = referenceDetail;
    final info = this.info;
    final labels = label == null
        ? null
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [caption(label), if (detail != null) caption(detail)],
          );
    // The affordance and the caption share the foot of the column. The button
    // carries its own 16px of empty around a 32px glyph, so the row needs no
    // gap of its own, and the caption centres against it rather than sitting on
    // its baseline — the two are not one sentence.
    final reference = (labels == null && info == null)
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (labels != null) Flexible(child: labels),
              ?info,
            ],
          );

    if (!filled) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          average,
          if (reference != null) ...[
            const SizedBox(height: AppSpacing.x3),
            reference,
          ],
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: average,
          ),
        ),
        ?reference,
      ],
    );
  }
}

/// The window average: the numeral, its unit beneath it, and the line that
/// says which window it is.
///
/// The unit sits under the number rather than beside it, against
/// [MetricValue]'s own rule of one baseline. That rule is right for a metric
/// with a row to itself; here the column is the narrow half of a card that
/// declares its own width, and `km/kWh` beside a four-character numeral is the
/// widest thing in it. So this composes the two runs itself, at the same
/// styles, stacked and leading-aligned.
///
/// The numeral and its unit are one tap target when [onCycleUnit] is set.
/// The host holds the persisted choice; this widget only draws it.
class _Average extends StatelessWidget {
  const _Average({
    required this.series,
    required this.caption,
    required this.unit,
    required this.unitSuffix,
    this.onCycleUnit,
  });

  final EfficiencySeries series;
  final Widget caption;
  final EfficiencyUnit unit;
  final String unitSuffix;
  final VoidCallback? onCycleUnit;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // The numeral is 72 px and four characters wide. It must stay on
        // one line whatever the width and the text scale: a number
        // broken across two lines reads as two numbers, and truncating
        // one would change what it says. Scaling down is the only
        // failure that keeps it true, and on the car it never happens.
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            formatEfficiencyForUnit(series.averageKmPerKwh, unit),
            maxLines: 1,
            softWrap: false,
            style: AppText.metricXl.copyWith(color: colors.ink),
          ),
        ),
        Text(
          unitSuffix,
          maxLines: 1,
          style: AppText.unitLg.copyWith(color: colors.ink),
        ),
        const SizedBox(height: AppSpacing.x2),
        caption,
      ],
    );
    final onCycleUnit = this.onCycleUnit;
    if (onCycleUnit == null) return column;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onCycleUnit,
      child: column,
    );
  }
}
