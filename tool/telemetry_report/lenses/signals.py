"""Which signals actually arrived.

Almost every wrong number in this app has turned out to be a signal that was
absent, stale or inverted rather than maths that was wrong. This lens runs
first for that reason: read it before believing anything a later lens says.

What survives on disk is not per-second frames but the change log: one
`telemetry_events` row per signal change, plus the session lifecycle
(`TRIP_*`, `CHARGE_*`). Only session-narrative signals attach to a session
(`GEAR`, doors, charge state); high-rate signals (SOC, odometer, power)
are logged without one by design and read here from the session's own
time window instead.
"""

from __future__ import annotations

import sqlite3

from ..db import Session, rows, session_events
from ..lens import Report, register

# Session-narrative signals: the ones the car attaches to a session row.
# Attachment is sparse (doors speak on 4 of 164 trips), so only the
# kind-defining signal is demanded: GEAR on a trip, the charge pair on a
# charge. Anything else is read from the session window below, not demanded
# here.
NARRATIVE: dict[str, tuple[str, ...]] = {
    "STATE": ("GEAR", "PEPS_POWER_MODE", "HEADLIGHTS_SWITCH",
              "ADAS_ACC_CRUISE_MODE", "DOOR_MOVE"),
    "CHARGE": ("EV_CHARGE_STATE", "EV_CHARGE_PLUG_TYPE",
               "EV_CHARGE_ESTIMATED_TIME"),
}
REQUIRED: dict[str, tuple[str, ...]] = {
    "trip": ("GEAR",),
    "charge": ("EV_CHARGE_STATE", "EV_CHARGE_PLUG_TYPE"),
}

# High-rate signals, logged session-less. Presence is checked over the
# session's own time window so a trip still answers whether its SOC moved.
WINDOWED: tuple[str, ...] = (
    "HV_BATTERY_SOC", "ODOMETER", "AMBIENT_AIR_TEMPERATURE",
)


@register("signals", "Signal coverage", ("trip", "charge"))
def signals(conn: sqlite3.Connection, session: Session, report: Report) -> None:
    events = session_events(conn, session.id)
    if not events:
        report.problem("the session has no events")
        return

    report.add("events", len(events))
    by_signal: dict[str, list] = {}
    for event in events:
        by_signal.setdefault(event["signalId"] or "(lifecycle)", []).append(event)

    for group, names in NARRATIVE.items():
        for name in names:
            seen = by_signal.get(name, [])
            measured = sum(1 for e in seen if (e["quality"] or "MEASURED") == "MEASURED")
            values = sorted({e["value"] for e in seen if e["value"] is not None})
            report.table.append({
                "source": group,
                "signal": name,
                "events": len(seen),
                "measured": measured,
                "values": ",".join(values[:4]),
            })
            if not seen and name in REQUIRED.get(session.kind, ()):
                report.problem(f"{name} never arrived")

    lifecycles = [e["type"] for e in events if not e["signalId"]]
    if lifecycles:
        report.add("lifecycle", ", ".join(lifecycles))
    qualities: dict[str, int] = {}
    for event in events:
        qualities[event["quality"] or "?"] = qualities.get(event["quality"] or "?", 0) + 1
    report.add("qualities", ", ".join(f"{k} {v}" for k, v in sorted(qualities.items())))

    _windowed(conn, session, report)


def _windowed(conn: sqlite3.Connection, session: Session, report: Report) -> None:
    """High-rate signals over the session's own window, session-less by design."""
    if not session.started_utc_millis:
        return
    end = session.ended_utc_millis or session.started_utc_millis
    for name in WINDOWED:
        found = rows(
            conn,
            "select count(*) n, min(value) lo, max(value) hi from telemetry_events "
            "where signalId = ? and sessionId is null "
            "and occurredAtUtcMillis between ? and ? and quality = 'MEASURED'",
            name, session.started_utc_millis, end,
        )[0]
        report.table.append({
            "source": "WINDOW",
            "signal": name,
            "events": found["n"],
            "measured": found["n"],
            "values": f"{found['lo']}..{found['hi']}" if found["n"] else "silent in window",
        })

