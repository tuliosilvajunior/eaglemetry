package com.timhss.capyenergy.telemetry.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

@Dao
interface PreferenceDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsert(preference: PreferenceEntity)

    @Query("SELECT * FROM preferences WHERE scope = :scope AND `key` = :key LIMIT 1")
    fun findById(scope: String, key: String): PreferenceEntity?

    @Query("SELECT * FROM preferences WHERE deletedAtUtcMillis IS NULL ORDER BY scope ASC, `key` ASC")
    fun active(): List<PreferenceEntity>

    @Query("SELECT * FROM preferences ORDER BY scope ASC, `key` ASC")
    fun all(): List<PreferenceEntity>

    /**
     * The rows the annotation channel carries: account and vehicle scopes.
     * Device-scoped preferences never leave the device that holds them.
     */
    @Query("SELECT * FROM preferences WHERE scope IN ('account', 'vehicle') ORDER BY updatedAtUtcMillis ASC, scope ASC, `key` ASC")
    fun syncable(): List<PreferenceEntity>

    @Query(
        "SELECT * FROM preferences " +
            "WHERE scope IN ('account', 'vehicle') " +
            "AND (updatedAtUtcMillis > :afterUpdatedAtUtcMillis " +
            "OR (updatedAtUtcMillis = :afterUpdatedAtUtcMillis AND (scope > :afterScope OR (scope = :afterScope AND `key` > :afterKey)))) " +
            "ORDER BY updatedAtUtcMillis ASC, scope ASC, `key` ASC LIMIT :limit"
    )
    fun syncPage(
        afterUpdatedAtUtcMillis: Long,
        afterScope: String,
        afterKey: String,
        limit: Int
    ): List<PreferenceEntity>

    @Query(
        "SELECT COUNT(*) FROM preferences " +
            "WHERE scope IN ('account', 'vehicle') " +
            "AND (updatedAtUtcMillis > :afterUpdatedAtUtcMillis " +
            "OR (updatedAtUtcMillis = :afterUpdatedAtUtcMillis AND (scope > :afterScope OR (scope = :afterScope AND `key` > :afterKey))))"
    )
    fun syncPendingCount(afterUpdatedAtUtcMillis: Long, afterScope: String, afterKey: String): Long
}
