package com.timhss.capyenergy.vehicle

data class NumericReading(
    val ok: Boolean,
    val value: Float?,
    val source: String,
    val details: String
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "ok" to ok,
        "value" to value,
        "source" to source,
        "details" to details
    )
}

data class ChargingReading(
    val ok: Boolean,
    val isCharging: Boolean?,
    val stateRaw: Int?,
    val stateLabel: String?,
    val plugRaw: Int?,
    val plugLabel: String?,
    val acPowerKw: Float?,
    val dcPowerKw: Float?,
    val currentA: Float?,
    val voltageV: Float?,
    val estimatedTimeMinutes: Float?,
    val workTimeMinutes: Float?,
    val source: String,
    val details: String
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "ok" to ok,
        "isCharging" to isCharging,
        "stateRaw" to stateRaw,
        "stateLabel" to stateLabel,
        "plugRaw" to plugRaw,
        "plugLabel" to plugLabel,
        "acPowerKw" to acPowerKw,
        "dcPowerKw" to dcPowerKw,
        "currentA" to currentA,
        "voltageV" to voltageV,
        "estimatedTimeMinutes" to estimatedTimeMinutes,
        "workTimeMinutes" to workTimeMinutes,
        "source" to source,
        "details" to details
    )
}

data class TelemetrySnapshot(
    val timestampMillis: Long,
    val batteryPercent: NumericReading,
    val speedKmh: NumericReading,
    val odometerKm: NumericReading,
    val charging: ChargingReading,
    val gear: NumericReading
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "timestampMillis" to timestampMillis,
        "batteryPercent" to batteryPercent.toMap(),
        "speedKmh" to speedKmh.toMap(),
        "odometerKm" to odometerKm.toMap(),
        "charging" to charging.toMap(),
        "gear" to gear.toMap()
    )
}
