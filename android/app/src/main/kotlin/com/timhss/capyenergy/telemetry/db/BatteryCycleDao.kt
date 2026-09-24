package com.timhss.capyenergy.telemetry.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

@Dao
interface BatteryCycleDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsertAll(cycles: List<BatteryCycleEntity>)

    @Query("SELECT * FROM battery_cycles ORDER BY ordinal DESC LIMIT :limit")
    fun latest(limit: Int): List<BatteryCycleEntity>

    /**
     * The cycle a refresh rebuilds: the open one, or the newest closed one when
     * nothing is open. Either is a valid resume point.
     */
    @Query("SELECT * FROM battery_cycles ORDER BY ordinal DESC LIMIT 1")
    fun newest(): BatteryCycleEntity?

    @Query("SELECT * FROM battery_cycles WHERE isOpen = 1 ORDER BY ordinal DESC LIMIT 1")
    fun open(): BatteryCycleEntity?

    /**
     * The newest cycle that can still be rebuilt. A refresh resumes here, and it
     * rebuilds that cycle whether it is open or closed: a closed cycle stores
     * only the blend it opened with, so reproducing it is what carries the
     * blend forward into the cycle that follows.
     */
    @Query(
        "SELECT * FROM battery_cycles WHERE frozenAtUtcMillis IS NULL " +
            "ORDER BY ordinal DESC LIMIT 1"
    )
    fun newestRebuildable(): BatteryCycleEntity?

    @Query("SELECT MAX(ordinal) FROM battery_cycles")
    fun maxOrdinal(): Long?

    @Query("SELECT * FROM battery_cycles WHERE ordinal = :ordinal LIMIT 1")
    fun findById(ordinal: Long): BatteryCycleEntity?

    /**
     * The oldest cycle that is not frozen and that ends at or after the given
     * time. It is the resume point for a late pricing edit.
     */
    @Query(
        "SELECT * FROM battery_cycles " +
            "WHERE frozenAtUtcMillis IS NULL AND endUtcMillis >= :utcMillis " +
            "ORDER BY ordinal ASC LIMIT 1"
    )
    fun oldestRebuildableEndingAtOrAfter(utcMillis: Long): BatteryCycleEntity?

    /**
     * The newest closed cycle that ended before the oldest surviving session,
     * and is not frozen yet. Everything up to it has lost its sessions.
     */
    @Query(
        "SELECT * FROM battery_cycles " +
            "WHERE isOpen = 0 AND frozenAtUtcMillis IS NULL AND endUtcMillis < :utcMillis " +
            "ORDER BY ordinal DESC LIMIT 1"
    )
    fun newestClosedEndingBefore(utcMillis: Long): BatteryCycleEntity?

    @Query("DELETE FROM battery_cycles WHERE ordinal >= :ordinal")
    fun deleteFrom(ordinal: Long)

    @Query("UPDATE battery_cycles SET frozenAtUtcMillis = :frozenAtUtcMillis WHERE ordinal <= :ordinal AND frozenAtUtcMillis IS NULL")
    fun freezeUpTo(ordinal: Long, frozenAtUtcMillis: Long)

    @Query("SELECT COUNT(*) FROM battery_cycles")
    fun count(): Long

    @Query(
        "SELECT * FROM battery_cycles " +
            "WHERE ordinal > :afterOrdinal AND isOpen = 0 " +
            "ORDER BY ordinal ASC LIMIT :limit"
    )
    fun syncPage(
        afterOrdinal: Long,
        limit: Int
    ): List<BatteryCycleEntity>

    /** How many rows [syncPage] still has to give after this cursor. */
    @Query("SELECT COUNT(*) FROM battery_cycles WHERE ordinal > :afterOrdinal AND isOpen = 0")
    fun syncPendingCount(afterOrdinal: Long): Long

    @Query("SELECT * FROM battery_cycles WHERE dirty = 1 ORDER BY ordinal ASC LIMIT :limit")
    fun dirtyCycles(limit: Int): List<BatteryCycleEntity>

    @Query("SELECT COUNT(*) FROM battery_cycles WHERE dirty = 1")
    fun dirtyCycleCount(): Long

    @Query("UPDATE battery_cycles SET dirty = 0 WHERE ordinal IN (:ordinals)")
    fun clearDirty(ordinals: List<Long>): Int

    @Query("UPDATE battery_cycles SET dirty = 1")
    fun markAllDirty(): Int
}
