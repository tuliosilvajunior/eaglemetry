"""Retired: per-frame signal movement died with `telemetry_frames`.

These lenses measured how much each 1 Hz frame column moved and what a
deadband would keep. Migration 32->33 dropped that table, and schema 44
carries no per-frame signal store at all: the minute grid (`interval`)
holds integrated energy, not signal samples, and `telemetry_events`
holds change-only rows, not a series a deadband can be simulated
against. There is nothing left for these lenses to walk.

The module stays so old imports fail loudly rather than silently. It
registers no lens. The `_simulate`/`_fold` helpers and their constants
remain for the unit tests, which pin the deadband math itself.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field


# The ladder each state signal was simulated against.
CANDIDATES: dict[str, tuple[float, ...]] = {
    "speedKmh": (0.5, 1.0, 2.0, 5.0),
    "socPercent": (0.1, 0.25, 0.5, 1.0),
    "odometerKm": (0.1, 0.2, 0.5, 1.0),
    "canPackVoltageV": (0.5, 1.0, 2.0, 5.0),
    "canRoadInclinePercent": (0.25, 0.5, 1.0, 2.0),
    "canAccelPedalPercent": (1.0, 2.0, 5.0, 10.0),
    "canCabinSetpointC": (0.5, 1.0),
    "ambientTempC": (0.5, 1.0, 2.0),
    "altitudeM": (0.5, 1.0, 2.0, 5.0),
    "gpsAccuracyM": (1.0, 2.0, 5.0),
    "gps": (5.0, 10.0, 25.0, 50.0),
}

# A flat signal still has to say so. Five minutes is the starting value.
MAX_GAP_SECONDS = 300.0


@dataclass
class Movement:
    """What one state signal did across the sessions it was recorded in."""

    name: str
    samples: int = 0
    changes: int = 0
    travel: float = 0.0
    steps: list[float] = field(default_factory=list)
    kept: dict[float, int] = field(default_factory=dict)
    gap_writes: dict[float, int] = field(default_factory=dict)


def _metres(a: tuple[float, float], b: tuple[float, float]) -> float:
    """Distance on the ground. Equirectangular is accurate enough at this
    scale, and exact enough that the tests pin it rather than trust it."""
    lat = math.radians((a[0] + b[0]) / 2.0)
    dx = math.radians(b[1] - a[1]) * math.cos(lat)
    dy = math.radians(b[0] - a[0])
    return math.hypot(dx, dy) * 6371000.0


def _scalar_distance(a: float, b: float) -> float:
    return abs(b - a)


def _simulate(
    series: list[tuple[float, int]],
    band: float,
    distance,
) -> tuple[int, int]:
    """Rows a deadband would keep, and how many of them the max gap forced.

    `series` is (value, millis) in time order. `distance` measures how far a
    value is from the last written one, so a scalar and a coordinate share one
    simulation.
    """
    written = None
    written_millis = 0
    kept = 0
    forced = 0
    for value, millis in series:
        if written is None:
            written, written_millis = value, millis
            kept += 1
            continue
        moved = distance(written, value) >= band
        gap = (millis - written_millis) / 1000
        stale = gap >= MAX_GAP_SECONDS
        if moved or stale:
            kept += 1
            if stale and not moved:
                forced += 1
            written, written_millis = value, millis
    return kept, forced


def _fold(state: Movement, series: list[tuple[float, int]], distance) -> None:
    state.samples += len(series)
    for (previous, _), (value, _) in zip(series, series[1:]):
        step = distance(previous, value)
        state.travel += step
        if step > 0:
            state.changes += 1
            state.steps.append(step)
    for band in CANDIDATES.get(state.name, ()):
        kept, forced = _simulate(series, band, distance)
        state.kept[band] = state.kept.get(band, 0) + kept
        state.gap_writes[band] = state.gap_writes.get(band, 0) + forced
