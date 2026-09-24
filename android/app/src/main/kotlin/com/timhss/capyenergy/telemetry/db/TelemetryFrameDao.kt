package com.timhss.capyenergy.telemetry.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

@Dao
interface TelemetryFrameDao {
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    fun insert(frame: TelemetryFrameEntity)

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    fun insertAll(frames: List<TelemetryFrameEntity>)

    @Query("SELECT * FROM telemetry_frames ORDER BY elapsedRealtimeNanos DESC LIMIT :limit")
    fun latest(limit: Int): List<TelemetryFrameEntity>

    @Query(
        "SELECT * FROM telemetry_frames " +
            "WHERE sessionId = :sessionId " +
            "ORDER BY elapsedRealtimeNanos ASC LIMIT :limit"
    )
    fun latestForSession(sessionId: String, limit: Int): List<TelemetryFrameEntity>

    @Query(
        "SELECT * FROM telemetry_frames " +
            "WHERE sessionId = :sessionId " +
            "ORDER BY elapsedRealtimeNanos DESC LIMIT 1"
    )
    fun lastForSession(sessionId: String): TelemetryFrameEntity?

    @Query("SELECT COUNT(*) FROM telemetry_frames")
    fun count(): Long

    @Query("SELECT COUNT(*) FROM telemetry_frames WHERE sessionId = :sessionId")
    fun countForSession(sessionId: String): Long

    @Query("UPDATE telemetry_frames SET sessionId = :targetSessionId WHERE sessionId IN (:sourceSessionIds)")
    fun reassignSessions(sourceSessionIds: List<String>, targetSessionId: String): Int

    /**
     * One page of the aggregation sweep, keyset-paged like the detail queries.
     *
     * Replaces a `SELECT` of the whole session: finalization and retention used to
     * hold every row of a session in memory to fold over it, which on a long trip
     * meant thousands of rows, and in the finalizer's case meant holding them while
     * the write transaction was open.
     */
    @Query(
        "SELECT id, elapsedRealtimeNanos, wallTimeUtcMillis, speedKmh, socPercent, odometerKm, " +
            "voltageV, currentA, powerKw, freshnessMask, " +
            "canDrivePowerKw, canPackVoltageV, canPackCurrentA, " +
            "ambientTempC, latitude, longitude, altitudeM " +
            "FROM telemetry_frames " +
            "WHERE sessionId = :sessionId AND elapsedRealtimeNanos > 0 " +
            "AND (elapsedRealtimeNanos > :afterElapsedNanos " +
            "OR (elapsedRealtimeNanos = :afterElapsedNanos AND id > :afterId)) " +
            "ORDER BY elapsedRealtimeNanos ASC, id ASC LIMIT :limit"
    )
    fun aggregatePage(
        sessionId: String,
        afterElapsedNanos: Long,
        afterId: Long,
        limit: Int
    ): List<SessionAggregateSampleRow>

    /**
     * The same page, ordered by insertion instead of by the elapsed clock.
     *
     * For a session that outlived a reboot, `elapsedRealtimeNanos` restarts
     * mid-session, so ordering by it interleaves two boots and puts the later
     * frames first. `id` is assigned by the single write thread in the order
     * frames were built, which stays chronological across the reset. This costs a
     * sort — the ordinary paths keep the composite index — and only sessions
     * flagged by [com.timhss.capyenergy.telemetry.SessionTimeline] pay it.
     */
    @Query(
        "SELECT id, elapsedRealtimeNanos, wallTimeUtcMillis, speedKmh, socPercent, odometerKm, " +
            "voltageV, currentA, powerKw, freshnessMask, " +
            "canDrivePowerKw, canPackVoltageV, canPackCurrentA, " +
            "ambientTempC, latitude, longitude, altitudeM " +
            "FROM telemetry_frames " +
            "WHERE sessionId = :sessionId AND elapsedRealtimeNanos > 0 AND id > :afterId " +
            "ORDER BY id ASC LIMIT :limit"
    )
    fun aggregatePageByInsertion(
        sessionId: String,
        afterId: Long,
        limit: Int
    ): List<SessionAggregateSampleRow>

    @Query(
        "SELECT COUNT(*) AS totalCount, MIN(elapsedRealtimeNanos) AS firstElapsedNanos, " +
            "MAX(elapsedRealtimeNanos) AS lastElapsedNanos FROM telemetry_frames " +
            "WHERE sessionId = :sessionId AND elapsedRealtimeNanos > 0"
    )
    fun sessionFrameBounds(sessionId: String): SessionFrameBounds

