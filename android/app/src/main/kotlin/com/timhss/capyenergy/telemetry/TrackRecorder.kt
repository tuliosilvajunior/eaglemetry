package com.timhss.capyenergy.telemetry

import android.util.Log
import com.timhss.capyenergy.telemetry.db.TrackEntity
import org.json.JSONArray

/**
 * Collects one Session's drive and hands out the row to store.
 *
 * Fed one point per written position group, so the Track holds exactly the
 * fixes the Sample series holds. The minute tick asks for [rawRow] and the
 * close asks for [closedRow].
 *
 * ## Raw during, simplified once
 *
 * The tick never simplifies and never drops a point. Douglas-Peucker is not
 * incremental: a section cannot know about the bend that follows it, so
 * simplifying each tick and joining the pieces gives a different path from
 * simplifying the whole drive once. Issue 174 carries both vectors, the pair
 * that agrees and the pair that does not, and `TrackRecorderTest` measures the
 * difference here rather than assuming it.
 *
 * ## Protection comes from the stored speed
 *
 * The first point, the last point and both ends of every stop survive
 * simplification. The stop ends are found by replaying [StopBand] over the
 * speeds **as the row stores them**, tenth of a km/h, not over the doubles that
 * arrived. That is deliberate: a process restart mid-drive reloads the points
 * by decoding the row that was already written, and only the quantized speed
 * comes back. Deriving from the quantized value makes the protected set the
 * same whether or not the app was restarted, instead of nearly the same.
 *
 * ## Not thread confined
 *
 * Points arrive on the receiver's tick and rows are asked for on the Roadcast
 * thread, so every entry point holds the same lock. The lists are copied out.
 */
internal class TrackRecorder {

    private val lock = Any()
    private var sessionId: String? = null
    private var baseWallMillis: Long = 0L
    private val points = mutableListOf<TrackPoint>()
    private var overflowed = false

    /**
     * True once a fix has reported a real altitude.
     *
     * The row carries one altitude per point, so a fix without one has to be
     * given a number. Holding the last known metre forward is what a reader of
     * a sparse series already does between rows. Before the first reading
     * there is nothing to hold, so those points are back-filled with it the
     * moment it arrives — otherwise the drive would open with a climb from
     * zero to whatever the ground really is, and `climbM` would carry it.
     */
    private var sawAltitude = false

    /** The session the held points belong to, or null when nothing is held. */
    fun currentSessionId(): String? = synchronized(lock) { sessionId }

    fun pointCount(): Int = synchronized(lock) { points.size }

    /**
     * Starts [id] at [startWallMillis], discarding anything held for another.
     *
     * [seed] is the row already stored for this session, if any. A process that
     * restarts mid-drive would otherwise rewrite the row on the next tick with
     * only the points taken since, throwing away the route it had already
     * recorded.
     */
    fun begin(id: String, startWallMillis: Long, seed: TrackEntity?) {
        synchronized(lock) {
            if (sessionId == id) return
            sessionId = id
            baseWallMillis = startWallMillis
            points.clear()
            overflowed = false
            sawAltitude = false
            if (seed != null) {
                try {
                    points.addAll(TrackCodec.decode(seed.toRow()))
                    // A stored point already carries a metre, held or measured.
                    sawAltitude = points.isNotEmpty()
                } catch (e: Exception) {
                    // A row this build cannot read is replaced, not trusted.
                    // Losing the earlier half of one route costs less than
                    // writing a path assembled from a format we misread.
                    Log.w(TAG, "Unreadable stored track for $id, starting the route over", e)
                    points.clear()
                    sawAltitude = false
                }
            }
        }
    }

    fun clear() {
        synchronized(lock) {
            sessionId = null
            points.clear()
            overflowed = false
            sawAltitude = false
        }
    }

