package com.timhss.capyenergy.telemetry.db

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

/**
 * The drive of one Session as a single row.
 *
 * Slice 5 of issue 173, built by 178. The shape is fixed by the comment on 178
 * and read by `tool/telemetry_report/lenses/track.py`; changing a column name
 * here without changing it there fails a test in that harness.
 *
 * [t], [speed] and [alt] are JSON arrays of integers, each holding exactly
 * [pointCount] entries; [path] is the same [pointCount] positions as a Google
 * polyline at 1e5. A short array is a failing decode, never a shifted map —
 * `TrackCodec.decode` refuses it.
 *
 * The row is rewritten on the minute tick while the Session runs, holding the
 * points raw, and replaced once when the Session closes with the simplified
 * path. Douglas-Peucker is not incremental, so simplifying on each tick and
 * joining the pieces gives a different path from simplifying the whole drive
 * once — the vectors in issue 174 carry that pair. Raw during, simplified once
 * at the end, is the one deterministic answer.
 *
 * A Session that never closes keeps its raw row. That is the point: a vehicle
 * that loses power mid-drive still has the route up to the last minute.
 *
 * [updatedAtUtcMillis] is when this version of the row was written, and it is
 * the order the sync pages over. A session's own start cannot serve: the row
 * is rewritten every minute and once more at close, and a cursor over the
 * start would carry the raw path to the phone and never the simplified one
 * that replaced it. See issue 179.
 */
@Entity(
    tableName = "track",
    indices = [
        Index(value = ["updatedAtUtcMillis", "sessionId"]),
        Index(value = ["dirty", "sessionId"])
    ]
)
data class TrackEntity(
    @PrimaryKey val sessionId: String,
    val encodingVersion: Int,
    val pointCount: Int,
    val t: String,
    val path: String,
    val speed: String,
    val alt: String,
    val updatedAtUtcMillis: Long = 0L,
    val dirty: Boolean = true,
    val accountId: String? = null,
) {
    fun toMap(): Map<String, Any?> = toExportRow()
    fun toExportRow(): Map<String, Any?> = mapOf(
        "sessionId" to sessionId,
        "encodingVersion" to encodingVersion,
        "pointCount" to pointCount,
        "t" to t,
        "path" to path,
        "speed" to speed,
        "alt" to alt,
        "updatedAtUtcMillis" to updatedAtUtcMillis
    )
}
