package com.timhss.capyenergy.telemetry.db

import androidx.room.Entity
import androidx.room.Index

/**
 * Persisted synchronization cursor for a companion device and data stream.
 *
 * Tracks the last confirmed record and causal timestamp acknowledged by [deviceId]
 * for a specific [streamType].
 *
 * [lastConfirmedRecordId] and [lastConfirmedHlcMillis] / [lastConfirmedHlcCounter] / [lastConfirmedHlcDeviceId]
 * are either all set (when at least one record has been confirmed) or all null.
 *
 * [updatedAtUtcMillis] is the car's wall clock at the write. It is not an HLC:
 * the car has no causal clock of its own yet, and a triple whose counter is
 * always zero would order two writes in the same millisecond as equal, which is
 * the one thing a counter exists to prevent.
 */
@Entity(
    tableName = "sync_cursors",
    primaryKeys = ["deviceId", "streamType"],
    indices = [
        Index(value = ["streamType"])
    ]
)
data class SyncCursorEntity(
    val deviceId: String,
    val streamType: String,
    val lastConfirmedRecordId: String?,
    val lastConfirmedHlcMillis: Long?,
    val lastConfirmedHlcCounter: Int?,
    val lastConfirmedHlcDeviceId: String?,
    val updatedAtUtcMillis: Long
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "deviceId" to deviceId,
        "streamType" to streamType,
        "lastConfirmedRecordId" to lastConfirmedRecordId,
        "lastConfirmedHlc" to if (lastConfirmedHlcMillis != null && lastConfirmedHlcCounter != null && lastConfirmedHlcDeviceId != null) {
            mapOf(
                "millis" to lastConfirmedHlcMillis,
                "counter" to lastConfirmedHlcCounter,
                "deviceId" to lastConfirmedHlcDeviceId
            )
        } else null,
        "updatedAtUtcMillis" to updatedAtUtcMillis
    )
}
