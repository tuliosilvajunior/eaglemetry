"""Self-tests for the parts of the harness that could rot silently.

Run with:

    python3 -m unittest tool.telemetry_report.test_harness

Three things are guarded. The bucket classification is a port of
`readEfficiency` in `lib/core/efficiency_window.dart`, so it can drift away
from the app it is supposed to describe. The per-minute reductions are pinned
against hand-computed fixtures, so a lens that stops reading the real
`session`/`interval` tables fails here instead of printing zeroes against a
live snapshot. And the schema pins below fail the moment the tool's tables
or columns drift from `45.json`, which is how the last rot arrived: the
tool queried three tables the app had dropped, and the fixtures built them
back, so every test passed against a schema that no longer existed.
"""

from __future__ import annotations

import json
import sqlite3
import unittest
from pathlib import Path

from . import track_codec
from .db import Session, intervals, measured_minutes, recent_charges, recent_trips
from .lenses import track as track_lens
from .lens import CORPUS_REGISTRY, REGISTRY, Report
from .lenses.buckets import buckets, classify
from .lenses.charging import charging
from .lenses.efficiency import efficiency
from .lenses.insights import cluster, haversine_m, insights, quantile, trip_energy
from .lenses.movement import (
    MAX_GAP_SECONDS,
    _metres,
    _scalar_distance,
    _simulate,
)
from .lenses.overview import overview
from .lenses.signals import signals
from .maths import correlation, integrate, soc_energy_kwh


def _schema_45() -> dict:
    root = Path(__file__).resolve().parents[2]
    return json.loads(
        (root / "android" / "app" / "schemas" /
         "com.timhss.capyenergy.telemetry.db.TelemetryDatabase" /
         "45.json").read_text()
    )


def _schema_columns(table: str) -> set[str]:
    for entity in _schema_45()["database"]["entities"]:
        if entity["tableName"] == table:
            return {f["columnName"] for f in entity["fields"]}
    raise AssertionError(f"schema 45 has no table {table}")


class SchemaPinTest(unittest.TestCase):
    """The tool reads the tables 45.json describes, with the columns it needs.

    This is the test that would have caught the last rot: every table and
    column a lens queries must exist in the shipped schema, and the three
    dead names must stay dead.
    """

    def test_session_carries_the_columns_the_lenses_read(self):
        have = _schema_columns("session")
        for column in (
            "id", "kind", "status", "startedAtUtcMillis", "endedAtUtcMillis",
            "plugDisconnectedAtUtcMillis", "chargeEndedAtUtcMillis",
            "startOdometerKm", "endOdometerKm",
            "startSocPercent", "endSocPercent", "socAgreesWithIntegral",
            "rollupDistanceKm", "rollupTractionWh", "rollupRegenWh",
            "rollupAuxiliaryWh", "rollupDeliveredWh", "rollupIntegratedSeconds",
            "endReason", "plugType", "chargeEndReason",
            "startAmbientTempC", "endAmbientTempC",
        ):
            self.assertIn(column, have, f"session.{column}")

    def test_interval_carries_the_columns_the_lenses_read(self):
        have = _schema_columns("interval")
        for column in (
            "sessionId", "startUtcMillis", "tractionWh", "regenWh",
            "auxiliaryWh", "deliveredWh", "distanceKm", "coveredSeconds",
            "deliveredCoveredSeconds", "startSoc", "endSoc",
            # Time authority T1: the monotonic pair and time state.
            "startElapsedNanos", "startBootCount", "timeState",
        ):
            self.assertIn(column, have, f"interval.{column}")
    def test_events_and_segments_carry_the_columns_the_lenses_read(self):
        events = _schema_columns("telemetry_events")
        for column in ("sessionId", "type", "signalId", "value", "quality",
                       "occurredAtUtcMillis"):
            self.assertIn(column, events, f"telemetry_events.{column}")
        segments = _schema_columns("trip_segments")
        for column in ("sessionId", "ordinal", "startLatitude", "startLongitude",
                       "endLatitude", "endLongitude"):
            self.assertIn(column, segments, f"trip_segments.{column}")

    def test_the_dead_tables_stay_dead(self):
        names = {e["tableName"]
                 for e in _schema_45()["database"]["entities"]}
        for dead in ("telemetry_frames", "session_aggregates", "energy_buckets",
                     "trip_sessions", "charge_sessions"):
            self.assertNotIn(dead, names, f"{dead} came back")

    def test_every_lens_query_names_a_real_table(self):
        import re
        names = {e["tableName"]
                 for e in _schema_45()["database"]["entities"]}
        root = Path(__file__).resolve().parent
        for path in list(root.glob("db.py")) + list((root / "lenses").glob("*.py")):
            if path.name in ("drivetrain.py", "movement.py"):
                continue  # retired: registers no lens, runs no query
            text = path.read_text()
            for match in re.finditer(
                r"['\"](?:select|insert into|update|delete from)\b(.*?)['\"]",
                text, re.IGNORECASE | re.DOTALL,
            ):
                for name in re.findall(
                    r"\b(?:from|join|into|update|table)\s+([a-z_]+)",
                    match.group(1), re.IGNORECASE,
                ):
                    if name in ("sqlite_master",):
                        continue  # the catalog, not a data table
                    self.assertIn(name, names, f"{path.name}: {name}")


