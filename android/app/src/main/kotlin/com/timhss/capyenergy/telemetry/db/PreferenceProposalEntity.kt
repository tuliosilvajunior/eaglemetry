package com.timhss.capyenergy.telemetry.db

import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * A phone's proposal for a control (Lane C) preference.
 *
 * The phone writes a proposal, never the value: the control keys (see
 * [com.timhss.capyenergy.telemetry.PreferenceRepository.CONTROL_KEYS])
 * change what the car records, so only the car's acceptance turns one into
 * a write — and acceptance runs the normal write path, so the cycle refold
 * a new capacity causes happens exactly once, when a person on the car
 * confirmed it.
 */
@Entity(tableName = "preference_proposals")
data class PreferenceProposalEntity(
    @PrimaryKey val id: String,
    val key: String,
    val value: String?,
    val status: String,
    val proposedAtUtcMillis: Long,
    val decidedAtUtcMillis: Long?,
    val updatedAtUtcMillis: Long,
    val origin: String,
    val accountId: String? = null,
    val hlcMillis: Long = 0L,
    val hlcCounter: Int = 0,
    val hlcDeviceId: String = "car"
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "id" to id,
        "key" to key,
        "value" to value,
        "status" to status,
        "proposedAtUtcMillis" to proposedAtUtcMillis,
        "decidedAtUtcMillis" to decidedAtUtcMillis,
        "updatedAtUtcMillis" to updatedAtUtcMillis,
        "origin" to origin,
        "hlcMillis" to hlcMillis,
        "hlcCounter" to hlcCounter,
        "hlcDeviceId" to hlcDeviceId,
        "hlc" to mapOf("millis" to hlcMillis, "counter" to hlcCounter, "deviceId" to hlcDeviceId)
    )

    companion object {
        const val STATUS_PENDING = "PENDING"
        const val STATUS_ACCEPTED = "ACCEPTED"
        const val STATUS_REFUSED = "REFUSED"
    }
}
