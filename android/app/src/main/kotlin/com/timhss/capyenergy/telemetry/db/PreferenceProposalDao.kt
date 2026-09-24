package com.timhss.capyenergy.telemetry.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

@Dao
interface PreferenceProposalDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsert(proposal: PreferenceProposalEntity)

    @Query("SELECT * FROM preference_proposals WHERE id = :id LIMIT 1")
    fun findById(id: String): PreferenceProposalEntity?

    @Query("SELECT * FROM preference_proposals ORDER BY proposedAtUtcMillis DESC, id DESC")
    fun all(): List<PreferenceProposalEntity>

    @Query(
        "SELECT * FROM preference_proposals WHERE status = :status " +
            "ORDER BY proposedAtUtcMillis DESC, id DESC"
    )
    fun byStatus(status: String): List<PreferenceProposalEntity>

    @Query(
        "SELECT * FROM preference_proposals " +
            "WHERE updatedAtUtcMillis > :afterUpdatedAtUtcMillis " +
            "OR (updatedAtUtcMillis = :afterUpdatedAtUtcMillis AND id > :afterId) " +
            "ORDER BY updatedAtUtcMillis ASC, id ASC LIMIT :limit"
    )
    fun syncPage(afterUpdatedAtUtcMillis: Long, afterId: String, limit: Int): List<PreferenceProposalEntity>

    @Query(
        "SELECT COUNT(*) FROM preference_proposals " +
            "WHERE updatedAtUtcMillis > :afterUpdatedAtUtcMillis " +
            "OR (updatedAtUtcMillis = :afterUpdatedAtUtcMillis AND id > :afterId)"
    )
    fun syncPendingCount(afterUpdatedAtUtcMillis: Long, afterId: String): Long
}