def _fixture_db() -> sqlite3.Connection:
    """One trip and one charge on the real tables, with hand-computed energy.

    The trip runs 10 measured minutes: 150 Wh traction and 1.0 km each,
    so the reference is a round 150 Wh/km. The charge runs 5 measured
    minutes at 200 Wh delivered each. One extra minute with
    `coveredSeconds = 0` sits in each session: absence, not a zero, and
    every reduction must skip it.
    """
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.execute(
        "create table session (id text, kind text, status text, "
        "startedAtUtcMillis int, endedAtUtcMillis int, "
        "plugDisconnectedAtUtcMillis int, chargeEndedAtUtcMillis int, "
        "startOdometerKm real, endOdometerKm real, "
        "startSocPercent real, endSocPercent real, socAgreesWithIntegral text, "
        "rollupDistanceKm real, rollupTractionWh real, rollupRegenWh real, "
        "rollupAuxiliaryWh real, rollupDeliveredWh real, "
        "rollupIntegratedSeconds real, endReason text, plugType int, "
        "chargeEndReason text, startAmbientTempC real, endAmbientTempC real)"
    )
    conn.execute(
        "create table interval (sessionId text, startUtcMillis int, "
        "tractionWh real, regenWh real, auxiliaryWh real, deliveredWh real, "
        "distanceKm real, coveredSeconds real, deliveredCoveredSeconds real, "
        "startSoc real, endSoc real)"
    )
    conn.execute(
        "create table telemetry_events (id integer, sessionId text, type text, "
        "signalId text, value text, quality text, occurredAtUtcMillis int)"
    )
    conn.execute(
        "create table trip_segments (sessionId text, ordinal int, "
        "startLatitude real, startLongitude real, "
        "endLatitude real, endLongitude real)"
    )
    base = 1_800_000_000_000
    conn.execute(
        "insert into session values ('trip-0', 'TRIP', 'ENDED', ?, ?, "
        "null, null, 100.0, 110.0, 80.0, 76.21, 'agrees', "
        "10.0, 1500.0, 0.0, 0.0, 0.0, 600.0, 'PARK_CONFIRMED', null, null, null, null)",
        (base, base + 600_000),
    )
    for minute in range(10):
        conn.execute(
            "insert into interval values ('trip-0', ?, 150.0, 0.0, 0.0, 0.0, "
            "1.0, 60.0, 0.0, ?, ?)",
            (base + minute * 60_000, 80.0 - minute * 0.379, 80.0 - (minute + 1) * 0.379),
        )
    conn.execute(
        "insert into interval values ('trip-0', ?, 0.0, 0.0, 0.0, 0.0, "
        "0.0, 0.0, 0.0, null, null)",
        (base + 10 * 60_000,),
    )
    conn.execute(
        "insert into telemetry_events values (1, 'trip-0', 'TRIP_STARTED', null, null, null, ?)",
        (base,),
    )
    conn.execute(
        "insert into telemetry_events values (2, 'trip-0', 'SIGNAL_UPDATED', "
        "'GEAR', '2', 'MEASURED', ?)",
        (base + 60_000,),
    )
    conn.execute(
        "insert into telemetry_events values (3, 'trip-0', 'SIGNAL_UPDATED', "
        "'GEAR', '8', 'MEASURED', ?)",
        (base + 120_000,),
    )
    conn.execute(
        "insert into telemetry_events values (4, 'trip-0', 'TRIP_ENDED', null, null, null, ?)",
        (base + 600_000,),
    )
    # High-rate signals log session-less by design; the lens reads them
    # from the session window.
    conn.execute(
        "insert into telemetry_events values (5, null, 'SIGNAL_UPDATED', "
        "'HV_BATTERY_SOC', '79.0', 'MEASURED', ?)",
        (base + 60_000,),
    )
    conn.execute(
        "insert into telemetry_events values (6, null, 'SIGNAL_UPDATED', "
        "'HV_BATTERY_SOC', '78.0', 'MEASURED', ?)",
        (base + 120_000,),
    )
    conn.execute(
        "insert into trip_segments values ('trip-0', 0, -23.5, -46.6, -23.49, -46.59)"
    )
    conn.execute(
        "insert into session values ('charge-0', 'CHARGE', 'DISCONNECTED', ?, ?, "
        "?, ?, null, null, 70.0, 72.5, 'agrees', "
        "null, null, null, null, 1000.0, 300.0, null, null, 'COMPLETED', 11.5, 11.5)",
        (base, base + 300_000, base + 300_000, base + 300_000),
    )
    for minute in range(5):
        conn.execute(
            "insert into interval values ('charge-0', ?, 0.0, 0.0, 0.0, 200.0, "
            "0.0, 60.0, 60.0, ?, ?)",
            (base + minute * 60_000, 70.0 + minute * 0.5, 70.0 + (minute + 1) * 0.5),
        )
    conn.commit()
    return conn


