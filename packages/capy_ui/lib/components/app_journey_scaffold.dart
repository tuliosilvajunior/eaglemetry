import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import 'card_stage_controller.dart';
import 'pill_tab_bar.dart';

/// Page-level shell for a journey in the replacement UI.
///
/// The shell owns the global pill tabs and the common canvas spacing. The
/// caller owns selection state and supplies the selected screen as [body].
class AppJourneyScaffold<T> extends StatelessWidget {
  const AppJourneyScaffold({
    required this.tabs,
    required this.selected,
    required this.onSelected,
    required this.body,
    this.position,
    this.stage,
    this.trailing,
    this.footer,
    this.staticBar,
    this.staticBarHeight = AppSizes.climateBarHeight,
    this.footerVisible = true,
    this.footerHeightFactor = _defaultFooterHeightFactor,
    super.key,
  });

  final List<TabItem<T>> tabs;
  final T selected;
  final ValueChanged<T> onSelected;
  final Widget body;

  /// A chrome-level action anchored to the right edge of the tab row and
  /// centred on its height — the settings gear.
  ///
  /// It sits outside the scrolling tab row rather than after the last pill,
  /// because it is not a destination: it opens a floating surface and the roll
  /// never lands on it. Keeping it out of that row is also what stops a long
  /// localized tab set from scrolling it off the screen.
  final Widget? trailing;

  /// Persistent chrome pinned under [body], the mirror of the pill row above
  /// it. Reserves [footerHeightFactor] out of the body's height, and rides [stage]
  /// on the same clock as the pills — pushed *down* off screen while they are
  /// pushed up, so an expanding card takes the whole screen and the body grows
  /// into both vacated strips in the same frame.
  ///
  /// It belongs to the journey, not to a destination: built once, outside
  /// whatever the caller uses to switch bodies, so it neither re-enters nor
  /// re-reads anything when the user changes tab. Give it no state that a tab
  /// switch should reset.
  final Widget? footer;

  /// A strip pinned under everything else, which nothing in the journey can
  /// take off the screen — the climate bar.
  ///
  /// The distinction from [footer] is the point, and it is structural rather
  /// than a flag. The pill row and the footer are chrome *of the journey*:
  /// they are painted over the body, they ride [stage], and a card growing to
  /// fullscreen pushes both off screen because the card is what the journey is
  /// now showing. This bar is not part of the journey at all. It is the
  /// vehicle's, it sits outside that stack as a sibling, and its height comes
  /// off the journey's before the journey measures anything — so no card,
  /// no destination and no [footerVisible] can reach it.
  ///
  /// There is no `staticBarVisible`: a control the driver may need at any
  /// moment must not be something a screen can decide to take away. Pass
  /// `null` to leave it out of the app entirely.
  ///
  /// The one thing that does drop it is a viewport too short to hold it and a
  /// touch target's worth of [body] as well — the same judgement
  /// [footerHeightFactor] documents, and for the same reason. That is not a
  /// screen taking the bar away; it is there being no screen to put it on.
  final Widget? staticBar;

  /// The height reserved for [staticBar], which the scaffold pins rather than
  /// reading off the child.
  ///
  /// The scaffold has to know this number before it can lay anything out: it
  /// comes off the height the journey is measured against, and the check that
  /// drops the bar on a short viewport needs it too.
  final double staticBarHeight;

  /// Whether the selected destination wants the [footer] strip.
  ///
  /// A destination whose whole point is one full-bleed surface gets the strip's
  /// share of the screen back, the same way a card that expands does: the strip
  /// slides down off screen and the body grows into it, on the same clock and
  /// with the same travel.
  ///
  /// It hides the strip; it does not remove it. Passing `null` for [footer]
  /// instead would unmount whatever it holds and re-enter it on the way back —
  /// and the footer is journey chrome, which exists precisely so a tab switch
  /// resets nothing in it.
  final bool footerVisible;

