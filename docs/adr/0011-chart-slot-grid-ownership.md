# 11. Who Owns the Chart Slot Grid

## Context and Decision

The energy chart draws bars on a fixed grid. One slot is `barWidth + gap` wide,
and slot zero sits at the left edge of the plot. Two packages depend on that
pitch:

- `capy_ui` draws it. `_ChartGeometry` in `components/energy_bar_chart.dart`
  places each bar at `contentLeft + barWidth / 2 + index * (barWidth + gap)`.
- `telemetry_core` counts it. `energyChartBarCapacity` in `energy_buckets.dart`
  reports how many bars fit a plot width, and `chooseEnergyBucketWidth` picks
  the bucket width against that count.

The two agreed because both read `EnergyChartTokens`, a `telemetry_core` class
holding two doubles, which `AppSizes.chartBarWidth` and `AppSizes.chartBarGap`
re-exported.

That put pixel measurements in the domain package. It also read as the reason
`capy_ui` imports `telemetry_core`, which it is not: `capy_ui` imports that
package in 19 library files as of this ADR, for domain models — journeys, places, efficiency
windows, sync annotations. Deleting the tokens removes no package dependency,
and the design system is expected to keep that import.

**The design system owns the pixels; the domain owns the arithmetic.**

`ChartBarProfile` in `packages/capy_ui/lib/tokens/chart_bar_profile.dart` is the
grid. It holds `width` and `gap`, and it is the only place `width + gap` is
summed. `AppSizes.chartBarProfile` and `AppSizes.chartDenseBarProfile` are the
two profiles the apps draw with. `EnergyChartTokens` is deleted.

The width and the gap are one value, not two arguments, because they always
travel together. `charge_session_chart.dart` used to name `chartDenseBarWidth`
twice — once to ask for a bucket count, once to draw — and never named the gap
at the second call, which took the default. Nothing made the two agree. A chart
now names one profile and passes it to both.

`energyChartBarCapacity` keeps the capacity formula, because bucket selection is
domain work, but takes `pitch` and `gap` as required named arguments. Those are
the measurements the count actually needs. The domain neither holds a pixel nor
restates the pitch. `ChartBarProfile.slotsIn` is the way in, so a caller reaches
the count through the profile rather than spelling the grid out.

## Consequences

`telemetry_core` holds no logical pixel and no second statement of the pitch.
A reader of `energy_buckets.dart` sees that the plot geometry arrives from
above.

`_ChartGeometry` in `energy_bar_chart.dart` reads `profile.pitch` instead of
summing. The sum has one home.

`packages/capy_ui/test/energy_bar_chart_test.dart` pins the two sides together:
for both profiles across five plot widths, the last bar `slotsIn` counts must
land inside the plot, and one more bar must not fit. A drift on either side
fails it.

The required arguments are a breaking change to the `telemetry_core` surface,
and `EnergyBarChart` takes `profile` in place of `barWidth`/`barGap`. The
analyzer reports every call site, so both breaks are loud.

`SessionDetailScreen.columnWidth` in the companion had a fourth statement of the
grid, and it was wrong: it divided by the pitch without sparing the trailing
gap, so it under-counted by one bar at some widths. It now calls `slotsIn`. The
companion chart may show one more column than before at those widths.
