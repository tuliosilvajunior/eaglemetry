package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

class LiveTelemetryPublisher(
    private val store: SignalStateStore,
    private val metadataProvider: () -> Map<String, Any?>
) : EventChannel.StreamHandler, SignalStateStore.Listener {
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        store.addListener(this)
        publishSnapshot(store.snapshot())
    }

    override fun onCancel(arguments: Any?) {
        store.removeListener(this)
        eventSink = null
    }

    override fun onSignalUpdated(sample: SignalSample, snapshot: Map<SignalKey, SignalSample>) {
        publishSnapshot(snapshot, sample)
    }

    private fun publishSnapshot(snapshot: Map<SignalKey, SignalSample>, updated: SignalSample? = null) {
        val payload = mapOf(
            "timestampMillis" to System.currentTimeMillis(),
            "updatedSignalId" to updated?.signalId?.name,
            "signals" to snapshot.values.map { it.toMap() }
        ) + metadataProvider()
        mainHandler.post {
            eventSink?.success(payload)
        }
    }
}