  /// Height reserved for [footer], as a fraction of the **whole screen**, not
  /// of the padded content box. A quarter by default, so the pill row and
  /// [body] together hold the other three quarters.
  ///
  /// A fraction rather than a fixed height because the strip is a share of a
  /// head unit, and a head unit is the one thing here that does not vary; a
  /// number tuned on one display would be a different share of the next. The
  /// screen, not the box, is what the caller is dividing — the page margins
  /// come out of the strip's share along with everything else.
  ///
  /// Clamped at layout time so the pill row and a touch target's worth of
  /// [body] always survive. On a viewport too short for the fraction the strip
  /// gives way, because chrome that squeezes the content to nothing is worse
  /// than chrome that is not the size it asked for.
  final double footerHeightFactor;

  /// Drives the pill indicator off an external continuous position — a
  /// rolling body's own [PageTabPosition] — instead of the bar animating
  /// itself off [selected]. See `PillTabBar.position`.
  final ValueListenable<double>? position;

  /// The card stage currently expanding under [body], if any.
  ///
  /// Not every journey has one, and even one that does only has it while the
  /// selected destination is a staged one — pass `null` otherwise. When set,
  /// the pill row hides in lockstep with the card taking over the screen,
  /// the same "pushed away by the card underneath it" treatment the mock
  /// validated: translated up and off-screen, not faded, and taken out of
  /// hit testing and semantics once the card has fully taken over.
  final CardStageController? stage;

