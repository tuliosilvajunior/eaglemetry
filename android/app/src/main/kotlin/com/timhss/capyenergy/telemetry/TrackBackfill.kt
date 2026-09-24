package com.timhss.capyenergy.telemetry

import android.content.ContentValues
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import androidx.sqlite.db.SupportSQLiteDatabase
import com.timhss.capyenergy.telemetry.db.TrackEntity
import kotlin.math.max

/**
 * Backfills a one-row Track and the three Session numbers for a session
 * recorded before issue 184, when the route lived in `sample` rows.
 *
 * Issue 184 moved the position tuple (latitude/longitude/altitude) out of
 * `sample` into `track`. Sessions recorded before it have no Track row, so the
 * fallback readers in `session_detail_reading.dart` used to walk their `sample`
 * rows. Issue 221 deletes that fallback, and this class makes sure nothing is
 * left to fall back for: schema 40 -> 41 runs a one-time backfill before the
 * `sample` table is dropped.
 *
 * The pairing rules mirror `packages/telemetry_core/lib/track_backfill.dart`,
 * the reference implementation this migration was tested against:
 * - a position tuple is paired by its shared `groupId`, or by timestamp when
 *   the group is missing,
 * - altitude and speed read at the fix's instant, zero-order held forward,
 * - climb/descent are summed from the raw points before simplification, and
 * - when no fix ever landed but altitude was measured, the climb still counts.
 */
object LegacyTrackBackfill {
    const val KEY_LATITUDE = "LATITUDE"
    const val KEY_LONGITUDE = "LONGITUDE"
    const val KEY_ALTITUDE = "ALTITUDE"
    const val KEY_SPEED = "VEHICLE_SPEED"

    const val VALIDITY_INVALID = "INVALID"

    /** One row of the pre-221 `sample` table, position keys only in practice. */
    data class SampleRow(
        val key: String,
        val value: Double?,
        val validity: String,
        val groupId: String?,
        val tUtcMillis: Long,
        val tElapsedNanos: Long
    )

    /** What the backfill produced for one session, or nothing when it had no route. */
    data class BackfillOutcome(
        val track: TrackEntity?,
        val climbM: Double,
        val descentM: Double,
        val fixCount: Int
    )

    /**
     * Reads position and speed rows for [sessionId] in write order.
     *
     * Reading raw SQL is deliberate: this runs inside the 40 -> 41 migration,
     * where the `sample` table still exists but the `SampleEntity` that mapped
     * it is gone from the schema.
     */
    fun readRows(db: SupportSQLiteDatabase, sessionId: String): List<SampleRow> {
        val out = mutableListOf<SampleRow>()
        db.query(
            "SELECT key, value, validity, groupId, tUtcMillis, tElapsedNanos " +
                "FROM sample WHERE sessionId = ? " +
                "ORDER BY tElapsedNanos ASC, id ASC",
            arrayOf(sessionId)
        ).use { cursor ->
            val colKey = cursor.getColumnIndexOrThrow("key")
            val colValue = cursor.getColumnIndexOrThrow("value")
            val colValidity = cursor.getColumnIndexOrThrow("validity")
            val colGroup = cursor.getColumnIndexOrThrow("groupId")
            val colUtc = cursor.getColumnIndexOrThrow("tUtcMillis")
            val colElapsed = cursor.getColumnIndexOrThrow("tElapsedNanos")
            while (cursor.moveToNext()) {
                val key = cursor.getString(colKey)
                if (key != KEY_LATITUDE &&
                    key != KEY_LONGITUDE &&
                    key != KEY_ALTITUDE &&
                    key != KEY_SPEED
                ) {
                    continue
                }
                out.add(
                    SampleRow(
                        key = key,
                        value = if (cursor.isNull(colValue)) null else cursor.getDouble(colValue),
                        validity = cursor.getString(colValidity),
                        groupId = if (cursor.isNull(colGroup)) null else cursor.getString(colGroup),
                        tUtcMillis = cursor.getLong(colUtc),
                        tElapsedNanos = cursor.getLong(colElapsed)
                    )
                )
            }
        }
        return out
    }

    /** The numeric value of [row], or null when the reading is invalid. */
    fun validValue(row: SampleRow): Double? = if (row.validity == VALIDITY_INVALID) null else row.value