def _session(conn: sqlite3.Connection, kind: str, sid: str) -> Session:
    row = dict(conn.execute("select * from session where id = ?", (sid,)).fetchone())
    row.setdefault("startSoc", row.get("startSocPercent"))
    row.setdefault("endSoc", row.get("endSocPercent"))
    if kind == "trip":
        return Session(kind="trip", id=sid, status=row["status"],
                       started_utc_millis=row["startedAtUtcMillis"],
                       ended_utc_millis=row["endedAtUtcMillis"], row=row)
    return Session(kind="charge", id=sid, status=row["status"],
                   started_utc_millis=row["startedAtUtcMillis"],
                   ended_utc_millis=row["plugDisconnectedAtUtcMillis"]
                   or row["chargeEndedAtUtcMillis"] or row["endedAtUtcMillis"],
                   row=row)


def _run(lens, conn: sqlite3.Connection, kind: str, sid: str) -> Report:
    report = Report(lens="test")
    lens(conn, _session(conn, kind, sid), report)
    return report


class RecentSessionsTest(unittest.TestCase):
    def test_trips_and_charges_come_from_the_unified_table(self):
        conn = _fixture_db()
        trips = recent_trips(conn, 5)
        charges = recent_charges(conn, 5)
        self.assertEqual(["trip-0"], [s.id for s in trips])
        self.assertEqual(["charge-0"], [s.id for s in charges])
        self.assertEqual(76.21 - 80.0, trips[0].row["endSoc"] - trips[0].row["startSoc"])

    def test_an_unmeasured_minute_is_absence_not_a_zero(self):
        conn = _fixture_db()
        self.assertEqual(11, len(intervals(conn, "trip-0")))
        self.assertEqual(10, len(measured_minutes(intervals(conn, "trip-0"))))


class OverviewLensTest(unittest.TestCase):
    def test_reports_rollups_minutes_and_events(self):
        report = _run(overview, _fixture_db(), "trip", "trip-0")
        values = {f.label: f.value for f in report.findings}
        self.assertEqual(10, values["minutes"])
        self.assertEqual(4, values["events"])
        self.assertEqual(1500.0, values["rollup traction"])
        self.assertEqual([], report.problems)

    def test_names_a_session_that_was_never_finalized(self):
        conn = _fixture_db()
        conn.execute("update session set rollupTractionWh = null where id = 'trip-0'")
        report = _run(overview, conn, "trip", "trip-0")
        self.assertTrue(any("never finalized" in p for p in report.problems))


class BucketsLensTest(unittest.TestCase):
    def test_totals_match_the_hand_computed_fixture(self):
        report = _run(buckets, _fixture_db(), "trip", "trip-0")
        values = {f.label: f.value for f in report.findings}
        self.assertEqual(10, values["buckets"])
        self.assertAlmostEqual(10.0, values["bucket distance total"])
        self.assertAlmostEqual(1500.0, values["bucket net energy total"])
        average = next(f for f in report.findings if f.label == "window average")
        self.assertAlmostEqual(10.0 / 1.5, average.value, places=6)


class EfficiencyLensTest(unittest.TestCase):
    def test_rollup_and_re_sum_agree_on_the_fixture(self):
        report = _run(efficiency, _fixture_db(), "trip", "trip-0")
        values = {f.label: f.value for f in report.findings}
        self.assertAlmostEqual(1500.0, values["pack energy, re-summed minutes"])
        self.assertAlmostEqual(1500.0, values["pack energy, stored rollup"])
        self.assertFalse(any(f.disagrees for f in report.findings
                             if f.label == "pack energy, stored rollup"))

    def test_a_divergent_rollup_disagrees(self):
        conn = _fixture_db()
        conn.execute("update session set rollupTractionWh = 900.0 where id = 'trip-0'")
        report = _run(efficiency, conn, "trip", "trip-0")
        stored = next(f for f in report.findings
                      if f.label == "pack energy, stored rollup")
        self.assertTrue(stored.disagrees)


class ChargingLensTest(unittest.TestCase):
    def test_delivered_energy_matches_the_fixture(self):
        report = _run(charging, _fixture_db(), "charge", "charge-0")
        values = {f.label: f.value for f in report.findings}
        self.assertAlmostEqual(1000.0, values["delivered energy, re-summed minutes"])
        self.assertAlmostEqual(1000.0, values["delivered energy, stored rollup"])


