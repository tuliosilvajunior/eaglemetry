package com.timhss.capyenergy.telemetry.db

import androidx.room.Entity
import androidx.room.Index

@Entity(
    tableName = "interval",
    primaryKeys = ["sessionId", "startUtcMillis"],
    indices = [
        Index(value = ["startUtcMillis"]),
        Index(value = ["sessionId", "startUtcMillis"]),
        Index(value = ["dirty"])
    ]
)
data class IntervalEntity(
    val sessionId: String,
    val startUtcMillis: Long,
    val widthMillis: Long = 60_000L,
    val tractionWh: Double = 0.0,
    val regenWh: Double = 0.0,
    val auxiliaryWh: Double = 0.0,
    val climateWh: Double = 0.0,
    val deliveredWh: Double = 0.0,
    val distanceKm: Double = 0.0,
    val coveredSeconds: Double = 0.0,
    val climateCoveredSeconds: Double = 0.0,
    val speedCoveredSeconds: Double = 0.0,
    val deliveredCoveredSeconds: Double = 0.0,
    val startSoc: Double? = null,
    val endSoc: Double? = null,
    val startVoltage: Double? = null,
    val endVoltage: Double? = null,
    val updatedAtUtcMillis: Long = System.currentTimeMillis(),
    /**
     * The monotonic reading behind [startUtcMillis], from
     * `elapsedRealtimeNanos`, with the boot it belongs to. The wall clock
     * lies after a cold boot until time sync lands, but the monotonic clock
     * does not, so once a trusted wall instant arrives for the boot every
     * earlier minute resolves by exact arithmetic. Null on rows recorded
     * before the pair existed: those rows cannot be recovered, and the null
     * says so. Written by the accumulator (T2); this task only stores it.
     */
    val startElapsedNanos: Long? = null,
    val startBootCount: Int? = null,
    /**
     * What the time authority believes about this minute's stamp. Starts at
     * `'unknown'`; the detector and sweeper (later tasks) own the rest of
     * the vocabulary.
     */
    val timeState: String = "unknown",
    /**
     * The stamp this row carried before the sweeper corrected it (time
     * authority T9). Null means never corrected. This is the target the
     * cloud re-upload deletes after the corrected row lands: the corrected
     * row's key is the NEW minute, and the old wrong key must be removed
     * from the cloud exactly, never the corrected one.
     */
    val correctedFromUtcMillis: Long? = null,
    val dirty: Boolean = true,
    val accountId: String? = null,
) {
    fun toMap(): Map<String, Any?> = toExportRow()
    fun toExportRow(): Map<String, Any?> = mapOf(
        "sessionId" to sessionId,
        "startUtcMillis" to startUtcMillis,
        "widthMillis" to widthMillis,
        "tractionWh" to tractionWh,
        "regenWh" to regenWh,
        "auxiliaryWh" to auxiliaryWh,
        "climateWh" to climateWh,
        "deliveredWh" to deliveredWh,
        "distanceKm" to distanceKm,
        "coveredSeconds" to coveredSeconds,
        "climateCoveredSeconds" to climateCoveredSeconds,
        "speedCoveredSeconds" to speedCoveredSeconds,
        "deliveredCoveredSeconds" to deliveredCoveredSeconds,
        "startSoc" to startSoc,
        "endSoc" to endSoc,
        "startVoltage" to startVoltage,
        "endVoltage" to endVoltage,
        "updatedAtUtcMillis" to updatedAtUtcMillis,
        "startElapsedNanos" to startElapsedNanos,
        "startBootCount" to startBootCount,
        "timeState" to timeState,
        "correctedFromUtcMillis" to correctedFromUtcMillis
    )
}

fun IntervalEntity.toEnergyBucket(): com.timhss.capyenergy.telemetry.EnergyBucket =
    com.timhss.capyenergy.telemetry.EnergyBucket(
        startUtcMillis = startUtcMillis,
        tractionWh = tractionWh,
        regeneratedWh = regenWh,
        auxiliaryWh = auxiliaryWh,
        climateWh = climateWh,
        deliveredWh = deliveredWh,
        speedDistanceKm = distanceKm,
        odometerDistanceKm = distanceKm,
        integratedSeconds = coveredSeconds,
        climateIntegratedSeconds = climateCoveredSeconds,
        deliveredCoveredSeconds = deliveredCoveredSeconds,
        startSoc = startSoc,
        endSoc = endSoc,
        startVoltage = startVoltage,
        endVoltage = endVoltage,
        startElapsedNanos = startElapsedNanos,
        startBootCount = startBootCount
    )
