package com.timhss.capyenergy.telemetry.db

import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * A journey the driver named: one real-world event, a drive to another city,
 * a holiday, a weekend.
 *
 * The membership model is the time window: the row holds no member list and no
 * exclusions. Which sessions belong is computed when the group is read, from
 * the window alone.
 *
 * A journey is an annotation: it syncs both directions, it is edited from the
 * phone as well, and [deletedAtUtcMillis] is its tombstone — a deletion is
 * the stamp, never a physical removal, or a stale replica resurrects the
 * journey on the next sync.
 */
@Entity(tableName = "journeys")
data class JourneyEntity(
    @PrimaryKey val id: String,
    val name: String,
    val startedAtUtcMillis: Long,
    val endedAtUtcMillis: Long,
    val note: String? = null,
    val createdAtUtcMillis: Long,
    val updatedAtUtcMillis: Long,
    val accountId: String? = null,
    val origin: String = "car",
    val deletedAtUtcMillis: Long? = null,
    val hlcMillis: Long = 0L,
    val hlcCounter: Int = 0,
    val hlcDeviceId: String = "car"
) {
    val isDeleted: Boolean get() = deletedAtUtcMillis != null

    fun toMap(): Map<String, Any?> = mapOf(
        "id" to id,
        "name" to name,
        "startedAtUtcMillis" to startedAtUtcMillis,
        "endedAtUtcMillis" to endedAtUtcMillis,
        "note" to note,
        "createdAtUtcMillis" to createdAtUtcMillis,
        "updatedAtUtcMillis" to updatedAtUtcMillis,
        "accountId" to accountId,
        "origin" to origin,
        "deletedAtUtcMillis" to deletedAtUtcMillis,
        "hlcMillis" to hlcMillis,
        "hlcCounter" to hlcCounter,
        "hlcDeviceId" to hlcDeviceId,
        "hlc" to mapOf("millis" to hlcMillis, "counter" to hlcCounter, "deviceId" to hlcDeviceId)
    )
}