class SignalsLensTest(unittest.TestCase):
    def test_names_the_signals_that_spoke_and_the_ones_that_did_not(self):
        report = _run(signals, _fixture_db(), "trip", "trip-0")
        values = {f.label: f.value for f in report.findings}
        self.assertEqual(4, values["events"])
        table = {row["signal"]: row for row in report.table}
        self.assertEqual(2, table["GEAR"]["events"])
        self.assertEqual(2, table["HV_BATTERY_SOC"]["events"])
        # Sparse narrative signals are shown, not demanded.
        self.assertFalse(any("EV_CHARGE_STATE never arrived" in p
                             for p in report.problems))

    def test_demands_the_kind_defining_signal(self):
        conn = _fixture_db()
        conn.execute("delete from telemetry_events where signalId = 'GEAR'")
        report = _run(signals, conn, "trip", "trip-0")
        self.assertTrue(any("GEAR never arrived" in p for p in report.problems))


class ClassificationTest(unittest.TestCase):
    def test_names_the_four_ways_an_interval_has_no_ratio(self):
        self.assertEqual("consuming", classify(0.5, 100.0, 60))
        self.assertEqual("regenerating", classify(0.5, -100.0, 60))
        self.assertEqual("coasting", classify(0.5, 0.1, 60))
        self.assertEqual("idle", classify(0.0, 100.0, 60))
        self.assertEqual("gap", classify(0.5, 100.0, 0))

    def test_stillness_that_was_reported_is_not_a_measurement(self):
        # The car said it neither moved nor drew. That is not efficiency.
        self.assertEqual("gap", classify(0.0, 0.0, 60))

    def test_the_floors_are_the_app_s_floors(self):
        self.assertEqual("idle", classify(0.0009, 1.0, 60))
        self.assertEqual("consuming", classify(0.0010, 1.0, 60))
        self.assertEqual("coasting", classify(1.0, 0.49, 60))
        self.assertEqual("consuming", classify(1.0, 0.50, 60))


    def test_skips_a_recording_gap_instead_of_stitching_over_it(self):
        # Ten seconds at 1 kW, a five-minute silence, ten more seconds.
        points = [(0.0, 1.0), (10.0, 1.0), (310.0, 1.0), (320.0, 1.0)]
        result = integrate(points)
        self.assertEqual(1, result.gaps)
        self.assertAlmostEqual(20.0, result.covered_seconds)
        self.assertAlmostEqual(20.0, result.value)
        self.assertAlmostEqual(20.0 / 320.0, result.coverage)

    def test_keeps_traction_and_regeneration_apart(self):
        result = integrate([(0.0, 10.0), (1.0, 10.0), (2.0, -10.0), (3.0, -10.0)])
        self.assertAlmostEqual(10.0, result.positive)
        self.assertAlmostEqual(10.0, result.negative)

    def test_reads_an_inverted_pack_current_as_a_negative_correlation(self):
        drive = [float(i % 40) - 20.0 for i in range(200)]
        self.assertGreater(correlation(drive, [d * 1.02 for d in drive]), 0.9)
        self.assertLess(correlation(drive, [-d * 1.02 for d in drive]), -0.9)

    def test_ignores_state_of_charge_steps_below_the_noise_floor(self):
        quiet = [50.0, 49.99, 49.98, 49.97]
        consumed, regenerated = soc_energy_kwh(quiet, 39_600.0)
        self.assertEqual(0.0, consumed)
        self.assertEqual(0.0, regenerated)

    def test_splits_state_of_charge_movement_by_direction(self):
        consumed, regenerated = soc_energy_kwh([50.0, 45.0, 46.0], 39_600.0)
        self.assertAlmostEqual(5.0 * 0.396, consumed, places=6)
        self.assertAlmostEqual(1.0 * 0.396, regenerated, places=6)



def _corpus(
    trips: int = 12,
    with_rollup: int | None = None,
    segments: bool = True,
    days_apart: int = 2,
) -> sqlite3.Connection:
    """A snapshot with `trips` closed trips, the newest one last.

    Each trip runs 10 minutes, 10 km and 1500 Wh, so the reference is a round
    150 Wh/km and a deviation in a test is visible by eye.
    """
    with_rollup = trips if with_rollup is None else with_rollup
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.execute(
        "create table session (id text, status text, kind text, "
        "startedAtUtcMillis int, endedAtUtcMillis int, "
        "startSocPercent real, endSocPercent real, "
        "rollupTractionWh real, rollupRegenWh real, rollupAuxiliaryWh real)"
    )
    conn.execute(
        "create table interval (sessionId text, startUtcMillis int, "
        "tractionWh real, auxiliaryWh real, regenWh real, "
        "distanceKm real, coveredSeconds real, deliveredCoveredSeconds real)"
    )
    conn.execute("create table track (sessionId text)")
    conn.execute(
        "create table trip_segments (sessionId text, ordinal int, "
        "startLatitude real, startLongitude real, "
        "endLatitude real, endLongitude real)"
    )

    base = 1_800_000_000_000
    for index in range(trips):
        trip_id = f"trip-{index}"
        started = base + index * days_apart * 86_400_000
        # 1500 Wh of a 39.6 kWh pack is 3.79 % of state of charge, so the SOC
        # agrees with the integral by construction. A test that wants a
        # contradiction moves one of the two.
        conn.execute(
            "insert into session values (?, 'ENDED', 'TRIP', ?, ?, 80.0, ?, ?, 0.0, 0.0)",
            (trip_id, started, started + 600_000, 80.0 - 1500.0 / 396.0,
             1500.0 if index < with_rollup else None),
        )
        for minute in range(10):
            conn.execute(
                "insert into interval values (?, ?, ?, 0, 0, 1.0, 60.0, 0.0)",
                (trip_id, started + minute * 60_000, 150.0),
            )
        if segments:
            # A straight run east, from the same start every trip.
            conn.execute(
                "insert into trip_segments values (?, 0, -23.5, -46.6, -23.5, -46.5)",
                (trip_id,),
            )
            conn.execute("insert into track values (?)", (trip_id,))
    conn.commit()
    return conn


