package com.timhss.capyenergy.telemetry.db

import androidx.room.Entity

/**
 * One synced preference annotation: [scope] and [key] are its identity.
 *
 * `TelemetrySettings` and the Flutter preference stores stay the car's
 * authoritative values; a row here is what syncs. On the car a row is
 * written only when a person edits the setting directly or accepts a
 * proposal, and when an incoming sync row lands. The control keys (see
 * [com.timhss.capyenergy.telemetry.PreferenceRepository.CONTROL_KEYS])
 * have no rows of this kind at all — they are proposed, and a proposal is
 * a different table.
 */
@Entity(tableName = "preferences", primaryKeys = ["scope", "key"])
data class PreferenceEntity(
    val scope: String,
    val key: String,
    val value: String?,
    val updatedAtUtcMillis: Long,
    val origin: String,
    val accountId: String? = null,
    val deletedAtUtcMillis: Long?,
    val hlcMillis: Long = 0L,
    val hlcCounter: Int = 0,
    val hlcDeviceId: String = "car"
) {
    val isDeleted: Boolean get() = deletedAtUtcMillis != null

    fun toMap(): Map<String, Any?> = mapOf(
        "scope" to scope,
        "key" to key,
        "value" to value,
        "updatedAtUtcMillis" to updatedAtUtcMillis,
        "origin" to origin,
        "deletedAtUtcMillis" to deletedAtUtcMillis,
        "hlcMillis" to hlcMillis,
        "hlcCounter" to hlcCounter,
        "hlcDeviceId" to hlcDeviceId,
        "hlc" to mapOf("millis" to hlcMillis, "counter" to hlcCounter, "deviceId" to hlcDeviceId)
    )
}
