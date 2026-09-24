"""Every lens the report can run.

Importing a module registers it. To add a component, drop a module here and
add it to this list — nothing else in the tool needs to change.
"""

from . import (  # noqa: F401
    buckets,
    charging,
    drivetrain,
    efficiency,
    insights,
    movement,
    overview,
    signals,
    track,
)

__all__ = [
    "buckets",
    "charging",
    "drivetrain",
    "efficiency",
    "insights",
    "movement",
    "overview",
    "signals",
]
