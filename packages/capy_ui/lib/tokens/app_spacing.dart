import 'package:flutter/widgets.dart';

import 'chart_bar_profile.dart';

/// 4px-based spacing scale for the `capy_ui` design system.
///
/// Finer than [AutomotiveSpacing]'s 8px unit, because the reference layout
/// needs 4px and 12px steps inside controls while keeping 24/32px between
/// cards.
abstract final class AppSpacing {
  static const x1 = 4.0;
  static const x2 = 8.0;
  static const x3 = 12.0;
  static const x4 = 16.0;
  static const x5 = 20.0;
  static const x6 = 24.0;
  static const x8 = 32.0;
  static const x10 = 40.0;
  static const x12 = 48.0;

  /// Padding inside a card.
  static const cardPadding = EdgeInsets.all(x6);

  /// Gap between cards in the dashboard grid, and between the grid and the
  /// screen edge.
  static const gridGutter = x3;

  /// Outer padding of a dashboard screen.
  static const screenPadding = EdgeInsets.all(x3);

  /// How much bezel shows around the app window while the journey has a
  /// static bar — see `AppJourneyScaffold.staticBar`.
  ///
  /// Deliberately thinner than [screenPadding]: the window already carries
  /// that padding inside it, so the two stack. What is wanted is a frame the
  /// eye reads as an edge, not a second margin.
  static const bezelInset = x2;
}

/// Corner radii. Far larger than the legacy [AutomotiveRadii] scale, which
/// topped out at 12px; the reference language is built on soft, generous
/// corners and no borders.
abstract final class AppRadii {
  static const xs = 8.0;
  static const sm = 12.0;

  /// Controls resting inside a card: action rows, preset tiles.
  static const md = 16.0;

  static const lg = 20.0;

  /// Cards.
  static const xl = 24.0;

  static const xxl = 32.0;

  /// Fully rounded — pills, slider tracks, knobs.
  static const full = 999.0;

  static const xsRadius = BorderRadius.all(Radius.circular(xs));
  static const smRadius = BorderRadius.all(Radius.circular(sm));
  static const mdRadius = BorderRadius.all(Radius.circular(md));
  static const lgRadius = BorderRadius.all(Radius.circular(lg));
  static const xlRadius = BorderRadius.all(Radius.circular(xl));
  static const xxlRadius = BorderRadius.all(Radius.circular(xxl));
  static const fullRadius = BorderRadius.all(Radius.circular(full));
}

/// Fixed sizes shared by the new components.
abstract final class AppSizes {
  /// Minimum touch target. Carried over from the automotive constraint in
  /// `AGENTS.md` — this is a driving-context UI, not a phone UI.
  static const minTouchTarget = 64.0;

  /// Height of a full-width action row (`Open charge port`).
  static const actionRowHeight = 64.0;

  /// Height of a two-line preset tile (`85% / Extended`).
  static const presetTileHeight = 72.0;

  /// Height of the tall charge-limit slider track.
  static const limitSliderHeight = 88.0;

  /// Visual knob inside the 64px automotive hit target.
  static const limitSliderKnob = 52.0;

  /// Outline of the zone beyond the selected charge target.
  static const limitSliderOutline = 2.0;

  /// Background-colour cut that marks a target below the current charge.
  static const limitSliderTargetMarker = 8.0;

  /// Visual guides in the unfilled part of the charge-limit track.
  static const limitSliderTickWidth = 6.0;
  static const limitSliderTickHeight = 32.0;

  /// Scale applied while a pointer that started on the knob stays down.
  static const limitSliderPressedScale = 1.14;

  /// Height of the static battery-cycle pill. Shorter than the charge-limit
  /// track, because it carries no knob and repeats down a list.
  static const cycleBarHeight = 64.0;

  /// The thin rule under each named quantity in a magnitude list.
  static const magnitudeBarHeight = 6.0;

  /// The partition pill and the key beside each of its names.
  static const shareBarHeight = 10.0;
  static const shareBarDot = 8.0;

  /// Tall enough for a hill to have a shape, short enough that several traces
  /// stack inside one card on a phone.
  static const seriesTraceHeight = 72.0;

  /// Room for the two range labels beside a trace.
  static const seriesTraceLabelWidth = 56.0;

  /// Shorter than a cycle bar, which carries a label inside it. This one has
  /// its numerals underneath, so the pill only has to read as a battery.
  static const socSpanBarHeight = 20.0;

  /// Fixed geometry for the breathing warning banner.
  static const warningBannerHeight = 112.0;
  static const warningBannerLeading = 96.0;
  static const warningBannerIconCircle = 56.0;

  /// Shared floating-tooltip geometry.
  static const anchoredTooltipWidth = 416.0;
  static const anchoredTooltipCaret = 16.0;

  /// Distance that the caret tip enters the trigger button.
  static const anchoredTooltipCaretOverlap = 4.0;

  /// Floating charging-amperage control.
  static const amperageDialogHeight = 408.0;
  static const amperageDialogStepHeight = 80.0;

