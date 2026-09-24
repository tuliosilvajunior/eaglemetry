# CLAUDE.md

## Agent Conversation

These rules are mandatory when you talk to the project owner:

- Write in ASD-STE100. Use short sentences and direct verbs.
- Reply in the language the project owner used.
- When the language is Portuguese, use common Brazilian Portuguese (e.g., tela, celular, registro, arquivo, time/equipe, conexao, acessar, rodar/executar, gerenciar, "vai mudar", "esta fazendo").
- Keep technical terms in English when the code uses them: sync, pull, ack, cursor, thread, commit, merge, branch, build, log.
- Be brief when work is complete and correct. State what you did and stop.
- When a problem is found, explain clearly what is wrong, why, and what follows from it.
- When the project owner must decide, write the decision in full:
  1. **Cause**: What happened or what the code does now.
  2. **Why a decision is necessary**: What you cannot choose for the owner.
  3. **Choices**: Each choice as its own item.
  4. **Effects of each choice**: Specific gains and losses (data, UI, car safety, tests).

## Project Overview

Capy Energy is an automotive telemetry application for Geely / Flyme Auto Android Automotive head units, paired with a phone companion app (`apps/companion/`).

Architecture boundaries:
- **Flutter** owns UI, navigation, presentation state, charts, filters, and user workflows.
- **Native Android/Kotlin** owns vehicle access, Android Automotive permissions, lifecycle services, and Room persistence.
- **Pigeon** (`pigeons/telemetry_wire.dart`) defines the typed bridge between Flutter and Kotlin.
- **UI Design System** is defined in `packages/capy_ui/` (see `packages/capy_ui/DESIGN.md`).

## Always Keep Awake During Long Work

Start desktop keep-awake for any non-trivial task:

```bash
caffeinate -dimsu
```

Stop the process when work completes.

## Tooling and Validation Commands

Run Flutter checks:

```bash
dart format lib test packages apps
flutter analyze lib test packages apps
flutter test
(cd packages/capy_ui && flutter test)
(cd packages/telemetry_core && flutter test)
(cd apps/companion && flutter test)
```

Speed up locally with concurrency and parallel jobs:

```bash
flutter test --concurrency 6
(cd packages/capy_ui && flutter test --concurrency 6) & (cd packages/telemetry_core && flutter test) & (cd apps/companion && flutter test) & wait
```

In CI, run the four suites as parallel jobs — wall time is the slowest shard, not the sum.

Run Native Android unit tests whenever Kotlin telemetry code changes:

```bash
(cd android && ./gradlew testDebugUnitTest)
```

Update Pigeon bridge bindings:

```bash
dart run pigeon --input pigeons/telemetry_wire.dart
dart format lib test packages
```

Build release APK:

```bash
flutter build apk --release
```

Test real cloud sync end to end (gate ON for both apps):

```bash
scripts/build_cloud_sync_test.sh
```

Production default stays ON (standing owner decision: the cloud stays on).
The script refuses a build when local config pins the gate false.

## Safety and Hardware Rules

- **Instrumented Tests Data Loss Warning**: Running `connectedDebugAndroidTest` or reinstalling the app on the physical vehicle replaces the package and destroys existing recorded telemetry. Always pull a database snapshot first:
  ```bash
  python3 -m tool.telemetry_report pull dbpull/<name>.db
  ```
- **Install Script**: Install release APKs using `scripts/install.sh`. Never install to `/system/priv-app` and never use `pm uninstall`.
- **Local Builds Do Not Update Themselves**: `scripts/install.sh` stamps the version name with `-debug`, and `AppUpdateManager` refuses to update a build that carries that suffix. Keep both sides in step (`LOCAL_BUILD_SUFFIX`). Never install a working-tree APK by hand with plain `adb install`: the update watchdog runs every minute, compares only version codes, and replaces an unmarked local build with the published release. When the published release is older by schema, Room falls back to a destructive migration and the car's recorded telemetry is destroyed.
- **Write Verification**: Any control that writes to the vehicle (such as `setChargingAmperage`) must display the confirmed hardware read-back value, never optimistic local state.
- **Layer 0 Isolation**: Hardware properties and vendor constants belong strictly in `profile/` (`VehicleProfile`, `GeelyProfile`). Code above layer 0 must not reference raw VHAL hex constants.

## Release Notes

Update `release_notes/current.json` after completing features or fixes:
- Write notes in English, Portuguese, and Russian using ASD-STE100 format.
- Describe results for the end user, not internal code changes.
- Keep each locale list to 12 notes or fewer, with each note under 240 characters.

## Context Pointers

- **Lane C (control plane)**: The car's control read/write lives in `android/app/src/main/kotlin/com/timhss/capyenergy/telemetry/control/`. `PreferenceControlSync` reads `preference_desired` (surfaces via `PreferenceRepository.mergeIncomingProposal`) and reports decisions to `preference_reported` through the `PreferenceControlCloud` seam, always carrying the `x-car-token` header. It is additive beside the mDNS proposal channel until Phase 4. The phone's half is the companion's `apps/companion/lib/sync/preference_control_sync.dart` (`PreferenceControlController` + `SupabasePreferenceControlCloud` over `CloudSink`): it writes `preference_desired` as `authenticated` and surfaces the `preference_control_status` view's derived statuses, never optimistic state. Control-vs-annotation classification is a mirrored registry pinned by `testdata/preference_lanes.json`: Dart `kPreferenceLane` in `packages/telemetry_core/lib/sync_annotations.dart` (control keys via `kControlPreferenceKeys`) and Kotlin `PreferenceRepository.PREFERENCE_LANE`/`CONTROL_KEYS`; add a new key in all three places.
- **Architecture Decisions**: Read [`docs/adr/`](docs/adr/) before modifying core architectural patterns.
- **Design Tokens**: Read [`packages/capy_ui/DESIGN.md`](packages/capy_ui/DESIGN.md) for UI components and typography rules.

## Agent skills

### Issue tracker

GitHub issues via `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical roles (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout (`CONTEXT.md` and `docs/adr/` at repo root). See `docs/agents/domain.md`.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
