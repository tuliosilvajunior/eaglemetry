# 4. Typed Cross-Platform Bridge via Pigeon

## Context and Decision

Untyped `MethodChannel` communications led to schema divergence, silent type casting bugs, and difficult-to-maintain bridge interfaces. We decided to migrate all Flutter Dart to Kotlin Native communication to strongly typed Pigeon schemas defined in `pigeons/telemetry_wire.dart`.

## Consequences

- All new native bridge methods must be declared in Pigeon schemas rather than added as raw `MethodChannel` handlers.
- Generated wire classes handle serialization across the platform boundary.
- Parity tests ensure zero orphaned or duplicate routes exist across the bridge.