  /// One key of the money keypad. It keeps the automotive touch minimum: a
  /// digit typed by mistake is a wrong price, and the reader must not have to
  /// aim.
  static const moneyKeypadKeyHeight = 64.0;

  /// Floating category menu: a card-sized surface, not a tooltip. It holds a
  /// rail and a detail pane side by side, so it is bounded by what that pair
  /// needs rather than by the reading width of one column of text.
  static const categoryMenuWidth = 1040.0;
  static const categoryMenuHeight = 720.0;

  /// Rail width. Wide enough for a two-line label beside its icon at the 64px
  /// touch height, which is what `Mirrors and steering wheel` needs.
  static const categoryMenuRailWidth = 320.0;

  /// Rule between category groups. The one real separator in this system —
  /// see `CategoryMenuGroup`.
  static const categoryMenuRule = 1.0;

  /// Confirmation surface. Narrow on purpose: it is read, not navigated, and
  /// a wide one puts the buttons in the eye before the sentence.
  static const confirmDialogWidth = 480.0;

  /// Stroke width of the charge-session donut.
  static const donutStroke = 40.0;

  /// Angular gap between adjacent donut segments, in radians, measured on the
  /// stroke centerline. A real gap rather than a contrasting stroke, so
  /// segments of the same hue stay readable as separate.
  ///
  /// Two degrees was not enough: adjacent tints of one hue read as one arc with
  /// a seam. Four is the smallest gap that separates them at the sizes this
  /// ring is drawn at.
  static const donutSegmentGap = 0.07;

  /// Corner radius on the ends of a donut arc. Deliberately far smaller than
  /// half the stroke: a cap radius of `donutStroke / 2` is what `StrokeCap
  /// .round` gives, and at this thickness that reads as a semicircular blob
  /// rather than a softened edge.
  static const donutCapRadius = 6.0;

  /// Stroke of the concentric arc drawn inside the donut ring.
  ///
  /// Half the main stroke, because the inner arc is a second reading of the
  /// same total (regeneration against energy used), not another category in
  /// the breakdown. Equal weight would read as a competing ring.
  ///
  /// Held at exactly `donutStroke / 2`, so a change of ring thickness carries
  /// the inner arc with it and the two never drift apart.
  static const donutInnerStroke = donutStroke / 2;

  /// Clear space between the donut ring and the inner arc.
  static const donutInnerGap = 8.0;

  /// Width of the energy chart's window selector. Fixed so the field does not
  /// resize as the chosen label changes length.
  static const energyWindowFieldWidth = 220.0;

  /// Height of the pill-track segmented control (`Drive | Parked`).
  static const segmentedHeight = 56.0;

  /// Circular status badge in a card title (`Charging`).
  static const statusBadge = 32.0;

  /// Square icon button sitting next to a metric, as opposed to the circular
  /// info button in a card header.
  static const squareIconButton = 48.0;

  /// Chart bar geometry. Bars are pill-capped at both ends, which is why the
  /// width is a token: the cap radius is half of it.
  ///
  /// The measurements are here; the grid they make is a [ChartBarProfile].
  /// Width and gap travel as one value so a chart cannot take one and miss the
  /// other, and the pitch is summed in one place. See ADR 0011.
  static const chartBarWidth = 14.0;
  static const chartDenseBarWidth = 10.5;
  static const chartBarGap = 6.0;

  /// The normal slot grid. Pass this to a chart, do not pass a bare width.
  static const chartBarProfile = ChartBarProfile(
    width: chartBarWidth,
    gap: chartBarGap,
  );

  /// The charge session chart packs a whole session into one screen.
  static const chartDenseBarProfile = ChartBarProfile(
    width: chartDenseBarWidth,
    gap: chartBarGap,
  );

  /// Clear space between the zero rule and the near end of every chart column.
  ///
  /// Columns used to be drawn onto the rule, which put the baseline through the
  /// bar it was meant to measure from and made a short reading hard to separate
  /// from the axis. Stacked segments do *not* get a gap of their own: they meet
  /// flat so one column reads as one bar.
  static const chartZeroGap = 4.0;

  /// Left band reserved for chart y-axis labels.
  static const chartAxisGutter = 48.0;

  /// Bottom band reserved for sparse chart x-axis labels.
  static const chartLabelBand = 28.0;

  /// Thickness of a chart guide. A hairline disappears against a bright cabin
  /// and reads as an artifact rather than as the scale.
  static const chartGridStroke = 2.0;

  /// Clearance a guide keeps from a column it runs into.
  ///
  /// The guide passes behind the data: it stops this far short of a bar and
  /// picks up again on the far side, so a crossing stays legible and the line
  /// is never mistaken for part of the column.
  static const chartGridHalo = 4.0;

  static const chartOverlayStroke = 3.0;
  static const chartOverlayDot = 16.0;
  static const chartSelectionDot = 24.0;