def _insights(conn: sqlite3.Connection) -> Report:
    report = Report(lens="insights")
    insights(conn, report)
    return report


def _finding(report: Report, label: str):
    return next(f for f in report.findings if f.label == label)


class InsightsLensTest(unittest.TestCase):
    """The lens that says whether the corpus can support the insights layer."""

    def test_counts_only_the_trips_that_carry_measured_energy(self):
        report = _insights(_corpus(trips=12, with_rollup=5))
        self.assertEqual(12, _finding(report, "closed trips").value)
        self.assertEqual(5, _finding(report, "with measured energy").value)

    def test_refuses_the_whole_corpus_when_no_trip_has_energy(self):
        report = _insights(_corpus(trips=6, with_rollup=0))
        self.assertTrue(any("nothing to compare" in p for p in report.problems))
        # It must stop rather than report a window over an empty universe.
        self.assertFalse(any(f.label.endswith("window") for f in report.findings))

    def test_measures_the_window_back_from_the_newest_trip(self):
        # 12 trips two days apart span 22 days, so all of them are in reach;
        # at four days apart only the newest eight are.
        near = _insights(_corpus(trips=12, days_apart=2))
        far = _insights(_corpus(trips=12, days_apart=4))
        self.assertEqual(12, _finding(near, "trips in the 30-day window").value)
        self.assertEqual(8, _finding(far, "trips in the 30-day window").value)

    def test_reference_is_the_ratio_of_sums(self):
        report = _insights(_corpus(trips=12))
        average = next(
            f for f in report.findings
            if f.label == "window average" and f.unit == "Wh/km"
        )
        self.assertAlmostEqual(150.0, average.value, places=6)
        self.assertIn("ratio of sums", average.note)

    def test_refuses_an_integral_the_state_of_charge_contradicts(self):
        # The inverted pack-current regime: the energy sign flips while the
        # SOC still falls. A rollup cannot detect this on its own.
        conn = _corpus(trips=12)
        conn.execute(
            "update interval set tractionWh = -150.0 "
            "where sessionId in ('trip-10', 'trip-11')"
        )
        report = _insights(conn)
        self.assertEqual(
            2, _finding(report, "window trips the SOC contradicts").value
        )
        # The reference must not move: the two trips left the total whole.
        average = next(
            f for f in report.findings
            if f.label == "window average" and f.unit == "Wh/km"
        )
        self.assertAlmostEqual(150.0, average.value, places=6)
        self.assertTrue(any("inverted" in p for p in report.problems))

    def test_keeps_a_descent_the_state_of_charge_confirms(self):
        # A long downhill returns more than it draws. That is a drive, not a
        # defect, and the SOC rises with it.
        conn = _corpus(trips=12)
        conn.execute(
            "update interval set tractionWh = -150.0 where sessionId = 'trip-11'"
        )
        conn.execute(
            "update session set endSocPercent = startSocPercent + ? where id = 'trip-11'",
            (1500.0 / 396.0,),
        )
        report = _insights(conn)
        self.assertFalse(
            any(f.label == "window trips the SOC contradicts"
                for f in report.findings)
        )
        # It is kept, so it pulls the reference below the 150 Wh/km of the rest.
        average = next(
            f for f in report.findings
            if f.label == "window average" and f.unit == "Wh/km"
        )
        self.assertLess(average.value, 150.0)

    def test_says_nothing_about_a_sign_the_state_of_charge_cannot_arbitrate(self):
        conn = _corpus(trips=12)
        conn.execute(
            "update interval set tractionWh = -150.0 where sessionId = 'trip-11'"
        )
        conn.execute("update session set startSocPercent = null where id = 'trip-11'")
        report = _insights(conn)
        self.assertEqual(
            1, _finding(report, "returning energy, SOC unknown").value
        )

    def test_says_the_spread_cannot_be_estimated_from_a_thin_window(self):
        report = _insights(_corpus(trips=4))
        self.assertTrue(any("not enough data yet" in p for p in report.problems))

    def test_names_the_missing_segments_and_tracks(self):
        report = _insights(_corpus(trips=12, segments=False))
        self.assertEqual(
            0, _finding(report, "measured trips with segments").value
        )
        self.assertEqual(
            0, _finding(report, "measured trips with a track").value
        )
        self.assertTrue(
            any("no measured trip carries a track row" in p
                for p in report.problems)
        )

    def test_groups_the_repeated_endpoints_into_places(self):
        report = _insights(_corpus(trips=12))
        # Every trip starts at one point and ends at another shared one.
        self.assertEqual(2, _finding(report, "endpoint clusters at 150 m").value)
        self.assertEqual(2, _finding(report, "clusters worth naming").value)

    def test_reports_a_snapshot_that_has_no_minute_grid(self):
        conn = _corpus(trips=12)
        conn.execute("drop table interval")
        report = _insights(conn)
        self.assertTrue(any("no interval table" in p for p in report.problems))
        self.assertFalse(any("lens failed" in p for p in report.problems))

    def test_reports_a_snapshot_without_the_rollup_columns(self):
        conn = sqlite3.connect(":memory:")
        conn.row_factory = sqlite3.Row
        conn.execute("create table session (id text)")
        report = _insights(conn)
        self.assertTrue(any("no rollup energy columns" in p for p in report.problems))


