"""The charge reading, from the pack side and the wall side.

Charge sessions keep using the minute integral, because unlike the drive
case that signal is reliable while charging. The pack side is the
`deliveredWh` the car folds per minute, the wall side is the same minute
read against the state-of-charge gain, and dividing the delivered energy by
it solves for pack capacity. That is the measurement the 39.6 kWh nameplate
is checked against.
"""

from __future__ import annotations

import sqlite3

from ..db import Session, intervals, measured_minutes
from ..lens import Report, register


@register("charging", "Charge energy", ("charge",))
def charging(conn: sqlite3.Connection, session: Session, report: Report) -> None:
    row = session.row
    minutes = measured_minutes(intervals(conn, session.id))
    if not minutes:
        report.problem("no measured minutes: nothing to recompute")
        return

    # --- wall side --------------------------------------------------------
    delivered_wh = sum(m["deliveredWh"] or 0 for m in minutes)
    rollup_wh = row.get("rollupDeliveredWh")
    report.add("delivered energy, re-summed minutes", delivered_wh, "Wh",
               note=f"{len(minutes)} measured minutes")
    report.add("delivered energy, stored rollup", rollup_wh, "Wh",
               expected=delivered_wh,
               tolerance=max(150.0, abs(delivered_wh or 0) * 0.05))
    covered = sum(m["coveredSeconds"] or 0 for m in minutes)
    delivered_covered = sum(m["deliveredCoveredSeconds"] or 0 for m in minutes)
    report.add("minute coverage", covered, "s")
    report.add("delivered coverage", delivered_covered, "s",
               expected=session.duration_seconds,
               tolerance=max(300.0, (session.duration_seconds or 0) * 0.3))

    # --- state of charge, and the capacity it implies ---------------------
    socs = [
        s for m in minutes
        for s in (m["startSoc"], m["endSoc"])
        if s is not None
    ]
    gain = (socs[-1] - socs[0]) if len(socs) >= 2 else None
    report.add("SOC gain (minutes)", gain, "%")
    if row.get("startSoc") is not None and row.get("endSoc") is not None:
        report.add("SOC gain (session)", row["endSoc"] - row["startSoc"],
                   "%", expected=gain, tolerance=0.5)
    if gain and gain > 2.0 and delivered_wh:
        implied = delivered_wh / 1000.0 / (gain / 100.0)
        report.add("implied pack capacity", implied, "kWh",
                   expected=39.6, tolerance=6.0)
    elif gain is not None and gain <= 2.0:
        report.add("implied pack capacity", None, "kWh",
                   note=f"a {gain:.1f} % gain is too small to divide by")

    report.add("ambient, start", row.get("startAmbientTempC"), "C")
    report.add("ambient, end", row.get("endAmbientTempC"), "C")


def _pct(value: float | None) -> str:
    return "--" if value is None else f"{value * 100:.0f} %"
