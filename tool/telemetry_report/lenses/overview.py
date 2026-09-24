"""What the session is, before any component is judged."""

from __future__ import annotations

import sqlite3
from datetime import datetime, timezone

from ..db import Session, intervals, measured_minutes, rows, session_events
from ..lens import Report, register


def _local(millis: int | None) -> str | None:
    if not millis:
        return None
    return datetime.fromtimestamp(millis / 1000, timezone.utc).astimezone().strftime(
        "%Y-%m-%d %H:%M:%S"
    )


@register("overview", "Session", ("trip", "charge"))
def overview(conn: sqlite3.Connection, session: Session, report: Report) -> None:
    row = session.row
    report.add("id", session.id)
    report.add("status", session.status)
    report.add("started", _local(session.started_utc_millis))
    report.add("ended", _local(session.ended_utc_millis))
    report.add("duration", session.duration_seconds, "s")

    start_soc, end_soc = row.get("startSoc"), row.get("endSoc")
    report.add("start SOC", start_soc, "%")
    report.add("end SOC", end_soc, "%")
    if start_soc is not None and end_soc is not None:
        report.add("SOC delta", end_soc - start_soc, "%")

    start_odo, end_odo = row.get("startOdometerKm"), row.get("endOdometerKm")
    if start_odo is not None and end_odo is not None:
        report.add("odometer distance", end_odo - start_odo, "km")
    else:
        report.add("odometer distance", None, "km", note="one bound missing")

    if session.kind == "trip":
        report.add("rollup distance", row.get("rollupDistanceKm"), "km")
        report.add("rollup traction", row.get("rollupTractionWh"), "Wh")
        report.add("rollup regen", row.get("rollupRegenWh"), "Wh")
        report.add("rollup auxiliary", row.get("rollupAuxiliaryWh"), "Wh")
        report.add("rollup delivered", row.get("rollupDeliveredWh"), "Wh")
        report.add("rollup integrated", row.get("rollupIntegratedSeconds"), "s")
        report.add("SOC agrees with integral", row.get("socAgreesWithIntegral"))
        report.add("end reason", row.get("endReason"))
    else:
        report.add("rollup delivered", row.get("rollupDeliveredWh"), "Wh")
        report.add("rollup integrated", row.get("rollupIntegratedSeconds"), "s")
        report.add("SOC agrees with integral", row.get("socAgreesWithIntegral"))
        report.add("plug type", row.get("plugType"))
        report.add("charge end reason", row.get("chargeEndReason"))
        report.add("ambient at start", row.get("startAmbientTempC"), "C")

    minutes = measured_minutes(intervals(conn, session.id))
    report.add("minutes", len(minutes))
    if minutes and session.duration_seconds:
        report.add(
            "minute coverage",
            sum(m["coveredSeconds"] or 0 for m in minutes) / session.duration_seconds,
            note="integrated seconds over session duration; gaps are unrecorded time",
        )

    events = session_events(conn, session.id)
    report.add("events", len(events))

    if row.get("rollupTractionWh") is None and session.kind == "trip":
        report.problem("no rollup energy: the session was never finalized")
    if row.get("rollupDeliveredWh") is None and session.kind == "charge":
        report.problem("no rollup energy: the session was never finalized")

    _timestamp_health(conn, session, report)


def _timestamp_health(conn: sqlite3.Connection, session: Session, report: Report) -> None:
    """Whether the session's minute keys still describe the session's own span.

    A session whose minute keys fall far outside its start/end bounds caught
    a device clock jump. Every absolute-time query over those minutes then
    mis-sorts them, so this is checked before any lens is believed rather
    than after a number looks wrong.
    """
    span = rows(
        conn,
        "select min(startUtcMillis) a, max(startUtcMillis) b, "
        "count(*) n from interval where sessionId = ?",
        session.id,
    )[0]
    if not span["n"]:
        return

    duration = session.duration_seconds
    report.add("first minute", _local(span["a"]))
    report.add("last minute", _local(span["b"]))
    if duration and session.started_utc_millis and session.ended_utc_millis:
        early = (session.started_utc_millis - span["a"]) / 3_600_000.0
        late = (span["b"] - session.ended_utc_millis) / 3_600_000.0
        if early > 1.0:
            report.problem(
                f"the first minute starts {early:.1f} h before the session: "
                "a clock jump mis-keyed it"
            )
        if late > 1.0:
            report.problem(
                f"the last minute starts {late:.1f} h after the session ends: "
                "a clock jump mis-keyed it"
            )
