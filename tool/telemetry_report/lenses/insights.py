"""Whether the recorded corpus can support the insights layer.

The insights layer needs four things, none of them readable from one session:

1. the universe — trips that carry measured CAN energy, because SOC-derived
   energy is refused;
2. the 30-day reference window — how many trips fall in it, and what the ratio
   of sums says;
3. the noise floor — the spread of the recorded trips, because a claim is only
   allowed when the difference exceeds it;
4. geometry — how much history still has GPS, and whether the proposed 200 m
   segment and 150 m place radius survive contact with the recorded drives.

This lens answers those, and nothing else. It states what is missing rather
than filling it in: a corpus that cannot support a comparison is the finding.

The window is measured back from the newest trip in the snapshot, not from the
wall clock of the machine reading it. A snapshot is a photograph, and reading
it against today's date would report an empty window for an old one.
"""

from __future__ import annotations

import math
import sqlite3
from datetime import datetime, timezone

from ..db import columns, rows
from ..lens import Report, register_corpus

# Tunables this lens checks: 30-day window, 0.2 km segments, 150 m place radius.
WINDOW_DAYS = 30
SEGMENT_KM = 0.2
PLACE_RADIUS_M = 150.0

DAY_MILLIS = 86_400_000

# The nameplate pack, used only when the trip recorded no capacity of its own.
NOMINAL_CAPACITY_WH = 39_600.0
# Below this, an SOC move and an integral are both too small to arbitrate a
# sign. One tenth of a percent of the pack is about 40 Wh.
SOC_FLOOR_WH = 40.0


def haversine_m(a: tuple[float, float], b: tuple[float, float]) -> float:
    """Great-circle distance in metres between two (lat, lon) pairs."""
    radius = 6_371_000.0
    lat1, lon1 = math.radians(a[0]), math.radians(a[1])
    lat2, lon2 = math.radians(b[0]), math.radians(b[1])
    d_lat, d_lon = lat2 - lat1, lon2 - lon1
    h = (
        math.sin(d_lat / 2) ** 2
        + math.cos(lat1) * math.cos(lat2) * math.sin(d_lon / 2) ** 2
    )
    return 2 * radius * math.asin(min(1.0, math.sqrt(h)))


def quantile(values: list[float], fraction: float) -> float | None:
    """Linear-interpolated quantile. Returns None for an empty sample."""
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = fraction * (len(ordered) - 1)
    low = math.floor(position)
    high = math.ceil(position)
    if low == high:
        return ordered[low]
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def cluster(points: list[tuple[float, float]], radius_m: float) -> list[list[int]]:
    """Greedy single-pass clustering at a fixed radius.

    A point joins the first cluster whose centre is within the radius. This is
    the same rule a named place would apply, so the count it produces is the
    count the product would see, not a better one from a better algorithm.
    """
    centres: list[tuple[float, float]] = []
    members: list[list[int]] = []
    for index, point in enumerate(points):
        for slot, centre in enumerate(centres):
            if haversine_m(centre, point) <= radius_m:
                members[slot].append(index)
                count = len(members[slot])
                centres[slot] = (
                    centre[0] + (point[0] - centre[0]) / count,
                    centre[1] + (point[1] - centre[1]) / count,
                )
                break
        else:
            centres.append(point)
            members.append([index])
    return members


def trip_energy(conn: sqlite3.Connection, trip_id: str) -> tuple[float, float, int]:
    """Distance in km, net energy in Wh, and the minute count, from the grid.

    The rules are the app's: one stored distance per minute, and a minute
    the car did not integrate is not a zero. This is deliberately the same
    reduction `lenses/buckets.py` performs for one session, so a corpus
    total and a session total cannot disagree.
    """
    found = rows(
        conn,
        "select tractionWh, auxiliaryWh, regenWh, distanceKm, "
        "coveredSeconds, deliveredCoveredSeconds from interval where sessionId = ?",
        trip_id,
    )
    distance = 0.0
    net = 0.0
    used = 0
    for minute in found:
        try:
            delivered = minute["deliveredCoveredSeconds"] or 0
        except IndexError:
            delivered = 0
        if (minute["coveredSeconds"] or 0) <= 0 and delivered <= 0:
            continue
        distance += minute["distanceKm"] or 0
        net += (minute["tractionWh"] or 0) + (minute["auxiliaryWh"] or 0) - (minute["regenWh"] or 0)
        used += 1
    return distance, net, used