    /** Chart bounds on the wall clock, for a session that spans a reboot. */
    @Query(
        "SELECT COUNT(*) AS totalCount, MIN(wallTimeUtcMillis) AS firstWallUtcMillis, " +
            "MAX(wallTimeUtcMillis) AS lastWallUtcMillis FROM telemetry_frames " +
            "WHERE sessionId = :sessionId AND elapsedRealtimeNanos > 0"
    )
    fun sessionWallBounds(sessionId: String): SessionWallBounds

    /**
     * Middle value of `wall - elapsed` over the session, in milliseconds.
     *
     * Inside one boot a session has a single clock offset, and this is it. The
     * head unit boots without a time reference and corrects itself later, so
     * individual frames can carry a wall stamp that is hours or years away from
     * the rest. A median does not move for those; `MIN(wallTimeUtcMillis)` gave
     * the whole axis to the worst one. See [SessionClockAnchor], which holds the
     * same fold for callers that already have the offsets in memory.
     */
    @Query(
        "SELECT wallTimeUtcMillis - elapsedRealtimeNanos / 1000000 FROM telemetry_frames " +
            "WHERE sessionId = :sessionId AND elapsedRealtimeNanos > 0 " +
            "ORDER BY wallTimeUtcMillis - elapsedRealtimeNanos / 1000000 ASC " +
            "LIMIT 1 OFFSET (SELECT COUNT(*) / 2 FROM telemetry_frames " +
            "WHERE sessionId = :sessionId AND elapsedRealtimeNanos > 0)"
    )
    fun sessionMedianClockOffsetMillis(sessionId: String): Long?

    @Query(
        "SELECT id, elapsedRealtimeNanos, wallTimeUtcMillis, speedKmh, socPercent, odometerKm, " +
            "ambientTempC, latitude, longitude, altitudeM, gpsAccuracyM, " +
            "canDrivePowerKw, canPackVoltageV, canPackCurrentA FROM telemetry_frames " +
            "WHERE sessionId = :sessionId AND elapsedRealtimeNanos > 0 " +
            "AND (elapsedRealtimeNanos > :afterElapsedNanos " +
            "OR (elapsedRealtimeNanos = :afterElapsedNanos AND id > :afterId)) " +
            "ORDER BY elapsedRealtimeNanos ASC, id ASC LIMIT :limit"
    )
    fun tripDetailPage(
        sessionId: String,
        afterElapsedNanos: Long,
        afterId: Long,
        limit: Int
    ): List<TripDetailFrameRow>

    /** See [aggregatePageByInsertion]. */
    @Query(
        "SELECT id, elapsedRealtimeNanos, wallTimeUtcMillis, speedKmh, socPercent, odometerKm, " +
            "ambientTempC, latitude, longitude, altitudeM, gpsAccuracyM, " +
            "canDrivePowerKw, canPackVoltageV, canPackCurrentA FROM telemetry_frames " +
            "WHERE sessionId = :sessionId AND elapsedRealtimeNanos > 0 AND id > :afterId " +
            "ORDER BY id ASC LIMIT :limit"
    )
    fun tripDetailPageByInsertion(
        sessionId: String,
        afterId: Long,
        limit: Int
    ): List<TripDetailFrameRow>

    @Query(
        "SELECT id, elapsedRealtimeNanos, wallTimeUtcMillis, socPercent, voltageV, currentA, " +
            "powerKw, freshnessMask " +
            "FROM telemetry_frames WHERE sessionId = :sessionId AND elapsedRealtimeNanos > 0 " +
            "AND (elapsedRealtimeNanos > :afterElapsedNanos " +
            "OR (elapsedRealtimeNanos = :afterElapsedNanos AND id > :afterId)) " +
            "ORDER BY elapsedRealtimeNanos ASC, id ASC LIMIT :limit"
    )
    fun chargeDetailPage(
        sessionId: String,
        afterElapsedNanos: Long,
        afterId: Long,
        limit: Int
    ): List<ChargeDetailFrameRow>

