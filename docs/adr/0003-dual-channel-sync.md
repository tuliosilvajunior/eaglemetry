# 3. Dual-Channel Synchronization Topology

**Status: superseded by ADR-0012.**

Two of its parts were replaced. The channel count: the proposal path the car
and phone already use is a third lane, desired-and-reported, not an annotation.
And the measurement channel's mechanism: cursor-based replication with
acknowledgements existed only because the two devices met on the local network
with nothing between them. What stands is the shape of the split — a lane whose
writer is the vehicle behaves differently from a lane both sides edit — and the
LWW rule with tombstones and origin precedence, which ADR-0012 keeps and moves
into the database.

## Context and Decision

Telemetry consists of immutable recorded measurements (sessions, intervals, samples) and mutable user metadata (places, preferences, cost receipts). We decided to split synchronization into two separate channels:
1. **Measurement channel**: One-way stream from car to companion/cloud using cursor-based replication and acknowledgements.
2. **Annotation channel**: Two-way stream resolving conflicts via Last-Writer-Wins (LWW), explicit deletion tombstones, and hierarchical origin precedence (car > phone > cloud).

## Consequences

- Measurements are immutable once written on the vehicle.
- User metadata (e.g. named places, charge pricing) can be updated from phone or car without mutating underlying telemetry tables.
