"""Snapshot access to the telemetry database.

The database lives on the car in the app's private directory. This module
copies it off the device and opens it read-only, so an analysis run can never
change what the car recorded.
"""

from __future__ import annotations

import os
import shutil
import sqlite3
import subprocess
from dataclasses import dataclass
from typing import Any

PACKAGE = "com.timhss.capy"
DEVICE_DB = f"/data/data/{PACKAGE}/databases/geely_telemetry.db"
STAGING = "/data/local/tmp/geely_telemetry_report.db"


class PullError(RuntimeError):
    pass


def pull(destination: str, serial: str | None = None) -> str:
    """Copy the database off the car, with its write-ahead log.

    The app writes continuously, so the `-wal` and `-shm` files hold data the
    main file does not. All three are copied, and the first read checkpoints
    them into the snapshot. A copy that leaves the log behind loses the most
    recent minutes, which are usually the ones you want.
    """
    adb = ["adb"] + (["-s", serial] if serial else [])
    staged = (
        f'cd {os.path.dirname(DEVICE_DB)} && '
        f'cp {os.path.basename(DEVICE_DB)} {STAGING} && '
        f'cp {os.path.basename(DEVICE_DB)}-wal {STAGING}-wal 2>/dev/null; '
        f'cp {os.path.basename(DEVICE_DB)}-shm {STAGING}-shm 2>/dev/null; '
        f'chmod 666 {STAGING}*'
    )
    run = subprocess.run(
        adb + ["shell", f'su 0 sh -c "{staged}"'],
        capture_output=True,
        text=True,
    )
    if run.returncode != 0:
        raise PullError(f"staging copy failed: {run.stderr.strip() or run.stdout.strip()}")

    os.makedirs(os.path.dirname(os.path.abspath(destination)) or ".", exist_ok=True)
    for suffix in ("", "-wal", "-shm"):
        target = destination + suffix
        got = subprocess.run(
            adb + ["pull", STAGING + suffix, target],
            capture_output=True,
            text=True,
        )
        if got.returncode != 0:
            if suffix == "":
                raise PullError(f"pull failed: {got.stderr.strip()}")
            # A missing log is normal when the app is not running.
            if os.path.exists(target):
                os.remove(target)

    # Fold the log in, so the snapshot is one self-contained file.
    with sqlite3.connect(destination) as conn:
        conn.execute("pragma journal_mode=delete")
    for suffix in ("-wal", "-shm"):
        if os.path.exists(destination + suffix):
            os.remove(destination + suffix)
    return destination


def open_snapshot(path: str) -> sqlite3.Connection:
    """Open a pulled snapshot read-only.

    A snapshot that still carries a log is copied first: opening it read-only
    would fail, and opening it writable would let an analysis run mutate the
    evidence.
    """
    if os.path.exists(path + "-wal"):
        merged = path + ".merged"
        shutil.copyfile(path, merged)
        shutil.copyfile(path + "-wal", merged + "-wal")
        with sqlite3.connect(merged) as conn:
            conn.execute("pragma journal_mode=delete")
        path = merged
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def rows(conn: sqlite3.Connection, sql: str, *params: Any) -> list[sqlite3.Row]:
    return conn.execute(sql, params).fetchall()


def columns(conn: sqlite3.Connection, table: str) -> set[str]:
    return {r["name"] for r in conn.execute(f"pragma table_info({table})")}


@dataclass(frozen=True)
class Session:
    """One trip or charge, with the fields every lens needs to locate it.

    `kind` is the discriminator lenses select on, so a lens declares the
    session kinds it understands instead of re-deriving it from the row.
    The car records four kinds (`TRIP`, `CHARGE`, `PARKED`, `CONTINUOUS`);
    this tool reports the two with session-level lenses.
    """

    kind: str  # "trip" | "charge"
    id: str
    status: str
    started_utc_millis: int
    ended_utc_millis: int | None
    row: dict[str, Any]

    @property
    def duration_seconds(self) -> float | None:
        if self.ended_utc_millis is None:
            return None
        return (self.ended_utc_millis - self.started_utc_millis) / 1000.0


