"""Retired: the Signal Lab stage 1 per-frame columns are gone.

Stage 1 added eleven per-frame columns to `telemetry_frames`. Migration 32->33 dropped that table, and schema 44
carries no per-frame signal store at all: `interval` holds per-minute
energy, `telemetry_events` holds the change log, neither holds CAN raw
counts or incline samples. There is nothing left for this lens to read.

The module stays so old snapshots and old test imports fail loudly rather
than silently. It registers no lens.
"""

from __future__ import annotations
