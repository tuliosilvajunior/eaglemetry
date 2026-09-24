"""Where trips come from: a snapshot on the desk, or the whole fleet.

Both readers produce `Trip`, and neither computes anything the metric owns.
The SQL differs because the stores differ — SQLite holds the car's camelCase
Room columns, Postgres holds the same names in snake_case — but the questions
are the same three: what the odometer did, what the readout did, and when the
last readout landed.
"""

from __future__ import annotations

import os
import sqlite3
import subprocess
from pathlib import Path

from .metric import Trip, rolling_efficiency

#: Wh in the pack, when the caller states one. The car keeps this in its own
#: settings and never syncs it, so a fleet reader cannot know it per vehicle.
DEFAULT_CAPACITY_KWH = 39.6


def _net_kwh(traction, regen, auxiliary) -> float | None:
    if traction is None or regen is None or auxiliary is None:
        return None
    net = (traction - regen + auxiliary) / 1000
    return net if net > 0 else None


def from_snapshot(path: str | Path, *, capacity_kwh: float | None = DEFAULT_CAPACITY_KWH) -> list[Trip]:
    """Trips out of a database pulled off one car.

    Capacity is the caller's to state: this is one known vehicle, so the app
    line can be computed here even though it cannot be for the fleet.
    """
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        sessions = conn.execute(
            """
            select id, startedAtUtcMillis, endedAtUtcMillis, status,
                   rollupDistanceKm, rollupTractionWh, rollupRegenWh, rollupAuxiliaryWh,
                   startOdometerKm, endOdometerKm
            from session
            where kind = 'TRIP' and status = 'ENDED' and endedAtUtcMillis is not null
            order by startedAtUtcMillis
            """
        ).fetchall()

        closed = []
        for row in sessions:
            net = _net_kwh(row["rollupTractionWh"], row["rollupRegenWh"], row["rollupAuxiliaryWh"])
            distance = _odometer_span(row["startOdometerKm"], row["endOdometerKm"]) or row["rollupDistanceKm"]
            if net is None or not distance or distance <= 0:
                continue
            closed.append((row["endedAtUtcMillis"], distance, net))

        trips = []
        for row in sessions:
            edges = _snapshot_edges(conn, row["id"])
            distance = edges["odometer_span"]
            if distance is None:
                distance = _odometer_span(row["startOdometerKm"], row["endOdometerKm"])
            efficiency, _, _ = rolling_efficiency(closed, row["startedAtUtcMillis"])
            trips.append(
                Trip(
                    vehicle_id="local",
                    trip_id=row["id"],
                    started_utc_millis=row["startedAtUtcMillis"],
                    distance_km=distance,
                    car_range_start_km=edges["range_first"],
                    car_range_end_km=edges["range_last"],
                    range_lag_seconds=(
                        None
                        if edges["range_last_t"] is None
                        else (row["endedAtUtcMillis"] - edges["range_last_t"]) / 1000
                    ),
                    soc_start_percent=edges["soc_first"],
                    soc_end_percent=edges["soc_last"],
                    efficiency_km_per_kwh=efficiency,
                    capacity_kwh=capacity_kwh,
                )
            )
        return trips
    finally:
        conn.close()


def _odometer_span(start, end) -> float | None:
    if start is None or end is None or end <= start:
        return None
    return end - start