class CorpusGeometryTest(unittest.TestCase):
    def test_haversine_matches_a_known_short_distance(self):
        # One thousandth of a degree of latitude is 111.19 m everywhere.
        self.assertAlmostEqual(
            111.19, haversine_m((0.0, 0.0), (0.001, 0.0)), places=1
        )

    def test_a_point_joins_the_first_cluster_within_the_radius(self):
        points = [(0.0, 0.0), (0.0005, 0.0), (0.01, 0.0)]
        groups = cluster(points, 150.0)
        self.assertEqual([[0, 1], [2]], groups)

    def test_quantile_interpolates_and_refuses_an_empty_sample(self):
        self.assertIsNone(quantile([], 0.5))
        self.assertEqual(2.5, quantile([1.0, 2.0, 3.0, 4.0], 0.5))
        self.assertEqual(1.75, quantile([1.0, 2.0, 3.0, 4.0], 0.25))


class DeadbandSimulationTest(unittest.TestCase):
    """The three rules the deadband measurement stands on.

    Each of these, got wrong, flatters the result rather than breaking it, so
    each one is pinned rather than trusted.
    """

    def _drift(self, step: float, count: int, every_ms: int = 1000):
        return [(step * i, i * every_ms) for i in range(count)]

    def test_a_deadband_is_measured_against_the_last_written_value(self):
        # A tenth per second for a minute. No consecutive step reaches 1.0, so
        # a filter on consecutive steps would write one row and lose the ramp.
        # Against the last written value the signal crosses 1.0 six times.
        kept, forced = _simulate(self._drift(0.1, 61), 1.0, _scalar_distance)
        self.assertEqual(7, kept)  # the first sample, then six crossings
        self.assertEqual(0, forced)

    def test_the_maximum_gap_writes_a_flat_signal(self):
        # A signal that never moves, sampled once a second for twice the gap.
        flat = [(42.0, i * 1000) for i in range(int(MAX_GAP_SECONDS) * 2 + 1)]
        kept, forced = _simulate(flat, 1.0, _scalar_distance)
        self.assertEqual(3, kept)  # the first sample and two forced writes
        self.assertEqual(2, forced)

    def test_a_forced_write_is_not_counted_as_movement(self):
        # A crossing that lands exactly on a gap boundary is movement, and
        # must not be reported as the gap keeping the series alive.
        moving = [(0.0, 0), (5.0, int(MAX_GAP_SECONDS) * 1000)]
        kept, forced = _simulate(moving, 1.0, _scalar_distance)
        self.assertEqual(2, kept)
        self.assertEqual(0, forced)

    def test_a_coordinate_is_simulated_as_one_group(self):
        # Two points 111.19 m apart pass a 100 m band and fail a 200 m one.
        points = [((0.0, 0.0), 0), ((0.001, 0.0), 1000)]
        self.assertEqual(2, _simulate(points, 100.0, _metres)[0])
        self.assertEqual(1, _simulate(points, 200.0, _metres)[0])

    def test_the_ground_distance_matches_a_known_short_step(self):
        self.assertAlmostEqual(111.19, _metres((0.0, 0.0), (0.001, 0.0)), places=1)
        # A degree of longitude shortens with the cosine of the latitude.
        self.assertAlmostEqual(
            55.60, _metres((60.0, 0.0), (60.0, 0.001)), places=1
        )


