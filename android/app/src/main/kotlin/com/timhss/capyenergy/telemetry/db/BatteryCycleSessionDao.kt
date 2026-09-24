package com.timhss.capyenergy.telemetry.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

@Dao
interface BatteryCycleSessionDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsertAll(rows: List<BatteryCycleSessionEntity>)

    /** What one cycle is made of, oldest first. */
    @Query(
        "SELECT * FROM battery_cycle_sessions WHERE cycleOrdinal = :ordinal " +
            "ORDER BY startUtcMillis ASC, endUtcMillis ASC"
    )
    fun forCycle(ordinal: Long): List<BatteryCycleSessionEntity>

    /**
     * Clears the membership of the cycles a rebuild is about to replace. It
     * runs in the same transaction as `BatteryCycleDao.deleteFrom`.
     */
    @Query("DELETE FROM battery_cycle_sessions WHERE cycleOrdinal >= :ordinal")
    fun deleteFrom(ordinal: Long)

    @Query("SELECT COUNT(*) FROM battery_cycle_sessions WHERE cycleOrdinal = :ordinal")
    fun countForCycle(ordinal: Long): Long
}
