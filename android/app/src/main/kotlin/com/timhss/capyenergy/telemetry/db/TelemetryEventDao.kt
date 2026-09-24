package com.timhss.capyenergy.telemetry.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

@Dao
interface TelemetryEventDao {
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    fun insert(event: TelemetryEventEntity)

    @Query("SELECT * FROM telemetry_events ORDER BY occurredAtElapsedNanos DESC LIMIT :limit")
    fun latest(limit: Int): List<TelemetryEventEntity>

    @Query(
        "SELECT * FROM telemetry_events WHERE sessionId = :sessionId ORDER BY occurredAtUtcMillis ASC, id ASC"
    )
    fun forSession(sessionId: String): List<TelemetryEventEntity>

    /**
     * Events in a window that belong to no session yet.
     *
     * A trip is back-dated to when movement began, so the rows between that
     * instant and the moment the detector opened the session are orphans that
     * belong to it. Only null rows are offered, so a session cannot take an
     * event that another one already holds.
     */
    @Query(
        "SELECT * FROM telemetry_events WHERE sessionId IS NULL " +
            "AND occurredAtUtcMillis >= :fromUtcMillis " +
            "AND occurredAtUtcMillis <= :toUtcMillis " +
            "ORDER BY occurredAtUtcMillis ASC"
    )
    fun orphansInWindow(fromUtcMillis: Long, toUtcMillis: Long): List<TelemetryEventEntity>

    @Query("UPDATE telemetry_events SET sessionId = :sessionId WHERE id IN (:eventIds)")
    fun backStampSession(sessionId: String, eventIds: List<Long>): Int

    @Query("SELECT * FROM telemetry_events WHERE id = :id LIMIT 1")
    fun findById(id: Long): TelemetryEventEntity?

    /**
     * Events of one type inside a session's window, oldest first.
     *
     * The event log is append-only and never passes through session-time
     * reconciliation, so it is the trustworthy record of when something
     * happened even where the session row's own timestamps were rewritten.
     */
    @Query(
        "SELECT * FROM telemetry_events WHERE `type` = :type " +
            "AND occurredAtUtcMillis >= :fromUtcMillis " +
            "AND occurredAtUtcMillis <= :toUtcMillis " +
            "ORDER BY occurredAtUtcMillis ASC"
    )
    fun byTypeInWindow(
        type: String,
        fromUtcMillis: Long,
        toUtcMillis: Long
    ): List<TelemetryEventEntity>

    @Query("SELECT COUNT(*) FROM telemetry_events")
    fun count(): Long

    @Query("SELECT MAX(id) FROM telemetry_events")
    fun maxId(): Long?

    @Query(
        "SELECT * FROM telemetry_events " +
            "WHERE id > :afterId ORDER BY id ASC LIMIT :limit"
    )
    fun syncPage(afterId: Long, limit: Int): List<TelemetryEventEntity>

    /** How many rows [syncPage] still has to give after this cursor. */
    @Query("SELECT COUNT(*) FROM telemetry_events WHERE id > :afterId")
    fun syncPendingCount(afterId: Long): Long

    @Query("SELECT COUNT(*) FROM telemetry_events WHERE occurredAtUtcMillis < :cutoffUtcMillis")
    fun countOlderThan(cutoffUtcMillis: Long): Long

    /**
     * Time authority G2: a PENDING session's wall stamps are not yet
     * trustworthy — a wrong stamp can make a young event look ancient (the
     * 2025 boot-default band). The session age purges already hold pending
     * sessions (`SessionDao.deleteOlderThan*`); the event purge must hold
     * their children too, or the cutoff eats them as "ultra-old". Once the
     * sweep resolves the session to `known`/`uncorrectable`, the corrected
     * stamp ages normally. The anti-join is uncorrelated (one pass over the
     * small session table per chunk); session-less rows keep the normal
     * path — they upload promptly and are deletable once synced.
     */
    @Query(
        "DELETE FROM telemetry_events WHERE id IN (" +
            "SELECT id FROM telemetry_events WHERE occurredAtUtcMillis < :cutoffUtcMillis AND dirty = 0 " +
            "AND (sessionId IS NULL OR sessionId NOT IN (SELECT id FROM session WHERE timeState = 'pending')) LIMIT :limit)"
    )
    fun deleteOlderThanChunk(cutoffUtcMillis: Long, limit: Int): Int

    @Query(
        "DELETE FROM telemetry_events WHERE id IN (" +
            "SELECT id FROM telemetry_events " +
            "WHERE occurredAtUtcMillis < :cutoffUtcMillis AND dirty = 0 AND id <= :floorId " +
            "AND (sessionId IS NULL OR sessionId NOT IN (SELECT id FROM session WHERE timeState = 'pending')) LIMIT :limit)"
    )
    fun deleteOlderThanConfirmedChunk(cutoffUtcMillis: Long, floorId: Long, limit: Int): Int

    @Query(
        "DELETE FROM telemetry_events WHERE id IN (" +
            "SELECT id FROM telemetry_events " +
            "WHERE sessionId IS NOT NULL " +
            "AND sessionId NOT IN (SELECT id FROM session) LIMIT :limit)"
    )
    fun deleteOrphanSessionEventsChunk(limit: Int): Int

    @Query("SELECT * FROM telemetry_events WHERE dirty = 1 ORDER BY id ASC LIMIT :limit")
    fun dirtyEvents(limit: Int): List<TelemetryEventEntity>

    @Query("SELECT COUNT(*) FROM telemetry_events WHERE dirty = 1")
    fun dirtyEventCount(): Long

    @Query("UPDATE telemetry_events SET dirty = 0 WHERE id IN (:ids)")
    fun clearDirty(ids: List<Long>): Int

    @Query("UPDATE telemetry_events SET dirty = 1")
    fun markAllDirty(): Int
}
