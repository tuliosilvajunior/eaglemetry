package com.timhss.capyenergy.telemetry.db

import androidx.room.Dao
import androidx.room.Entity
import androidx.room.Query
import androidx.room.Upsert

/**
 * Time authority T9: one wrong key the sweeper already rewrote, queued for
 * exact deletion from the cloud after the corrected row lands.
 *
 * `start_utc_millis` is part of the cloud natural key, so a corrected row is
 * a new key and the old wrong row must be deleted — scoped to EXACTLY the
 * keys the car itself rewrote, never a blanket (scout §8.3 / plan §5.2,
 * Option A). When two pending minutes collide onto one corrected minute, the
 * merged row carries precisely one `correctedFromUtcMillis` but two old keys
 * died for it; this queue records every old key, so the delete stays exact
 * and the row is removed only after its corrected insert succeeded. A row is
 * removed from the queue only when the delete is accepted, so a mid-pass
 * failure repeats the delete, never skips it — insert first, delete after,
 * else a failure leaves the captain with neither row (the deletion target is
 * the OLD key, never the corrected one).
 */
@Entity(tableName = "interval_replaced_keys", primaryKeys = ["sessionId", "startUtcMillis"])
data class IntervalReplacedKeyEntity(
    val sessionId: String,
    /** The OLD wrong key that must leave the cloud. */
    val startUtcMillis: Long,
    val replacedByUtcMillis: Long,
)

@Dao
interface IntervalReplacedKeyDao {
    @Upsert
    fun upsertAll(keys: List<IntervalReplacedKeyEntity>)

    @Query("SELECT * FROM `interval_replaced_keys` ORDER BY startUtcMillis ASC LIMIT :limit")
    fun pending(limit: Int): List<IntervalReplacedKeyEntity>

    @Query(
        "DELETE FROM `interval_replaced_keys` " +
            "WHERE sessionId = :sessionId AND startUtcMillis = :startUtcMillis"
    )
    fun deleteKey(sessionId: String, startUtcMillis: Long): Int
}