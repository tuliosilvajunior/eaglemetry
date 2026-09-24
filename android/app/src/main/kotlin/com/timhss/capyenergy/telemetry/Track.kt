package com.timhss.capyenergy.telemetry

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.asin
import kotlin.math.atan2
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Track format and codec, with shared vectors.
 *
 * One row per Session holding the drive as parallel arrays: time, position,
 * speed and altitude, one entry per point, plus the count and the encoding
 * version.
 *
 * See issue 174 and parent 173. Dart is the reference in
 * `packages/telemetry_core/lib/track.dart`; this file is byte-identical to it.
 */
const val TRACK_ENCODING_VERSION = 1
const val TRACK_POLYLINE_FACTOR = 1e5
const val TRACK_TIME_FACTOR = 1000
const val TRACK_SPEED_FACTOR = 10
const val TRACK_ALT_FACTOR = 10
const val TRACK_SIMPLIFY_TOLERANCE_M = 10.0

/**
 * One point of a drive, before encoding.
 */
data class TrackPoint(
    val latitude: Double,
    val longitude: Double,
    val tSeconds: Double,
    val speedKmh: Double,
    val altitudeM: Double,
    val protected: Boolean = false
)

/**
 * The row as it is stored and synced. One row per Session.
 *
 * The four arrays each carry exactly [pointCount] entries. A short array is a
 * failing decode, not a shifted map. The path string encodes [pointCount]
 * points as a Google polyline at 1e5.
 */
data class TrackRow(
    val encodingVersion: Int,
    val pointCount: Int,
    /** Seconds from session start, delta encoded as millis ints. */
    val t: List<Int>,
    /** Geometry as encoded polyline (1e5). Empty for zero points. */
    val path: String,
    /** km/h per point, tenth km/h absolute ints. */
    val speed: List<Int>,
    /** Metres per point, delta encoded as deci-metre ints. */
    val alt: List<Int>
)

class TrackDecodeException(message: String) : Exception(message)

/**
 * Codec for the Track: encode a path, decode it back, validate row shape.
 */
object TrackCodec {

    fun encode(points: List<TrackPoint>): TrackRow {
        val n = points.size
        if (n == 0) {
            return TrackRow(
                encodingVersion = TRACK_ENCODING_VERSION,
                pointCount = 0,
                t = emptyList(),
                path = "",
                speed = emptyList(),
                alt = emptyList()
            )
        }
        // t delta millis
        val tMillis = points.map { dartRound(it.tSeconds * TRACK_TIME_FACTOR) }
        val tDelta = mutableListOf<Int>()
        for (i in 0 until n) {
            if (i == 0) tDelta.add(tMillis[0].toInt())
            else tDelta.add((tMillis[i] - tMillis[i - 1]).toInt())
        }
        // alt delta deci-metres
        val altDeci = points.map { dartRound(it.altitudeM * TRACK_ALT_FACTOR) }
        val altDelta = mutableListOf<Int>()
        for (i in 0 until n) {
            if (i == 0) altDelta.add(altDeci[0].toInt())
            else altDelta.add((altDeci[i] - altDeci[i - 1]).toInt())
        }
        val speedTenth = points.map { dartRound(it.speedKmh * TRACK_SPEED_FACTOR).toInt() }
        val path = encodePolyline(points.map { Pair(it.latitude, it.longitude) })
        return TrackRow(
            encodingVersion = TRACK_ENCODING_VERSION,
            pointCount = n,
            t = tDelta,
            path = path,
            speed = speedTenth,
            alt = altDelta
        )
    }

    /**
     * Decodes a row back to points.
     *
     * Protection is not on the wire. Simplification happens once, before the
     * row is written, so a decoder has nothing left to protect. Every decoded
     * point comes back unprotected.
     */
    fun decode(row: TrackRow): List<TrackPoint> {
        if (row.encodingVersion != TRACK_ENCODING_VERSION) {
            throw TrackDecodeException(
                "unknown encoding version ${row.encodingVersion}, expected $TRACK_ENCODING_VERSION"
            )
        }
        if (row.t.size != row.pointCount) {
            throw TrackDecodeException("t length ${row.t.size} != point_count ${row.pointCount}")
        }
        if (row.speed.size != row.pointCount) {
            throw TrackDecodeException("speed length ${row.speed.size} != point_count ${row.pointCount}")
        }
        if (row.alt.size != row.pointCount) {
            throw TrackDecodeException("alt length ${row.alt.size} != point_count ${row.pointCount}")
        }
        val positions = decodePolyline(row.path)
        if (positions.size != row.pointCount) {
            throw TrackDecodeException("path point count ${positions.size} != point_count ${row.pointCount}")
        }
        if (row.pointCount == 0) return emptyList()
        // reconstruct cumulative millis and deci-alt
        val tMillis = mutableListOf<Long>()
        var cum = 0L
        for (d in row.t) {
            cum += d
            tMillis.add(cum)
        }
        val altDeci = mutableListOf<Long>()
        cum = 0L
        for (d in row.alt) {
            cum += d
            altDeci.add(cum)
        }
        val result = mutableListOf<TrackPoint>()
        for (i in 0 until row.pointCount) {
            val pos = positions[i]
            result.add(
                TrackPoint(
                    latitude = pos.first,
                    longitude = pos.second,
                    tSeconds = tMillis[i].toDouble() / TRACK_TIME_FACTOR,
                    speedKmh = row.speed[i].toDouble() / TRACK_SPEED_FACTOR,
                    altitudeM = altDeci[i].toDouble() / TRACK_ALT_FACTOR
                )
            )
        }
        return result
    }

