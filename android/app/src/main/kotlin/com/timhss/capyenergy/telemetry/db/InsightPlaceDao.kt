package com.timhss.capyenergy.telemetry.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

@Dao
interface InsightPlaceDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsert(place: InsightPlaceEntity)

    /// The live places, for readers. Tombstones are rows the sync needs, not
    /// places the app shows.
    @Query("SELECT * FROM insight_places WHERE deletedAtUtcMillis IS NULL ORDER BY name ASC, id ASC")
    fun all(): List<InsightPlaceEntity>

    @Query("SELECT * FROM insight_places WHERE id = :id LIMIT 1")
    fun findById(id: String): InsightPlaceEntity?

    /// Includes tombstones: the only physical removal this table knows is a
    /// destructive wipe.
    @Query("SELECT * FROM insight_places ORDER BY updatedAtUtcMillis ASC, id ASC")
    fun allIncludingDeleted(): List<InsightPlaceEntity>

    @Query(
        "SELECT * FROM insight_places " +
            "WHERE updatedAtUtcMillis > :afterUpdatedAtUtcMillis " +
            "OR (updatedAtUtcMillis = :afterUpdatedAtUtcMillis AND id > :afterId) " +
            "ORDER BY updatedAtUtcMillis ASC, id ASC LIMIT :limit"
    )
    fun syncPage(afterUpdatedAtUtcMillis: Long, afterId: String, limit: Int): List<InsightPlaceEntity>

    @Query(
        "SELECT COUNT(*) FROM insight_places " +
            "WHERE updatedAtUtcMillis > :afterUpdatedAtUtcMillis " +
            "OR (updatedAtUtcMillis = :afterUpdatedAtUtcMillis AND id > :afterId)"
    )
    fun syncPendingCount(afterUpdatedAtUtcMillis: Long, afterId: String): Long
}
