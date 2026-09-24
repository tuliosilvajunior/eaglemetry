package com.timhss.capyenergy.telemetry.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

@Dao
interface SyncCursorDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsert(cursor: SyncCursorEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsertAll(cursors: List<SyncCursorEntity>)

    @Query("SELECT * FROM sync_cursors WHERE deviceId = :deviceId AND streamType = :streamType")
    fun getCursor(deviceId: String, streamType: String): SyncCursorEntity?

    @Query("SELECT * FROM sync_cursors WHERE deviceId = :deviceId")
    fun getCursorsForDevice(deviceId: String): List<SyncCursorEntity>

    @Query("SELECT * FROM sync_cursors WHERE streamType = :streamType")
    fun getCursorsForStream(streamType: String): List<SyncCursorEntity>

    @Query("SELECT * FROM sync_cursors")
    fun getAllCursors(): List<SyncCursorEntity>

    /**
     * The record every device on [streamType] has already confirmed, one id per
     * device.
     *
     * A cursor row is only ever written by an applied ack, so the id is never
     * null in practice; the filter states that rather than trusting it. An empty
     * result means no device has confirmed anything on this stream, which is not
     * the same as a device that is behind — see
     * `TelemetryRetentionManager.confirmedSessionFloor`.
     */
    @Query(
        "SELECT lastConfirmedRecordId FROM sync_cursors " +
            "WHERE streamType = :streamType AND lastConfirmedRecordId IS NOT NULL"
    )
    fun confirmedRecordIdsForStream(streamType: String): List<String>

    @Query("DELETE FROM sync_cursors WHERE deviceId = :deviceId")
    fun deleteForDevice(deviceId: String): Int

    @Query("DELETE FROM sync_cursors WHERE deviceId = :deviceId AND streamType = :streamType")
    fun deleteCursor(deviceId: String, streamType: String): Int

    @Query("DELETE FROM sync_cursors")
    fun clearAll(): Int
}
