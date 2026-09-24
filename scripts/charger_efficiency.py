#!/usr/bin/env python3
"""Charger efficiency, and through it an absolute check on the pack scale.

During an AC charge the same energy is described twice by two independent
measurement chains: `OBC_uInAct`/`OBC_iInAct` (0x221) report what the charger
draws from the mains, and `BMSH_BattVolt`/`BMSH_BattCurr` (0x178, 0x250) report
what arrives at the pack. All four are calibrated. Their ratio is bounded by
physics from both sides, which is what makes it useful: an onboard charger
cannot exceed 100 %, and at light load it cannot reach the high nineties either.

So this doubles as the only absolute check the app has on the pack signals.
Drive-side comparisons cannot do it — regressing pack power on `VCU_DrvPwrAct`
gives a slope near 0.97 in both directions, which looks like a scale error and
is not one. Least squares assumes an exact regressor; the drive signal carries
sampling jitter, and that biases the slope toward zero in *both* directions. A
2026-08-05 capture brackets the true traction slope at [1.000, 1.014]. The
charge path has no such trap, because nothing is being differenced.

Two things the ratio is not:

  * It is not efficiency. The bus reports volts and amps, so the AC side is
    apparent power. True efficiency is the printed ratio divided by the power
    factor, i.e. *higher* than what is printed.
  * It is not only the charger. Anything fed from the AC side during the charge
    (DC-DC, cooling pump) counts here as loss, and anything fed from the pack
    subtracts from the DC side. Both push the printed number down, so it is a
    lower bound on charger efficiency.

Both caveats point the same way, which is why an implausibly *high* ratio is
the informative outcome: it cannot be explained away, and it means the pack
reads high relative to the mains.

    python3 -m tool.telemetry_report pull geely_telemetry.db
    python3 scripts/charger_efficiency.py geely_telemetry.db

Pull with the harness, not with `adb pull` on the `.db` alone. The database
runs in WAL mode, so the newest minutes — the ones a charge you just finished
lives in — are in the `-wal` file. A copy that leaves it behind does not fail:
it opens, it has every table, and it answers with old rows or with none. The
harness copies all three files and folds the log into the snapshot.
"""

import sqlite3
import statistics as st
import sys

REQUIRED = ("canAcInputVoltageV", "canAcInputCurrentA",
            "canPackVoltageV", "canPackCurrentA")

MIN_FRAMES = 300      # about five minutes at the 1 Hz frame rate
MAX_GAP_SECONDS = 10  # bridge a dropped frame, never a parked hour

# An onboard charger at a fraction of its rating runs in the high eighties. The
# upper bound is what matters: apparent power and shared loads both understate,
# so a ratio above this cannot be reached by any real charger and indicts the
# measurement instead.
PLAUSIBLE_MAX = 0.97


def sessions(con):
    """Charge sessions newest first, including one still in progress."""
    return [r[0] for r in con.execute(
        "SELECT id FROM charge_sessions WHERE chargeStartedAtUtcMillis IS NOT NULL "
        "ORDER BY chargeStartedAtUtcMillis DESC LIMIT 20")]


def integrate(con, session_id):
    """Trapezoidal DC and AC energy over intervals where both sides have samples.

    Restricting both integrals to the same intervals is the point. Integrating
    each over its own coverage once produced a 100.4 % ratio here, which was an
    artifact of the two sides spanning different windows.
    """
    rows = []
    for ns, pv, pa, av, aa in con.execute(
        """SELECT elapsedRealtimeNanos, canPackVoltageV, canPackCurrentA,
                  canAcInputVoltageV, canAcInputCurrentA
           FROM telemetry_frames WHERE sessionId = ?
           ORDER BY elapsedRealtimeNanos""",
        (session_id,),
    ):
        if None in (pv, pa, av, aa):
            continue
        # Pack current is positive on discharge, so charging is a negation.
        rows.append((ns / 1e9, -(pv * pa) / 1000.0, av * aa / 1000.0, pv, av, aa))

    if len(rows) < MIN_FRAMES:
        return None

    dc = ac = seconds = 0.0
    previous = None
    for row in rows:
        if previous is not None:
            dt = row[0] - previous[0]
            if 0 < dt <= MAX_GAP_SECONDS:
                dc += (previous[1] + row[1]) / 2 * dt / 3.6
                ac += (previous[2] + row[2]) / 2 * dt / 3.6
                seconds += dt
        previous = row

    if dc <= 0 or ac <= 0:
        return None
    return dict(dc=dc, ac=ac, seconds=seconds, rows=rows)


def main(path):
    con = sqlite3.connect(path)

    columns = {r[1] for r in con.execute("PRAGMA table_info(telemetry_frames)")}
    missing = set(REQUIRED) - columns
    if missing:
        version = con.execute("PRAGMA user_version").fetchone()[0]
        print(f"This database is at schema {version} and is missing "
              + ", ".join(sorted(missing)))
        print("The charger input was added in schema 19. Install a build carrying")
        print("it, charge once, then pull the database again.")
        return 1

    measured = []
    for session_id in sessions(con):
        result = integrate(con, session_id)
        if result is None:
            continue
        ratio = result['dc'] / result['ac']
        measured.append(ratio)
        print(f"{session_id[:8]}  {result['seconds']/60:5.1f} min   "
              f"DC {result['dc']/1000:6.3f} kWh   AC {result['ac']/1000:6.3f} kWh   "
              f"ratio {100*ratio:5.2f} %")
        rows = result['rows']
        print(f"          mains {st.median(r[4] for r in rows):5.1f} V "
              f"{st.median(r[5] for r in rows):4.2f} A     "
              f"pack {st.median(r[3] for r in rows):5.1f} V     "
              f"DC {st.median(r[1] for r in rows):5.3f} kW")

    if not measured:
        print("No charge session carries both sides yet. Charge once on schema 19")
        print(f"or newer for at least {MIN_FRAMES} frames, then pull again.")
        return 1

    worst = max(measured)
    print()
    if worst > PLAUSIBLE_MAX:
        print(f"A ratio of {100*worst:.2f} % is not reachable by an onboard charger.")
        print("Apparent power and shared loads both understate this number, so the")
        print("true efficiency is higher still. Something reads out of scale, and")
        print("the pack pair is the candidate: it is the only side used elsewhere.")
        return 1

    print(f"Highest ratio {100*worst:.2f} %, within what a charger can deliver once")
    print("power factor is taken into account. The pack scale is consistent with")
    print("the mains measurement; no correction is indicated.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "geely_telemetry.db"))
