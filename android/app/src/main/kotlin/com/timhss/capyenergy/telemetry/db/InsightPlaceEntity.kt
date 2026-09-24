package com.timhss.capyenergy.telemetry.db

import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * A place the driver named.
 *
 * The app never invents place names; the user or an opt-in reverse geocode
 * names them. The 150 m radius is the product starting value.
 *
 * A place is an annotation: it syncs both directions, it is edited from the
 * phone as well, and [deletedAtUtcMillis] is its tombstone — a deletion is
 * the stamp, never a physical removal, or a stale replica resurrects the
 * place on the next sync.
 */
@Entity(tableName = "insight_places")
data class InsightPlaceEntity(
    @PrimaryKey val id: String,
    val name: String,
    val latitude: Double,
    val longitude: Double,
    val radiusM: Double,
    val createdAtUtcMillis: Long,
    val updatedAtUtcMillis: Long,
    val accountId: String? = null,
    val origin: String = "car",
    val deletedAtUtcMillis: Long? = null,
    val autoName: String? = null,
    val autoNameUpdatedAtUtcMillis: Long? = null,
    val autoNameSource: String? = null,
    val hlcMillis: Long = 0L,
    val hlcCounter: Int = 0,
    val hlcDeviceId: String = "car"
) {
    val isDeleted: Boolean get() = deletedAtUtcMillis != null

    fun toMap(): Map<String, Any?> = mapOf(
        "id" to id,
        "name" to name,
        "latitude" to latitude,
        "longitude" to longitude,
        "radiusM" to radiusM,
        "createdAtUtcMillis" to createdAtUtcMillis,
        "updatedAtUtcMillis" to updatedAtUtcMillis,
        "accountId" to accountId,
        "origin" to origin,
        "deletedAtUtcMillis" to deletedAtUtcMillis,
        "autoName" to autoName,
        "autoNameUpdatedAtUtcMillis" to autoNameUpdatedAtUtcMillis,
        "autoNameSource" to autoNameSource,
        "hlcMillis" to hlcMillis,
        "hlcCounter" to hlcCounter,
        "hlcDeviceId" to hlcDeviceId,
        "hlc" to mapOf("millis" to hlcMillis, "counter" to hlcCounter, "deviceId" to hlcDeviceId)
    )
}
