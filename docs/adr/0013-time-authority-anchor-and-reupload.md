# 13. Time Authority: Two-Source Anchor and Insert-Before-Delete

## Context and Decision

The car boots on the MCU firmware time and syncs seconds later, so every wall
stamp before the sync is suspect. Two rules from the time-authority build
(issues 287–298) are durable beyond that build.

**Rule 1: an anchor needs two independent sources or history, never one
source alone.** `ClockAnchorStore` learns the boot's wall-to-monotonic pair
only when server `Date` and GPS fix agree within tolerance, or when one of
them agrees with the session-median reference offset. One source alone keeps
the boot pending. A single server clock running wrong can therefore never
anchor the car by itself.

**Rule 2: the corrected row lands before the wrong row dies.** The backfill
sweeper writes resolved minutes and queues the exact replaced keys; the
uploader deletes a queued key only after its corrected insert succeeds, and a
refused delete keeps its key for the next pass. A network failure mid-pass
leaves a recoverable duplicate, never an absence.

## Consequences

- New truth sources (NITZ, a second server) join the corroboration rule; no
  source may anchor a boot alone.
- Cloud fix ordering stays insert-then-delete; delete-before-insert is a data
  loss bug, not an optimization.
- `ClockAnchorStore` stays a synchronized singleton: the uploader thread
  offers server dates while the collector thread offers GPS fixes.