# ---------------------------------------------------------------------------
# Locating the sessions.
#
# One `session` table with a `kind` column (`TRIP`, `CHARGE`, `PARKED`,
# `CONTINUOUS`), as `45.json` describes it. The per-kind `trip_sessions` and
# `charge_sessions` tables are long gone, and so is every migration that
# still carried them: this file reads the unified table only.
#
# Two session columns were renamed along the way (`startSocPercent`,
# `endSocPercent`); they are aliased back, because every lens reads
# `startSoc` and `endSoc`.


def _unified(row: sqlite3.Row) -> dict[str, Any]:
    d = dict(row)
    d.setdefault("startSoc", d.get("startSocPercent"))
    d.setdefault("endSoc", d.get("endSocPercent"))
    return d


def recent_trips(conn: sqlite3.Connection, limit: int) -> list[Session]:
    found = rows(
        conn,
        "select * from session where kind = 'TRIP' "
        "order by startedAtUtcMillis desc limit ?",
        limit,
    )
    return [
        Session(
            kind="trip",
            id=r["id"],
            status=r["status"],
            started_utc_millis=r["startedAtUtcMillis"],
            ended_utc_millis=r["endedAtUtcMillis"],
            row=_unified(r),
        )
        for r in found
    ]


def recent_charges(conn: sqlite3.Connection, limit: int) -> list[Session]:
    found = rows(
        conn,
        "select * from session where kind = 'CHARGE' "
        "order by startedAtUtcMillis desc limit ?",
        limit,
    )
    return [
        Session(
            kind="charge",
            id=r["id"],
            status=r["status"],
            started_utc_millis=r["startedAtUtcMillis"],
            ended_utc_millis=r["plugDisconnectedAtUtcMillis"]
            or r["chargeEndedAtUtcMillis"]
            or r["endedAtUtcMillis"],
            row=_unified(r),
        )
        for r in found
    ]


def intervals(conn: sqlite3.Connection, session_id: str) -> list[sqlite3.Row]:
    """One row per recorded minute, oldest first.

    `interval` is keyed `(sessionId, startUtcMillis)`. A row the car did not
    integrate is not a zero: callers skip `coveredSeconds <= 0`, the way the
    app's own bucket reduction does.
    """
    return rows(
        conn,
        "select * from interval where sessionId = ? order by startUtcMillis",
        session_id,
    )


def session_events(conn: sqlite3.Connection, session_id: str) -> list[sqlite3.Row]:
    """The narrative and signal changes attached to one session, oldest first."""
    return rows(
        conn,
        "select * from telemetry_events where sessionId = ? "
        "order by occurredAtUtcMillis, id",
        session_id,
    )


def segments(conn: sqlite3.Connection, session_id: str) -> list[sqlite3.Row]:
    """The derived per-segment rows for one trip, in order."""
    return rows(
        conn,
        "select * from trip_segments where sessionId = ? order by ordinal",
        session_id,
    )


def measured_minutes(found: list[sqlite3.Row]) -> list[sqlite3.Row]:
    """The minutes the car actually integrated, in time order.

    A row with neither `coveredSeconds` nor `deliveredCoveredSeconds`
    positive is a minute the car recorded nothing for. It is absence, not
    a measured zero: charge minutes integrate delivery while the drive
    side stays at zero, so both coverages gate. Every per-minute reduction
    skips the rest the way the app's own bucket code does.
    """
    return [r for r in found if _covered(r) > 0 or _delivered(r) > 0]


def _covered(row: sqlite3.Row) -> float:
    return row["coveredSeconds"] or 0


def _delivered(row: sqlite3.Row) -> float:
    # Snapshots predating the delivered-coverage column carry no such key;
    # `Row` raises `IndexError` on a missing one.
    try:
        return row["deliveredCoveredSeconds"] or 0
    except IndexError:
        return 0
