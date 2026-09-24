# 8. Shared Screen Bodies via Surface Capabilities

## Context and Decision

Settings, History, and Journeys exist in both the car head unit and the companion phone app. The data seam is already shared (`Telemetry Store` with `listSessions`/`session`/`series` plus `TelemetryQuery`/`Loadable`), and the token/component seam is shared (`capy_ui`). What diverges is composition: the car uses `AppJourneyScaffold` with bezel, `staticBar`, and `CardStage` master-detail; the companion uses `CompanionShell` with `PillTabBar` and `Navigator.push`. The companion re-implements toggles, metric pills, and journey cards that `capy_ui` already ships, and both apps duplicate the `_themeName` switch and theme-id parsing.

We decided to keep two surface scaffolds and share screen bodies:

1. **Two scaffolds, shared bodies.** `AppJourneyScaffold` and `CompanionShell` keep their chrome and navigation. Shared, platform-agnostic bodies (`SettingsBody`, `HistoryBody`, etc.) live in `capy_ui` as Tier 4 and are composed by each scaffold. A body takes view state, intents, and surface capabilities; it never calls `Navigator` and never reads a store directly.
2. **Three reactivity axes.** Every body handles `data-reactive` (store to view model to UI), `viewport-reactive` (available width), and `input-reactive` (rotary vs touch, selection model, keyboard allowance, reduced motion) as named dimensions.
3. **Surface Capabilities, not platform enum.** Bodies branch on a value object `{widthClass, supportsSelection, inputMode, allowKeyboard, density}` derived from `MediaQuery`. No `isCar` flag. `widthClass` follows Material 3 `compact`/`medium`/`expanded` (phone is `compact`, car is `expanded`). `allowKeyboard == false` (vehicle moving) makes the body render read-only with an explanatory `TipBox` rather than delegating the block to the adapter.
4. **Shared ARB in the package.** `capy_ui` gains its own `l10n/` and `gen-l10n` for strings owned by shared bodies; shell/chrome strings stay in each app's ARB. This follows `DESIGN.md`'s "text as parameter" lineage but centralizes what is truly shared.
5. **View model beside the body.** `SettingsBodyController extends ChangeNotifier` (and peers) live beside the body in `capy_ui` and depend on an injected `SettingsSource` interface. The car adapts `ThemeController`/`SharedPreferences`; the companion adapts `CompanionThemeController`/`Archive`. Pilot is Settings because it validates l10n, form controls, and toggles with the smallest blast radius; History follows with the proven contract.
6. **Pure intents up.** Bodies emit `onThemeChanged`, `onRequestThemePicker`, etc. The scaffold decides whether to call `showCategoryMenu`, `showMoneyKeypadDialog`, or `CardStage.expand`.

## Consequences

- New bodies follow the non-negotiables in one place: text via l10n, 64 touch targets, tokens only. A visual fix lands in both surfaces with one commit.
- Chrome divergence remains explicit and testable. `AppJourneyScaffold` and `CompanionShell` are the only adapters at that seam; the "unified scaffold" alternative is rejected to avoid scattering `isCar` branches.
- `capy_ui` grows a bodies tier and a `l10n/` directory. `DESIGN.md` inventory and gallery gain body pages. The workspace makes a later split into `capy_bodies` cheap if weight demands it.
- Capability mis-wiring fails locally: a body given `supportsSelection: true` on a phone still renders selection, but the contract is one object, not N dispersed checks.
- Settings strings move from two app ARBs into the package ARB; the duplicated `_themeName` switch and hand-rolled `appThemeIdFromName` copies are deleted when the body adopts them.
