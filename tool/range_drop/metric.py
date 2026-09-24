"""The Range Drop metric, over whatever source hands it trips.

The comparison the in-car panel makes live, made again over recorded history.
For one trip it is three numbers: the distance the odometer moved, the range
the car's readout gave up, and the range the app's own estimate gave up. The
ideal drop equals the distance; anything above it is a readout that was
promising more than the road could take.

Nothing here reads a database. `Trip` is the shape both sources produce, so the
metric cannot drift between the snapshot on the desk and the fleet in the
cloud.
"""

from __future__ import annotations

from dataclasses import dataclass
from statistics import median


@dataclass(frozen=True)
class Trip:
    """One closed trip, reduced to what the metric needs."""

    vehicle_id: str
    trip_id: str
    started_utc_millis: int
    distance_km: float | None
    car_range_start_km: float | None
    car_range_end_km: float | None

    #: Seconds between the last range sample and the end of the trip. The
    #: readout is written on a deadband, so a sample minutes old understates
    #: how far the range actually fell — the error this leaves is always in
    #: the dashboard's favour.
    range_lag_seconds: float | None

    #: SOC either side of the trip, for the app-side line. Absent for a
    #: vehicle whose pack capacity is unknown.
    soc_start_percent: float | None = None
    soc_end_percent: float | None = None

    #: km/kWh the app would have projected with, from the same rolling window
    #: the car uses. None when history was too thin to state one.
    efficiency_km_per_kwh: float | None = None
    capacity_kwh: float | None = None

    @property
    def car_drop_km(self) -> float | None:
        if self.car_range_start_km is None or self.car_range_end_km is None:
            return None
        return self.car_range_start_km - self.car_range_end_km

    @property
    def app_drop_km(self) -> float | None:
        """What the app's estimate gave up, or None when it cannot be stated.

        Pack capacity does not leave the car — it is a device setting, not a
        synced column — so this is None for every vehicle but the one whose
        capacity the caller knows.
        """
        if self.soc_start_percent is None or self.soc_end_percent is None:
            return None
        if self.efficiency_km_per_kwh is None or self.capacity_kwh is None:
            return None
        soc_drop = self.soc_start_percent - self.soc_end_percent
        return soc_drop / 100 * self.capacity_kwh * self.efficiency_km_per_kwh

    @property
    def car_error_km(self) -> float | None:
        drop = self.car_drop_km
        if drop is None or self.distance_km is None:
            return None
        return drop - self.distance_km

    @property
    def app_error_km(self) -> float | None:
        drop = self.app_drop_km
        if drop is None or self.distance_km is None:
            return None
        return drop - self.distance_km

    def is_usable(self, min_distance_km: float, max_lag_seconds: float | None) -> bool:
        if self.distance_km is None or self.distance_km < min_distance_km:
            return False
        if self.car_drop_km is None:
            return False
        if max_lag_seconds is None:
            return True
        return self.range_lag_seconds is not None and self.range_lag_seconds <= max_lag_seconds


@dataclass(frozen=True)
class Summary:
    """What a set of trips says about one readout."""

    trips: int
    distance_km: float
    drop_km: float
    mean_error_km: float | None
    median_error_km: float | None
    mean_absolute_error_km: float | None
    faster_than_road: int
    slower_than_road: int

    @property
    def ratio(self) -> float | None:
        """Kilometres of promise spent per kilometre driven. 1.0 is honest."""
        if self.distance_km <= 0:
            return None
        return self.drop_km / self.distance_km


def summarise(trips: list[Trip], *, side: str) -> Summary | None:
    """Pool `trips` for one side, `"car"` or `"app"`.

    A trip the side cannot answer for is left out rather than counted as zero:
    the app line is unavailable for most vehicles, and folding those in as
    perfect scores would be the one bias this whole exercise exists to avoid.
    """
    drop_of = (lambda t: t.car_drop_km) if side == "car" else (lambda t: t.app_drop_km)
    error_of = (lambda t: t.car_error_km) if side == "car" else (lambda t: t.app_error_km)

    scored = [t for t in trips if drop_of(t) is not None and t.distance_km is not None]
    if not scored:
        return None

    errors = [error_of(t) for t in scored]
    return Summary(
        trips=len(scored),
        distance_km=sum(t.distance_km for t in scored),
        drop_km=sum(drop_of(t) for t in scored),
        mean_error_km=sum(errors) / len(errors),
        median_error_km=median(errors),
        mean_absolute_error_km=sum(abs(e) for e in errors) / len(errors),
        faster_than_road=sum(1 for e in errors if e > 0),
        slower_than_road=sum(1 for e in errors if e < 0),
    )


def rolling_efficiency(
    closed: list[tuple[int, float, float]],
    at_millis: int,
    windows_days: tuple[int, ...] = (7, 30),
) -> tuple[float | None, int | None, int]:
    """The km/kWh the app would have held at `at_millis`.

    `closed` is `(ended_utc_millis, distance_km, net_kwh)` per finished trip.
    It mirrors `RangeEfficiencyRepository`: the first window that yields a
    plausible ratio wins, so a quiet week falls back to the month rather than
    leaving the estimate unavailable.

    This recomputes what the car's in-memory cache held. The cache refreshes on
    a 60-second tick, so a value here can be one tick fresher than the one the
    driver saw. It is not a reconstruction of the screen; it is the same
    function over the same rows.
    """
    for days in windows_days:
        floor = at_millis - days * 86_400_000
        distance = energy = 0.0
        qualifying = 0
        for ended, trip_distance, net_kwh in closed:
            if not (floor <= ended < at_millis):
                continue
            if net_kwh <= 0 or trip_distance <= 0:
                continue
            distance += trip_distance
            energy += net_kwh
            qualifying += 1
        if qualifying and energy > 0:
            ratio = distance / energy
            if MIN_EFFICIENCY_KM_PER_KWH <= ratio <= MAX_EFFICIENCY_KM_PER_KWH:
                return ratio, days, qualifying
    return None, None, 0


#: The same gates `RangeEfficiencyRepository` applies before it publishes a
#: ratio. A value outside them is a broken integral, not a frugal driver.
MIN_EFFICIENCY_KM_PER_KWH = 0.5
MAX_EFFICIENCY_KM_PER_KWH = 20.0
