"""The Track route, one row per Session.

Before a single Track is written on a vehicle, the report harness has to be
able to print one. The two faults ADR-0010 records were both found by reading
stored rows off the car, and a format nobody can inspect is the wrong thing to
ship into that history.

This lens reads a Track out of a pulled snapshot and prints it as points a
human can check against a map. It decodes with the same constants as Dart and
Kotlin, reports the point count, the time span and the total distance, and
says plainly when it meets an encoding version it does not know rather than
printing wrong numbers.
"""

from __future__ import annotations

import json
import sqlite3

from ..db import Session
from ..lens import Report, register
from ..track_codec import (
    TRACK_ENCODING_VERSION,
    TrackDecodeException,
    TrackRow,
    _haversine_m,
    decode,
)

# ---------------------------------------------------------------------------
# The schema this lens reads.
#
# One name, not a list of guesses. An earlier draft tried four table names and
# several column names each, and fell back to any table whose name held
# "track". That never fails: a rename lands on the next candidate and the lens
# keeps printing, against the wrong thing. Naming one shape means a rename
# breaks here, loudly, which is the only way the tool stays honest about a
# database it does not own.
#
# The names match what the car writes in issue 178, and follow the Room
# entities already in the database: a singular table like `sample` and
# `interval`, camelCase columns like `sessionId`.

TRACK_TABLE = "track"
TRACK_COLUMNS = {
    "session": "sessionId",
    "version": "encodingVersion",
    "count": "pointCount",
    "t": "t",
    "path": "path",
    "speed": "speed",
    "alt": "alt",
}


def _table_exists(conn: sqlite3.Connection, table: str) -> bool:
    row = conn.execute(
        "select 1 from sqlite_master where type='table' and name=?", (table,)
    ).fetchone()
    return row is not None


def _missing_columns(conn: sqlite3.Connection, table: str) -> list[str]:
    try:
        present = {r[1] for r in conn.execute(f"pragma table_info({table})")}
    except sqlite3.OperationalError:
        return sorted(TRACK_COLUMNS.values())
    return sorted(c for c in TRACK_COLUMNS.values() if c not in present)


def _parse_int_list(value) -> list[int]:
    """Reads one of the integer arrays.

    The column holds a JSON array. Anything else is a shape this lens does not
    know, and raises rather than decoding to an empty list, which would look
    like a Track with no points.
    """
    if value is None:
        raise ValueError("array column is NULL")
    if isinstance(value, (bytes, bytearray)):
        value = value.decode("utf-8")
    if isinstance(value, str):
        parsed = json.loads(value)
    else:
        parsed = value
    if not isinstance(parsed, list):
        raise ValueError(f"array column is {type(parsed).__name__}, not a list")
    return [int(v) for v in parsed]


def _load_track_row(
    conn: sqlite3.Connection, session_id: str
) -> tuple[TrackRow | None, str | None]:
    """Returns (row, problem). Exactly one of the two is set."""
    cols = TRACK_COLUMNS
    select = ", ".join(
        cols[k] for k in ("version", "count", "t", "path", "speed", "alt")
    )
    try:
        row = conn.execute(
            f"select {select} from {TRACK_TABLE} where {cols['session']} = ?",
            (session_id,),
        ).fetchone()
    except sqlite3.OperationalError as e:
        return None, f"track query failed: {e}"
    if row is None:
        return None, None

    version, count, t_raw, path_raw, speed_raw, alt_raw = row

    # A version this lens cannot read is the one case where guessing does the
    # most damage: the numbers still print, and they are wrong. Dart and Kotlin
    # both refuse rather than guess, and so does this.
    if version is None:
        return None, (
            f"the {TRACK_TABLE} row for session {session_id} carries no "
            f"{cols['version']}. A Track without a version cannot be decoded, "
            f"because nothing says which encoder wrote it."
        )
    try:
        version = int(version)
    except (TypeError, ValueError):
        return None, (
            f"the {TRACK_TABLE} row for session {session_id} carries "
            f"{cols['version']}={version!r}, which is not a version number."
        )

    if version != TRACK_ENCODING_VERSION:
        return None, (
            f"unknown encoding version {version}, expected "
            f"{TRACK_ENCODING_VERSION}: this row was written by an encoder "
            f"this tool does not know, and decoding it with the current one "
            f"would print wrong numbers. Update the report tool."
        )

    try:
        point_count = int(count)
    except (TypeError, ValueError):
        return None, (
            f"the {TRACK_TABLE} row for session {session_id} carries "
            f"{cols['count']}={count!r}, which is not a point count."
        )

    if isinstance(path_raw, (bytes, bytearray)):
        path_raw = path_raw.decode("utf-8")
    if not isinstance(path_raw, str):
        return None, (
            f"the {TRACK_TABLE} row for session {session_id} carries a "
            f"{cols['path']} of type {type(path_raw).__name__}, not text."
        )

    try:
        return (
            TrackRow(
                encoding_version=version,
                point_count=point_count,
                t=_parse_int_list(t_raw),
                path=path_raw,
                speed=_parse_int_list(speed_raw),
                alt=_parse_int_list(alt_raw),
            ),
            None,
        )
    except (ValueError, json.JSONDecodeError) as e:
        return None, f"the {TRACK_TABLE} row for session {session_id} is malformed: {e}"