    /**
     * Builds the raw drive from paired sample rows.
     *
     * Latitude and longitude are paired by `groupId`, with the elapsed-nanos
     * string as the timestamp fallback the old GPS writer shared. Altitude and
     * speed are read at each fix's instant, held forward from the last valid
     * reading, and a fix without both coordinates names no place and is
     * dropped, exactly as the position evaluator decided at write time. The
     * returned path is empty when no fix ever landed.
     */
    fun trackPoints(
        rows: List<SampleRow>,
        startedAtElapsedNanos: Long?,
        startedAtUtcMillis: Long?
    ): List<TrackPoint> {
        val latitudes = rows
            .filter { it.key == KEY_LATITUDE }
            .sortedBy { it.tElapsedNanos }
        val longitudes = rows.filter { it.key == KEY_LONGITUDE }
        if (latitudes.isEmpty() || longitudes.isEmpty()) return emptyList()

        val lonByGroup = HashMap<String, SampleRow>()
        for (point in longitudes) {
            val group = point.groupId ?: point.tElapsedNanos.toString()
            lonByGroup[group] = point
        }
        val altByGroup = HashMap<String, SampleRow>()
        val altitudeRows = rows.filter { it.key == KEY_ALTITUDE }
        for (point in altitudeRows) {
            val group = point.groupId ?: point.tElapsedNanos.toString()
            altByGroup[group] = point
        }

        val out = mutableListOf<TrackPoint>()
        val speedRows = rows.filter { it.key == KEY_SPEED }
        for (latPoint in latitudes) {
            val group = latPoint.groupId ?: latPoint.tElapsedNanos.toString()
            val lonPoint = lonByGroup[group]
            val lat = validValue(latPoint)
            val lon = lonPoint?.let { validValue(it) }
            if (lat == null || lon == null) continue

            val tSeconds = when {
                startedAtElapsedNanos != null -> max(
                    0.0,
                    (latPoint.tElapsedNanos - startedAtElapsedNanos) / 1e9
                )
                startedAtUtcMillis != null && latPoint.tUtcMillis > 0 -> max(
                    0.0,
                    (latPoint.tUtcMillis - startedAtUtcMillis) / 1000.0
                )
                else -> max(0.0, latPoint.tElapsedNanos / 1e9)
            }

            val alt = altByGroup[group]?.let { validValue(it) }
                ?: holdSampleValue(altitudeRows, latPoint.tElapsedNanos)
                ?: 0.0
            val speed = holdSampleValue(speedRows, latPoint.tElapsedNanos) ?: 0.0

            out.add(
                TrackPoint(
                    latitude = lat,
                    longitude = lon,
                    tSeconds = tSeconds,
                    speedKmh = speed,
                    altitudeM = alt
                )
            )
        }
        return out
    }

    /** Climb and descent summed over the raw points, before any simplification. */
    fun computeClimbDescent(points: List<TrackPoint>): Pair<Double, Double> {
        if (points.size < 2) return 0.0 to 0.0
        var climb = 0.0
        var descent = 0.0
        var previous: Double? = null
        for (p in points) {
            previous?.let { before ->
                val delta = p.altitudeM - before
                if (delta > 0) climb += delta else descent -= delta
            }
            previous = p.altitudeM
        }
        return climb to descent
    }

    /** Climb and descent from raw altitude rows, when no fix ever landed. */
    fun computeClimbDescentFromAltitudeSamples(rows: List<SampleRow>): Pair<Double, Double> {
        val valid = rows.filter { it.key == KEY_ALTITUDE }.mapNotNull { validValue(it) }
        if (valid.size < 2) return 0.0 to 0.0
        var climb = 0.0
        var descent = 0.0
        var previous: Double? = null
        for (value in valid) {
            previous?.let { before ->
                val delta = value - before
                if (delta > 0) climb += delta else descent -= delta
            }
            previous = value
        }
        return climb to descent
    }

    /**
     * The row to store for one session, and the numbers the Session carries.
     *
     * The track is simplified once, like every close, and the climb/descent
     * are summed from the raw points before anything is dropped. A session
     * that never got a fix gets no row; when it still measured altitude, the
     * climb and descent that follow from those readings are returned so the
     * session is stamped even though no track exists.
     */
    fun backfill(
        sessionId: String,
        raw: List<TrackPoint>,
        altitudeRows: List<SampleRow>,
        nowUtcMillis: Long
    ): BackfillOutcome {
        if (raw.isEmpty()) {
            val (climb, descent) = computeClimbDescentFromAltitudeSamples(altitudeRows)
            return BackfillOutcome(track = null, climbM = climb, descentM = descent, fixCount = 0)
        }

        val (climb, descent) = computeClimbDescent(raw)
        val protected = TrackRecorder.protectionFrom(raw)
        val simplified = TrackSimplifier.simplify(raw, protected = protected)
        val entity = TrackCodec.encode(simplified).toEntity(sessionId, nowUtcMillis)
        return BackfillOutcome(
            track = entity,
            climbM = climb,
            descentM = descent,
            fixCount = raw.size
        )
    }

