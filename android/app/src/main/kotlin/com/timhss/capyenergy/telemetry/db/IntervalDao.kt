package com.timhss.capyenergy.telemetry.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

@Dao
interface IntervalDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsertAll(intervals: List<IntervalEntity>)

    @Query(
        "SELECT * FROM interval WHERE sessionId = :sessionId " +
            "ORDER BY startUtcMillis ASC"
    )
    fun forSession(sessionId: String): List<IntervalEntity>

    @Query("SELECT COUNT(*) FROM interval WHERE sessionId = :sessionId")
    fun countForSession(sessionId: String): Long

    @Query(
        "SELECT DISTINCT sessionId FROM interval WHERE sessionId IN (:sessionIds)"
    )
    fun sessionsWithBuckets(sessionIds: List<String>): List<String>

    @Query(
        "SELECT * FROM interval WHERE sessionId IN (:sessionIds) " +
            "AND startUtcMillis >= :startUtcMillis AND startUtcMillis < :endUtcMillis " +
            "ORDER BY startUtcMillis ASC"
    )
    fun forSessionsInWindow(
        sessionIds: List<String>,
        startUtcMillis: Long,
        endUtcMillis: Long
    ): List<IntervalEntity>

    @Query("DELETE FROM interval WHERE sessionId IN (:sessionIds)")
    fun deleteBySessionIds(sessionIds: List<String>): Int

    @Query("SELECT * FROM interval WHERE sessionId = :sessionId AND startUtcMillis = :startUtcMillis LIMIT 1")
    fun findById(sessionId: String, startUtcMillis: Long): IntervalEntity?

    /**
     * `CONTINUOUS` is excluded: this stream is cursor-based and does not
     * otherwise filter by kind, so without this a `CONTINUOUS` session's
     * minutes would double the companion's interval volume. Issue 199.
     */
    @Query(
        "SELECT i.* FROM interval i " +
            "JOIN session s ON i.sessionId = s.id " +
            "WHERE s.endedAtUtcMillis IS NOT NULL AND s.status != 'FINALIZATION_PENDING' " +
            "AND s.kind != 'CONTINUOUS' " +
            "AND (i.startUtcMillis > :afterStartUtcMillis " +
            "OR (i.startUtcMillis = :afterStartUtcMillis AND i.sessionId > :afterSessionId)) " +
            "ORDER BY i.startUtcMillis ASC, i.sessionId ASC LIMIT :limit"
    )
    fun syncPage(
        afterStartUtcMillis: Long,
        afterSessionId: String,
        limit: Int
    ): List<IntervalEntity>

    @Query(
        "SELECT COUNT(*) FROM interval i " +
            "JOIN session s ON i.sessionId = s.id " +
            "WHERE s.endedAtUtcMillis IS NOT NULL AND s.status != 'FINALIZATION_PENDING' " +
            "AND s.kind != 'CONTINUOUS' " +
            "AND (i.startUtcMillis > :afterStartUtcMillis " +
            "OR (i.startUtcMillis = :afterStartUtcMillis AND i.sessionId > :afterSessionId))"
    )
    fun syncPendingCount(
        afterStartUtcMillis: Long,
        afterSessionId: String
    ): Long

    @Query("SELECT COUNT(*) FROM interval")
    fun count(): Long

    @Query("DELETE FROM interval WHERE sessionId NOT IN (SELECT id FROM session)")
    fun deleteOrphans(): Int

    /**
     * Finding 9: chunked orphan sweep. [deleteOrphans] deletes every orphan in
     * one statement; after a purge of months of continuous sessions that is
     * hundreds of thousands of rows under one write lock, ballooning the WAL
     * and stalling frame writes. Retention loops this instead, releasing the
     * lock and re-checking for an active session between chunks.
     */
    @Query(
        "DELETE FROM `interval` WHERE rowid IN (" +
            "SELECT rowid FROM `interval` " +
            "WHERE sessionId NOT IN (SELECT id FROM session) LIMIT :limit)"
    )
    fun deleteOrphansChunk(limit: Int): Int

    /**
     * Time authority T6: the uploader's row source — same hold as
     * `SessionDao.dirtySessions`. Pending minutes wait for the anchor here
     * instead of leaking a wrong `start_utc_millis` key to the cloud.
     */
    @Query("SELECT * FROM `interval` WHERE dirty = 1 AND timeState != 'pending' LIMIT :limit")
    fun dirtyIntervals(limit: Int): List<IntervalEntity>

    @Query("SELECT COUNT(*) FROM `interval` WHERE dirty = 1 AND timeState != 'pending'")
    fun dirtyIntervalCount(): Long

    @Query("SELECT COUNT(*) FROM `interval` WHERE dirty = 1 AND timeState = 'pending'")
    fun pendingIntervalCount(): Long

    @Query("UPDATE `interval` SET dirty = 0 WHERE sessionId = :sessionId AND startUtcMillis = :startUtcMillis")
    fun clearDirty(sessionId: String, startUtcMillis: Long): Int

    @Query("UPDATE `interval` SET dirty = 0 WHERE (sessionId || ':' || startUtcMillis) IN (:keys)")
    fun clearDirtyByKeys(keys: List<String>): Int

    @Query("UPDATE `interval` SET dirty = 1")
    fun markAllDirty(): Int

    @Query("UPDATE `interval` SET timeState = 'uncorrectable' WHERE timeState = 'pending' AND sessionId IN (SELECT id FROM session WHERE status = 'ENDED')")
    fun promoteEndedPendingToUncorrectable(): Int


    /** The boot's rows, paired first: the signature ledger's input. */
    @Query(
        "SELECT * FROM `interval` WHERE startBootCount = :bootCount " +
            "AND startElapsedNanos IS NOT NULL ORDER BY startElapsedNanos ASC"
    )
    fun forBoot(bootCount: Long): List<IntervalEntity>
    /**
     * Every paired row of every boot: the detector's census needs other
     * boots' stamps as witnesses, so the ledger folds the whole table.
     */
    @Query(
        "SELECT * FROM `interval` WHERE startElapsedNanos IS NOT NULL " +
            "ORDER BY startElapsedNanos ASC"
    )
    fun allPaired(): List<IntervalEntity>

    /**
     * The minutes a trusted anchor can still rewrite: every row carries the
     * boot's monotonic pair and is not yet resolved. Rows without the pair
     * (pre-T2 recordings) are not candidates — they have no axis to
     * subtract against, and a guess is forbidden.
     */
    @Query(
        "SELECT * FROM `interval` " +
            "WHERE startBootCount = :bootCount AND timeState != 'known' " +
            "AND startElapsedNanos IS NOT NULL " +
            "ORDER BY startElapsedNanos ASC"
    )
    fun pendingsForBoot(bootCount: Long): List<IntervalEntity>

    /** Removes one replaced key; the sweeper rewrites under the corrected one. */
    @Query("DELETE FROM `interval` WHERE sessionId = :sessionId AND startUtcMillis = :startUtcMillis")
    fun deleteKey(sessionId: String, startUtcMillis: Long): Int
}