def _snapshot_edges(conn: sqlite3.Connection, session_id: str) -> dict:
    """First and last measured reading of each signal the metric needs.

    Only `MEASURED` rows count. A reading the car itself marked unusable is
    not a position or a range; treating one as an edge would invent a drop.
    """
    edges = {
        "range_first": None,
        "range_last": None,
        "range_last_t": None,
        "range_count": 0,
        "odometer_span": None,
        "soc_first": None,
        "soc_last": None,
    }
    rows = conn.execute(
        """
        select key, value, tUtcMillis
        from sample
        where sessionId = ? and validity = 'MEASURED'
          and key in ('RANGE_REMAINING', 'ODOMETER', 'HV_BATTERY_SOC')
        order by tUtcMillis
        """,
        (session_id,),
    ).fetchall()

    by_key: dict[str, list] = {}
    for row in rows:
        by_key.setdefault(row["key"], []).append(row)

    ranges = by_key.get("RANGE_REMAINING", [])
    # One reading is a value, not a drop: a trip needs both edges to score.
    if len(ranges) >= 2:
        edges["range_first"] = ranges[0]["value"]
        edges["range_last"] = ranges[-1]["value"]
        edges["range_last_t"] = ranges[-1]["tUtcMillis"]
        edges["range_count"] = len(ranges)

    odometers = by_key.get("ODOMETER", [])
    if len(odometers) >= 2:
        edges["odometer_span"] = odometers[-1]["value"] - odometers[0]["value"]

    socs = by_key.get("HV_BATTERY_SOC", [])
    if len(socs) >= 2:
        edges["soc_first"] = socs[0]["value"]
        edges["soc_last"] = socs[-1]["value"]
    return edges


CLOUD_SQL = """
with ranges as (
  select session_id, vehicle_id,
         (array_agg(value order by t_utc_millis))[1] as first_km,
         (array_agg(value order by t_utc_millis desc))[1] as last_km,
         max(t_utc_millis) as last_t,
         count(*) as n
  from public.sample
  where key = 'RANGE_REMAINING' and validity = 'MEASURED' and session_id is not null
  group by session_id, vehicle_id
),
odometers as (
  select session_id,
         (array_agg(value order by t_utc_millis desc))[1]
           - (array_agg(value order by t_utc_millis))[1] as span
  from public.sample
  where key = 'ODOMETER' and validity = 'MEASURED' and session_id is not null
  group by session_id
)
select s.vehicle_id, s.id, s.started_at_utc_millis,
       coalesce(odometers.span, s.end_odometer_km - s.start_odometer_km) as distance_km,
       ranges.first_km, ranges.last_km,
       (s.ended_at_utc_millis - ranges.last_t) / 1000.0 as lag_seconds
from public.session s
join ranges on ranges.session_id = s.id and ranges.n >= 2
left join odometers on odometers.session_id = s.id
where s.kind = 'TRIP' and s.status = 'ENDED' and s.ended_at_utc_millis is not null
order by s.started_at_utc_millis
"""


def from_cloud(url_file: str | Path = ".pgurl.pooler") -> list[Trip]:
    """Trips for every vehicle in the cloud replica.

    The connection URL is read from a file and handed to `psql` through the
    environment, so the password never reaches an argument list or a log. The
    role in that file bypasses row-level security by design: this reads other
    people's vehicles, and that is the owner's call to make, not this
    function's to hide.

    No app line comes back. Pack capacity is a device setting the car never
    uploads, so `soc_*` and `capacity_kwh` stay empty and `app_drop_km` is
    None for every trip here.
    """
    url = Path(url_file).read_text().strip()
    environment = dict(os.environ, PGCONNECT_TIMEOUT="20")
    result = subprocess.run(
        ["psql", url, "-qAtF", "\t", "-c", CLOUD_SQL],
        capture_output=True,
        text=True,
        env=environment,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"psql failed: {result.stderr.strip().splitlines()[-1:]}")

    trips = []
    for line in result.stdout.splitlines():
        if not line.strip():
            continue
        vehicle, trip_id, started, distance, first_km, last_km, lag = line.split("\t")
        trips.append(
            Trip(
                vehicle_id=vehicle,
                trip_id=trip_id,
                started_utc_millis=int(started),
                distance_km=_maybe_float(distance),
                car_range_start_km=_maybe_float(first_km),
                car_range_end_km=_maybe_float(last_km),
                range_lag_seconds=_maybe_float(lag),
            )
        )
    return trips


def _maybe_float(text: str) -> float | None:
    text = text.strip()
    return float(text) if text else None
