package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/** Narrow live stream for the normalized CarPropertyManager vehicle speed. */
class VehicleSpeedPublisher(
    private val store: SignalStateStore,
) : EventChannel.StreamHandler, SignalStateStore.Listener {
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        store.addListener(this)
        store.snapshot()[SignalKey.VEHICLE_SPEED]?.let(::publish)
    }

    override fun onCancel(arguments: Any?) {
        detach()
    }

    override fun onSignalUpdated(
        sample: SignalSample,
        snapshot: Map<SignalKey, SignalSample>,
    ) {
        if (sample.signalId == SignalKey.VEHICLE_SPEED) publish(sample)
    }

    fun detach() {
        store.removeListener(this)
        eventSink = null
    }

    private fun publish(sample: SignalSample) {
        val payload = vehicleSpeedPayload(sample)
        mainHandler.post { eventSink?.success(payload) }
    }
}

internal fun vehicleSpeedPayload(sample: SignalSample): Map<String, Any?> = mapOf(
    "speedKmh" to carPropertyVehicleSpeedKmh(sample),
    "quality" to sample.quality.name,
    "source" to sample.source.name,
    "receivedAtUtcMillis" to sample.timestamp.receivedAtUtcMillis,
    "receivedAtElapsedNanos" to sample.timestamp.receivedAtElapsedNanos,
    "sourceTimestampNanos" to sample.timestamp.sourceTimestampNanos,
)
