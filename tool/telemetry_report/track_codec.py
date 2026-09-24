"""Track format and codec, with shared vectors.

One row per Session holding the drive as parallel arrays: time, position,
speed and altitude, one entry per point, plus the count and the encoding
version.

Dart is the reference in `packages/telemetry_core/lib/track.dart`; this file
is byte-identical to it. Kotlin mirrors it in
`android/app/src/main/kotlin/com/timhss/capyenergy/telemetry/Track.kt`.
"""

from __future__ import annotations

import math
from dataclasses import dataclass


TRACK_ENCODING_VERSION = 1
TRACK_POLYLINE_FACTOR = 1e5
TRACK_TIME_FACTOR = 1000
TRACK_SPEED_FACTOR = 10
TRACK_ALT_FACTOR = 10
TRACK_SIMPLIFY_TOLERANCE_M = 10.0


@dataclass(frozen=True)
class TrackPoint:
    latitude: float
    longitude: float
    t_seconds: float
    speed_kmh: float
    altitude_m: float
    protected: bool = False

    def to_json(self) -> dict:
        d: dict = {
            "lat": self.latitude,
            "lon": self.longitude,
            "t": self.t_seconds,
            "speed": self.speed_kmh,
            "alt": self.altitude_m,
        }
        if self.protected:
            d["protected"] = True
        return d

    @staticmethod
    def from_json(obj: dict) -> "TrackPoint":
        return TrackPoint(
            latitude=float(obj["lat"]),
            longitude=float(obj["lon"]),
            t_seconds=float(obj["t"]),
            speed_kmh=float(obj["speed"]),
            altitude_m=float(obj["alt"]),
            protected=bool(obj.get("protected", False)),
        )


@dataclass(frozen=True)
class TrackRow:
    encoding_version: int
    point_count: int
    t: list[int]
    path: str
    speed: list[int]
    alt: list[int]

    def to_json(self) -> dict:
        return {
            "encoding_version": self.encoding_version,
            "point_count": self.point_count,
            "t": list(self.t),
            "path": self.path,
            "speed": list(self.speed),
            "alt": list(self.alt),
        }

    @staticmethod
    def from_json(obj: dict) -> "TrackRow":
        return TrackRow(
            encoding_version=int(obj["encoding_version"]),
            point_count=int(obj["point_count"]),
            t=[int(x) for x in obj["t"]],
            path=str(obj["path"]),
            speed=[int(x) for x in obj["speed"]],
            alt=[int(x) for x in obj["alt"]],
        )


class TrackDecodeException(Exception):
    pass


# ---------------------------------------------------------------------------
# Dart round: ties away from zero, not Python's bankers rounding.

def _dart_round(value: float) -> int:
    if value >= 0:
        return int(math.floor(value + 0.5))
    return int(math.ceil(value - 0.5))


# ---------------------------------------------------------------------------
# Codec

def encode(points: list[TrackPoint]) -> TrackRow:
    n = len(points)
    if n == 0:
        return TrackRow(
            encoding_version=TRACK_ENCODING_VERSION,
            point_count=0,
            t=[],
            path="",
            speed=[],
            alt=[],
        )
    t_millis = [_dart_round(p.t_seconds * TRACK_TIME_FACTOR) for p in points]
    t_delta: list[int] = []
    for i in range(n):
        if i == 0:
            t_delta.append(int(t_millis[0]))
        else:
            t_delta.append(int(t_millis[i] - t_millis[i - 1]))
    alt_deci = [_dart_round(p.altitude_m * TRACK_ALT_FACTOR) for p in points]
    alt_delta: list[int] = []
    for i in range(n):
        if i == 0:
            alt_delta.append(int(alt_deci[0]))
        else:
            alt_delta.append(int(alt_deci[i] - alt_deci[i - 1]))
    speed_tenth = [_dart_round(p.speed_kmh * TRACK_SPEED_FACTOR) for p in points]
    path = _encode_polyline([(p.latitude, p.longitude) for p in points])
    return TrackRow(
        encoding_version=TRACK_ENCODING_VERSION,
        point_count=n,
        t=t_delta,
        path=path,
        speed=[int(x) for x in speed_tenth],
        alt=alt_delta,
    )


