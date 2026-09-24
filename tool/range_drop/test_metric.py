"""Run with: python3 -m unittest tool.range_drop.test_metric"""

from __future__ import annotations

import unittest

from .metric import Trip, rolling_efficiency, summarise

DAY = 86_400_000


def trip(**overrides) -> Trip:
    base = dict(
        vehicle_id="v1",
        trip_id="t1",
        started_utc_millis=0,
        distance_km=25.0,
        car_range_start_km=266.0,
        car_range_end_km=226.0,
        range_lag_seconds=5.0,
    )
    base.update(overrides)
    return Trip(**base)


class TripMetric(unittest.TestCase):
    def test_scores_the_car_against_the_road(self):
        one = trip()
        self.assertAlmostEqual(one.car_drop_km, 40.0)
        self.assertAlmostEqual(one.car_error_km, 15.0)

    def test_recovered_range_is_a_negative_drop(self):
        one = trip(car_range_start_km=200, car_range_end_km=203, distance_km=2)
        self.assertAlmostEqual(one.car_drop_km, -3.0)
        self.assertAlmostEqual(one.car_error_km, -5.0)

    def test_the_app_line_needs_capacity_and_efficiency(self):
        without = trip(soc_start_percent=42.1, soc_end_percent=40.5)
        self.assertIsNone(without.app_drop_km)

        with_both = trip(
            soc_start_percent=50.0,
            soc_end_percent=40.0,
            efficiency_km_per_kwh=8.0,
            capacity_kwh=39.6,
        )
        # 10 points of a 39.6 kWh pack is 3.96 kWh, and 8 km/kWh of that is 31.68 km.
        self.assertAlmostEqual(with_both.app_drop_km, 31.68, places=2)

    def test_a_half_measured_trip_is_not_usable(self):
        self.assertFalse(trip(car_range_end_km=None).is_usable(1.0, None))
        self.assertFalse(trip(distance_km=0.4).is_usable(1.0, None))

    def test_the_lag_filter_only_applies_when_asked(self):
        stale = trip(range_lag_seconds=200.0)
        self.assertTrue(stale.is_usable(1.0, None))
        self.assertFalse(stale.is_usable(1.0, 60.0))
        self.assertFalse(trip(range_lag_seconds=None).is_usable(1.0, 60.0))


class Summarising(unittest.TestCase):
    def test_pools_the_ratio_over_distance_not_over_trips(self):
        summary = summarise(
            [
                trip(distance_km=10, car_range_start_km=100, car_range_end_km=88),
                trip(distance_km=90, car_range_start_km=100, car_range_end_km=10),
            ],
            side="car",
        )
        # 102 km of promise for 100 km of road: the long trip carries its weight.
        self.assertAlmostEqual(summary.ratio, 1.02)
        self.assertEqual(summary.faster_than_road, 1)
        self.assertEqual(summary.slower_than_road, 0)

    def test_a_trip_the_side_cannot_answer_for_is_left_out(self):
        trips = [
            trip(soc_start_percent=50, soc_end_percent=40, efficiency_km_per_kwh=8, capacity_kwh=39.6),
            trip(),
        ]
        self.assertEqual(summarise(trips, side="car").trips, 2)
        # The second trip has no app line; counting it would score it as perfect.
        self.assertEqual(summarise(trips, side="app").trips, 1)

    def test_no_scorable_trip_is_no_summary(self):
        self.assertIsNone(summarise([trip()], side="app"))
        self.assertIsNone(summarise([], side="car"))


class RollingEfficiency(unittest.TestCase):
    def test_prefers_the_seven_day_window(self):
        closed = [(1 * DAY, 100.0, 12.5), (20 * DAY, 100.0, 10.0)]
        ratio, days, count = rolling_efficiency(closed, at_millis=25 * DAY)
        self.assertAlmostEqual(ratio, 10.0)
        self.assertEqual((days, count), (7, 1))

    def test_falls_back_to_the_month_when_the_week_is_quiet(self):
        closed = [(1 * DAY, 100.0, 12.5)]
        ratio, days, count = rolling_efficiency(closed, at_millis=25 * DAY)
        self.assertAlmostEqual(ratio, 8.0)
        self.assertEqual((days, count), (30, 1))

    def test_a_trip_at_or_after_the_moment_is_not_history(self):
        closed = [(25 * DAY, 100.0, 10.0)]
        self.assertEqual(rolling_efficiency(closed, at_millis=25 * DAY), (None, None, 0))

    def test_an_implausible_ratio_is_refused(self):
        closed = [(1 * DAY, 1000.0, 1.0)]
        self.assertEqual(rolling_efficiency(closed, at_millis=2 * DAY), (None, None, 0))
