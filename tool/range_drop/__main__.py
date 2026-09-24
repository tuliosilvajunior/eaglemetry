"""Range Drop over recorded history.

    python3 -m tool.range_drop snapshot dbpull/<name>.db
    python3 -m tool.range_drop cloud --by-vehicle

The snapshot reader scores both sides, because the capacity of that one car is
known. The cloud reader scores the car's readout only — see `from_cloud`.
"""

from __future__ import annotations

import argparse
import json

from .metric import Summary, Trip, summarise
from .sources import DEFAULT_CAPACITY_KWH, from_cloud, from_snapshot


def main() -> int:
    parser = argparse.ArgumentParser(prog="range_drop")
    sub = parser.add_subparsers(dest="source", required=True)

    snapshot = sub.add_parser("snapshot", help="one car, from a pulled database")
    snapshot.add_argument("path")
    snapshot.add_argument(
        "--capacity-kwh",
        type=float,
        default=DEFAULT_CAPACITY_KWH,
        help=f"pack capacity for the app line (default {DEFAULT_CAPACITY_KWH})",
    )

    cloud = sub.add_parser("cloud", help="every vehicle, from the cloud replica")
    cloud.add_argument("--url-file", default=".pgurl.pooler")

    for command in (snapshot, cloud):
        command.add_argument("--min-km", type=float, default=1.0)
        command.add_argument(
            "--max-lag",
            type=float,
            default=None,
            help="drop trips whose last range sample is older than this many "
            "seconds; the lag always understates the drop",
        )
        command.add_argument("--by-vehicle", action="store_true")
        command.add_argument("--json", action="store_true")

    args = parser.parse_args()
    trips = (
        from_snapshot(args.path, capacity_kwh=args.capacity_kwh)
        if args.source == "snapshot"
        else from_cloud(args.url_file)
    )
    usable = [t for t in trips if t.is_usable(args.min_km, args.max_lag)]

    if args.json:
        print(json.dumps(_as_dict(trips, usable, args), indent=2))
        return 0
    _print(trips, usable, args)
    return 0


def _sides(trips: list[Trip]) -> list[tuple[str, Summary]]:
    return [
        (name, summary)
        for name, summary in (("car", summarise(trips, side="car")), ("app", summarise(trips, side="app")))
        if summary is not None
    ]


def _print(trips: list[Trip], usable: list[Trip], args) -> None:
    print(f"{len(trips)} trips read, {len(usable)} usable "
          f"(>= {args.min_km:g} km" + (f", lag <= {args.max_lag:g} s)" if args.max_lag else ")"))
    if not usable:
        return

    print()
    print(f"{'':5} {'trips':>6} {'km':>8} {'drop':>8} {'ratio':>7} "
          f"{'mean':>7} {'median':>7} {'faster':>7} {'slower':>7}")
    for name, summary in _sides(usable):
        print(
            f"{name:5} {summary.trips:6d} {summary.distance_km:8.1f} {summary.drop_km:8.1f} "
            f"{summary.ratio:7.3f} {summary.mean_error_km:+7.2f} {summary.median_error_km:+7.2f} "
            f"{summary.faster_than_road:7d} {summary.slower_than_road:7d}"
        )
    print()
    print("ratio is kilometres of promised range spent per kilometre driven; 1.000 is honest.")
    print("faster/slower counts trips whose readout fell quicker or slower than the road.")

    if not args.by_vehicle:
        return
    print()
    for vehicle in sorted({t.vehicle_id for t in usable}):
        mine = [t for t in usable if t.vehicle_id == vehicle]
        summary = summarise(mine, side="car")
        if summary is None:
            continue
        print(f"  {vehicle}  {summary.trips:3d} trips  {summary.distance_km:7.1f} km  "
              f"ratio {summary.ratio:.3f}  mean {summary.mean_error_km:+.2f} km")


def _as_dict(trips: list[Trip], usable: list[Trip], args) -> dict:
    return {
        "read": len(trips),
        "usable": len(usable),
        "min_km": args.min_km,
        "max_lag_seconds": args.max_lag,
        "sides": {
            name: {
                "trips": s.trips,
                "distance_km": round(s.distance_km, 2),
                "drop_km": round(s.drop_km, 2),
                "ratio": round(s.ratio, 4) if s.ratio else None,
                "mean_error_km": round(s.mean_error_km, 3),
                "median_error_km": round(s.median_error_km, 3),
                "mean_absolute_error_km": round(s.mean_absolute_error_km, 3),
                "faster_than_road": s.faster_than_road,
                "slower_than_road": s.slower_than_road,
            }
            for name, s in _sides(usable)
        },
    }


if __name__ == "__main__":
    raise SystemExit(main())
