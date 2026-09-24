package com.timhss.capyenergy.telemetry.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

/**
 * One row per Session. Every write replaces.
 *
 * The minute tick rewrites the open Session's row and the close replaces it a
 * last time, so `REPLACE` on the primary key is the intended path rather than a
 * duplicate. There is no update-in-place: the arrays are rebuilt whole.
 */
@Dao
interface TrackDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsert(track: TrackEntity)

    @Query("SELECT * FROM track WHERE sessionId = :sessionId")
    fun forSession(sessionId: String): TrackEntity?

    @Query("SELECT * FROM track WHERE sessionId IN (:sessionIds)")
    fun forSessions(sessionIds: List<String>): List<TrackEntity>

    @Query("SELECT COUNT(*) FROM track")
    fun count(): Long

    @Query("SELECT COUNT(*) FROM track WHERE sessionId = :sessionId")
    fun countForSession(sessionId: String): Long

    @Query("DELETE FROM track WHERE sessionId IN (:sessionIds)")
    fun deleteBySessionIds(sessionIds: List<String>): Int

    @Query("DELETE FROM track WHERE sessionId NOT IN (SELECT id FROM session)")
    fun deleteOrphans(): Int

    /**
     * One page of the sync stream, oldest write first.
     *
     * The order is the write stamp and not the session, so a row rewritten
     * after the phone already took it moves back to the end of the queue and
     * is offered again. That is what carries the simplified path across after
     * the raw one: the close is a later write of the same primary key.
     */
    @Query(
        "SELECT * FROM track " +
            "WHERE updatedAtUtcMillis > :afterUpdatedAtUtcMillis " +
            "OR (updatedAtUtcMillis = :afterUpdatedAtUtcMillis AND sessionId > :afterSessionId) " +
            "ORDER BY updatedAtUtcMillis ASC, sessionId ASC LIMIT :limit"
    )
    fun syncPage(
        afterUpdatedAtUtcMillis: Long,
        afterSessionId: String,
        limit: Int
    ): List<TrackEntity>

    @Query(
        "SELECT COUNT(*) FROM track " +
            "WHERE updatedAtUtcMillis > :afterUpdatedAtUtcMillis " +
            "OR (updatedAtUtcMillis = :afterUpdatedAtUtcMillis AND sessionId > :afterSessionId)"
    )
    fun syncPendingCount(afterUpdatedAtUtcMillis: Long, afterSessionId: String): Long

    @Query("SELECT * FROM track WHERE dirty = 1 LIMIT :limit")
    fun dirtyTracks(limit: Int): List<TrackEntity>

    @Query("SELECT COUNT(*) FROM track WHERE dirty = 1")
    fun dirtyTrackCount(): Long

    @Query("UPDATE track SET dirty = 0 WHERE sessionId IN (:ids)")
    fun clearDirty(ids: List<String>): Int

    @Query("UPDATE track SET dirty = 1")
    fun markAllDirty(): Int
}