  /// Tooltip caret: how far it reaches out of the bubble, and how wide its
  /// base is. The base is deliberately much wider than the reach, so the caret
  /// reads as part of the bubble rather than as a spike.
  static const tooltipCaret = 9.0;
  static const tooltipCaretWidth = 18.0;

  /// Series swatch dot prefixing a tooltip row.
  static const tooltipSwatch = 10.0;

  /// Pinned annotation on a plot: the datum dot, the light ring that keeps it
  /// legible where it lands on top of a bar, and the vertical rule it rides.
  static const chartPinDot = 14.0;
  static const chartPinRing = 3.0;
  static const chartPinRule = 2.0;

  /// Drag travel, in logical pixels, that carries a card in an
  /// `ExpandableCardStage` from its docked size to filling the stage.
  ///
  /// Deliberately shorter than any card is tall: the gesture has to be
  /// completable with a thumb resting on a wheel, so it is a decisive flick
  /// rather than a proportional drag across the card's own height.
  static const cardStageExpandDistance = 260.0;

  /// Drag travel that carries a fullscreen card's sideways peek from nothing
  /// to fully revealing its neighbour. Shorter than
  /// [cardStageExpandDistance] because a peek only previews — it never
  /// commits, so it should give way sooner.
  static const cardStagePeekDistance = 220.0;

  /// Fling speed, in px/s, that settles a card-stage drag regardless of how
  /// far it got. Well above `kMinFlingVelocity` (50): this is not "was that a
  /// flick", it is "was that decisive enough to override the halfway rule".
  static const cardStageFlingVelocity = 800.0;

  /// How far a peek can travel toward a side that has no neighbour to reveal,
  /// as a fraction of a full peek.
  ///
  /// Not zero, because a dead edge gives no feedback at all and reads as a
  /// dropped gesture; not free travel either, because sliding half a screen to
  /// uncover nothing promises a card that does not exist. See
  /// `CardStageController.peek`.
  static const cardStagePeekResistance = 0.08;

  /// Tilt gauge. The dial itself has no fixed size — it is resolved from the
  /// box the gauge is given — but these three are absolute, because a stroke
  /// that scaled with the dial would thin out to nothing on a small card.
  static const tiltGroundLine = 5.0;
  static const tiltReferenceDash = 5.0;

  /// Height of the dial inside a `TiltCard`.
  static const tiltGaugeHeight = 200.0;

  /// Dial diameter used only when the gauge is given an unbounded width, which
  /// is a layout mistake rather than a supported size.
  static const tiltFallbackDiameter = 240.0;

  /// Shortest the tape may be squeezed to in a low card. Below this the
  /// cardinal letters no longer clear the ticks.
  static const compassTapeMinHeight = 48.0;

  /// Height of the tape inside a `CompassCard`. The letters are the reading, so
  /// the tape is given the height they need to be set large.
  static const compassTapeHeight = 104.0;

  /// Degrees visible across the full width of a compass tape.
  ///
  /// A sixth of the dial. The card is a square in the readout strip, so a
  /// quarter of the dial put three cardinal letters and seventeen ticks across
  /// about 250 px and read as a ruler. Narrower spreads the same letters out;
  /// it also makes a turn cover more ground, which is the honest direction for
  /// a reading taken at a glance.
  static const compassTapeSpanDeg = 60.0;

  /// Width of the fixed centre bar on a compass tape, and of a tick.
  static const compassMarker = 8.0;
  static const compassMarkerHeight = 56.0;
  static const compassTick = 2.0;

  /// Length of a tick, centred on the same line as the cardinal letters.
  static const compassTickLength = 10.0;

  /// Icon sizes.
  static const iconSm = 20.0;
  static const iconMd = 24.0;
  static const iconLg = 32.0;

  /// Height of the always-dark climate quick-adjust bar. Equal to
  /// [minTouchTarget] so its chevrons need no oversized hit box of their own.
  static const climateBarHeight = 64.0;

  /// Horizontal travel that steps volume once on the now-playing pill.
  static const nowPlayingVolumeDragStep = 24.0;
}

/// Shared animation timings, so state changes across components feel like one
/// system rather than per-widget guesses.
abstract final class AppMotion {
  static const fast = Duration(milliseconds: 120);
  static const base = Duration(milliseconds: 220);
  static const slow = Duration(milliseconds: 400);

  /// One expansion or contraction of a breathing status pulse.
  static const breathing = Duration(milliseconds: 1800);

  static const curve = Curves.easeOutCubic;

  /// Delay between adjacent bars in a left-to-right chart entrance.
  static const chartBarStagger = Duration(milliseconds: 18);

  /// Small late lift added to a new bar before it settles at its real value.
  static const chartBarBounce = 0.08;

  /// Travel time of a bar that already exists and reports a new reading.
  ///
  /// Shorter than an entrance, and with no bounce: the bar must settle well
  /// before the next reading arrives, or it never reaches the value it plots
  /// and the chart reads as lag rather than as motion.
  static const chartBarGrowth = Duration(milliseconds: 180);
}