def decode(row: TrackRow) -> list[TrackPoint]:
    if row.encoding_version != TRACK_ENCODING_VERSION:
        raise TrackDecodeException(
            f"unknown encoding version {row.encoding_version}, expected {TRACK_ENCODING_VERSION}"
        )
    if len(row.t) != row.point_count:
        raise TrackDecodeException(f"t length {len(row.t)} != point_count {row.point_count}")
    if len(row.speed) != row.point_count:
        raise TrackDecodeException(
            f"speed length {len(row.speed)} != point_count {row.point_count}"
        )
    if len(row.alt) != row.point_count:
        raise TrackDecodeException(f"alt length {len(row.alt)} != point_count {row.point_count}")
    positions = _decode_polyline(row.path)
    if len(positions) != row.point_count:
        raise TrackDecodeException(
            f"path point count {len(positions)} != point_count {row.point_count}"
        )
    if row.point_count == 0:
        return []
    t_millis: list[int] = []
    cum = 0
    for d in row.t:
        cum += d
        t_millis.append(cum)
    alt_deci: list[int] = []
    cum = 0
    for d in row.alt:
        cum += d
        alt_deci.append(cum)
    result: list[TrackPoint] = []
    for i in range(row.point_count):
        lat, lon = positions[i]
        result.append(
            TrackPoint(
                latitude=lat,
                longitude=lon,
                t_seconds=t_millis[i] / TRACK_TIME_FACTOR,
                speed_kmh=row.speed[i] / TRACK_SPEED_FACTOR,
                altitude_m=alt_deci[i] / TRACK_ALT_FACTOR,
            )
        )
    return result


# ---------------------------------------------------------------------------
# Polyline codec at 1e5, Google algorithm.


def _encode_polyline(points: list[tuple[float, float]]) -> str:
    if not points:
        return ""
    out: list[str] = []
    prev_lat = 0
    prev_lon = 0
    for lat_f, lon_f in points:
        lat = _dart_round(lat_f * TRACK_POLYLINE_FACTOR)
        lon = _dart_round(lon_f * TRACK_POLYLINE_FACTOR)
        d_lat = int(lat - prev_lat)
        d_lon = int(lon - prev_lon)
        _encode_signed_number(d_lat, out)
        _encode_signed_number(d_lon, out)
        prev_lat = lat
        prev_lon = lon
    return "".join(out)


def _decode_polyline(encoded: str) -> list[tuple[float, float]]:
    if not encoded:
        return []
    result: list[tuple[float, float]] = []
    index = 0
    lat = 0
    lon = 0
    n = len(encoded)
    while index < n:
        d_lat, index = _decode_signed_number(encoded, index)
        lat += d_lat
        d_lon, index = _decode_signed_number(encoded, index)
        lon += d_lon
        result.append((lat / TRACK_POLYLINE_FACTOR, lon / TRACK_POLYLINE_FACTOR))
    return result


def _encode_signed_number(value: int, out: list[str]) -> None:
    s = ~(value << 1) if value < 0 else value << 1
    while s >= 0x20:
        out.append(chr((0x20 | (s & 0x1F)) + 63))
        s >>= 5
    out.append(chr(s + 63))


def _decode_signed_number(encoded: str, start: int) -> tuple[int, int]:
    result = 0
    shift = 0
    index = start
    n = len(encoded)
    b = 0
    while True:
        if index >= n:
            raise TrackDecodeException("truncated polyline")
        b = ord(encoded[index]) - 63
        index += 1
        result |= (b & 0x1F) << shift
        shift += 5
        if b < 0x20:
            break
    delta = ~(result >> 1) if (result & 1) else result >> 1
    return delta, index


# ---------------------------------------------------------------------------
# Simplification: Douglas-Peucker at TRACK_SIMPLIFY_TOLERANCE_M.


def simplify(
    points: list[TrackPoint],
    tolerance_m: float = TRACK_SIMPLIFY_TOLERANCE_M,
    protected: list[bool] | None = None,
) -> list[TrackPoint]:
    if len(points) <= 2:
        return list(points)
    n = len(points)
    is_protected = [False] * n
    is_protected[0] = True
    is_protected[n - 1] = True
    for i in range(n):
        if points[i].protected:
            is_protected[i] = True
    if protected is not None:
        for i in range(n):
            if i < len(protected) and protected[i]:
                is_protected[i] = True
    protected_indexes = [i for i, v in enumerate(is_protected) if v]
    result: list[TrackPoint] = []
    for k in range(len(protected_indexes) - 1):
        a = protected_indexes[k]
        b = protected_indexes[k + 1]
        segment = points[a : b + 1]
        simplified = _douglas_peucker(segment, tolerance_m)
        if not result:
            result.extend(simplified)
        else:
            result.extend(simplified[1:])
    return result


