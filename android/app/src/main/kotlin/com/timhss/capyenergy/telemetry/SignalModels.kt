package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey

enum class SignalQuality {
    MEASURED,
    DERIVED,
    UNAVAILABLE,
    ERROR
}

enum class SignalSource {
    VHAL_CALLBACK,
    VHAL_POLLING,
    ECARX_WRAPPED,
    SNAPSHOT_FALLBACK,

    // Read from Roadcast's decoded CAN stream. This includes values omitted by
    // the public Android property surface.
    CAN_BRIDGE,

    // Historical source identifier retained for existing database rows.
    PROP_RAM
}

enum class VehicleActivity {
    UNKNOWN,
    STATIONARY,
    MOVING,
    CHARGE_CONNECTED,
    CHARGING,
    DATA_STALE
}

enum class TimestampAccuracy {
    SOURCE_EVENT,
    RECEIVED_EVENT,
    POLLED,
    INFERRED
}

data class SignalTimestamp(
    val receivedAtUtcMillis: Long,
    val receivedAtElapsedNanos: Long,
    val sourceTimestampNanos: Long?,
    val accuracy: TimestampAccuracy,
    val uncertaintyMillis: Long
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "receivedAtUtcMillis" to receivedAtUtcMillis,
        "receivedAtElapsedNanos" to receivedAtElapsedNanos,
        "sourceTimestampNanos" to sourceTimestampNanos,
        "accuracy" to accuracy.name,
        "uncertaintyMillis" to uncertaintyMillis
    )
}

data class SignalSample(
    val signalId: SignalKey,
    val value: Any?,
    val unit: String,
    val quality: SignalQuality,
    val source: SignalSource,
    val propertyId: Int,
    val propertyIdHex: String,
    val areaId: Int,
    val timestamp: SignalTimestamp,
    val details: String
) {
    val timestampMillis: Long
        get() = timestamp.receivedAtUtcMillis

    val sourceTimestampNanos: Long?
        get() = timestamp.sourceTimestampNanos

    fun toMap(): Map<String, Any?> = mapOf(
        "signalId" to signalId.name,
        "value" to value,
        "unit" to unit,
        "quality" to quality.name,
        "source" to source.name,
        "propertyId" to propertyId,
        "propertyIdHex" to propertyIdHex,
        "areaId" to areaId,
        "timestampMillis" to timestampMillis,
        "sourceTimestampNanos" to sourceTimestampNanos,
        "timestamp" to timestamp.toMap(),
        "details" to details
    )
}

enum class TelemetryEventType {
    SIGNAL_UPDATED,
    SIGNAL_UNAVAILABLE,
    SIGNAL_ERROR,
    VEHICLE_ACTIVITY_CHANGED,
    TRIP_ARMED,
    TRIP_CANCELLED,
    TRIP_STARTED,
    TRIP_RECOVERED,
    TRIP_PENDING_END,
    TRIP_ENDED,
    CHARGE_PLUG_CONNECTED,
    CHARGE_STARTED,
    CHARGE_RECOVERED,
    CHARGE_PAUSED,
    CHARGE_ENDED,
    CHARGE_PLUG_DISCONNECTED,
    CHARGE_LIMIT_ARMED,
    CHARGE_LIMIT_REACHED,
    CHARGE_STOP_REQUESTED,
    CHARGE_STOP_FAILED
}

enum class TripState {
    IDLE,
    ARMED,
    ACTIVE,
    PENDING_END
}

enum class TripEndReason {
    PARK_CONFIRMED,
    CHARGING_STARTED,
    COLLECTOR_STOPPED,
    VEHICLE_DATA_LOST,
    APP_RESTART_RECOVERY,
    MANUAL,
    UNKNOWN
}

enum class ChargeSessionState {
    DISCONNECTED,
    PLUG_CONNECTED,
    CHARGING,
    ENDED_WAITING_DISCONNECT
}

enum class ChargeEndReason {
    COMPLETED,
    USER_STOPPED,
    PLUG_DISCONNECTED,
    POWER_LOST,
    TARGET_REACHED,
    INTERRUPTED,
    COLLECTOR_STOPPED,
    APP_RESTART_RECOVERY,
    UNKNOWN
}

data class TelemetryEvent(
    val id: String,
    val type: TelemetryEventType,
    val timestamp: SignalTimestamp,
    val signalId: SignalKey?,
    val value: Any?,
    val previousValue: Any?,
    val quality: SignalQuality?,
    val source: SignalSource?,
    val details: String,
    val sessionId: String? = null
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "id" to id,
        "type" to type.name,
        "timestamp" to timestamp.toMap(),
        "occurredAtUtcMillis" to timestamp.receivedAtUtcMillis,
        "occurredAtElapsedNanos" to timestamp.receivedAtElapsedNanos,
        "sourceTimestampNanos" to timestamp.sourceTimestampNanos,
        "timestampAccuracy" to timestamp.accuracy.name,
        "uncertaintyMillis" to timestamp.uncertaintyMillis,
        "signalId" to signalId?.name,
        "value" to value,
        "previousValue" to previousValue,
        "quality" to quality?.name,
        "source" to source?.name,
        "details" to details,
        "sessionId" to sessionId
    )
}

data class CollectorStatus(
    val running: Boolean,
    val collectorStatus: String,
    val vehicleActivity: VehicleActivity,
    val tripState: TripState,
    val chargeState: ChargeSessionState,
    val callbackSignals: Int,
    val pollingSignals: Int,
    val lastUpdateMillis: Long,
    val signalCount: Int
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "running" to running,
        "collectorStatus" to collectorStatus,
        "vehicleActivity" to vehicleActivity.name,
        "tripState" to tripState.name,
        "chargeState" to chargeState.name,
        "callbackSignals" to callbackSignals,
        "pollingSignals" to pollingSignals,
        "lastUpdateMillis" to lastUpdateMillis,
        "signalCount" to signalCount
    )
}

internal fun Int.toHexPropertyId(): String =
    "0x" + toUInt().toString(16).padStart(8, '0')