class TrackCodecTest(unittest.TestCase):
    """The Python side of the shared vectors.

    `testdata/track_cases.json` is the contract between Dart, Kotlin and this
    tool. Dart derives it, Kotlin asserts it, and until this class existed
    nothing here did: the codec was correct and unguarded, which is the state a
    drift is discovered in by whoever is unluckiest.
    """

    @classmethod
    def setUpClass(cls) -> None:
        root = Path(__file__).resolve().parents[2]
        cls.fixture = json.loads((root / "testdata" / "track_cases.json").read_text())
        cls.cases = cls.fixture["cases"]

    def _points(self, case) -> list[track_codec.TrackPoint]:
        return [
            track_codec.TrackPoint(
                latitude=p["lat"],
                longitude=p["lon"],
                t_seconds=p["t"],
                speed_kmh=p["speed"],
                altitude_m=p["alt"],
                protected=p.get("protected", False),
            )
            for p in case["points"]
        ]

    def test_declares_the_same_version_and_tolerance(self) -> None:
        self.assertEqual(self.fixture["encoding_version"], track_codec.TRACK_ENCODING_VERSION)
        self.assertEqual(self.fixture["tolerance_m"], track_codec.TRACK_SIMPLIFY_TOLERANCE_M)

    def test_encoding_every_case_reproduces_its_stored_vector(self) -> None:
        for case in self.cases:
            with self.subTest(case["name"]):
                row = track_codec.encode(self._points(case))
                stored = case["encoded"]
                self.assertEqual(row.encoding_version, stored["encoding_version"])
                self.assertEqual(row.point_count, stored["point_count"])
                self.assertEqual(row.t, stored["t"])
                self.assertEqual(row.path, stored["path"])
                self.assertEqual(row.speed, stored["speed"])
                self.assertEqual(row.alt, stored["alt"])

    def test_decoding_every_stored_vector_returns_the_points(self) -> None:
        # Declared precision is half a step, plus room for floating point.
        limits = (
            ("latitude", 0.5 / track_codec.TRACK_POLYLINE_FACTOR),
            ("longitude", 0.5 / track_codec.TRACK_POLYLINE_FACTOR),
            ("t_seconds", 0.5 / track_codec.TRACK_TIME_FACTOR),
            ("speed_kmh", 0.5 / track_codec.TRACK_SPEED_FACTOR),
            ("altitude_m", 0.5 / track_codec.TRACK_ALT_FACTOR),
        )
        for case in self.cases:
            with self.subTest(case["name"]):
                stored = case["encoded"]
                decoded = track_codec.decode(
                    track_codec.TrackRow(
                        encoding_version=stored["encoding_version"],
                        point_count=stored["point_count"],
                        t=stored["t"],
                        path=stored["path"],
                        speed=stored["speed"],
                        alt=stored["alt"],
                    )
                )
                want = self._points(case)
                self.assertEqual(len(decoded), len(want))
                for i, (got, exp) in enumerate(zip(decoded, want)):
                    for attr, limit in limits:
                        self.assertLessEqual(
                            abs(getattr(got, attr) - getattr(exp, attr)),
                            limit + 1e-9,
                            f"point {i} {attr}",
                        )

    def test_every_case_simplifies_to_its_stored_vector(self) -> None:
        for case in self.cases:
            with self.subTest(case["name"]):
                points = self._points(case)
                kept = track_codec.simplify(points, protected=case["protected"])
                self.assertEqual(
                    track_codec.indexes_in(kept, points), case["simplified_expected"]
                )

    def test_sections_cut_on_protected_indexes_join_to_the_whole(self) -> None:
        case = next(c for c in self.cases if c["name"] == "piecewise_equivalence_protected_cuts")
        points = self._points(case)
        whole = track_codec.simplify(points, protected=case["protected"])
        joined = track_codec.simplify_in_sections(
            points, case["piecewise_cuts"], protected=case["protected"]
        )
        self.assertTrue(case["piecewise_equal"])
        self.assertEqual(joined, whole)
        self.assertEqual(
            track_codec.indexes_in(joined, points), case["simplified_piecewise_expected"]
        )
        self.assertLess(len(whole), len(points))

    def test_sections_cut_anywhere_else_do_not(self) -> None:
        # Douglas-Peucker is not incremental. The counter-example lives in the
        # fixture so all three languages measure the difference, not assume it.
        case = next(c for c in self.cases if c["name"] == "piecewise_diverges_off_cut")
        points = self._points(case)
        whole = track_codec.simplify(points, protected=case["protected"])
        joined = track_codec.simplify_in_sections(
            points, case["piecewise_cuts"], protected=case["protected"]
        )
        self.assertFalse(case["piecewise_equal"])
        self.assertNotEqual(joined, whole)
        self.assertEqual(
            track_codec.indexes_in(joined, points), case["simplified_piecewise_expected"]
        )
        self.assertGreater(len(joined), len(whole))

    def test_the_decoder_refuses_a_version_it_does_not_know(self) -> None:
        case = next(c for c in self.cases if c["name"] == "equator_crossing")
        stored = case["encoded"]
        for version in (0, track_codec.TRACK_ENCODING_VERSION + 1, 99):
            with self.subTest(version=version):
                with self.assertRaises(track_codec.TrackDecodeException):
                    track_codec.decode(
                        track_codec.TrackRow(
                            encoding_version=version,
                            point_count=stored["point_count"],
                            t=stored["t"],
                            path=stored["path"],
                            speed=stored["speed"],
                            alt=stored["alt"],
                        )
                    )

    def test_a_short_array_fails_the_decode(self) -> None:
        case = next(c for c in self.cases if c["name"] == "equator_crossing")
        stored = case["encoded"]
        for field_name in ("t", "speed", "alt"):
            with self.subTest(field_name):
                kw = {k: list(stored[k]) for k in ("t", "speed", "alt")}
                kw[field_name] = kw[field_name][:-1]
                with self.assertRaises(track_codec.TrackDecodeException):
                    track_codec.decode(
                        track_codec.TrackRow(
                            encoding_version=stored["encoding_version"],
                            point_count=stored["point_count"],
                            path=stored["path"],
                            **kw,
                        )
                    )