    /** See [aggregatePageByInsertion]. */
    @Query(
        "SELECT id, elapsedRealtimeNanos, wallTimeUtcMillis, socPercent, voltageV, currentA, " +
            "powerKw, freshnessMask " +
            "FROM telemetry_frames WHERE sessionId = :sessionId AND elapsedRealtimeNanos > 0 " +
            "AND id > :afterId ORDER BY id ASC LIMIT :limit"
    )
    fun chargeDetailPageByInsertion(
        sessionId: String,
        afterId: Long,
        limit: Int
    ): List<ChargeDetailFrameRow>

    @Query("SELECT MAX(id) FROM telemetry_frames")
    fun maxId(): Long?

    @Query(
        "SELECT EXISTS(SELECT 1 FROM telemetry_frames " +
            "WHERE id <= :maxId AND (latitude IS NOT NULL OR longitude IS NOT NULL) LIMIT 1)"
    )
    fun hasGps(maxId: Long): Boolean

    @Query(
        "SELECT * FROM telemetry_frames " +
            "WHERE sessionId = :sessionId " +
            "AND (wallTimeUtcMillis > :afterWallTimeUtcMillis " +
            "OR (wallTimeUtcMillis = :afterWallTimeUtcMillis AND id > :afterId)) " +
            "ORDER BY wallTimeUtcMillis ASC, id ASC LIMIT :limit"
    )
    fun framesSyncPage(
        sessionId: String,
        afterWallTimeUtcMillis: Long,
        afterId: Long,
        limit: Int
    ): List<TelemetryFrameEntity>

    /** How many frames [framesSyncPage] still has to give after this cursor. */
    @Query(
        "SELECT COUNT(*) FROM telemetry_frames " +
            "WHERE sessionId = :sessionId " +
            "AND (wallTimeUtcMillis > :afterWallTimeUtcMillis " +
            "OR (wallTimeUtcMillis = :afterWallTimeUtcMillis AND id > :afterId))"
    )
    fun framesSyncPendingCount(
        sessionId: String,
        afterWallTimeUtcMillis: Long,
        afterId: Long
    ): Long

    @Query("SELECT COUNT(*) FROM telemetry_frames WHERE wallTimeUtcMillis < :cutoffUtcMillis")
    fun countOlderThan(cutoffUtcMillis: Long): Long

    @Query("DELETE FROM telemetry_frames WHERE sessionId = :sessionId")
    fun deleteForSession(sessionId: String): Int

    @Query(
        "DELETE FROM telemetry_frames WHERE id IN (" +
            "SELECT id FROM telemetry_frames " +
            "WHERE sessionId IS NOT NULL " +
            "AND sessionId NOT IN (SELECT id FROM session) LIMIT :limit)"
    )
    fun deleteOrphanSessionFramesChunk(limit: Int): Int

    @Query(
        "DELETE FROM telemetry_frames WHERE id IN (" +
            "SELECT f.id FROM telemetry_frames f " +
            "LEFT JOIN session s ON s.id = f.sessionId " +
            "WHERE f.wallTimeUtcMillis < :cutoffUtcMillis " +
            "AND (f.sessionId IS NULL OR (s.id IS NOT NULL AND s.endedAtUtcMillis IS NOT NULL AND s.status != 'FINALIZATION_PENDING')) " +
            "LIMIT :limit)"
    )
    fun deleteOlderThanChunk(
        cutoffUtcMillis: Long,
        limit: Int
    ): Int

    /** Sessions whose frames are already past the cutoff, oldest first. */
    @Query(
        "SELECT DISTINCT f.sessionId FROM telemetry_frames f " +
            "LEFT JOIN session s ON s.id = f.sessionId " +
            "WHERE f.sessionId IS NOT NULL " +
            "AND f.wallTimeUtcMillis < :cutoffUtcMillis " +
            "AND (s.id IS NULL OR s.endedAtUtcMillis IS NULL OR s.status = 'FINALIZATION_PENDING') " +
            "LIMIT :limit"
    )
    fun sessionsBlockingRetention(
        cutoffUtcMillis: Long,
        limit: Int
    ): List<String>

    @Query(
        "SELECT DISTINCT s.id FROM session s " +
            "WHERE s.endedAtUtcMillis IS NOT NULL " +
            "AND s.endedAtUtcMillis < :cutoffUtcMillis " +
            "AND s.noLongerReducible = 0 " +
            "LIMIT :limit"
    )
    fun sessionsEligibleForNoLongerReducible(
        cutoffUtcMillis: Long,
        limit: Int
    ): List<String>
}