@register("track", "Track route", ("trip",))
def track(conn: sqlite3.Connection, session: Session, report: Report) -> None:
    if not _table_exists(conn, TRACK_TABLE):
        report.add("track rows", 0)
        report.problem(
            f"this snapshot holds no {TRACK_TABLE} table, so it predates the "
            f"Track format. Pull a newer snapshot after the vehicle has "
            f"written a Track (issue 178)."
        )
        return

    missing = _missing_columns(conn, TRACK_TABLE)
    if missing:
        report.add("track rows", 0)
        report.problem(
            f"the {TRACK_TABLE} table is missing {', '.join(missing)}. The "
            f"lens reads one shape and does not guess at another."
        )
        return

    track_row, problem = _load_track_row(conn, session.id)
    if problem is not None:
        report.problem(problem)
        return
    if track_row is None:
        report.add("track rows", 0)
        report.add("point count", 0)
        # An open Session has no finalized Track yet; that is not a defect.
        if session.status and session.status.upper() in ("OPEN", "ACTIVE", "RUNNING"):
            report.add("note", "open session — the Track is written when the Session closes")
        else:
            report.problem(f"no {TRACK_TABLE} row for session {session.id}")
        return

    report.add("encoding version", track_row.encoding_version)
    report.add("point count", track_row.point_count)

    try:
        points = decode(track_row)
    except TrackDecodeException as e:
        report.problem(f"Track decode failed: {e}")
        return

    if not points:
        report.add("span", 0.0, "s")
        report.add("distance", 0.0, "km")
        return

    report.add("span", points[-1].t_seconds - points[0].t_seconds, "s")
    total_m = 0.0
    for a, b in zip(points, points[1:]):
        total_m += _haversine_m(a.latitude, a.longitude, b.latitude, b.longitude)
    report.add("distance", total_m / 1000.0, "km")

    # A long drive is thousands of points and no one reads them all in a
    # terminal. Head and tail are what a person checks against a map; the
    # whole array is one --json away.
    max_table = 300
    display = points
    if len(points) > max_table:
        head = max_table // 2
        tail = max_table - head - 1
        display = points[:head] + points[-tail:]
        report.add(
            "table shows", f"first {head} and last {tail} of {len(points)}; --json for all"
        )

    for i, p in enumerate(display):
        if len(points) > max_table and i == max_table // 2:
            report.table.append(
                {"t (s)": "...", "lat": "...", "lon": "...", "speed km/h": "...", "alt m": "..."}
            )
        report.table.append(
            {
                "t (s)": round(p.t_seconds, 3),
                "lat": round(p.latitude, 5),
                "lon": round(p.longitude, 5),
                "speed km/h": round(p.speed_kmh, 1),
                "alt m": round(p.altitude_m, 1),
            }
        )
