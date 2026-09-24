package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey

import com.timhss.capyenergy.concurrent.namedSingleThreadExecutor
import java.util.concurrent.Executor

class SignalStateStore(
    private val dispatchExecutor: Executor = namedSingleThreadExecutor("signal-fanout")
) {
    interface Listener {
        fun onSignalUpdated(sample: SignalSample, snapshot: Map<SignalKey, SignalSample>)
    }

    private val lock = Any()
    private val latest = linkedMapOf<SignalKey, SignalSample>()
    private val listeners = mutableSetOf<Listener>()

    fun upsert(sample: SignalSample) {
        val snapshot: Map<SignalKey, SignalSample>
        val listenersCopy: List<Listener>
        synchronized(lock) {
            latest[sample.signalId] = sample
            snapshot = latest.toMap()
            listenersCopy = listeners.toList()
        }
        dispatchExecutor.execute {
            listenersCopy.forEach { it.onSignalUpdated(sample, snapshot) }
        }
    }

    fun snapshot(): Map<SignalKey, SignalSample> = synchronized(lock) {
        latest.toMap()
    }

    fun addListener(listener: Listener) {
        synchronized(lock) {
            listeners.add(listener)
        }
    }

    fun removeListener(listener: Listener) {
        synchronized(lock) {
            listeners.remove(listener)
        }
    }

    fun clear() {
        synchronized(lock) {
            latest.clear()
        }
    }
}