  /// The pill row, with [trailing] pinned to its right edge.
  Widget _tabsRow(BuildContext context) {
    final trailing = this.trailing;
    final pills = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: PillTabBar<T>(
        items: tabs,
        selected: selected,
        onSelected: onSelected,
        position: position,
      ),
    );
    // The pills keep the space they need and the gear stays pinned right, so
    // the two never trade places as the tab set changes width.
    if (trailing == null) return pills;
    return Row(
      children: [
        Expanded(child: pills),
        const SizedBox(width: AppSpacing.gridGutter),
        Center(child: trailing),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final screenHeight = MediaQuery.sizeOf(context).height;
    final staticBar = this.staticBar;
    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        // The bottom inset is ignored on purpose. The app runs immersive, so
        // the navigation bar is not there — but Android keeps reporting its
        // inset for the first frames after launch, and a `SafeArea` that reads
        // it then reserves a strip that nothing ever occupies. Honouring an
        // inset for a bar the app has asked not to have is the bug, not the
        // fix for it.
        //
        // This is a head-unit decision. On a device that really does show a
        // navigation bar, the footer strip would sit under it.
        bottom: false,
        // The static bar is taken off the height **before** anything else is
        // measured, and it sits outside the `Stack` below rather than in it.
        // That placement is the whole contract: the pill row and the footer
        // are overlays that a card can slide away, and an overlay is exactly
        // what a fullscreen card grows over. A sibling above the stack cannot
        // be covered by anything inside it, and the clamp in [_footerHeight]
        // divides the height that is left rather than the whole screen.
        child: LayoutBuilder(
          builder: (context, constraints) {
            final reserved = staticBar == null
                ? 0.0
                : _staticBarReserved(constraints.maxHeight);
            final column = Column(
              // The bar states a height and no width, so a centred column
              // would shrink-wrap it to its content and leave it floating in
              // the middle of the bezel.
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: reserved > 0
                      // The window. Its corners are large — a bezel with a
                      // timid radius reads as a rendering seam rather than as
                      // a frame — and it is a real clip, not a painted
                      // outline, so a full-bleed surface inside it (the
                      // history map, an expanded card) is cut by the frame
                      // instead of squaring it off at the corners.
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.bezelInset,
                            AppSpacing.bezelInset,
                            AppSpacing.bezelInset,
                            // The gap down to the bar is the bezel too, so it
                            // is the same inset rather than a grid gutter.
                            AppSpacing.bezelInset,
                          ),
                          child: _bezelWindow(
                            context,
                            screenHeight,
                            colors.canvas,
                          ),
                        )
                      : _journey(context, screenHeight),
                ),
                if (reserved > 0)
                  Padding(
                    // Sides and bottom only, and the same inset the window
                    // above uses, so the bar's ends line up with the window's
                    // edges and the frame reads as one shape. The gap above
                    // the bar is the window's own bottom inset — a top inset
                    // here would double it.
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.bezelInset,
                      0,
                      AppSpacing.bezelInset,
                      AppSpacing.bezelInset,
                    ),
                    child: SizedBox(height: staticBarHeight, child: staticBar),
                  ),
              ],
            );
            // Bezel colour follows the same reserved>0 decision as the window.
            // Keying it off `staticBar != null` left the near-black ground in
            // place after a short viewport dropped the bar.
            if (reserved <= 0) return column;
            return ColoredBox(
              color: AppColors.climateBarSurface,
              child: column,
            );
          },
        ),
      ),
    );
  }

  /// The rounded window the journey sits in while a static bar is shown.
  ///
  /// Two clips, not one. A single `ClipRRect` around [_journey] made every
  /// footer tick recompose a ~1920×1000 layer — `EfficiencyReadout` and
  /// `InclineReadout` sample at 60 Hz even though they paint slower. The body
  /// clip is what cuts the history map and an expanded card; the footer clip
  /// is only as tall as the strip. When the footer is gone the body clip
  /// takes all four corners so the window stays one shape.
  Widget _bezelWindow(BuildContext context, double screenHeight, Color canvas) {
    final footer = this.footer;
    return LayoutBuilder(
      builder: (context, constraints) {
        final footerHeight = footer == null
            ? 0.0
            : _footerHeight(screenHeight, constraints.maxHeight);
        return _ChromeVisibility(
          visible: footerVisible,
          builder: (context, shown) {
            return AnimatedBuilder(
              animation: stage ?? kAlwaysDismissedAnimation,
              builder: (context, _) {
                // A footer that has already snapped to zero height is gone
                // for the window, even though the widget stays mounted.
                final gone = footer == null || footerHeight <= 0
                    ? 1.0
                    : math.max(stage?.expansion ?? 0.0, 1 - shown);
                final footerSlot =
                    (footerHeight +
                        AppSpacing.gridGutter +
                        AppSpacing.screenPadding.bottom) *
                    (1 - gone);
                return Column(
                  key: const Key('journey-window'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: ClipRRect(
                        key: const Key('journey-body-clip'),
                        borderRadius: _bodyWindowRadii(
                          gone,
                          hasFooter: footer != null,
                        ),
                        child: ColoredBox(
                          color: canvas,
                          child: _bodyStack(
                            context,
                            bottomPadding:
                                AppSpacing.screenPadding.bottom * gone,
                          ),
                        ),
                      ),
                    ),
                    if (footer != null)
                      ClipRRect(
                        key: const Key('journey-footer-clip'),
                        borderRadius: const BorderRadius.only(
                          bottomLeft: Radius.circular(AppRadii.xxl),
                          bottomRight: Radius.circular(AppRadii.xxl),
                        ),
                        child: ColoredBox(
                          color: canvas,
                          child: SizedBox(
                            height: footerSlot,
                            child: RepaintBoundary(
                              child: Align(
                                alignment: Alignment.bottomCenter,
                                child: Padding(
                                  padding: AppSpacing.screenPadding.copyWith(
                                    top: AppSpacing.gridGutter,
                                  ),
                                  child: _ChromeOverlay(
                                    stage: stage,
                                    height: footerHeight,
                                    slideUp: false,
                                    visible: footerVisible,
                                    child: footer,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  /// Body and pill row only — the footer is a sibling clip in [_bezelWindow].
  Widget _bodyStack(BuildContext context, {required double bottomPadding}) {
    final padding = AppSpacing.screenPadding.copyWith(bottom: bottomPadding);
    return Stack(
      children: [
        Padding(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ChromeSpacer(stage: stage, reserved: _chromeReserved),
              Expanded(child: body),
            ],
          ),
        ),
        Padding(
          padding: padding,
          child: _ChromeOverlay(
            stage: stage,
            height: _chromeHeight,
            child: _tabsRow(context),
          ),
        ),
      ],
    );
  }

  /// Everything the static bar does **not** cover, with no bezel and no clip.
  ///
  /// Used when the bar is absent or has been dropped on a short viewport. The
  /// footer stays an overlay in this stack, the same shape as before the
  /// bezel existed.
  Widget _journey(BuildContext context, double screenHeight) {
    final footer = this.footer;
    final tabsRow = _tabsRow(context);
    // Measures what the safe area and the static bar actually left, which is
    // what the clamp below divides up. The fraction itself is taken from the
    // screen, so both numbers are needed and neither can stand in for the
    // other.
    return LayoutBuilder(
      builder: (context, constraints) {
        final footerHeight = footer == null
            ? 0.0
            : _footerHeight(screenHeight, constraints.maxHeight);
        return Stack(
          children: [
            Padding(
              padding: AppSpacing.screenPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ChromeSpacer(stage: stage, reserved: _chromeReserved),
                  Expanded(child: body),
                  if (footer != null)
                    _ChromeSpacer(
                      stage: stage,
                      visible: footerVisible,
                      reserved: footerHeight + AppSpacing.gridGutter,
                    ),
                ],
              ),
            ),
            Padding(
              padding: AppSpacing.screenPadding,
              child: _ChromeOverlay(
                stage: stage,
                height: _chromeHeight,
                child: tabsRow,
              ),
            ),
            if (footer != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Padding(
                  // Only the sides and the bottom: a top inset here would
                  // sit between the body and the footer, which is what the
                  // spacer's own gutter already accounts for.
                  padding: AppSpacing.screenPadding.copyWith(top: 0),
                  child: _ChromeOverlay(
                    stage: stage,
                    height: footerHeight,
                    slideUp: false,
                    visible: footerVisible,
                    child: footer,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// What [staticBar] costs the journey — its own height plus the bottom page
  /// margin under it — or 0 on a viewport that cannot afford it.
  ///
  /// All or nothing, unlike the footer's clamp. The footer is a strip whose
  /// height was a share to begin with, so a smaller one is still the same
  /// strip; this bar holds fixed-size touch targets, and half of it is not a
  /// control anyone can press.
  ///
  /// What has to survive is the pill row and a touch target's worth of [body].
  /// The footer is not in that sum: [_footerHeight] drops it whole once it
  /// cannot hold a touch target, so this check only runs after that.
  double _staticBarReserved(double safeHeight) {
    final reserved = staticBarHeight + AppSpacing.bezelInset;
    final needed =
        reserved +
        // The bezel the window is inset by, top and bottom.
        AppSpacing.bezelInset * 2 +
        AppSpacing.screenPadding.vertical +
        _chromeReserved +
        AppSizes.minTouchTarget;
    return safeHeight >= needed ? reserved : 0.0;
  }

  /// The footer's share of [screenHeight], held back to what [safeHeight]
  /// can actually give it.
  double _footerHeight(double screenHeight, double safeHeight) {
    final boxHeight = safeHeight - AppSpacing.screenPadding.vertical;
    final available =
        boxHeight -
        _chromeReserved -
        AppSizes.minTouchTarget -
        AppSpacing.gridGutter;
    final share = screenHeight * footerHeightFactor;
    final height = share.clamp(0.0, available > 0 ? available : 0.0);
    return height < AppSizes.minTouchTarget ? 0.0 : height;
  }
}

/// Body-clip corners: top always rounded, bottom rounding only once the
/// footer has given the window back. [gone] is 0 while the footer is shown
/// and 1 when it is gone.
BorderRadius _bodyWindowRadii(double gone, {required bool hasFooter}) {
  if (!hasFooter || gone >= 1) return AppRadii.xxlRadius;
  if (gone <= 0) {
    return const BorderRadius.only(
      topLeft: Radius.circular(AppRadii.xxl),
      topRight: Radius.circular(AppRadii.xxl),
    );
  }
  final bottom = Radius.circular(AppRadii.xxl * gone);
  return BorderRadius.only(
    topLeft: const Radius.circular(AppRadii.xxl),
    topRight: const Radius.circular(AppRadii.xxl),
    bottomLeft: bottom,
    bottomRight: bottom,
  );
}

/// A quarter of the screen, leaving the pill row and the body the other three.
const _defaultFooterHeightFactor = 1 / 4;

const _chromeHeight = AppSizes.minTouchTarget;
const _chromeReserved = _chromeHeight + AppSpacing.gridGutter;

/// Reserves one chrome strip's footprint, shrinking to 0 in lockstep with the
/// matching [_ChromeOverlay] sliding away so the body grows to fill exactly the
/// space that strip gives up. A plain fixed spacer when there is no [stage].
class _ChromeSpacer extends StatelessWidget {
  const _ChromeSpacer({
    required this.stage,
    required this.reserved,
    this.visible = true,
  });

  final CardStageController? stage;

  /// See [AppJourneyScaffold.footerVisible]. Multiplies the stage's own factor
  /// rather than replacing it, so a strip that is hidden by both is hidden
  /// once.
  final bool visible;

  /// Strip height plus the gutter between it and the body.
  final double reserved;

  @override
  Widget build(BuildContext context) {
    final stage = this.stage;
    return _ChromeVisibility(
      visible: visible,
      builder: (context, shown) {
        if (stage == null) {
          return SizedBox(height: reserved * shown);
        }
        return AnimatedBuilder(
          animation: stage,
          builder: (context, _) {
            return SizedBox(height: reserved * stage.chromeVisibility * shown);
          },
        );
      },
    );
  }
}

/// Animates a strip between shown (1) and hidden (0) on the design system's
/// own clock, so the spacer and the overlay it belongs to travel together.
class _ChromeVisibility extends StatelessWidget {
  const _ChromeVisibility({required this.visible, required this.builder});

  final bool visible;
  final Widget Function(BuildContext context, double shown) builder;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: visible ? 1 : 0),
      duration: AppMotion.base,
      curve: AppMotion.curve,
      builder: (context, shown, _) => builder(context, shown),
    );
  }
}

/// One strip of persistent chrome — the pill row above the body, or the footer
/// below it — painted on top of the body rather than living inside the spacer's
/// box, so it slides away as a rigid whole instead of being clipped by a
/// shrinking box.
class _ChromeOverlay extends StatelessWidget {
  const _ChromeOverlay({
    required this.stage,
    required this.height,
    required this.child,
    this.slideUp = true,
    this.visible = true,
  });

  final CardStageController? stage;
  final double height;

  /// See [AppJourneyScaffold.footerVisible]. A hidden strip leaves by the same
  /// edge, over the same travel, as one pushed away by an expanding card.
  final bool visible;

  /// Which edge the strip leaves by. The two strips are driven by the same
  /// [CardStageController.expansion] in opposite directions, so the card that
  /// pushes them out reads as one surface growing between them.
  final bool slideUp;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bounded = SizedBox(
      height: height,
      child: ClipRect(child: child),
    );
    // Always the same shape, on `kAlwaysDismissedAnimation` (never fires)
    // when there's no `stage` — a conditional early return would change the
    // tree's shape the moment a transition crosses from a staged destination
    // to an unstaged one, and Flutter would tear down and remount the pill
    // bar instead of updating it, silently resetting its measured state.
    return _ChromeVisibility(
      visible: visible,
      builder: (context, shown) {
        return AnimatedBuilder(
          animation: stage ?? kAlwaysDismissedAnimation,
          builder: (context, _) {
            // Whichever of the two pushes the strip further is the one that
            // decides where it sits, so the card and the destination cannot
            // add their travels together and overshoot.
            final gone = math.max(stage?.expansion ?? 0.0, 1 - shown);
            final travel = height + AppSpacing.x8;
            return IgnorePointer(
              ignoring: gone > 0.001,
              child: Transform.translate(
                offset: Offset(0, (slideUp ? -1 : 1) * gone * travel),
                child: bounded,
              ),
            );
          },
        );
      },
    );
  }
}

/// The dashboard grid from the replacement UI: 1/4, 2/4, and 1/4.
///
/// Gutters are removed before the remaining width is distributed, so the
/// center column is always exactly twice the width of each side column.
///
/// There is deliberately no narrow fallback. The target is a landscape head
/// unit, and reflowing an at-a-glance driving dashboard into a scrolling column
/// would defeat its purpose. Screens are composed against 1280 logical px or
/// wider and supported down to a 960 px floor, below which a side column falls
/// under ~220 px; a component that can shrink gracefully does so with its own
/// `LayoutBuilder`. See the layout section of `DESIGN.md` before adding a
/// breakpoint here.
class ThreeColumnLayout extends StatelessWidget {
  const ThreeColumnLayout({
    required this.leading,
    required this.primary,
    required this.trailing,
    super.key,
  });

  final Widget leading;
  final Widget primary;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: leading),
        const SizedBox(width: AppSpacing.gridGutter),
        Expanded(flex: 2, child: primary),
        const SizedBox(width: AppSpacing.gridGutter),
        Expanded(child: trailing),
      ],
    );
  }
}

/// The same grid with the leading column left out: 3/4 and 1/4.
///
/// The primary column keeps twice the width of a [ThreeColumnLayout] centre
/// panel plus the gutter it absorbs, so a screen that gains its third panel
/// later does not have to be re-proportioned — the side column stays put and
/// the centre gives the space back.
class TwoColumnLayout extends StatelessWidget {
  const TwoColumnLayout({
    required this.primary,
    required this.trailing,
    super.key,
  });

  final Widget primary;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 3, child: primary),
        const SizedBox(width: AppSpacing.gridGutter),
        Expanded(child: trailing),
      ],
    );
  }
}

/// A [TwoColumnLayout] followed by one more 3/4-width panel off-screen.
///
/// At scroll offset zero, [primary] and [trailing] have exactly the same widths
/// as [TwoColumnLayout]. A horizontal drag reveals [extension] to the right of
/// the trailing panel without shrinking the first dashboard viewport.
class HorizontallyExtendedTwoColumnLayout extends StatelessWidget {
  const HorizontallyExtendedTwoColumnLayout({
    required this.primary,
    required this.trailing,
    required this.extension,
    this.controller,
    super.key,
  });

  final Widget primary;
  final Widget trailing;
  final Widget extension;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final firstViewportWidth = constraints.maxWidth;
        final columnWidth = (firstViewportWidth - AppSpacing.gridGutter) / 4;
        final primaryWidth = columnWidth * 3;
        final contentWidth =
            firstViewportWidth + AppSpacing.gridGutter + primaryWidth;

        return SingleChildScrollView(
          controller: controller,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: contentWidth,
            height: constraints.maxHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: primaryWidth, child: primary),
                const SizedBox(width: AppSpacing.gridGutter),
                SizedBox(width: columnWidth, child: trailing),
                const SizedBox(width: AppSpacing.gridGutter),
                SizedBox(width: primaryWidth, child: extension),
              ],
            ),
          ),
        );
      },
    );
  }
}
