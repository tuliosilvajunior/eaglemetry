package com.timhss.capyenergy.telemetry.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction

@Dao
interface TripSegmentDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsertAll(segments: List<TripSegmentEntity>)

    @Query("SELECT * FROM trip_segments WHERE sessionId = :sessionId ORDER BY ordinal ASC")
    fun forSession(sessionId: String): List<TripSegmentEntity>

    @Query(
        "SELECT * FROM trip_segments WHERE sessionId IN (:sessionIds) " +
            "ORDER BY sessionId ASC, ordinal ASC"
    )
    fun forSessions(sessionIds: List<String>): List<TripSegmentEntity>

    @Query("SELECT COUNT(*) FROM trip_segments WHERE sessionId = :sessionId")
    fun countForSession(sessionId: String): Long

    @Query("DELETE FROM trip_segments WHERE sessionId = :sessionId")
    fun deleteBySessionId(sessionId: String): Int

    @Query("DELETE FROM trip_segments WHERE sessionId IN (:sessionIds)")
    fun deleteBySessionIds(sessionIds: List<String>): Int

    /**
     * Drops stretches whose trip is gone. They outlive frames on purpose, so
     * only the disappearance of the session itself retires them.
     */
    @Query(
        "DELETE FROM trip_segments WHERE sessionId NOT IN (SELECT id FROM session)"
    )
    fun deleteOrphans(): Int

    @Transaction
    fun replaceForSession(sessionId: String, segments: List<TripSegmentEntity>) {
        deleteBySessionId(sessionId)
        if (segments.isNotEmpty()) upsertAll(segments)
    }
}