    /**
     * Adds one fix. Returns false when the point was refused.
     *
     * A fix is refused when it belongs to another session, when its wall stamp
     * puts it outside [MAX_TRACK_SPAN_MILLIS] of the session start, or when the
     * session has already reached [MAX_POINTS].
     *
     * The time guard is not defensive noise. This head unit boots with no time
     * reference and corrects itself later, so single fixes carry stamps days or
     * years from their neighbours — three trips on 2026-08-14 each hold one
     * frame stamped 448 days back. `t` is stored as delta millis in an `Int`,
     * and 448 days of millis does not fit one. A stale stamp would not shift a
     * point on the map, it would corrupt the whole array.
     */
    fun add(
        id: String,
        wallMillis: Long,
        latitude: Double,
        longitude: Double,
        altitudeM: Double?,
        speedKmh: Double?
    ): Boolean = synchronized(lock) {
        if (sessionId != id) return false
        val offset = wallMillis - baseWallMillis
        if (offset < 0L || offset > MAX_TRACK_SPAN_MILLIS) return false
        if (points.size >= MAX_POINTS) {
            if (!overflowed) {
                overflowed = true
                Log.w(TAG, "Track for $id reached $MAX_POINTS points; later fixes are not in the route")
            }
            return false
        }
        if (altitudeM != null && !sawAltitude) {
            // The first metre this drive knows. Every point taken before it
            // was given a placeholder; give them this one, so the climb starts
            // counting at the ground and not at sea level.
            for (i in points.indices) points[i] = points[i].copy(altitudeM = altitudeM)
            sawAltitude = true
        }
        points.add(
            TrackPoint(
                latitude = latitude,
                longitude = longitude,
                tSeconds = offset / 1000.0,
                // Held forward, like the altitude beside it. The row carries
                // one speed per point and has no way to write "not measured",
                // so the last reading is the honest stand-in; a flat zero
                // would say the vehicle stopped, and the stop protection reads
                // this array back. Before any reading there is nothing to
                // hold: those points store zero, which protects the first
                // point — already protected — and no other.
                speedKmh = speedKmh ?: points.lastOrNull()?.speedKmh ?: 0.0,
                altitudeM = altitudeM ?: points.lastOrNull()?.altitudeM ?: 0.0
            )
        )
        return true
    }

    /** The row to store while the session runs: every point, none simplified. */
    fun rawRow(
        id: String,
        nowUtcMillis: Long = System.currentTimeMillis()
    ): TrackEntity? = synchronized(lock) {
        if (sessionId != id || points.isEmpty()) return null
        TrackCodec.encode(points.toList()).toEntity(id, nowUtcMillis)
    }

    /**
     * The raw row for the held session, but only while that session is open.
     *
     * [openSessionId] is the session the vehicle has open now. Nothing holds
     * the recorder to it: a fix from the next session replaces the held one,
     * and that arrives minutes after the close. A caller that asked for
     * [rawRow] in that window would write the raw points over the simplified
     * row the close had already stored, and the route would stay raw for the
     * rest of its life. Measured on the vehicle on 2026-08-28: three drives
     * stored 292, 212 and 87 points where the close had produced 56, 29 and
     * 13.
     *
     * So a held session that is no longer open is released, and no row comes
     * back. What the release costs is the points taken since the last tick,
     * which the close never saw either — it reads the stored row. Dropping
     * them is what makes the stored path agree with the `fixCount` and the
     * `climbM` stamped beside it.
     */
    fun rawRowWhileOpen(
        openSessionId: String?,
        nowUtcMillis: Long = System.currentTimeMillis()
    ): TrackEntity? = synchronized(lock) {
        val held = sessionId ?: return null
        if (held != openSessionId) {
            clear()
            return null
        }
        rawRow(held, nowUtcMillis)
    }

    /** The row and the three Session numbers, at close. Simplified once. */
    fun closedRow(
        id: String,
        nowUtcMillis: Long = System.currentTimeMillis()
    ): TrackClose? = synchronized(lock) {
        if (sessionId != id || points.isEmpty()) return null
        close(id, points.toList(), nowUtcMillis)
    }

