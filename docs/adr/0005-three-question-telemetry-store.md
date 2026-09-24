# 5. Three-Question TelemetryStore Query Model

## Context and Decision

Direct database queries scattered across UI controllers created tight coupling and inconsistent behavior between the car app (Room/Android) and companion app (SQLite/iOS/Android). We decided that all historical telemetry reads must go through `TelemetryStore`, which answers exactly three canonical questions:
1. `listSessions(filter, page)`
2. `session(id)`
3. `series(id, keys, width)`

## Consequences

- UI widgets and screens never construct ad-hoc SQL queries or ask a fourth historical question.
- Historical aggregates and statistics are computed by folding and reducing the answers returned by these three queries in Dart.