    /** Zero-order hold of [points] at [elapsedNanos]. */
    private fun holdSampleValue(points: List<SampleRow>, elapsedNanos: Long): Double? {
        var held: Double? = null
        for (point in points) {
            if (point.tElapsedNanos > elapsedNanos) break
            val value = validValue(point)
            if (value != null) held = value
        }
        return held
    }
}

/**
 * The one-time 40 -> 41 backfill runner.
 *
 * Walks every session that still holds position rows, writes the Track row
 * and the Session numbers, and leaves the caller to drop the `sample` table.
 * Sessions that already have a Track row (recorded after issue 184) are
 * skipped; the Track is the primary source and is not rewritten.
 */
object BackfillTrackMigration {
    private const val TAG = "BackfillTrackMigration"

    private val POSITION_KEYS = arrayOf(
        LegacyTrackBackfill.KEY_LATITUDE,
        LegacyTrackBackfill.KEY_LONGITUDE,
        LegacyTrackBackfill.KEY_ALTITUDE,
        LegacyTrackBackfill.KEY_SPEED
    )

    /**
     * Runs inside the migration's own transaction. Every failure is logged and
     * moved past, because a session whose samples cannot be read must not take
     * the rest of the database down with it: the migration still drops
     * `sample`, and the design intent (no route left unreadable forever) is
     * served by the sessions that did read.
     */
    fun run(db: SupportSQLiteDatabase, nowUtcMillis: Long = System.currentTimeMillis()) {
        val now = nowUtcMillis
        val sessionIds = mutableListOf<String>()
        db.query(
            "SELECT DISTINCT sessionId FROM sample " +
                "WHERE sessionId IS NOT NULL AND key IN (?, ?, ?, ?) " +
                "ORDER BY sessionId",
            POSITION_KEYS
        ).use { cursor ->
            while (cursor.moveToNext()) {
                sessionIds.add(cursor.getString(0))
            }
        }

        for (sessionId in sessionIds) {
            try {
                backfillOne(db, sessionId, now)
            } catch (e: Exception) {
                // One unreadable session must not abort the migration. Its
                // route is lost with the `sample` table, which is the price
                // this backfill exists to avoid; the rest of the database
                // must go through unscathed.
                Log.w(TAG, "Backfill failed for $sessionId; leaving it without a Track", e)
            }
        }
    }

    private fun backfillOne(db: SupportSQLiteDatabase, sessionId: String, now: Long) {
        val hasTrack = db.query(
            "SELECT sessionId FROM track WHERE sessionId = ?",
            arrayOf(sessionId)
        ).use { cursor -> cursor.moveToFirst() }
        if (hasTrack) return

        val rows = LegacyTrackBackfill.readRows(db, sessionId)
        if (rows.isEmpty()) return

        val startedAtElapsedNanos: Long?
        val startedAtUtcMillis: Long?
        db.query(
            "SELECT startedAtElapsedNanos, startedAtUtcMillis FROM session WHERE id = ?",
            arrayOf(sessionId)
        ).use { cursor ->
            if (!cursor.moveToFirst()) return
            val colElapsed = cursor.getColumnIndexOrThrow("startedAtElapsedNanos")
            val colUtc = cursor.getColumnIndexOrThrow("startedAtUtcMillis")
            startedAtElapsedNanos = if (cursor.isNull(colElapsed)) null else cursor.getLong(colElapsed)
            startedAtUtcMillis = if (cursor.isNull(colUtc)) null else cursor.getLong(colUtc)
        }

        val raw = LegacyTrackBackfill.trackPoints(
            rows,
            startedAtElapsedNanos = startedAtElapsedNanos,
            startedAtUtcMillis = startedAtUtcMillis
        )
        val altitudeRows = rows.filter { it.key == LegacyTrackBackfill.KEY_ALTITUDE }
        val outcome = LegacyTrackBackfill.backfill(sessionId, raw, altitudeRows, now)

        if (outcome.track != null) {
            val values = ContentValues().apply {
                put("sessionId", outcome.track.sessionId)
                put("encodingVersion", outcome.track.encodingVersion)
                put("pointCount", outcome.track.pointCount)
                put("t", outcome.track.t)
                put("path", outcome.track.path)
                put("speed", outcome.track.speed)
                put("alt", outcome.track.alt)
                put("updatedAtUtcMillis", outcome.track.updatedAtUtcMillis)
            }
            db.insert("track", SQLiteDatabase.CONFLICT_REPLACE, values)
        }

        if (outcome.fixCount > 0 || outcome.climbM != 0.0 || outcome.descentM != 0.0) {
            val update = ContentValues().apply {
                put("climbM", outcome.climbM)
                put("descentM", outcome.descentM)
                put("fixCount", outcome.fixCount)
            }
            db.update("session", SQLiteDatabase.CONFLICT_NONE, update, "id = ?", arrayOf(sessionId))
        }
    }
}