    internal fun dartRound(value: Double): Long {
        return if (value >= 0) floor(value + 0.5).toLong() else ceil(value - 0.5).toLong()
    }
}

// ---------------------------------------------------------------------------
// Polyline codec at 1e5, Google algorithm.

internal fun encodePolyline(points: List<Pair<Double, Double>>): String {
    if (points.isEmpty()) return ""
    val out = StringBuilder()
    var prevLat = 0L
    var prevLon = 0L
    for (p in points) {
        val lat = TrackCodec.dartRound(p.first * TRACK_POLYLINE_FACTOR)
        val lon = TrackCodec.dartRound(p.second * TRACK_POLYLINE_FACTOR)
        val dLat = (lat - prevLat).toInt()
        val dLon = (lon - prevLon).toInt()
        encodeSignedNumber(dLat, out)
        encodeSignedNumber(dLon, out)
        prevLat = lat
        prevLon = lon
    }
    return out.toString()
}

internal fun decodePolyline(encoded: String): List<Pair<Double, Double>> {
    if (encoded.isEmpty()) return emptyList()
    val result = mutableListOf<Pair<Double, Double>>()
    var index = 0
    var lat = 0
    var lon = 0
    while (index < encoded.length) {
        val latResult = decodeSignedNumber(encoded, index)
        lat += latResult.first
        index = latResult.second
        val lonResult = decodeSignedNumber(encoded, index)
        lon += lonResult.first
        index = lonResult.second
        result.add(Pair(lat / TRACK_POLYLINE_FACTOR, lon / TRACK_POLYLINE_FACTOR))
    }
    return result
}

internal fun encodeSignedNumber(value: Int, out: StringBuilder) {
    var s = if (value < 0) (value shl 1).inv() else value shl 1
    while (s >= 0x20) {
        out.append(((0x20 or (s and 0x1f)) + 63).toChar())
        s = s shr 5
    }
    out.append((s + 63).toChar())
}

/** Returns Pair(value, nextIndex) */
internal fun decodeSignedNumber(encoded: String, start: Int): Pair<Int, Int> {
    var result = 0
    var shift = 0
    var index = start
    var b: Int
    do {
        if (index >= encoded.length) {
            throw TrackDecodeException("truncated polyline")
        }
        b = encoded[index++].code - 63
        result = result or ((b and 0x1f) shl shift)
        shift += 5
    } while (b >= 0x20)
    val delta = if ((result and 1) != 0) (result shr 1).inv() else result shr 1
    return Pair(delta, index)
}

// ---------------------------------------------------------------------------
// Simplification: Douglas-Peucker at TRACK_SIMPLIFY_TOLERANCE_M.
// Never removes first, last, or protected.

object TrackSimplifier {

    /**
     * Simplifies [points], keeping the first, the last, and every protected
     * point.
     *
     * A point counts as protected when its own [TrackPoint.protected] flag is
     * set or when [protected] marks its index. The two are a union: a list
     * never disarms a flag the point carries.
     *
     * The path is cut at every protected index and each section is simplified
     * on its own. That is what makes a whole path and the same path assembled
     * from sections cut at protected indexes give the same result. Cuts that
     * fall anywhere else do not hold that equality: Douglas-Peucker is not
     * incremental.
     */
    fun simplify(
        points: List<TrackPoint>,
        toleranceM: Double = TRACK_SIMPLIFY_TOLERANCE_M,
        protected: List<Boolean>? = null
    ): List<TrackPoint> {
        if (points.size <= 2) return points.toList()
        val n = points.size
        val isProtected = MutableList(n) { false }
        isProtected[0] = true
        isProtected[n - 1] = true
        for (i in 0 until n) {
            if (points[i].protected) isProtected[i] = true
        }
        if (protected != null) {
            for (i in 0 until n) {
                if (i < protected.size && protected[i]) isProtected[i] = true
            }
        }
        val protectedIndexes = mutableListOf<Int>()
        for (i in 0 until n) if (isProtected[i]) protectedIndexes.add(i)
        val result = mutableListOf<TrackPoint>()
        for (k in 0 until protectedIndexes.size - 1) {
            val a = protectedIndexes[k]
            val b = protectedIndexes[k + 1]
            val segment = points.subList(a, b + 1)
            val simplified = douglasPeucker(segment, toleranceM)
            if (result.isEmpty()) result.addAll(simplified)
            else result.addAll(simplified.subList(1, simplified.size))
        }
        return result
    }

