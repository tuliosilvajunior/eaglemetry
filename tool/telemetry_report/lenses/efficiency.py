"""The efficiency reading, recomputed beside what the car stored.

A trip has one energy: the minute integral the car folded at record time.
The state-of-charge model was removed on 2026-08-19, so what this lens compares is:

  * the car's stored rollup (`rollupTractionWh`, `rollupRegenWh`,
    `rollupAuxiliaryWh` on the `session` row), written at finalization;
  * the same integral re-summed here from the `interval` minute rows;
  * a state-of-charge estimate derived **in this harness only**, as a field
    cross-check on the sign and the scale of the integral. It is not stored,
    not published, and not a second answer.

Putting them beside each other, with the distance each is divided by, lets a
disagreement name its own cause instead of appearing as a wrong number on a
screen.
"""

from __future__ import annotations

import sqlite3

from ..db import Session, intervals, measured_minutes
from ..lens import Report, register
from ..maths import soc_energy_kwh


@register("efficiency", "Efficiency", ("trip",))
def efficiency(conn: sqlite3.Connection, session: Session, report: Report) -> None:
    row = session.row
    minutes = measured_minutes(intervals(conn, session.id))
    if not minutes:
        report.problem("no measured minutes: nothing to recompute")
        return

    # --- distance, from each source that can supply it -------------------
    minute_km = sum(m["distanceKm"] or 0 for m in minutes)
    session_odo = None
    if row.get("startOdometerKm") is not None and row.get("endOdometerKm") is not None:
        session_odo = row["endOdometerKm"] - row["startOdometerKm"]

    report.add("distance, minutes", minute_km, "km")
    report.add("distance, odometer (session)", session_odo, "km",
               expected=minute_km, tolerance=max(0.3, (minute_km or 0) * 0.1))
    report.add("distance, stored rollup", row.get("rollupDistanceKm"), "km",
               expected=minute_km, tolerance=max(0.3, (minute_km or 0) * 0.1))
    covered = sum(m["coveredSeconds"] or 0 for m in minutes)
    if session.duration_seconds and covered < session.duration_seconds * 0.9:
        report.problem(
            f"minutes cover only {covered:.0f} s of a "
            f"{session.duration_seconds:.0f} s trip across "
            f"{len(minutes)} minutes"
        )

    # The odometer-first rule: the trip figure uses the odometer, and falls
    # back to summed minutes only when the odometer is unusable.
    distance_km = (
        session_odo if session_odo and session_odo > 0 else minute_km
    )
    rollup_km = row.get("rollupDistanceKm")
    rollup_km = rollup_km if rollup_km and rollup_km > 0 else distance_km

    # --- energy: the stored rollup, re-summed from the minutes ------------
    minute_traction = sum(m["tractionWh"] or 0 for m in minutes)
    minute_regen = sum(m["regenWh"] or 0 for m in minutes)
    minute_aux = sum(m["auxiliaryWh"] or 0 for m in minutes)
    minute_pack_wh = minute_traction - minute_regen + minute_aux
    rollup_pack_wh = None
    if (row.get("rollupTractionWh") is not None
            and row.get("rollupRegenWh") is not None
            and row.get("rollupAuxiliaryWh") is not None):
        rollup_pack_wh = (
            row["rollupTractionWh"] - row["rollupRegenWh"] + row["rollupAuxiliaryWh"]
        )
    report.add("pack energy, re-summed minutes", minute_pack_wh, "Wh",
               note=f"{len(minutes)} measured minutes")
    report.add("pack energy, stored rollup", rollup_pack_wh, "Wh",
               expected=minute_pack_wh,
               tolerance=max(150.0, abs(minute_pack_wh or 0) * 0.05))
    report.add("traction, stored rollup", row.get("rollupTractionWh"), "Wh")
    report.add("regenerated, stored rollup", row.get("rollupRegenWh"), "Wh")
    report.add("auxiliary, stored rollup", row.get("rollupAuxiliaryWh"), "Wh")
    if row.get("rollupAuxiliaryWh") is not None and row["rollupAuxiliaryWh"] < 0:
        report.problem(
            "stored auxiliary energy is negative, which is physically impossible: "
            "read the pack current sign in the signal lens before anything else"
        )
    report.add("rollup integrated seconds", row.get("rollupIntegratedSeconds"), "s",
               expected=session.duration_seconds,
               tolerance=max(60.0, (session.duration_seconds or 0) * 0.2))
    report.add("SOC agrees with integral", row.get("socAgreesWithIntegral"))
    # --- the SOC cross-check ---------------------------------------------
    # Decision 5 (2026-08-19) removed the SOC energy model. The car no longer
    # stores these numbers, and this lens no longer reads them back. What is
    # computed here is a **field cross-check on the integral**, derived in the
    # harness alone: if the two are far apart, one of them is wrong and the
    # recorded drive is worth looking at by hand.
    soc_net = None
    start, end = row.get("startSoc"), row.get("endSoc")
    if start is not None and end is not None:
        consumed, regenerated = soc_energy_kwh([start, end], 39_600.0)
        soc_net = max(consumed - regenerated, 0.0)
        report.add("SOC consumed, cross-check only", consumed, "kWh")
        report.add("SOC regenerated, cross-check only", regenerated, "kWh")
        report.add("SOC net, cross-check only", soc_net, "kWh",
                   expected=(minute_pack_wh / 1000.0) if minute_pack_wh else None,
                   tolerance=max(0.3, abs(minute_pack_wh / 1000.0 or 0) * 0.25),
                   note="not stored, not published; the app's energy is the minute integral")
    else:
        report.add("SOC net, cross-check only", None, "kWh",
                   note="the session recorded no usable SOC bounds")
    # --- the readings the screens show -----------------------------------
    pack_kwh = (rollup_pack_wh if rollup_pack_wh is not None else minute_pack_wh) / 1000.0
    report.add("efficiency, minute integral", _wh_per_km(pack_kwh, distance_km), "Wh/km",
               note="the trip figure, and the only one the app shows")
    report.add("efficiency, SOC cross-check", _wh_per_km(soc_net, distance_km), "Wh/km",
               note="harness-only; the SOC energy model was removed on 2026-08-19")
    report.add("range, minute integral", _km_per_kwh(pack_kwh, distance_km), "km/kWh")
    report.add("range, SOC cross-check", _km_per_kwh(soc_net, distance_km), "km/kWh")

    if pack_kwh and soc_net and soc_net > 0:
        ratio = pack_kwh / soc_net
        report.add("pack / SOC ratio", ratio, note="1.00 means the two agree",
                   expected=1.0, tolerance=0.15)
        if abs(ratio - 1.0) > 0.25:
            report.problem(
                f"the minute integral and the SOC cross-check disagree by "
                f"{abs(ratio - 1.0) * 100:.0f} %: check the pack current sign, the "
                "recorded SOC bounds, and the minute coverage above"
            )



def _wh_per_km(kwh: float | None, km: float | None) -> float | None:
    if not kwh or not km or km <= 0:
        return None
    return kwh * 1000.0 / km


def _km_per_kwh(kwh: float | None, km: float | None) -> float | None:
    if not kwh or not km or kwh <= 0:
        return None
    return km / kwh
