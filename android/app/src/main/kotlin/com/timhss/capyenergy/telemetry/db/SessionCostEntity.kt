package com.timhss.capyenergy.telemetry.db

import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * The price of one charge, as an annotation.
 *
 * This is a person stating what they paid, moved off the measurement table
 * by slice 6: it is edited by the car and by the phone, it changes after
 * the session is closed, and it syncs both directions with
 * last-writer-wins. The `session` table keeps dead cost columns so the
 * on-disk shape does not need a table rebuild; nothing writes them and the
 * reads compose this row instead.
 */
@Entity(tableName = "session_costs")
data class SessionCostEntity(
    @PrimaryKey val sessionId: String,
    val costPerKwh: Double?,
    val paidAmount: Double?,
    val costCurrency: String?,
    val updatedAtUtcMillis: Long,
    val origin: String,
    val accountId: String? = null,
    val hlcMillis: Long = 0L,
    val hlcCounter: Int = 0,
    val hlcDeviceId: String = "car"
) {
    fun hasAnyPrice(): Boolean = costPerKwh != null || paidAmount != null

    fun toMap(): Map<String, Any?> = mapOf(
        "sessionId" to sessionId,
        "costPerKwh" to costPerKwh,
        "paidAmount" to paidAmount,
        "costCurrency" to costCurrency,
        "updatedAtUtcMillis" to updatedAtUtcMillis,
        "origin" to origin,
        "hlcMillis" to hlcMillis,
        "hlcCounter" to hlcCounter,
        "hlcDeviceId" to hlcDeviceId,
        "hlc" to mapOf("millis" to hlcMillis, "counter" to hlcCounter, "deviceId" to hlcDeviceId)
    )
}
