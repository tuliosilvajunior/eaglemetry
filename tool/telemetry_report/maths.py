"""Integration and correlation, with the same guards the app applies.

These are deliberately the app's rules, not generic ones. A harness that
integrates differently from the code under test measures the harness.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

# Frames arrive about once a second. A longer step is a gap in recording, not
# a slow sample, and carrying a value across it invents energy that was never
# reported. The app uses the same bound.
MAX_STEP_SECONDS = 36.0

# Per-step state-of-charge deltas below this are noise, not movement.
SOC_NOISE_FLOOR = 0.05


@dataclass
class Integral:
    """A trapezoid sum, with the coverage needed to judge it.

    `covered_seconds` against `span_seconds` is the first thing to read: an
    integral over half the trip is not a smaller answer to the same question,
    it is an answer to a different one.
    """

    value: float = 0.0
    positive: float = 0.0
    negative: float = 0.0
    covered_seconds: float = 0.0
    span_seconds: float = 0.0
    samples: int = 0
    gaps: int = 0

    @property
    def coverage(self) -> float | None:
        if self.span_seconds <= 0:
            return None
        return self.covered_seconds / self.span_seconds


def integrate(points: list[tuple[float, float]]) -> Integral:
    """Trapezoid-integrate `(seconds, value)` pairs into value-seconds.

    Steps longer than [MAX_STEP_SECONDS] are skipped and counted, so a caller
    can tell a well-covered integral from one stitched over a recording gap.
    Positive and negative area are kept apart, because traction and
    regeneration are two readings, not one net number.
    """
    result = Integral(samples=len(points))
    if len(points) < 2:
        return result
    result.span_seconds = points[-1][0] - points[0][0]
    for (t0, v0), (t1, v1) in zip(points, points[1:]):
        dt = t1 - t0
        if dt <= 0:
            continue
        if dt > MAX_STEP_SECONDS:
            result.gaps += 1
            continue
        area = (v0 + v1) / 2.0 * dt
        result.value += area
        if area >= 0:
            result.positive += area
        else:
            result.negative += -area
        result.covered_seconds += dt
    return result


def correlation(xs: list[float], ys: list[float]) -> float | None:
    """Pearson r, used to read the sign regime of the pack current.

    Pack power against drive power separates at r near +-0.97, which is how
    both inverted windows of stored frames were found. See `FrameSamples.kt`.
    """
    n = len(xs)
    if n < 3 or n != len(ys):
        return None
    mx = sum(xs) / n
    my = sum(ys) / n
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    sxx = sum((x - mx) ** 2 for x in xs)
    syy = sum((y - my) ** 2 for y in ys)
    if sxx <= 0 or syy <= 0:
        return None
    return sxy / math.sqrt(sxx * syy)


def slope(xs: list[float], ys: list[float]) -> float | None:
    """Least-squares slope of y on x, through a free intercept.

    Read it with the bias in mind: least squares assumes x is exact, and a
    jittering regressor pulls the slope toward zero in both directions. Fit
    the reverse direction and invert to bracket the true value.
    """
    n = len(xs)
    if n < 3 or n != len(ys):
        return None
    mx = sum(xs) / n
    my = sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx <= 0:
        return None
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx


def soc_energy_kwh(socs: list[float], capacity_wh: float) -> tuple[float, float]:
    """Consumed and regenerated kWh from a state-of-charge series.

    This is the app's approved trip-energy model: per-step deltas below the
    noise floor are dropped, the rest are split by direction and scaled by
    pack capacity. It integrates no power at all, which is what makes it an
    independent check on the readings that do.
    """
    consumed = 0.0
    regenerated = 0.0
    for a, b in zip(socs, socs[1:]):
        delta = b - a
        if abs(delta) < SOC_NOISE_FLOOR:
            continue
        if delta < 0:
            consumed += -delta
        else:
            regenerated += delta
    scale = capacity_wh / 100.0 / 1000.0
    return consumed * scale, regenerated * scale
