# UI Design System

Status: In progress. The tokens and all Tier 1, Tier 2, Tier 3, and Tier 4 bodies
are built. A temporary V2 journey shell now provides the base for screen
migration. The Charging screen includes the migrated energy summary and charge
limit controls. The inventory at the end is authoritative. Update this document
when a rule, token, or component status changes.

This is the design system for the UI overhaul. It lives in `packages/capy_ui/`
and is shared by the car app and the companion app. It **coexists with the
legacy car-app `lib/design_system/`** (`AutomotiveDS`) rather than replacing it
in place. Screens migrate one at a time; a legacy widget is deleted once its
last usage is gone. See [Migration](#migration).

Legacy components live in the retired car-app `lib/design_system/`.
That system is retired for new work; every new screen is built on `capy_ui`.

The visual rules in this document replace the legacy visual rules for
components and complete screens that move to `capy_ui`. Project-wide Android
Automotive, accessibility, localization, responsive-layout, data-honesty, and
safety rules in `AGENTS.md` still apply. Never mix both design systems in one
widget.

---

## Scope and current state

- **A catalogue of themes.** Neutral surfaces, text, selection, chart plumbing
  and the data ramp all resolve through the `AppThemeColors` theme extension.
  Six themes keep the reference green and amber; three expressive ones state
  their own hues. No theme changes what a hue *means*.
- **Landscape, in-vehicle.** The target is Android Automotive, per `AGENTS.md`.
  Layouts assume a wide viewport and a 3-up card grid, and touch targets follow
  the automotive minimum, not a phone minimum.
- **The V2 journey opens on one theme out of a catalogue.**
  `lib/ui/tokens/app_palettes.dart` holds `AppThemeId`, one `AppThemeSpec` per
  theme, and nothing else. `AppTheme.forId(id)` builds and caches the
  `ThemeData`. `ThemeController.themeId` is the selection, persisted under
  `theme_id`; `themeMode` is derived from the chosen theme's brightness, and
  the older `theme_mode` key is still written so a downgrade opens on the same
  brightness. The previous journey stays reachable from Config, still runs on
  `AutomotiveTheme`, and still knows only light and dark.

  To add a theme: one `AppThemeId` value, one `AppThemeColors` constant, one
  entry in `palettes`, and one localized name. `_themeName` in the Displays
  pane is a `switch` with no default, so a theme with no name does not compile,
  and the picker reads `AppThemeId.values`, so it needs no change at all.

  The energy ramp is `AppEnergyRamp`, a field on `AppThemeColors`. It defaults
  to `AppEnergyRamp.standard` — green for recovered, amber for spent — and the
  six restrained themes all keep it, so they differ in their neutrals alone.
  The three expressive themes (Tokyo Neon, Sunset Drive, Bubblegum) state their
  own hues.

  What a theme may **not** do is change what a hue *means*. `gain` is energy
  recovered and `draw` is energy spent in every theme; every reader asks for
  one by name, so a theme that swapped them would relabel every chart at once.
  A theme also may not put the two hues close together: a driver tells them
  apart at a glance, and `app_theme_catalog_test.dart` fails a ramp whose two
  hues are within 60° of each other.

  Read the ramp from the context — `AppThemeColors.of(context).energy.gain` —
  never from the `AppColors` constants. Those constants remain as the values
  `AppEnergyRamp.standard` is built from, and as what the gallery draws, since
  the gallery is pinned to the light reference. A component that takes a series
  colour takes it as `Color?` and falls back to the theme's ramp in `build`, so
  a caller with no opinion gets the right hue in every theme.

Import the barrel, never the individual token files:

```dart
import 'package:capy_ui/capy_ui.dart';
```

---

## The visual language

Four rules carry most of the look. Everything else follows from them.

### 1. Surfaces separate by contrast, never by border or shadow

In light mode, an off-white canvas holds white cards, which hold light-grey
controls. In dark mode, a deep blue-petrol canvas holds lighter blue-petrol
cards and controls. Resolve these roles from `AppThemeColors.of(context)`.
Both modes use three surface steps, no outlines, and no elevation.

This is the sharpest break from the legacy system, where `TechnicalPanel` draws
a 1px border by default and nearly every screen inherits it. Do not add
`Border.all` to a new component. `AppColors.divider` exists for the rare real
separator, but reach for a surface step first.

`LimitSlider` has one deliberate exception. Its zone beyond the selected target
uses a 2px `AppColors.divider` outline because the zone is present but not part
of the charging plan. The painter starts the visible outline at the target or,
when the current charge is higher, at the current charge. The zone has no
closing edge under the knob. At 100%, the fill reaches the track edge while the
knob stays centered in the right end cap.

### 2. Corners are generous

Cards `AppRadii.xl` (24), controls inside cards `AppRadii.md` (16), tracks and
bars `AppRadii.full`. The legacy `AutomotiveRadii` scale topped out at 12 and is
not compatible with this language — don't mix the two scales in one screen.

### 3. Black means selection; color means data

This separation is the whole reason the dashboard stays readable with two chart
series on screen:

| Role | Token | Meaning |
| --- | --- | --- |
| Selection | `selectionFill` / `onSelection` | the user picked this |
| Gain | `energy.gain` (+ `Soft`, `Subtle`) | energy recovered or delivered |
| Draw | `energy.draw` (+ `Soft`, `Subtle`) | energy spent |

Consumption bars are amber, regen bars are green, charge meters are green
(charging is a gain). A series color is **never** a selection state, and
`selectionFill` is **never** a categorical series — its one charting use is the
reference overlay (the power curve drawn on top of the bars).

`SettingToggleRow` is the one named exception: an on switch uses
`energy.draw`, following the reference head unit, because an amber track
reads as *live* across a cabin at a glance. It applies to a switch and nothing
else — tabs, tiles, and every other selection stay on `selectionFill`.

Each series is a *ramp*, not one color: donuts split a series into sub-arcs and
bars stack a base segment, so both need tints of the same hue. Reaching for a
new hue to distinguish parts of one series is wrong.

### 4. Space is the layout tool

Padding is large (`AppSpacing.cardPadding` = 24), gutters are consistent
(`AppSpacing.gridGutter`), and cards do not compete for density. If a layout
feels cramped, remove content — do not shrink the padding scale.

---

## Typography

One family: **Inter**, bundled in `packages/capy_ui/assets/fonts/` at weights
400–800 and registered in the package `pubspec.yaml`. There is no monospace
face; the legacy system's `JetBrains Mono` for metrics is not part of this
language. The car app redeclares the same family so legacy screens keep
resolving `Inter` without a package prefix.

> Note: `lib/design_system/automotive_typography.dart` has always *asked* for
> `Inter` but the `fonts:` block was commented out, so the whole app silently
> rendered in Roboto. Bundling the font fixed that for the legacy screens too.

### Numerals must be tabular

Every numeric style carries `FontFeature.tabularFigures()`. This matters more
here than in a typical app: these readouts update live, and with proportional
digits the value visibly jitters as it counts. If you add a numeric style, add
the feature.

### Metric and unit are two runs, not one

`202 mi` is a large heavy numeral plus a small unit suffix, with the unit
baseline-aligned to the numeral. Never bake the unit into the metric string —
compose `AppText.metricXl` with `AppText.unitLg` so the sizes stay independent.

| Style | Use |
| --- | --- |
| `metricXl` / `metricLg` / `metricMd` / `metricSm` | hero numerals |
| `unitLg` / `unitMd` | the suffix trailing a metric |
| `statValue` | chart-footer stat columns |
| `legendValue` | compact icon+value legend rows |
| `delta` | signed change beside a total (`+12.2 kWh`) |
| `cardTitle` | card headers |
| `tabLabel` | all three tab kinds |
| `body` / `bodyStrong` | content, control labels |
| `label` / `caption` | supporting lines under a metric |
| `compassCardinal` | a cardinal point on the compass tape |
| `tooltipValue` / `tooltipLine` | text on `inverseSurface` |

---

## Iconography

Material icons, filled style, single weight. Sizes come from `AppSizes.iconSm`
/ `iconMd` / `iconLg`.

**Semantic color goes on the icon, not on the row.** A destructive action row
renders a `critical` icon next to an `ink` label — it does not tint the label or
the row background. Applying the semantic to the whole row overstates it and
breaks the grey-control rhythm.

Disabled controls keep their `control` background and drop *both* icon and label
to `inkSubtle`.

`BreathingWarningBanner` is a status exception. Its caller-supplied semantic
color fills only the central icon circle and the two pulse layers. The banner
surface and all text stay neutral.

---

## The mascot

`CapyFace` draws the mascot; `CapyBadge` puts it on a `surface` disc with an
optional corner glyph, which is the app's mark. The art lives in
`assets/images/mascot/`, one file per expression **per direction**.

`CapyDirection` names the two: `front` looks straight at the reader and is the
default and the app's mark; `right` is turned slightly towards the reader's
right, for a face that should look at the content beside it rather than out of
the screen. A direction carries nothing about a state — both sets hold all
nine moods, and both are cut with one common box, so the head lands on the
same centre at the same scale whichever is drawn. `CapyMood.assetFor` is the
one place that knows how a file is named.

It is the one image in this package that is **full colour and never tinted**.
The vehicle line art is ink in an alpha channel that a widget colours with the
theme; the mascot is a character, and a character that changes hue with the
theme stops being the same character.

`CapyMood` has nine values and each is spent on one thing, so a face means the
same wherever it appears: `happy` (the ordinary good state), `delighted` (an
action finished well), `surprised` (an unexpected reading that is not a fault),
`sad` (an action failed and cost nothing), `angry` (a fault to act on),
`worried` (a degraded state — a stale reading, an estimate standing in for a
measurement), `sleeping` (nothing running and nothing wrong), `winking` (an
aside or a hint), `determined` (work in flight).

Do:

- keep the face beside the words and the number that state the same thing. A
  mood must never be the only carrier of a state: a reader who does not read
  faces has to lose nothing;
- size a face through `CapyFace.size` and let it decode at that size. The art
  is authored at 512 px, and a list of small faces decoded at full size is
  what fills the image cache;
- add a new expression by cutting it from the authored sheet, and add its
  value to `CapyMood`. `scripts/slice_mascot_sheet.py` cuts a sheet laid on
  near-white paper; a sheet that already carries its own alpha needs no paper
  step, and a sheet exported without an alpha channel carries the transparency
  checkerboard as real pixels and needs the same border flood fill the paper
  gets. Whichever the sheet is, cut every face on its own artwork rather than
  on an arithmetic third, and use one box for every face and every direction:
  a per-face box takes its side from the sleeping face's `Zzz` and quietly
  draws that head smaller than the rest.

Avoid:

- tinting the mascot, or drawing it inside a `ColorFiltered`;
- a mood that contradicts the copy beside it. A `happy` face over a failed
  sync is the same defect as an optimistic UI over a bridge error;
- committing the authored sheet. It is roughly twenty times the size of the
  nine files cut from it, and it carries the paper background as real pixels.

---

## Floating controls

`showFloatingSurface` owns the shared floating-panel route — `AppThemeColors.modalScrim`,
`AppMotion.base`, the 97% entry scale, and the reduced-motion branch — and every
floating surface composes it. `AnchoredTooltipTrigger` reports its open state to
the trigger builder. The dim keeps the source screen visible but inactive. A caller
selects `auto`, left, or right. `auto` selects the side with more usable space.
An explicit side is a preference: the layout flips it only when that side
cannot contain the full panel and the opposite side can. The mirrored caret is
centered on the trigger height and enters it by 4px. Keep the trigger on
`selectionFill` until the panel closes.

Use `caretAlignment` to select the preferred vertical position of the caret on
the panel. The caret still targets the center height of the trigger. Use a low
value for a heading tooltip and a high value for a panel that connects near its
bottom controls. Screen-edge clamping can move the panel but not the caret
target. Use `anchorInsets` when the visible anchor is smaller than its hit box.
The info button uses this to keep a 64px touch target and attach the caret to
its 32px circle.

The panel shows a title, an explanation, a default-value line, and one large
metric. Two 80px controls fill the bottom row. The down chevron decreases the
value. The up chevron increases it. A control stays visible and becomes
disabled at its limit. Each step applies immediately. The panel does not use a
confirmation button.

`MoneyKeypadDialog<T>` is the second panel on that surface, and it breaks the
rule above on purpose: it **does** use a confirmation button. A stepper applies
one bounded step, so applying it at once is safe. A typed amount passes through
every partial figure on the way to the one the reader means, and saving `9,00`
on the way to `9,45` would price a charge at a number nobody chose.

It takes the amount digit by digit, right to left, the way a payment terminal
does: each key is one more cent position, the readout starts at `0,00`, and
there is no decimal key and no caret. A keyboard is not reachable while
driving, and a free-text field accepts `1.2.3`. A leading zero is not a digit
position. An empty amount reports null, which is *no amount saved* and not a
price of zero. Two or more `MoneyKeypadField`s add a `TrackSegmentedControl`
over the readout and keep the digits of each field apart, because the fields
are alternative readings of one charge rather than a form. The caller supplies
the currency symbol and the decimal mark, from
`chargeCurrencySymbolForLocale` and `chargeDecimalSeparatorForLocale`.

`AnchoredTooltipSurface` supplies the standard white surface. Its child can be
any tooltip content. `ChargingAmperageDialog`, `MoneyKeypadDialog` and
`InformationTooltipPanel` use this surface. The caller supplies all visible
text.

`CategoryMenu<T>` is the third floating pattern and the only one that is not
anchored. It is a card-sized surface with its own internal navigation — a rail
of categories on the left and the options of the selected one on the right — so
`showCategoryMenu` centers it and gives it no caret. A caret would claim the
panel belongs to the button that opened it. It composes `showFloatingSurface`, so all five floating surfaces arrive the same way.

The rail is the one selection surface, on `selectionFill`. The detail side
belongs entirely to the caller: `detailBuilder` receives the selected value and
the panel scrolls whatever it returns, so the menu holds no copy of the state
it shows and knows nothing about settings. Selection lives in the open panel and
is reported through `onSelected`; the caller stays free to persist it.

`detailScrolls: false` hands the detail a bounded box and its own scrolling
instead. Use it when the detail is a long list of records rather than a page of
controls: inside the panel's scroll view a list is given unbounded height, has
no viewport to be lazy against, and builds every row it holds. The history
screen passes it, and fifty sessions became the handful that are visible.

Groups are separated by a rule rather than a surface step. This is a deliberate
second exception to rule 1: the rail sits directly on the panel and so has no
surface of its own to step down from. Search is optional, filters on the label
the user is reading, and never changes the selection — a filtered rail is a view
of the rail, not a navigation.

`showConfirmDialog` is the fourth, and the narrowest. It asks before an action
that cannot be undone, on the same scrim and the same entry as the other
floating surfaces. Only the confirming action returns true — the scrim, the
cancel action, and a back gesture all return null or false, so a destructive
action is never reachable by dismissing something. Its width is deliberately
far under a card's: this surface is read, not navigated, and a wide one puts
the buttons in the eye before the sentence.

`showNamePlaceDialog` is the fifth, also centered and narrow. It asks for a
place name on the same scrim and entry. It returns the trimmed name, or null
if the scrim, cancel action, or back gesture dismisses it; an empty name never
saves. Its width is `min(available, AppSizes.confirmDialogWidth)` — the same
token as the confirm dialog, because both are centered narrow surfaces sized to
be read, not navigated.

`DropdownField<T>` owns a different modal pattern. Its menu uses the exact
field width and expands upward or downward over the field, so the floating
surface hides the source control. `DropdownMenuDirection.auto` selects the side
with more space. An explicit direction flips only when the opposite direction
can contain the complete menu. Keep the current option in the menu and use
`selectionFill` for it. The field and option labels use 32px horizontal
padding. The menu uses 8px outer padding and 8px between options. Keep the
field on `selectionFill` with an up chevron until the menu finishes its closing
transition. Apply a new value when that transition starts. The field behind
the menu must show the new label during the fade.

---

## Tabs: three distinct components

These look similar and behave differently. They are separate components, not
variants of one, because their selected states are visually opposite.

| Kind | Selected | Where |
| --- | --- | --- |
| `PillTabBar` | filled `selectionFill` pill, `onSelection` label | page level |
| `TextTabBar` | `ink` label; unselected is `inkSubtle` — no fill at all | inside a card |
| `TrackSegmentedControl` | `surface` pill on a `control` track | local filter inside a card |

Picking the wrong one is the most likely way to make a screen look almost-right
but off.

---

## Charts

Chart plumbing is tokenized separately from data, in `AppChartColors`. Keeping
them apart is intentional: with gridlines and series in the same class, it is
only a matter of time before someone uses a gridline color as data.

- **Bars** are pill-capped at both ends. The normal profile uses
  `AppSizes.chartBarWidth`. The dense charge profile uses
  `AppSizes.chartDenseBarWidth`. The cap radius is half of the configured
  width. Bars may be signed — regen descends below the zero rule.
- **The slot grid** is a `ChartBarProfile`: a bar width and the gap between
  bars, with slot zero at the left edge of the plot. `AppSizes.chartBarProfile`
  and `AppSizes.chartDenseBarProfile` are the two the apps use. Pass a profile
  to a chart; never pass a bare width, or the gap silently takes a default that
  the bucket count did not assume. Ask `profile.slotsIn(plotWidth)` how many
  bars fit — it is the only route into `telemetry_core`, which holds no pixel.
  See ADR 0011.
- **Projected intervals** use `AppChartColors.projected`, drawn in the same
  geometry as real bars so the plot keeps its rhythm rather than ending
  abruptly.
- **"Now"** is a single `nowMarker` bar inside the projected run.
- **Overlay** curves and their handle dot use `AppChartColors.overlay` (ink).
- **Gridlines** are sparse and light; axis labels use `axisLabel`.
- **Horizontal time labels use three fixed anchors.** They show 0%, 40%, and
  80% of the complete visible slot domain. The last 20% stays unlabeled. The
  caller formats all three times. The final tick is not the domain endpoint.
- **Bars and time labels share one fixed slot grid.** Each slot uses
  the configured bar width plus `chartBarGap`. Slot zero starts at the left
  edge. Live data grows from left to right. Historical data keeps leading,
  internal, and trailing empty slots. The chart changes the bucket width when
  the complete grid is full. Ticks do not change bar positions or bar spacing.
- **Tooltips** are a floating `inverseSurface` card. It stays readable over
  both a neutral card and a saturated series in either theme. `ChartTooltip`
  renders the bubble; **the chart
  positions it.** A tooltip that placed itself would have to know the plot's
  bounds, and each chart clamps against those differently. After clamping, the
  chart hands back a `caretAlignment` so the caret still lands on the datum —
  that split is the whole contract between the two. Bar-chart tooltips use an
  automatic horizontal caret. The chart tries the right side first and changes
  to the left side when the complete callout does not fit. A new bucket grid or
  a replaced selected bucket clears the tooltip. A live update to the same
  bucket keeps it.
- **Callouts are two components, not one.** `ChartPinAnnotation` carries the
  vertical rule and the datum dot; the tooltip floats separately. They span
  different rectangles — the rule crosses the whole plot while the bubble is
  clamped inside it — so one widget could not position both.
- **A marker on the plot never animates.** The rule follows a finger or a rotary
  control, and tweening between samples reads as input lag. Only values animate
  (see [Motion](#motion)); positions under direct manipulation do not.
- **Donut arc ends stay flat and carry a small corner radius.** They are not
  semicircular caps. `StrokeCap.round` cannot express this: its radius is
  always half the stroke, which on a 40px ring reads as a blob.
  `SegmentedDonut` instead draws the sector shrunk by
  `AppSizes.donutCapRadius` on all four sides and grows it back with a
  round-joined stroke of twice that radius. Dilating a shape by *r* produces
  the required flat end with softened corners and keeps the ring thickness.
- **Bar-chart columns are pills.** `EnergyBarChart` uses semicircular caps with
  a radius of half its configured bar width. This pill rule applies to
  bar-chart columns and their stacked segments. It does not apply to donut
  arcs.
- **Rounding must be compensated in the swept extent.** Any rounding pushes
  past the geometry it is applied to, so the extent gives it back on both ends.
  Without that, the rounding eats the neighbouring gap and the size of that gap
  silently depends on stroke width. `EnergyBarChart` applies the same rule
  against its zero baseline.
- **Donut segments** are separated by a real gap (`AppSizes.donutSegmentGap`),
  not by a contrasting stroke, so same-hue segments stay legible. A segment too
  small to host its caps collapses to a dot rather than disappearing, which
  keeps a tiny reading on the ring.
- **The gap holds one width at every radius, so the arc ends slant.** A gap held
  at a constant angle opens wider the further out it is drawn, which leaves the
  two ends parallel and the ring reading as a cut tube. Held at a width, each
  arc is slightly wider at the ring's outer edge than at its inner one, which is
  the funnel shape the reference dashboards show. `gap` still states the
  separation on the stroke centerline, so the mean is the same and only the
  slant is new. `SegmentedDonut.taper` turns it off for a test that reads the
  swept angle.
- **Two readings of one interval get two segments, not one netted bar.** A drive
  minute both spends energy and recovers some, and both are true of that minute.
  `EnergyBar.counter` draws from zero on its own side of the axis so neither is
  hidden; stacking regeneration into `value` would net them into a single
  shorter column and lose the fact that either happened.
- **A stack is one bar, not two pills.** Stacked segments meet flush and square;
  only the column's outer ends are capped. A gap at the join reads as two
  separate readings floating in the plot rather than one column split into its
  parts.
- **Columns stand off the zero rule** by `AppSizes.chartZeroGap` rather than
  being drawn onto it. The baseline is what every column is measured from, so it
  has to stay readable behind them — and a short reading has to be separable
  from the axis itself. The cost is that a column's *length* is its value less
  that gap; the tip stays exact, which is where a value is read.
- **A segment never draws shorter than its configured bar width**, and it grows
  *away from where it starts*, never around its midpoint. Centring a
  short reading let its cap reach back across the zero rule, which put
  regeneration dots and pale feet on top of the baseline. A segment at the floor
  has stopped being proportional and says only "present, too small to scale" —
  which the foot of a stack needs, since auxiliary energy is a small fraction of
  a minute and would otherwise vanish under every bar. Stacking above such a
  segment is resolved in pixels: the segment above starts where the one below
  actually finished, not where its value said it would.
- **A base that opposes its value is dropped.** `base` is the foot of a column,
  so it only stacks when it agrees with `value`'s direction. A residual that
  came out negative says the measurement is unusable, not that the bar grows
  downward, and the value starts from the axis in its place.
- **A second reading of the same total goes on the inner arc, not in the ring.**
  `DonutInnerArc` draws a thinner concentric arc inside the segments, sharing
  their denominator and start angle. Regeneration uses it: energy recovered is
  measured *against* the energy drawn, not a slice of it, so putting it in the
  ring would make the parts sum to something that is not the total. The arc
  never shifts the segments above it.
- **The inner arc ends square** (`SegmentedDonut.innerCapRadius`, zero). The
  ring's corner rounding is what makes an arc read as a slice of the breakdown,
  so the second reading must not carry it. Flat ends are what separate the two
  at a glance.

---

## Motion

Use `AppMotion.fast` (120ms) for control state changes, `base` (220ms) for
layout and value transitions, `slow` (400ms) for meters animating to a new
reading. `AppMotion.curve` is the common base curve. The chart entrance adds
the tokenized bar-wave delay and small bounce described below. Per-widget
timing guesses are what make a system feel assembled rather than designed.

`BreathingWarningBanner` uses `AppMotion.breathing` (1800ms) for each expansion
or contraction. Its first pulse grows from 1× to 2×. Its second pulse grows from
1× to 3× and uses lower opacity. Stop both at 1× when reduced motion is active.

Floating controls use `AppMotion.base` for a short fade and scale transition.
The modal surface starts at 97% scale. Do not add a long entrance animation.

Dropdown menus use `AppMotion.base` for opacity and a 6% vertical translation.
They enter from below and move upward into position. Selection plays the exact
reverse transition. The field label changes when the reverse transition starts.

Animated charts take plain values, so screens never drive an
`AnimationController`. These rules make motion safe on live telemetry:

- **Re-target from the current frame, not from the last settled state.** A new
  reading arriving mid-animation continues from where the ring actually is.
- **Animate geometry, not just values.** In `SegmentedDonut` the denominator is
  tweened separately from the segment values — dividing by the animated sum
  would render a full ring on the very first frame and no sweep would ever be
  seen.
- **Tween every animated field.** Leaving one out does not freeze it, it drives
  it to zero for the length of the animation and snaps it back at the end. On a
  live caller that restarts the tween every second, that is a flashing element,
  not a missing one.
- **Limit the bar wave to grid entrances.** `EnergyBarChart` runs the wave on
  its first build. It runs the wave again only when the grid identity derived
  from `EnergyBar.id` (bucket width), `slotCount`, `barWidth` and `barGap`
  changes. A new live bar runs its own entrance and bounce. It does not
  restart, resize, or move a bar that is already visible.
- **Stagger the complete entrance.** Measured bars enter from left to right
  with an 18 ms delay between adjacent bars. Each bar gets a small late lift
  and settles at its exact value. Empty slots stay empty.
- **Introduce once.** An entry effect belongs to the first appearance. Re-running
  it on each update reads as blinking; `SegmentedDonut` fades its center value in
  on the opening sweep only.
- **Hold an entrance back with `EntranceGate`, not with a flag.** A screen that
  animates in while it is still transitioning has spent its entrance where
  nobody could see it. Since a chart starts its entrance from its own
  `initState`, the only way to defer one is to defer the *mount* — which is all
  `EntranceGate` does. Do not reach for `MediaQuery.disableAnimations` to
  suppress a subtree: it renders the final state, so the screen arrives fully
  drawn, and it is a real accessibility setting that must keep meaning what it
  says.
- **Honour reduced motion.** Check `MediaQuery.disableAnimations` and render the
  final state.

---

## Non-negotiables

These come from outside the visual language and still apply.

- **No hardcoded user-facing strings.** All text goes through the ARB files and
  `gen-l10n` (`lib/l10n/app_en.arb` + `pt` + `ru`). This includes labels baked
  into components — a component takes its text as a parameter.
- **Touch targets** are at least `AppSizes.minTouchTarget` (64). This is a
  driving-context UI; the phone-sized 48 minimum does not apply. A component
  may render a smaller *visual* (`SquareIconButton` fills 48 by default) as long
  as it occupies and accepts touches across 64. `SquareIconButton.size` sets
  that visual, and the glyph keeps its share of it; the hit target never falls
  below 64 whatever the size. The journey shell passes 64, so the settings gear
  stands as tall as the pills it sits beside. The single exception is
  `StatColumn`'s inline stepper at 32 per chevron, which follows the reference;
  anything adjustable while driving must also have a full-size control on the
  same card.
- **No raw `Color(0x…)`, `Colors.black`, or `Colors.white`** in components or
  screens. If a value is missing, add a token here with a doc comment saying
  what role it plays.

---

## Component inventory

Tiers reflect build order. All components live in
`packages/capy_ui/lib/components/` and are exported from
`package:capy_ui/capy_ui.dart`.

**Tier 1 — primitives** — built

`AppCard` (title + optional status badge + subtitle + trailing action slot) ·
`StatusBadge` · `InfoIconButton` (circular) · `SquareIconButton` ·
`MetricValue` · `MetricWithCaption` · `SoftActionTile` (disabled and selected
states; icon-level semantic) · `SelectableTile` (two-line preset) ·
`SettingToggleRow` · `TipBox` ·
`DropdownField` · `IconValueGrid` · `StatColumn` (optional inline stepper;
optional `onPressed` editor entry) ·
`BreathingWarningBanner` · `AnchoredTooltipTrigger` ·
`AnchoredTooltipSurface` · `ChargingAmperageDialog` · `MoneyKeypadDialog` ·
`CategoryMenu` ·
`ConfirmDialog` · `NamePlaceDialog` · `InformationCard` · `CompassTape` / `CompassCard` ·

`CompassTape` — built. A strip of the dial running under a fixed centre bar,
rather than a needle sweeping a fixed dial. That is the right way round for a
car: the answer stays in one place and the dial slides behind it, so the reader
does not have to find the needle first. The degrees sit centred **under** the
tape, on the bar's own axis, rather than in the card header opposite the title.

**The centre bar is the one accent on the card**, and it is `energyDraw` amber.
That is a deliberate, owner-chosen exception to rule 3 — a direction is not
energy spent — and it is narrow: the bar and nothing else. Do not let the amber
spread to the ticks, the letters, or the numeral.

**Everything crossing the bar is redrawn in the opposite ink.** The dial is
painted, then the bar, then the dial again clipped to the bar with `ink`
swapped for `surface`. The swap inverts correctly in both themes, because those
two tokens trade places between them. Without it the letter under the bar is
dark on amber at exactly the moment it matters most — it is the letter being
read.

**The bar is outside the end fade, the dial is inside it.** The dial fades to
nothing at both ends, because it is a circle and a hard edge would read as one.
The bar is not part of the dial; it is where the reading is taken, so it stays
at full contrast at any width.

**Motion is a chase, built as a critically damped spring** — `CompassNeedle`,
stiffness 100 and damping ratio 1.0, integrated in bounded sub-steps so a
dropped frame cannot be applied as one large one. The simulation is required,
not decorative: a curve applies the same shape to a 5 degree correction and a
180 degree spin, so either the small turn bounces or the large one does not.
The needle tracks the course on the shortest arc, so a turn across north is two
degrees and not 358.

The damping was 0.38 first, so that a fast turn overshot and swung back the way
a needle in fluid does. **It must stay at 1.0.** The course arrives once a
second, so every reading is a step, and an underdamped needle answered each
step with a swing — the card was never still, and what it reported was the
update rate rather than the road. A 90 degree step now lands in about 0.8 s,
which is over before the next course comes in.

**The letters are the reading; everything else gives way to them.** The tape
spans 60 degrees, not 90, and carries a tick every 15 degrees, not every 5. The
card is a square in the readout strip: at a quarter of the dial it put three
cardinals and seventeen ticks across about 250 px and read as a ruler. The
numeral sits a full `x6` below the tape, because at a small gap it read as a
caption on the dial instead of the second reading of one course.

**A held course is drawn muted, not hidden.** It is a real reading of an
earlier moment, so the tape and the numeral drop to `inkSubtle` and the card
captions it, instead of printing a dash that would read as a failure.

`InformationTooltipPanel` · `EntranceGate` · `ExpandableCardStage` ·
`MetricMosaic` · `RouteMapCard` · `ClimateControlCard` · `ClimateTemperatureBar` ·
`NowPlayingBar`

`ClimateControlCard` — built. Temperature and fan-speed steppers, an AUTO
toggle, an A/C · sync · front-defrost row, a seat-heat · steering-wheel-heat ·
pet-mode row, and a climate-schedule entry, in the card's ordinary tokens and
theme. Every value and every callback is supplied by the caller; a stepper
callback left null disables that button rather than hiding it, and a toggle
callback left null disables that tile — the component never invents a bound
or a supported feature the connected car did not report. `SteeringWheelIcon`
is drawn with a `CustomPainter`, the same way `BatteryAndroidFrameAlertIcon`
is, because a steering wheel is not in Flutter's bundled Material Icons font.
Not yet wired to `TelemetryApi`.

`ClimateTemperatureBar` — built. A pill-shaped, always-dark strip with a
decrease/value/increase cluster at each end, one per climate zone, both
clusters drawn identically rather than mirrored. It is the one component in
`lib/ui/` that deliberately ignores the theme system: it reads `AppColors
.climateBar*` constants directly instead of `AppThemeColors.of(context)`, so
it renders the same near-black bar in every theme, the way the reference head
unit's own climate strip does not change with the cabin's day/night setting.
Do not thread `AppThemeColors` through it or give it a themed variant. The bar
is `AppSizes.climateBarHeight` tall (64, the automotive touch minimum) so its
chevrons need no larger hit box of their own. A numeric reading gets `°`
attached; a floor or ceiling label (`LO`, `HI`) or an unreported `--` does
not. The mode line under the reading uses `climateBarOnSurfaceMuted`.

It is the only user of `AppJourneyScaffold.staticBar` — see below. **Its
values do not come from the car yet.** `getHvacControlStatus` publishes one
zone, and this bar has two, so nothing may state a cabin temperature through
it until the passenger zone exists natively and the steppers report the
read-back instead of the request. The Settings row that turns the bar on names
it a preview for exactly that reason.

`NowPlayingBar` — built. A themed pill: artwork, title, artist, and volume as
a sideways drag. It reads `AppThemeColors`, so it follows the chosen theme —
it is not a second always-dark climate strip. At volume zero the fill is a
circle the height of the pill; the artwork sits in that circle and the
speaker sits in the matching circle at the other end. The fill then grows
across the pill. A track change twists the sleeve in and slides the copy up.
There is no tooltip: the drag is the control. Volume min and max come from
the caller. A null `onVolumeChanged` disables the drag rather than hiding
the fill. Not wired to a media session yet.

`RouteMapCard` — built. A square map whose map **is** the card: no padding, no
header, no border, tiles running to the rounded corners. Square is enforced
inside it (`AspectRatio`), not left to the caller: the card is a window onto a
route, and a window that changes shape with its neighbour crops the route
differently every time the layout moves. Constrain one dimension and it decides
the other.

Its expand button is optional and only *asks* — `onToggleExpanded` reports the
tap and the caller decides what gives the space up, since only the caller knows
what else is on screen. A caller that has already decided the width passes
`square: false`, which is what a drive's detail does: the card sits under the
energy ring in a column of its own and grows *upward* over it, keeping the
column's width, so nothing else on the page moves.

The map is the one surface in this system that a control may sit *on*, so the
button, the speed legend and the OpenStreetMap attribution ride translucent
plates (`surface` at 82%). That is a deliberate exception to the
no-floating-controls rhythm: a bare icon over map tiles is unreadable half the
time. The attribution string is the tile provider's requirement rather than
product copy, which is why it is the one literal in the component instead of an
ARB key.

**The route is coloured by speed**, in runs of one colour rather than as one
line, over a wider stroke of `surface` — the same plate logic, for the same
reason. The ramp is `focus → energyGain → energyDraw → critical`: four palette
tokens, because a map that shipped colours of its own would be the one surface
whose green means something different. `RouteSpeedScale` is **relative to the
drive**, not to an absolute speed — the question the line answers is "where on
this drive was I moving well", and a fixed scale paints a whole car park one
colour. A leg the car reported no speed for takes `inkSubtle`, apart from the
slowest colour: "did not say" is not "was crawling". The start and end of a
route are `play_arrow` and `flag` on plates of their own; a single recorded
position is a `place`, since a charge does not move.

The legend is `RouteSpeedLegend`, two already-localized strings — the card
computes the scale and the caller names it, which is how the component keeps
the rule that it takes its text as a parameter. `RouteSpeedScale.fromPoints` is
public and pure so the caller can ask for the same scale rather than being
handed the card's internals. A card narrower than 320 px drops the legend and
keeps the colours: a legend wider than the map covers the route it explains.

**The tiles are filtered down to a dark ground**, through the same colour
matrix the previous map shipped — a green-weighted luminance with the black
point lifted, plus a plate of `inverseSurface` at 16%. This is the one place in
this system that paints a dark surface, and it is deliberate: the tiles are not
the app's surface but a photograph, the only image the app draws, so the rule
that keeps every panel light does not reach them. The reason is legibility, not
mood — four saturated ramp colours over a full-colour street map is two
pictures competing, and the filter is what leaves the route as the only thing
being read. Everything the card puts *on* the map stays light and gains
contrast from the change. The card's own ground follows the tiles, so a tile
still loading is the dark it is about to be instead of a light square that
flashes; a card with no position to show keeps the ordinary empty surface.

`MetricMosaic` — built. A wall of readings for a finished session: squares and
rectangles packed into a fixed-column grid, one hero and the rest interlocking
around it. Four spans only (`small`/`wide`/`tall`/`hero`) — a mosaic whose
tiles can be any size stops reading as a grid. `packMosaic` is a first-fit pack
over an occupancy grid, exposed separately because the packing is the part with
a right answer and placements are far easier to assert on than pixels; a later
narrow tile backfills a gap a wide one had to drop past.

It **fills the box it is given** and divides the height by its packed row
count, rather than asking for a height: its home is a card on a stage that does
not scroll, so a mosaic that wanted more room than the card has would have
nowhere to put it. A wall that does not fit loses tiles, per rule 4.

A tile with an `onPressed` is an entry point to an editor, and it grows a
pencil beside its caption — the same signal `StatColumn` gives, and for the
same reason: it otherwise looks exactly like the readings beside it, and a
reader must not have to find out by tapping. The callback is given the cell's
own `BuildContext`, because the mosaic packs its cells itself and the caller
has no other way to name the box an anchored editor must point at. `editLabel`
is required with it: the caption says what the number is, not what a tap does.

Tiles are `control`-step surfaces at `AppRadii.md`, and a tile's `accent`
colors its **icon only**. A tile whose whole background carried a series color
would read as a selection, which is the one thing color must not say here.

`ExpandableCardStage` — built. The dashboard grid as animated `Rect`s in a
`Stack` rather than flex children, for screens where a card has to change size.
Two independent mechanisms that compose: `CardStageController` drives a
*transient* drag-to-fullscreen (and, once fullscreen, a sideways carousel peek
that always springs back), while `CardStageResize` holds a *permanent*
quarter-stepped resize a control can toggle. Each slot builds its content for
the `CardSize` it currently has, and the stage cross-fades between two layouts
at the halfway point of a resize — real content has no continuous "half its own
width" rendering. A card that looks the same at every size takes
`CardStageSlot.stable` instead: the cross-fade re-keys a slot on every size
change and disposes the layout it fades out of, which for a card whose `State`
owns something — a platform texture, a player, a controller — is a teardown
rather than a dissolve, and it fires exactly when the expand gesture lands on
`CardSize.fullscreen`. `ThreeColumnLayout` and friends stay for screens with no such
card: they have no geometry a card could grow beyond its own slot into, which is
the whole reason this exists.

Two rules it encodes that are easy to get wrong. A gutter belongs to a *pair* of
cards, not to a slot, so a card collapsed to nothing takes its gutter with it
instead of leaving the row inset from its own edge. And an edge with no
neighbour to reveal resists the peek asymptotically rather than sliding freely —
`AppSizes.cardStagePeekResistance` of travel and no more, because a dead edge
reads as a dropped gesture while free travel promises a card that does not
exist.

`EntranceGate` — built. The one component here with no visual of its own: an
`InheritedWidget` that decides whether the subtree below it is mounted yet, so
an entrance animation plays on arrival instead of behind a transition. Absent,
it reads as open, so a component dropped in the gallery or a test is unaffected.
Callers wrap content in `EntranceGate.guard`, which holds a placeholder in the
closed state — pass one whenever the content sizes itself rather than filling
the slot, or the layout jumps when the gate opens. See the motion rules above.

`BreathingWarningBanner` — built. It fills the available width and keeps a
fixed 112px height. It has a 56px icon circle, a 96px leading area, one 2×
pulse, and one more-transparent 3× pulse. Text truncates safely on narrow
panels. The animation repeats in both directions and stops for reduced motion.

`ChargingAmperageDialog` — built. It uses a responsive 416×408px maximum
surface, a light modal dim, a left-or-right button anchor, a 4px caret overlap,
a large value, and two 80px chevron controls. It applies each bounded step
immediately. The gallery `48 Amps` action stays selected while the panel is
open and reflects the selected value.

`MoneyKeypadDialog<T>` — built. A title, an explanation, an optional field
selector, the amount on a `control` step, a 3 x 4 keypad of 64px keys, and a
full-width confirm action. It reports one amount for one field and pops its own
route. It scrolls inside the surface, because it is the tallest floating panel
in the app and a viewport shorter than the head unit must lose no key.

`StatColumn` grows an editor entry with `onPressed`: the column steps up onto a
`control` surface and gains a pencil. A stat that opens a keypad is otherwise
identical to the stats beside it that do nothing, and the reader must not have
to find that out by tapping. Every column in the same strip then carries the
same padding, so the editable one does not sit a step below its neighbours.

`InformationCard` and `InformationTooltipPanel` — built. The panel shows a
centered heading and a stack of darker neutral information cards, scrolling the
stack when a translation makes it taller than the viewport allows. A card takes
an optional `icon` in its series color, so a legend can be explained with the
same glyph the chart draws rather than by naming a color in words. A card also
takes an optional `linkLabel` with `onLinkPressed`, drawn as an underlined line
of its own under the description rather than a span inside the paragraph: a link
buried in running text is hard to hit with a thumb, and it survives translation,
where the sentence around it moves. The card opens nothing itself — the screen
passes the callback — so the design system carries no URL launcher. The gallery
charge-limit tooltip explains the 70%, 85%, and 100% presets. Its info button
uses the selected inverse state until the tooltip closes.

`DropdownField<T>` — built. It is controlled by typed `DropdownOption<T>`
values. The modal menu matches the field width, dims the remaining screen,
selects an available vertical direction, and shows the current option with the
inverse selected style. A new choice updates the field when the reverse
fade-and-slide transition starts.

**Tier 2 — tabs** — built

`PillTabBar` · `TextTabBar` · `TrackSegmentedControl`. All three share
`TabItem<T>` from `pill_tab_bar.dart`. Each `TextTabBar` item keeps a minimum
64×64px touch target, including when its label is short.

`PillTabBar`'s selected pill is one shape that slides between tabs, and each
label inverts pixel-for-pixel with it. It measures each pill rather than
dividing a grid, because localized labels have no proportional grid to divide,
and it measures again after every build, because a text-scale change moves the
labels without changing one field of the widget. By default it animates itself
off `selected`. Give it a `position` — a continuous fractional index, and
`PageTabPosition` wraps a `PageController` as one — only when the bodies below
it roll rather than cut, so the pill and the cards run off one clock and cannot
drift. It masks the pill with a second copy of the label row painted through
`RichText`, not `Text`: a second `Text` would make every tab label match twice
in `find.text` for every test that builds a screen.

`AppJourneyScaffold<T>` owns the page-level pill tabs, canvas, safe area, and
common spacing for the temporary V2 journey. `trailing` anchors one chrome-level
action to the right edge of that row, centred on its height — the settings gear.
It sits outside the scrolling pill row on purpose: it is not a destination, and
a long localized tab set must never be able to scroll it off the screen.
Two more optional parameters exist for
a journey whose body rolls and whose cards can expand: `position` passes
through to `PillTabBar` unchanged, and `stage` — a `CardStageController` —
hides the pill row in lockstep with a card taking the screen over, the same
translate-off-screen treatment the mock validated, now shared rather than
duplicated per caller. Neither changes anything for a journey that passes
neither.

`staticBar` is a fourth strip, and its difference from `footer` is structural
rather than a flag. The pill row and the footer are chrome **of the journey**:
painted over the body, riding `stage`, pushed off screen by a card growing to
fullscreen because the card is what the journey now shows. `staticBar` is not
part of the journey. It is the vehicle's, it is laid out as a sibling above
that stack, and its height comes off the journey's before the journey measures
anything — so no card, no destination and no `footerVisible` can reach it.
There is deliberately no `staticBarVisible`: a control the driver may need at
any moment must not be something a screen can take away. The one thing that
drops it is a viewport too short to hold it and a touch target's worth of body
as well, and it drops whole rather than shrinking — half a bar is not a
control anyone can press. Reserve its height with `staticBarHeight`, which the
scaffold pins rather than reading off the child, because the drop decision
needs that number before layout.

A static bar also changes what the app **is**, not only what is under it. With
one, the scaffold paints the whole ground in `AppColors.climateBarSurface` and
insets the journey by `AppSpacing.bezelInset` into a rounded window at
`AppRadii.xxl`. The bar then sits in that same field, its ends flush with the
window's, so the strip reads as a hole in the frame rather than a panel laid
on top of one — which is why one colour constant serves both and why the
radius is large: a timid one reads as a rendering seam.

The window is two clips, not one. The body clip cuts the history map and an
expanded card; the footer clip is only as tall as the instant-readout strip.
A single clip around both made every footer tick recompose the whole window.
When the footer is gone the body clip takes all four corners so the window
stays one shape. Without a bar there is no bezel, and the canvas runs to the
edges exactly as before.

`ThreeColumnLayout` provides the dashboard grid; after gutters are
removed, it distributes the available width at an exact 1:2:1 ratio.

`HorizontallyExtendedTwoColumnLayout` keeps a complete `TwoColumnLayout` in
the first viewport: 3/4 for the primary panel and 1/4 for the trailing panel.
A horizontal drag reveals one additional 3/4-width panel after the trailing
panel. In this extension, the CarPlay texture fills its card with no header,
padding, inset, or caption. Do not shrink the first two panels to make the
extension visible. The Now destination no longer uses this layout — it moved
to `ExpandableCardStage`, below — but the component remains for a screen that
wants a scroll-revealed panel rather than a draggable one.

`ThreeColumnLayout` has no narrow fallback, and this is deliberate: the target
is a landscape head unit, and reflowing an at-a-glance driving dashboard into a
scrolling column would defeat its purpose. It does mean the layout has a floor.

- **Design width: 1280 logical px or wider.** Every V2 screen is composed
  against this and it is what the widget tests set the view to.
- **Floor: 960 px.** Below this a side column falls under ~220 px and content
  starts trading down — `MetricWithCaption` in the V2 Charging left panel
  already drops from `MetricSize.xl` to `.md` at that width. A component that
  can shrink gracefully should do so with `LayoutBuilder`, as that one does.
- **Below 960 px is unsupported.** Do not add a wrapping or stacking fallback
  to `ThreeColumnLayout` to reach it. If a real target needs it, that is a new
  layout with its own composition, not a breakpoint bolted onto this one.

A card that cannot survive the floor is a signal that the card is carrying too
much, not that the grid needs a breakpoint.

The V2 Charging center panel uses `TextTabBar` for Level and Graph. Level uses
`LimitSlider` with the live SOC, the persisted charge target, and the 70%, 85%,
and 100% presets. Its range value is an estimate from recent trip efficiency
and is always marked `EST`. Graph loads the latest charge session by default
and accepts a supplied `ChargeSessionSummary` for future list navigation. Its
SOC bars use a linear 0–100% height. Its power line uses a logarithmic 0–80 kW
scale, so low-power charging stays visible while sessions remain comparable. The
80 kW ceiling is shared and fixed for every session under it; a session that
peaks above it raises the ceiling to the next 10 kW step rather than clamping,
because flattening a real reading against the top gridline while the tooltip
still reports the true figure would make the chart disagree with itself. Time
buckets use progressive whole-minute intervals selected from the complete
session duration and the number of slots that the available width can show.
The charge chart keeps a five-minute minimum. Widths up to 60 minutes change in
one-minute steps. Widths from 61 through 180 minutes change in five-minute
steps. Larger widths change in fifteen-minute steps. This permits intervals
such as 32 minutes without letting long sessions overflow the plot.

The power line reaches the baseline through `EnergyBarChart.overlayAnchor`, not
by zeroing the edge samples. An anchor is drawn geometry placed on the outer
edge of the first or last column — outside the span any sample occupies — so
every bucket keeps the power it actually measured. Never overwrite a sample to
shape a curve: the tooltip reads the same array, and the two would diverge.

The V2 Charging right panel uses `ChargeSessionSummaryCard` for the selected
session. It always shows battery energy. The second slice is the **climate**
energy the charge measured, and it is the only auxiliary load a charge session
can report: during a charge the pack term is the charging current, so the
`pack - traction` remainder that names the system load on a trip does not exist,
and no CAN signal measures the rest. The slice appears only when the integral
covered the whole charge; a partial one stays `--` and creates no arc.

**Tier 3 — charts and charge-limit control** — built

`SegmentedDonut` — built. Multi-segment ring with tints, stacked center
value/unit/delta, and perimeter markers. Two modes: pass only `segments` for a
breakdown that fills the ring, or set `total` (with `showTrack`) to turn it into
a meter where the shortfall stays empty. It squares its own box before painting:
`AspectRatio` hands tight constraints straight back, so a stretched parent left
the ring centered on the full box while the markers were placed against the
shorter side, and the icons drifted onto the ring.

`ChargeSessionSummaryCard` — built. Charge-session donut and two-entry legend
for battery and climate energy. Climate energy is optional and missing data is
never converted into a zero-valued segment.

`ChartTooltip` — built. Dark callout with an optional title, a value/unit
headline and swatched `ChartTooltipRow`s. The caret is placed by `side` +
`caretAlignment` and drawn unioned into the bubble, so there is no seam where it
meets the edge; alignment is clamped to the flat part of the edge so the caret
never climbs a corner.

`ChartPinAnnotation` — built. Vertical rule plus a ringed datum dot, sized to a
fixed `ChartPinAnnotation.width` so a chart can center it on a column.

`EnergyBarChart` — built. One controlled, animated component for signed energy
use and positive charging projections. It includes pill columns, stacked bases,
projected and now states, a straight overlay, ring markers, drag selection,
clamped tooltips, axis labels, and a corner caption. The grid identity is
derived internally from each `EnergyBar.id`, `slotCount`, `barWidth` and
`barGap` — no caller key needed.

`CycleBar` — built. Static 64px pill for one battery cycle. The scale is the
whole battery, so the fill is the share of 100% of state of charge that driving
removed, in `energyGain`. The green is deliberate and is the one place it does
not mean recovered energy: the pill fills towards one whole battery, so a
complete cycle is a completely green pill and a partial one shows its share. It
carries the cycle ordinal at the filled end and the
percentage at the other end, both as caller-supplied strings. `isPartial` keeps
a 2px `divider` outline over the pill, which marks a battery that collection
joined in the middle of. It has no knob, no gesture, and no animation: it is a
reading, and it repeats down a list in a moving car. Do not reach for
`LimitSlider` for this. A charge target has a knob, a 50–100% travel and target
semantics, and none of those describe a battery that is already spent.

`SocSpanBar` — built. Static 20px pill for what one recorded session did to the
battery, with its two numerals underneath. The scale is the whole battery, so
two sessions can be compared by looking at them, and what the pill carries is
the span: the battery below the lower end takes `control`, the stretch between
the two ends takes `energyGain` for a session that gained and
`energyCritical` for one that lost, and the rest stays `track`. The direction
is read from the two ends alone, so a drive that somehow ended higher says so
instead of being repainted into the expected story. It has no knob, no gesture
and no animation. It is a sibling of `CycleBar` and of `LimitSlider`, not a use
of either: a cycle fills from zero because it counts a whole spent battery, a
target has a knob because it is a setting, and a recorded session is neither.

`MagnitudeBars` — built. Several measured quantities on one scale, each named,
each with its number, each over a 6px rule. The scale is the **largest** bar,
not the sum: this is a comparison, and a reader who takes it for a partition
would read the longest bar as "all of it". That distinction is the reason the
component exists. Energy drawn and energy recovered are the case — recovery is
measured against what was spent rather than carved out of it, so it has no
slice of a ring and no share of a pill, but it does have a magnitude that can
sit beside the others. A quantity that measured zero keeps its row and its
number and draws no bar: the row is the reading, the bar is only how long it
is. `footnote` carries a localized total under the list.

`ShareBar` — built. How a whole divides, drawn as one 10px pill with a named
key under it. A partition, not a progress bar: the segments always fill the
pill, because what it answers is "of the whole, how much was each", and a track
showing through would invent a remainder the reading does not have. `CycleBar`
and `SocSpanBar` are the readings that do have one. A part that measured
nothing is dropped rather than drawn as a hairline, since a sliver too thin to
see but wide enough to shift its neighbours is a lie about a part that was not
there. Widths and words come from the same values, so the bar cannot disagree
with its own legend, and the caller passes each label already localized and
already carrying its percentage.

`SeriesTrace` — built. One measured quantity across a session, drawn as a line
over its own range with the two ends of that range labelled beside it. The
vertical axis is the data, not a fixed scale, because a flat drive and a
mountain drive are different questions and one fixed altitude axis would draw
the first as a straight line at the bottom; the two labels are what stop a flat
trace reading as a dramatic one. A point with a null value breaks the line, and
joining across it would invent a slope nothing measured. The height is stated by
the component, since a stretching row inside a scrolling column is asked for an
infinite one. Use it for a plain reading — altitude, outside temperature. Do
not use it for efficiency: `EfficiencyChart` is fixed to Wh/km on a descending
axis because that chart carries a judgement about what is good, and nothing on
a `SeriesTrace` is good or bad.

`LimitSlider` — built. Tall single-pill track with charged, pending, and
beyond-target zones, a 52px knob inside a 64px hit target, clamped readouts,
50–100% target travel, drag-only 10% guides in `AppChartColors.nowMarker` that
fade in and out with `AppMotion.fast`, 1%
drag input, 1.14× pressed-knob feedback, semantics actions, keyboard input, and
interruption-free direct manipulation. The pill keeps the full 0–100% battery
scale. An 8px background-color cut marks a target below the current charge.
During active charging, three full-height light-green wave fronts move from
left to right only through the charged green zone. A bolt moves out from behind
the current SOC, from right to left, and pushes the SOC to the right. It
reverses the transition when charging stops. The wave traversal
uses a logarithmic 0–80 kW cadence from 2.8 to 0.95 seconds. This keeps slow
charging visible and prevents fast charging from producing distracting motion.
Unknown power uses the slowest cadence. Reduced motion stops the waves but keeps
the bolt as a static status cue. While the knob is being dragged it reports the
drag state through `onDraggingChanged`, so the preset row keeps **Custom**
selected across the whole gesture and only activates the matching named preset
once the drag ends.

`TiltGauge` and `TiltCard` — built. A vehicle standing on a ground line that
turns with the measured angle, over a half-disc, between two fixed level
dashes. One component serves both tilt axes: the axis is the `CarSilhouette`
alone — pitch is the side view, roll is the front view — and nothing inside the
gauge knows which reading it shows. Four rules it encodes:

- **The reference does not turn.** The car, the ground line and the disc are
  one group; the two dashes at the sides stay horizontal. The reading is the
  angle between them. A gauge whose reference turned with the car would show
  nothing.
- **The angle is drawn as measured, never exaggerated.** A 1° pitch looks very
  nearly level, because it is. The numeral beside the dial is what carries a
  small reading — scaling the drawing up to make 1° visible would report a
  slope the car is not on.
- **Which way a positive angle turns belongs to the artwork.**
  `CarSilhouette.rotationSign` carries it, because a drawing that faces the
  other way inverts the sense of every reading and a screen has no way to know
  which way the file happens to face. The side file faces left and is drawn
  with `mirrored`, so the nose is at the right of the drawing. A nose-up
  (positive) pitch must then raise the right edge, which on a y-down canvas is
  a counter-clockwise turn, thus a sign of -1. Reason this out from the drawing
  each time. The car showed the inverted card twice on 2026-08-11: the second
  time because the mirror was added and the sign was inverted with it, when
  only one of the two changes was the fix. The front
  view **mirrors the vehicle**: positive roll is the right side down, and the
  right side of the car is at the left of that drawing. Read that mirror before
  wiring a source — a roll signal in the driver's own frame has the opposite
  sense here, and the sign belongs to whoever knows which frame the signal is
  in.
- **An unknown tilt is not a level car.** A null angle draws level in
  `inkSubtle` and the caller shows `--`, so the tile never reports level as a
  measurement it does not have.

The gauge holds no fixed size. It resolves one dial diameter from the box it is
given and lays every part out as a fraction of it, so the drawing keeps its
proportions from a quarter card to a full one.

**Every view is drawn to the same height; the width follows from the aspect
ratio.** This is the one scale that is true — the views are the same vehicle,
so its height is the same in all of them, while a side view is over twice as
long as a front view is wide. Sizing by width instead makes the front view
tower over the side view at the same nominal size, and the two tiles then read
as two different cars.

**The box reserves the rotation envelope, not the resting height.** The group
turns about the middle of the ground line, so a corner of the drawing travels
on a circle of that radius, and the tallest the drawing ever stands is the
distance from the pivot to its far top corner — `sqrt(ar² / 4 + 1)` times its
height. Reserve only the resting height and a large angle swings the roof out
of the box, where the gauge's own `ClipRect` cuts it off. The headroom is the
largest envelope of **any** view, and the ground line sits at the same place in
all of them, so two tilt tiles beside each other share one dial rather than
reading as two instruments.

**Vehicle artwork is alpha, not colour.** Each silhouette is ink in the alpha
channel over black RGB, and the gauge tints it with the theme ink through
`BlendMode.srcIn` — so one file serves both themes and no dark-mode copy
exists to fall out of sync. Two scripts produce them, from the masters kept in
`art/`. `scripts/extract_line_art.py` rebuilds the alpha from luminance (the
source PNGs carry the transparency checkerboard as real pixels, which is what
makes them ~50x larger) and crops to the ink, so the asset's bottom edge is the
tyre contact line. `scripts/thicken_line_art.py` then sets the line weight for
the size the gauge draws at and reduces the master to the shipped asset. Both
print the aspect ratio the `CarSilhouette` needs; it must be updated with the
art or the gauge distorts the drawing.

**Line weight is chosen for the drawn size, not for the master.** The gauge
draws the vehicle about 156 logical pixels wide (side) and 80 (front), so a
1200px master is reduced 8 to 15 times. A line that falls below one pixel there
does not get thinner — the line *is* alpha, so it goes translucent, and the
vehicle reads as a grey ghost beside the solid ground line while the rotation
makes it shimmer. The thickening script separates the two kinds of line for
this reason: the **outer contour** carries the shape and the reading and is the
heaviest, while **interior** panel gaps, glass and wheels are detail and blob
into a solid mass at the same weight. The gauge decodes the art at the size it
draws it, capped at `CarSilhouette.sourceWidth`.

`EnergyBarChart` and `LimitSlider` follow the contracts specified in this
document. Two gaps remain open: the missing pin callout and the
`SegmentedDonut` leader lines. Read the chart sections here before you change
either component.

> A component that wraps text must cap its width in a way that survives an
> **intrinsic** query, not just layout. `ChartTooltip` learned this the hard
> way: a `ConstrainedBox` forwards the incoming width untouched to a height
> intrinsic, so it answers as if nothing wrapped and then wraps anyway, and any
> parent that measured it (an `IntrinsicHeight` row, a scrollable) lays it out
> too short and overflows. With three locales in play, `pt`/`ru` wrap where `en`
> does not — so this is a shipping bug, not a hypothetical one.

**Tier 4 — bodies** — built

`SettingsBody` + `SettingsBodyController` + `SurfaceCapabilities` + `SettingsAdaptiveGrid`/`SettingsEntry`/`SettingsSections`/`SettingsRows` + `appThemeName` — shared, platform-agnostic screen bodies. A body takes view state, intents, and `SurfaceCapabilities` and never calls `Navigator` or reads a store. `SurfaceCapabilities` branches only on `widthClass` (`compact` <600, `medium` 600–839, `expanded` >=840) — no `isCar` flag. `SettingsBody` renders its sections via `SettingsAdaptiveGrid`: `compact` is a single column, `medium`/`expanded` is a 2-column section grid with `AppSpacing.gridGutter`; `allowKeyboard==false` makes rows read-only with an explanatory `TipBox`. `appThemeName` is the single package-side resolver for the 9-case theme switch, replacing the duplicated `_themeName` in `DisplaysPane` and the companion `SettingsScreen`. Gallery `settings-body` covers `compact` (390 px phone, single column), `medium` (720 px tablet, grid), and `expanded` (960 px scaled head unit, grid). Both car (`DisplaysPane` via `SettingsBody`) and companion (`_AppearanceCard` via `SettingsBody`) mount the same body through thin adapters (`CarSettingsSource`/`CompanionSettingsSource`).

### Gallery

`packages/capy_ui/lib/gallery/gallery_home.dart` is the catalog. Each tile
opens one component's demonstration page under `packages/capy_ui/lib/gallery/pages/`.
A page that is driven by input — `TiltGauge`, `LimitSlider`, `CompassTape`,
climate, charts — carries the controls that change it, so states are judged
live rather than as a static collage. The live harnesses (efficiency, chart
motion, smoothness) stay on their own screens and are linked from the catalog.

It is not wired into the shipping app. Run it on its own:

```sh
flutter run -d chrome -t packages/capy_ui/lib/gallery/gallery_main.dart
```

Or push the catalog from a debug route:

```dart
Navigator.of(context).push(
  MaterialPageRoute<void>(builder: (_) => const GalleryHome()),
);
```

`GalleryApp` supplies `AppTheme.light()` at the `MaterialApp`. A page that
must demonstrate another theme wraps itself. Demo copy is exempt from the ARB
rule below — it never ships to a user.

---

## Migration

The rule is additive-then-subtractive, one screen at a time:

1. Build the components the screen needs in `packages/capy_ui/`, review them
   in the gallery.
2. Port one screen fully to `capy_ui` tokens and components. Do not leave a
   screen half-migrated — mixed radii and mixed border rules read as a bug.
3. Delete the legacy widget once its last usage is gone.
4. Swap `MaterialApp.theme` to `AppTheme.light()` only when the last screen has
   moved.

Never import `lib/design_system/` and `package:capy_ui/capy_ui.dart` tokens
into the same widget.