    companion object {
        private const val TAG = "TrackRecorder"

        /** Seven days of millis. Fits an `Int` with room to spare. */
        const val MAX_TRACK_SPAN_MILLIS = 7L * 24 * 60 * 60 * 1000

        /**
         * About 2 000 km at the 20 m position band. A session this long is a
         * defect somewhere else; the cap is here so it cannot become an
         * out-of-memory on the head unit.
         *
         * The figure is not rounder than this on purpose. `VehicleProfileBoundaryTest`
         * sweeps files above layer 0 for pack figures written out instead of read
         * from the profile, and 200 000 is the top of `GeelyProfile.battery`'s
         * accepted capacity band. A cap that happens to spell a vehicle number
         * would either fail that sweep or buy an exemption for this whole file,
         * and the exemption is the expensive one: it would blind the sweep to a
         * real vendor constant landing here later.
         */
        const val MAX_POINTS = 100_000

        /**
         * Simplifies [raw] once and sums the three Session numbers from the
         * raw points, before anything is dropped.
         */
        fun close(
            id: String,
            raw: List<TrackPoint>,
            nowUtcMillis: Long = System.currentTimeMillis()
        ): TrackClose {
            val protectedFlags = protectionFrom(raw)
            val simplified = TrackSimplifier.simplify(raw, protected = protectedFlags)
            var climb = 0.0
            var descent = 0.0
            var previous: Double? = null
            for (p in raw) {
                previous?.let { before ->
                    val delta = p.altitudeM - before
                    if (delta > 0) climb += delta else descent -= delta
                }
                previous = p.altitudeM
            }
            return TrackClose(
                track = TrackCodec.encode(simplified).toEntity(id, nowUtcMillis),
                climbM = climb,
                descentM = descent,
                fixCount = raw.size
            )
        }

        /**
         * Which of [raw] are stop ends, judged on the speed as the row stores
         * it.
         *
         * Both ends: the point where the vehicle came to a stand, and the point
         * where it moved again. Marking only one would let simplification pull
         * the straight line through the other, and the stop would lose the
         * place it happened at.
         */
        fun protectionFrom(raw: List<TrackPoint>): List<Boolean> {
            val flags = MutableList(raw.size) { false }
            var standing: Boolean? = null
            for (i in raw.indices) {
                val stored = TrackCodec.dartRound(
                    raw[i].speedKmh * TRACK_SPEED_FACTOR
                ) / TRACK_SPEED_FACTOR.toDouble()
                if (StopBand.crosses(standing, stored)) flags[i] = true
                standing = StopBand.nextStanding(standing, stored)
            }
            return flags
        }
    }
}

/** What a close produces: the row to store and the numbers to stamp on the Session. */
internal data class TrackClose(
    val track: TrackEntity,
    val climbM: Double,
    val descentM: Double,
    val fixCount: Int
)

internal fun TrackRow.toEntity(
    sessionId: String,
    updatedAtUtcMillis: Long,
    accountId: String? = null
): TrackEntity = TrackEntity(
    sessionId = sessionId,
    encodingVersion = encodingVersion,
    pointCount = pointCount,
    t = intsToJson(t),
    path = path,
    speed = intsToJson(speed),
    alt = intsToJson(alt),
    updatedAtUtcMillis = updatedAtUtcMillis,
    accountId = accountId
)

internal fun TrackEntity.toRow(): TrackRow = TrackRow(
    encodingVersion = encodingVersion,
    pointCount = pointCount,
    t = jsonToInts(t),
    path = path,
    speed = jsonToInts(speed),
    alt = jsonToInts(alt)
)

internal fun intsToJson(values: List<Int>): String {
    val array = JSONArray()
    for (v in values) array.put(v)
    return array.toString()
}

internal fun jsonToInts(text: String): List<Int> {
    val array = JSONArray(text)
    val out = ArrayList<Int>(array.length())
    for (i in 0 until array.length()) out.add(array.getInt(i))
    return out
}
