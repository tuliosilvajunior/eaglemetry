"""The minute grid, read the way the efficiency card reads it.

This lens is a port of `readEfficiency` in `lib/core/efficiency_window.dart`,
including its state classification and its floors. That duplication is the
point: it lets you see what the card would draw from stored data without a
car, and a divergence between the two is itself a finding.

The card runs on 10 s live buckets that are never persisted. What is stored
is the minute grid (`interval`, one row per recorded minute), which is what
the energy monitor footer reduces. Read the per-minute table below as the
footer's input, and as the closest stored proxy for what the card showed.

One stored row carries one distance (`distanceKm`), which serves both the
odometer and the speed reading exactly as the car's own
`EnergyBucket.fromInterval` mapping does. The stored grid does not keep the
two apart.
"""

from __future__ import annotations

import sqlite3
from datetime import datetime, timezone

from ..db import Session, intervals, measured_minutes
from ..lens import Report, register

# The floors are the app's, not this tool's. See `efficiency_window.dart`.
DISTANCE_FLOOR_KM = 0.001
ENERGY_FLOOR_WH = 0.5


def classify(distance_km: float, net_wh: float, integrated_seconds: float) -> str:
    if integrated_seconds <= 0:
        return "gap"
    moved = distance_km >= DISTANCE_FLOOR_KM
    drew = net_wh >= ENERGY_FLOOR_WH
    gave_back = net_wh <= -ENERGY_FLOOR_WH
    if gave_back:
        return "regenerating"
    if moved and drew:
        return "consuming"
    if moved:
        return "coasting"
    if drew:
        return "idle"
    return "gap"


@register("buckets", "Energy buckets", ("trip",))
def buckets(conn: sqlite3.Connection, session: Session, report: Report) -> None:
    found = measured_minutes(intervals(conn, session.id))
    if not found:
        report.problem("no measured minutes: the efficiency card would show nothing")
        return

    report.add("buckets", len(found))
    total_distance = 0.0
    total_net = 0.0
    states: dict[str, int] = {}

    for minute in found:
        drawn = (minute["tractionWh"] or 0) + (minute["auxiliaryWh"] or 0)
        net = drawn - (minute["regenWh"] or 0)
        distance = minute["distanceKm"] or 0
        state = classify(distance, net, minute["coveredSeconds"] or 0)
        states[state] = states.get(state, 0) + 1
        if state != "gap":
            total_distance += distance
            total_net += net

        report.table.append({
            "start": datetime.fromtimestamp(
                minute["startUtcMillis"] / 1000, timezone.utc
            ).astimezone().strftime("%H:%M"),
            "state": state,
            "traction Wh": round(minute["tractionWh"] or 0, 1),
            "regen Wh": round(minute["regenWh"] or 0, 1),
            "aux Wh": round(minute["auxiliaryWh"] or 0, 1),
            "net Wh": round(net, 1),
            "km": round(distance, 3),
            "cov s": round(minute["coveredSeconds"] or 0, 0),
            "SOC": (
                f"{minute['startSoc']:.1f}->{minute['endSoc']:.1f}"
                if minute["startSoc"] is not None and minute["endSoc"] is not None
                else None
            ),
            "km/kWh": (
                round(distance / (net / 1000.0), 2)
                if state == "consuming" else (0.0 if state == "idle" else None)
            ),
        })

    report.add("bucket distance total", total_distance, "km")
    report.add("bucket net energy total", total_net, "Wh")
    report.add(
        "window average",
        total_distance / (total_net / 1000.0)
        if total_distance >= DISTANCE_FLOOR_KM and total_net >= ENERGY_FLOOR_WH
        else None,
        "km/kWh",
        note="total distance over total net energy, not the mean of the ratios",
    )
    report.add("states", ", ".join(f"{k} {v}" for k, v in sorted(states.items())))

    # The card cannot draw a ratio without a distance term. A window whose
    # minutes carry energy but no distance reads as `idle` at zero km/kWh,
    # which looks like a measurement and is not one.
    if states.get("idle", 0) > states.get("consuming", 0):
        report.problem(
            f"{states['idle']} idle minutes against "
            f"{states.get('consuming', 0)} consuming: the distance term is "
            "missing more often than it is present"
        )

    aux = sum(m["auxiliaryWh"] or 0 for m in found)
    if aux < 0:
        report.problem(
            f"auxiliary energy sums to {aux:.0f} Wh, below zero: the pack "
            "current sign is inverted for this session"
        )