    /**
     * Splits [points] at [cuts], simplifies each section on its own, and joins
     * the results, dropping the joint point each section repeats.
     *
     * [cuts] holds indexes into [points]; the first must be 0 and the last
     * must be the last index.
     */
    fun simplifyInSections(
        points: List<TrackPoint>,
        cuts: List<Int>,
        toleranceM: Double = TRACK_SIMPLIFY_TOLERANCE_M,
        protected: List<Boolean>? = null
    ): List<TrackPoint> {
        val joined = mutableListOf<TrackPoint>()
        for (k in 0 until cuts.size - 1) {
            val a = cuts[k]
            val b = cuts[k + 1]
            val section = simplify(
                points.subList(a, b + 1),
                toleranceM = toleranceM,
                protected = protected?.subList(a, b + 1)
            )
            if (joined.isEmpty()) joined.addAll(section)
            else joined.addAll(section.subList(1, section.size))
        }
        return joined
    }

    /**
     * Indexes of [kept] within [all], matched by position, not by value.
     */
    fun indexesIn(kept: List<TrackPoint>, all: List<TrackPoint>): List<Int> {
        val out = mutableListOf<Int>()
        var cursor = 0
        for (p in kept) {
            while (cursor < all.size && all[cursor] != p) {
                cursor++
            }
            if (cursor == all.size) {
                throw IllegalStateException("kept point is not in the original path: $p")
            }
            out.add(cursor)
            cursor++
        }
        return out
    }

    private fun douglasPeucker(
        pts: List<TrackPoint>,
        toleranceM: Double
    ): List<TrackPoint> {
        if (pts.size <= 2) return pts.toList()
        var maxDist = -1.0
        var maxIndex = -1
        val first = pts.first()
        val last = pts.last()
        for (i in 1 until pts.size - 1) {
            val d = perpDistanceM(pts[i], first, last)
            if (d > maxDist) {
                maxDist = d
                maxIndex = i
            }
        }
        if (maxDist > toleranceM && maxIndex != -1) {
            val left = douglasPeucker(pts.subList(0, maxIndex + 1), toleranceM)
            val right = douglasPeucker(pts.subList(maxIndex, pts.size), toleranceM)
            return left.subList(0, left.size - 1) + right
        }
        return listOf(pts.first(), pts.last())
    }

    internal fun perpDistanceM(p: TrackPoint, a: TrackPoint, b: TrackPoint): Double {
        if (a.latitude == b.latitude && a.longitude == b.longitude) {
            return haversineM(a.latitude, a.longitude, p.latitude, p.longitude)
        }
        val r = 6371000.0
        val d13 = haversineM(a.latitude, a.longitude, p.latitude, p.longitude)
        if (d13 == 0.0) return 0.0
        val theta12 = bearing(a.latitude, a.longitude, b.latitude, b.longitude)
        val theta13 = bearing(a.latitude, a.longitude, p.latitude, p.longitude)
        var crossArg = sin(d13 / r) * sin(theta13 - theta12)
        crossArg = crossArg.coerceIn(-1.0, 1.0)
        val cross = abs(asin(crossArg)) * r
        val cosCross = cos(cross / r)
        if (abs(cosCross) < 1e-12) return cross
        val cosD13 = cos(d13 / r)
        var at = kotlin.math.acos((cosD13 / cosCross).coerceIn(-1.0, 1.0)) * r
        val deltaTheta = abs(theta13 - theta12)
        if (deltaTheta > PI / 2 && deltaTheta < 3 * PI / 2) {
            at = -at
        }
        if (at < 0) return d13
        val segLen = haversineM(a.latitude, a.longitude, b.latitude, b.longitude)
        if (at > segLen) return haversineM(b.latitude, b.longitude, p.latitude, p.longitude)
        return cross
    }

    internal fun haversineM(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val r = 6371000.0
        val p1 = lat1 * PI / 180.0
        val p2 = lat2 * PI / 180.0
        val dLat = (lat2 - lat1) * PI / 180.0
        val dLon = (lon2 - lon1) * PI / 180.0
        val a = sin(dLat / 2) * sin(dLat / 2) +
            cos(p1) * cos(p2) * sin(dLon / 2) * sin(dLon / 2)
        val c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return r * c
    }

    internal fun bearing(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val p1 = lat1 * PI / 180.0
        val p2 = lat2 * PI / 180.0
        val dLon = (lon2 - lon1) * PI / 180.0
        val y = sin(dLon) * cos(p2)
        val x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dLon)
        return atan2(y, x)
    }
}