def _track_db(rows: list[tuple], columns: tuple[str, ...] | None = None) -> sqlite3.Connection:
    """A snapshot holding a `track` table, for the lens tests."""
    cols = columns or tuple(track_lens.TRACK_COLUMNS[k] for k in
                            ("session", "version", "count", "t", "path", "speed", "alt"))
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.execute(f"create table {track_lens.TRACK_TABLE} ({', '.join(cols)})")
    conn.executemany(
        f"insert into {track_lens.TRACK_TABLE} values ({', '.join('?' * len(cols))})", rows
    )
    return conn


class TrackLensTest(unittest.TestCase):
    """What the lens prints, and what it refuses to print."""

    @classmethod
    def setUpClass(cls) -> None:
        root = Path(__file__).resolve().parents[2]
        cls.cases = json.loads((root / "testdata" / "track_cases.json").read_text())["cases"]

    def _case(self, name: str):
        return next(c for c in self.cases if c["name"] == name)

    _KEEP = object()

    def _row(self, name: str, session_id: str = "s1", version: object = _KEEP) -> tuple:
        # The sentinel is not None: None is a value this test has to be able to
        # store, because a NULL version is the case that matters most.
        enc = self._case(name)["encoded"]
        return (
            session_id,
            enc["encoding_version"] if version is self._KEEP else version,
            enc["point_count"],
            json.dumps(enc["t"]),
            enc["path"],
            json.dumps(enc["speed"]),
            json.dumps(enc["alt"]),
        )

    def _run(self, conn, session_id: str = "s1", status: str = "CLOSED") -> Report:
        report = Report(lens="track")
        session = Session(
            kind="trip",
            id=session_id,
            status=status,
            started_utc_millis=0,
            ended_utc_millis=1,
            row={},
        )
        track_lens.track(conn, session, report)
        return report

    def test_it_prints_every_fixture_case_it_is_given(self) -> None:
        for case in self.cases:
            if not case["points"]:
                continue
            with self.subTest(case["name"]):
                report = self._run(_track_db([self._row(case["name"])]))
                self.assertEqual(report.problems, [])
                self.assertEqual(len(report.table), len(case["points"]))
                first = case["points"][0]
                self.assertAlmostEqual(report.table[0]["lat"], round(first["lat"], 5), places=5)

    def test_it_reports_the_count_the_span_and_the_distance(self) -> None:
        report = self._run(_track_db([self._row("equator_crossing")]))
        labels = {f.label: f.value for f in report.findings}
        self.assertEqual(labels["point count"], 3)
        self.assertAlmostEqual(labels["span"], 25.0, places=3)
        self.assertGreater(labels["distance"], 0.0)

    def test_it_refuses_a_version_it_does_not_know(self) -> None:
        report = self._run(_track_db([self._row("equator_crossing", version=2)]))
        self.assertEqual(report.table, [])
        self.assertTrue(any("unknown encoding version 2" in p for p in report.problems))

    def test_a_missing_version_is_a_problem_not_the_current_one(self) -> None:
        # Assuming the current version here prints numbers that look right and
        # are not. Nothing about the row says which encoder wrote it.
        report = self._run(_track_db([self._row("equator_crossing", version=None)]))
        self.assertEqual(report.table, [])
        self.assertTrue(any("carries no encodingVersion" in p for p in report.problems))

    def test_a_snapshot_without_the_table_says_so(self) -> None:
        conn = sqlite3.connect(":memory:")
        conn.row_factory = sqlite3.Row
        report = self._run(conn)
        self.assertTrue(any("predates the Track format" in p for p in report.problems))

    def test_a_renamed_column_breaks_loudly_instead_of_being_guessed(self) -> None:
        cols = ("sessionId", "version", "pointCount", "t", "path", "speed", "alt")
        report = self._run(_track_db([self._row("equator_crossing")], columns=cols))
        self.assertEqual(report.table, [])
        self.assertTrue(any("missing encodingVersion" in p for p in report.problems))


if __name__ == "__main__":
    unittest.main()
