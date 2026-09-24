package com.timhss.capyenergy.telemetry.db

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import com.timhss.capyenergy.telemetry.TelemetryEvent

@Entity(
    tableName = "telemetry_events",
    indices = [
        Index(value = ["sessionId", "occurredAtUtcMillis"]),
        Index(value = ["dirty", "id"])
    ]
)
data class TelemetryEventEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val type: String,
    val occurredAtUtcMillis: Long,
    val occurredAtElapsedNanos: Long,
    val sourceTimestampNanos: Long?,
    val timestampAccuracy: String,
    val uncertaintyMillis: Long,
    val signalId: String?,
    val value: String?,
    val previousValue: String?,
    val quality: String?,
    val source: String?,
    val details: String,
    val sessionId: String? = null,
    val dirty: Boolean = true,
    val accountId: String? = null,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "id" to id,
        "type" to type,
        "occurredAtUtcMillis" to occurredAtUtcMillis,
        "occurredAtElapsedNanos" to occurredAtElapsedNanos,
        "sourceTimestampNanos" to sourceTimestampNanos,
        "timestampAccuracy" to timestampAccuracy,
        "uncertaintyMillis" to uncertaintyMillis,
        "signalId" to signalId,
        "value" to value,
        "previousValue" to previousValue,
        "quality" to quality,
        "source" to source,
        "details" to details,
        "sessionId" to sessionId
    )

    companion object {
        fun fromEvent(event: TelemetryEvent, accountId: String? = null): TelemetryEventEntity {
            return TelemetryEventEntity(
                type = event.type.name,
                occurredAtUtcMillis = event.timestamp.receivedAtUtcMillis,
                occurredAtElapsedNanos = event.timestamp.receivedAtElapsedNanos,
                sourceTimestampNanos = event.timestamp.sourceTimestampNanos,
                timestampAccuracy = event.timestamp.accuracy.name,
                uncertaintyMillis = event.timestamp.uncertaintyMillis,
                signalId = event.signalId?.name,
                value = event.value?.toString(),
                previousValue = event.previousValue?.toString(),
                quality = event.quality?.name,
                source = event.source?.name,
                details = event.details,
                sessionId = event.sessionId,
                accountId = accountId
            )
        }
    }
}
