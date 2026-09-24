package com.timhss.capyenergy.telemetry.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

@Dao
interface JourneyDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsert(journey: JourneyEntity)

    /// The live journeys, for readers. Tombstones are rows the sync needs,
    /// not journeys the app shows.
    @Query("SELECT * FROM journeys WHERE deletedAtUtcMillis IS NULL ORDER BY startedAtUtcMillis DESC, id ASC")
    fun all(): List<JourneyEntity>

    @Query("SELECT * FROM journeys WHERE id = :id LIMIT 1")
    fun findById(id: String): JourneyEntity?

    /// Includes tombstones: the only physical removal this table knows is a
    /// destructive wipe.
    @Query("SELECT * FROM journeys ORDER BY updatedAtUtcMillis ASC, id ASC")
    fun allIncludingDeleted(): List<JourneyEntity>

    @Query(
        "SELECT * FROM journeys " +
            "WHERE updatedAtUtcMillis > :afterUpdatedAtUtcMillis " +
            "OR (updatedAtUtcMillis = :afterUpdatedAtUtcMillis AND id > :afterId) " +
            "ORDER BY updatedAtUtcMillis ASC, id ASC LIMIT :limit"
    )
    fun syncPage(afterUpdatedAtUtcMillis: Long, afterId: String, limit: Int): List<JourneyEntity>

    @Query(
        "SELECT COUNT(*) FROM journeys " +
            "WHERE updatedAtUtcMillis > :afterUpdatedAtUtcMillis " +
            "OR (updatedAtUtcMillis = :afterUpdatedAtUtcMillis AND id > :afterId)"
    )
    fun syncPendingCount(afterUpdatedAtUtcMillis: Long, afterId: String): Long
}
