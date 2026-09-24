package com.timhss.capyenergy.telemetry.db

import androidx.room.Dao
import androidx.room.Entity
import androidx.room.Query
import androidx.room.Upsert

/**
 * Time authority T5: one proven boot-default wall value, learned from the
 * detector's structural evidence (never written as a constant). `wall_utc_
 * millis` is the exact stamp a head unit showed before its time service
 * synced; the next boot that opens on it is PENDING from the first minute.
 */
@Entity(tableName = "clock_bad_signatures", primaryKeys = ["wallUtcMillis"])
data class ClockBadSignatureEntity(
    val wallUtcMillis: Long,
    val firstSeenUtcMillis: Long,
    val hits: Int = 1,
)

@Dao
interface ClockBadSignatureDao {
    @Upsert
    fun upsert(signature: ClockBadSignatureEntity)

    @Query("SELECT COUNT(*) FROM clock_bad_signatures WHERE wallUtcMillis = :wallMillis")
    fun countByWall(wallMillis: Long): Int
}