def simplify_in_sections(
    points: list[TrackPoint],
    cuts: list[int],
    tolerance_m: float = TRACK_SIMPLIFY_TOLERANCE_M,
    protected: list[bool] | None = None,
) -> list[TrackPoint]:
    joined: list[TrackPoint] = []
    for k in range(len(cuts) - 1):
        a = cuts[k]
        b = cuts[k + 1]
        sec_protected = None
        if protected is not None:
            sec_protected = protected[a : b + 1]
        section = simplify(points[a : b + 1], tolerance_m=tolerance_m, protected=sec_protected)
        if not joined:
            joined.extend(section)
        else:
            joined.extend(section[1:])
    return joined


def indexes_in(kept: list[TrackPoint], all_points: list[TrackPoint]) -> list[int]:
    out: list[int] = []
    cursor = 0
    n = len(all_points)
    for p in kept:
        while cursor < n and all_points[cursor] != p:
            cursor += 1
        if cursor == n:
            raise ValueError(f"kept point is not in the original path: {p}")
        out.append(cursor)
        cursor += 1
    return out


def _douglas_peucker(pts: list[TrackPoint], tolerance_m: float) -> list[TrackPoint]:
    if len(pts) <= 2:
        return list(pts)
    max_dist = -1.0
    max_index = -1
    first = pts[0]
    last = pts[-1]
    for i in range(1, len(pts) - 1):
        d = _perp_distance_m(pts[i], first, last)
        if d > max_dist:
            max_dist = d
            max_index = i
    if max_dist > tolerance_m and max_index != -1:
        left = _douglas_peucker(pts[: max_index + 1], tolerance_m)
        right = _douglas_peucker(pts[max_index:], tolerance_m)
        return left[:-1] + right
    return [pts[0], pts[-1]]


def _perp_distance_m(p: TrackPoint, a: TrackPoint, b: TrackPoint) -> float:
    if a.latitude == b.latitude and a.longitude == b.longitude:
        return _haversine_m(a.latitude, a.longitude, p.latitude, p.longitude)
    r = 6371000.0
    d13 = _haversine_m(a.latitude, a.longitude, p.latitude, p.longitude)
    if d13 == 0:
        return 0.0
    theta12 = _bearing(a.latitude, a.longitude, b.latitude, b.longitude)
    theta13 = _bearing(a.latitude, a.longitude, p.latitude, p.longitude)
    cross_arg = math.sin(d13 / r) * math.sin(theta13 - theta12)
    cross_arg = max(-1.0, min(1.0, cross_arg))
    cross = abs(math.asin(cross_arg)) * r
    cos_cross = math.cos(cross / r)
    if abs(cos_cross) < 1e-12:
        return cross
    cos_d13 = math.cos(d13 / r)
    at = math.acos(max(-1.0, min(1.0, cos_d13 / cos_cross))) * r
    delta_theta = abs(theta13 - theta12)
    if delta_theta > math.pi / 2 and delta_theta < 3 * math.pi / 2:
        at = -at
    if at < 0:
        return d13
    seg_len = _haversine_m(a.latitude, a.longitude, b.latitude, b.longitude)
    if at > seg_len:
        return _haversine_m(b.latitude, b.longitude, p.latitude, p.longitude)
    return cross


def _haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371000.0
    p1 = math.radians(lat1)
    p2 = math.radians(lat2)
    d_lat = math.radians(lat2 - lat1)
    d_lon = math.radians(lon2 - lon1)
    a = math.sin(d_lat / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(d_lon / 2) ** 2
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return r * c


def _bearing(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    p1 = math.radians(lat1)
    p2 = math.radians(lat2)
    d_lon = math.radians(lon2 - lon1)
    y = math.sin(d_lon) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(d_lon)
    return math.atan2(y, x)


def haversine_m(a: tuple[float, float], b: tuple[float, float]) -> float:
    return _haversine_m(a[0], a[1], b[0], b[1])