def soc_agrees(trip, net_wh: float) -> bool | None:
    """Whether the state of charge confirms the sign of the integral.

    A trip that returns more energy than it draws is physically ordinary: a
    long descent does exactly that. So a negative net is not by itself a
    defect, and refusing one would silently throw away the most interesting
    drives in the corpus.

    What decides it is a second, independent measurement. The state of charge
    is not derived from pack current, so when the integral says the pack gained
    energy and the SOC says it fell, one of the two is wrong about the
    direction — and only the integral has a known way to be: the inverted
    `BMSH_BattCurr` regime, which some Roadcast builds decoded with a negative
    scale. A real descent has both agreeing.

    Returns True when they agree, False when they contradict, and None when the
    SOC is absent or the move is inside its noise floor and therefore says
    nothing.
    """
    start, end = trip["startSoc"], trip["endSoc"]
    if start is None or end is None:
        return None
    soc_wh = (start - end) / 100.0 * NOMINAL_CAPACITY_WH
    if abs(soc_wh) < SOC_FLOOR_WH or abs(net_wh) < SOC_FLOOR_WH:
        return None
    return (soc_wh > 0) == (net_wh > 0)


@register_corpus("insights", "Insight universe")
def insights(conn: sqlite3.Connection, report: Report) -> None:
    session_columns = columns(conn, "session")
    if "rollupTractionWh" not in session_columns:
        report.problem(
            "this snapshot's session table carries no rollup energy columns: "
            "no trip can carry measured energy, so the insights universe "
            "cannot be measured from it"
        )
        return

    trips = rows(
        conn,
        "select id, status, startedAtUtcMillis, endedAtUtcMillis, "
        "startSocPercent startSoc, endSocPercent endSoc, "
        "rollupTractionWh, rollupRegenWh, rollupAuxiliaryWh "
        "from session where kind = 'TRIP' "
        "order by startedAtUtcMillis",
    )
    if not trips:
        report.problem("the snapshot holds no trips")
        return

    closed = [t for t in trips if t["endedAtUtcMillis"] is not None]
    universe = [t for t in closed if t["rollupTractionWh"] is not None]

    report.add("trips in snapshot", len(trips))
    report.add("closed trips", len(closed))
    report.add(
        "with measured energy",
        len(universe),
        note="the whole universe of the insights layer; the rest never enters it",
    )

    if not universe:
        report.problem(
            "no closed trip carries measured energy: slice 1 has nothing "
            "to compare, and the layer cannot be built against this snapshot"
        )
        return

    if not columns(conn, "interval"):
        report.problem(
            "this snapshot has no interval table: the minute grid the "
            "reference is reduced from does not exist"
        )
        return

    def day(millis: int) -> str:
        return (
            datetime.fromtimestamp(millis / 1000, timezone.utc)
            .astimezone()
            .strftime("%Y-%m-%d")
        )

    report.add("first measured trip", day(universe[0]["startedAtUtcMillis"]))
    report.add("last measured trip", day(universe[-1]["startedAtUtcMillis"]))

    # ---- the 30-day reference window -------------------------------------
    newest = universe[-1]["startedAtUtcMillis"]
    cutoff = newest - WINDOW_DAYS * DAY_MILLIS
    window = [t for t in universe if t["startedAtUtcMillis"] >= cutoff]
    report.add(
        f"trips in the {WINDOW_DAYS}-day window",
        len(window),
        note=f"measured back from {day(newest)}, the newest trip in the snapshot",
    )

    total_distance = 0.0
    total_net = 0.0
    per_trip: list[float] = []
    without_buckets = 0
    contradicts_soc = 0
    unconfirmed = 0
    for trip in window:
        distance, net, used = trip_energy(conn, trip["id"])
        if used == 0:
            without_buckets += 1
            continue
        verdict = soc_agrees(trip, net)
        if verdict is False:
            contradicts_soc += 1
            continue
        if verdict is None and net <= 0:
            unconfirmed += 1
            continue
        total_distance += distance
        total_net += net
        if distance >= 0.5 and net > 0:
            per_trip.append(net / distance)

    report.add("window distance", total_distance or None, "km")
    report.add("window energy", total_net or None, "Wh")
    report.add(
        "window average",
        total_net / total_distance if total_distance > 0 and total_net > 0 else None,
        "Wh/km",
        note="ratio of sums, which is the reference slice 1 compares against",
    )
    report.add(
        "window average",
        total_distance / (total_net / 1000.0)
        if total_distance > 0 and total_net > 0
        else None,
        "km/kWh",
    )
    if without_buckets:
        report.add(
            "window trips with no measured minutes",
            without_buckets,
            note="measured energy in the rollup, nothing to reduce per minute",
        )
    if contradicts_soc:
        report.add(
            "window trips the SOC contradicts",
            contradicts_soc,
            note="excluded: the integral and the state of charge disagree in sign",
        )
        report.problem(
            f"{contradicts_soc} of {len(window)} window trips integrate to a "
            "sign the SOC contradicts: the inverted pack-current window. "
            "a rollup being present is not enough to admit a trip"
        )
    if unconfirmed:
        report.add(
            "returning energy, SOC unknown",
            unconfirmed,
            note="excluded: a net-regenerating drive that nothing can confirm",
        )

    # ---- the noise floor -------------------------------------------------
    median = quantile(per_trip, 0.5)
    low = quantile(per_trip, 0.25)
    high = quantile(per_trip, 0.75)
    report.add("trips over 0.5 km in the window", len(per_trip))
    report.add("median trip", median, "Wh/km")
    report.add(
        "interquartile range",
        high - low if high is not None and low is not None else None,
        "Wh/km",
    )
    smallest = (
        (high - low) / median * 100.0
        if median and high is not None and low is not None and median > 0
        else None
    )
    report.add(
        "IQR over the median",
        smallest,
        "%",
        note="what a single-trip claim must beat; a group claim divides it by root n",
    )
    if len(per_trip) < 8:
        report.problem(
            f"only {len(per_trip)} usable trips in the window: the spread "
            "cannot be estimated, so every insight would have to answer "
            "'not enough data yet'"
        )

    # ---- geometry --------------------------------------------------------
    # GPS arrives per trip as the start/end fix on the session row and as
    # the derived `trip_segments` table. What survives here is the whole of
    # what a retroactive segment derivation could ever see.
    with_segments = 0
    with_track = 0
    endpoints: list[tuple[float, float]] = []
    for trip in universe:
        try:
            segs = rows(
                conn,
                "select startLatitude, startLongitude, endLatitude, endLongitude "
                "from trip_segments where sessionId = ? order by ordinal",
                trip["id"],
            )
        except sqlite3.OperationalError:
            segs = []
        try:
            has_track = conn.execute(
                "select 1 from track where sessionId = ?", (trip["id"],)
            ).fetchone() is not None
        except sqlite3.OperationalError:
            has_track = False
        if has_track:
            with_track += 1
        if not segs:
            continue
        with_segments += 1
        located = [
            (s["startLatitude"], s["startLongitude"])
            for s in segs
            if s["startLatitude"] is not None and s["startLongitude"] is not None
        ]
        located += [
            (s["endLatitude"], s["endLongitude"])
            for s in segs
            if s["endLatitude"] is not None and s["endLongitude"] is not None
        ]
        if not located:
            continue
        endpoints.append(located[0])
        endpoints.append(located[-1])

    report.add("measured trips with segments", with_segments)
    report.add(
        "measured trips with a track",
        with_track,
        note="routes and segments are impossible without this",
    )
    if with_track == 0:
        report.problem(
            "no measured trip carries a track row: no route can be built "
            "from this snapshot"
        )

    # ---- the place radius ------------------------------------------------
    if endpoints:
        groups = cluster(endpoints, PLACE_RADIUS_M)
        report.add(
            f"endpoint clusters at {PLACE_RADIUS_M:.0f} m",
            len(groups),
            note=f"from {len(endpoints)} trip endpoints",
        )
        repeated = [g for g in groups if len(g) >= 4]
        report.add(
            "clusters worth naming",
            len(repeated),
            note="visited at least four times; a route needs two of these",
        )
        report.table.extend(
            {
                "endpoints": len(group),
                # Strings, because the renderer rounds a float above 10 to one
                # decimal, and one decimal of latitude is eleven kilometres.
                "lat": f"{sum(endpoints[i][0] for i in group) / len(group):.5f}",
                "lon": f"{sum(endpoints[i][1] for i in group) / len(group):.5f}",
            }
            for group in sorted(groups, key=len, reverse=True)[:10]
        )
        if len(repeated) < 2:
            report.problem(
                "fewer than two places are visited often enough to form a "
                f"route at a {PLACE_RADIUS_M:.0f} m radius: route comparison "
                "has nothing to compare yet"
            )
