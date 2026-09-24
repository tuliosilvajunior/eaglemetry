package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalTransport
import com.timhss.capyenergy.profile.SignalSpec
import com.timhss.capyenergy.profile.VehicleProfile

import com.timhss.capyenergy.profile.SignalKey

import android.car.Car
import android.car.hardware.CarPropertyConfig
import android.car.hardware.CarPropertyValue
import android.car.hardware.property.CarPropertyManager
import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.util.Log

internal const val ECARX_STATUS_SUPPORTED = 3

/**
 * Whether a `CarPropertyValue` status means the value is usable. Shared by the
 * initial-read (polling) and ON_CHANGE callback paths so both treat a
 * non-AVAILABLE status exactly the same: never normalized as MEASURED. Kept
 * behind a small function so the JVM tests can exercise it without a vehicle.
 *
 * ECARX / Flyme Auto sets mStatus to 3 on supported vendor properties (such as
 * AC_AMBIENT_TEMP), while standard AOSP uses STATUS_AVAILABLE (0).
 */
internal fun vhalStatusIsAvailable(status: Int): Boolean =
    status == CarPropertyValue.STATUS_AVAILABLE || status == ECARX_STATUS_SUPPORTED

/** Momentary key events are always raw-logged so a missed edge stays diagnosable. */
internal fun vhalShouldRawLog(spec: SignalSpec): Boolean =
    spec.rawLog || spec.keyEventLatch

/** Builds the sample that invalidates a previous measurement after a VHAL error. */
internal fun vhalErrorSample(
    normalizer: SignalNormalizer,
    spec: SignalSpec,
    propertyId: Int,
    source: SignalSource,
    uncertaintyMillis: Long,
    message: String
): SignalSample = normalizer.errorSample(
    spec = spec,
    propertyId = propertyId,
    source = source,
    uncertaintyMillis = uncertaintyMillis,
    error = IllegalStateException(message)
)

class VhalSubscriptionManager(
    context: Context,
    private val policy: TelemetryPolicy,
    private val normalizer: SignalNormalizer,
    private val store: SignalStateStore,
    private val ecarxSignalProvider: EcarxSignalProvider
) : SignalTransport {
    private val appContext = context.applicationContext
    private val activeSpecs = mutableListOf<ActiveSignalSpec>()
    private val callbacks = mutableListOf<Pair<Int, CarPropertyManager.CarPropertyEventCallback>>()
    private var car: Car? = null
    private var propertyManager: CarPropertyManager? = null
    private var workerThread: HandlerThread? = null
    private var worker: Handler? = null
    private var running = false
    private var callbackSignals = 0
    private var pollingSignals = 0
    @Volatile
    private var configByPropertyId: Map<Int, CarPropertyConfig<*>> = emptyMap()

    // Per-signal generation counter for the key-event latch. Each new press
    // bumps it; a scheduled "revert to idle" only fires if no newer press
    // arrived meanwhile. ConcurrentHashMap: written on the callback thread,
    // read on the worker thread that runs the revert.
    private val keyEventGeneration = java.util.concurrent.ConcurrentHashMap<SignalKey, Long>()

    // How often each signal has refused in a row, and therefore when to stop
    // asking. Written on the delivery thread, read on the worker that mutes.
    private val unavailable = VhalUnavailablePolicy()

    override val transportName: String = "vhal"

    /** The property surface answers whatever the profile binds to a property. */
    override fun answers(profile: VehicleProfile): Set<SignalKey> =
        profile.propertySignals.map { it.signalId }.toSet()

    /**
     * A registered callback or a running poll is what delivery means here.
     * The manager keeps both counts because a signal may fall back from one to
     * the other, and a run with neither is a subscription that never took.
     */
    override fun isDelivering(): Boolean = running && (callbackSignals + pollingSignals) > 0

    override fun start() {
        if (running) return
        running = true
        workerThread = HandlerThread(WORKER_THREAD_NAME).also { it.start() }
        worker = Handler(workerThread!!.looper)
        worker?.post { startOnWorker() }
    }

    override fun stop() {
        running = false
        worker?.post {
            unregisterCallbacks()
            try {
                car?.disconnect()
            } catch (e: Exception) {
                Log.w(TAG, "Error disconnecting car", e)
            }
            propertyManager = null
            car = null
            activeSpecs.clear()
        }
        configByPropertyId = emptyMap()
        workerThread?.quitSafely()
        workerThread = null
        worker = null
        callbackSignals = 0
        pollingSignals = 0
        keyEventGeneration.clear()
        unavailable.clear()
    }

    fun callbackSignalCount(): Int = callbackSignals

    fun pollingSignalCount(): Int = pollingSignals

    private fun startOnWorker() {
        val pm = connectPropertyManager()
        if (pm == null) {
            policy.signalSpecs.forEach {
                store.upsert(
                    normalizer.errorSample(
                        spec = it,
                        propertyId = it.propertyId,
                        source = SignalSource.VHAL_POLLING,
                        uncertaintyMillis = it.pollingIntervalMillis,
                        error = IllegalStateException("CarPropertyManager unavailable")
                    )
                )
            }
            return
        }

        callbackSignals = 0
        pollingSignals = 0
        activeSpecs.clear()
        loadConfigCache(pm)
        policy.signalSpecs.forEach { spec ->
            val active = resolveActiveSpec(spec)
            activeSpecs.add(active)
            readInitial(pm, active)
            val registered = registerCallback(pm, active)
            if (registered) {
                callbackSignals += 1
            } else if (active.spec.pollingFallback) {
                pollingSignals += 1
                schedulePolling(pm, active)
            } else {
                // Momentary key events must not degrade to polling silently:
                // surface the failure so it is visible instead of reading 0.
                Log.w(TAG, "ON_CHANGE callback unavailable for ${active.propertyId.toHexPropertyId()} (${active.spec.signalId}); polling disabled for this signal")
                store.upsert(
                    normalizer.errorSample(
                        spec = active.spec,
                        propertyId = active.propertyId,
                        source = SignalSource.VHAL_CALLBACK,
                        uncertaintyMillis = 0L,
                        error = IllegalStateException("ON_CHANGE callback unavailable")
                    )
                )
            }
        }
    }

    private fun connectPropertyManager(): CarPropertyManager? {
        propertyManager?.let { return it }
        return try {
            val connectedCar = car ?: createCarOnWorker().also { car = it }
            (connectedCar.getCarManager(Car.PROPERTY_SERVICE) as? CarPropertyManager).also {
                propertyManager = it
                if (it == null) Log.w(TAG, "CarPropertyManager unavailable")
            }
        } catch (e: Throwable) {
            Log.w(TAG, "Failed to connect to CarPropertyManager", e)
            null
        }
    }

    /**
     * Builds the `Car` so that property callbacks land on this manager's worker
     * thread instead of the main looper.
     *
     * `Car.createCar(context)` binds delivery to the main looper. Every
     * subscribed property then wakes the UI thread: the 2026-08-17 field probe
     * measured about 23 callbacks a second there on a parked car, each one an
     * OEM framework log line, an ECARX adaptation, a normalization and a full
     * snapshot copy. The worker thread this class already owns existed only to
     * register them.
     *
     * The overload is not on every car framework, and a missing one throws
     * `NoSuchMethodError` rather than a checked exception, so the fallback
     * catches `Throwable` and says out loud where the callbacks went.
     */
    private fun createCarOnWorker(): Car {
        val handler = worker
        if (handler != null) {
            try {
                return Car.createCar(appContext, handler)
            } catch (e: Throwable) {
                Log.w(TAG, "Car.createCar(context, handler) unavailable; VHAL callbacks stay on the main looper", e)
            }
        }
        return Car.createCar(appContext)
    }

    private fun resolveActiveSpec(spec: SignalSpec): ActiveSignalSpec {
        val wrapped = spec.ecarxLogicalId?.let { ecarxSignalProvider.resolve(it, spec.ecarxIdType) }
        return if (wrapped != null) {
            ActiveSignalSpec(
                spec = spec,
                propertyId = wrapped.propertyId,
                source = SignalSource.ECARX_WRAPPED,
                ecarxRef = wrapped
            )
        } else {
            ActiveSignalSpec(spec = spec, propertyId = spec.propertyId, source = SignalSource.VHAL_CALLBACK)
        }
    }

    private fun readInitial(pm: CarPropertyManager, active: ActiveSignalSpec) {
        readProperty(pm, active, SignalSource.VHAL_POLLING)?.let(store::upsert)
    }

    private fun registerCallback(pm: CarPropertyManager, active: ActiveSignalSpec): Boolean {
        return try {
            val callback = object : CarPropertyManager.CarPropertyEventCallback {
                override fun onChangeEvent(value: CarPropertyValue<*>?) {
                    if (value == null) return
                    // Area filter only for real per-area properties (doors use
                    // positive area masks). GEAR uses areaId -1 as a read hint;
                    // its events arrive with a different area id and must not
                    // be dropped (this silently froze gear and broke trip
                    // arming when the filter compared against -1).
                    if (active.spec.areaId > 0 && value.areaId != active.spec.areaId) return
                    // Validate status before adapting or latching the value.
                    // Momentary key events are measurements too; an unavailable
                    // edge must not become a latched press.
                    if (!vhalStatusIsAvailable(value.status)) {
                        onUnavailableCallback(active, value.status)
                        return
                    }
                    unavailable.onAvailable(active.spec.signalId)
                    val raw = if (active.spec.adaptEcarxValue && active.ecarxRef != null) {
                        ecarxSignalProvider.adaptValue(active.ecarxRef, value.value)
                    } else {
                        value.value
                    }
                    if (vhalShouldRawLog(active.spec)) {
                        // Raw diagnostic: every callback edge, including the 0
                        // release, so live logcat shows what the signal emits.
                        Log.i(TAG, "RAW ${active.spec.signalId} ${active.propertyId.toHexPropertyId()} raw=$raw area=${value.areaId} ts=${value.timestamp}")
                    }
                    if (active.spec.keyEventLatch) {
                        handleKeyEvent(active, raw, value.timestamp)
                        return
                    }
                    store.upsert(
                        normalizer.normalize(
                            spec = active.spec,
                            rawValue = raw,
                            rawSource = active.source,
                            propertyId = active.propertyId,
                            sourceTimestampNanos = value.timestamp,
                            uncertaintyMillis = 0L,
                            details = "callback area=${value.areaId}"
                        )
                    )
                }

                override fun onErrorEvent(propId: Int, zone: Int) {
                    Log.w(TAG, "VHAL callback error prop=${propId.toHexPropertyId()} zone=$zone")
                    // Replace the previous MEASURED sample. RANGE_REMAINING is
                    // ON_CHANGE and has no age expiry, so logging alone would
                    // leave an old distance available indefinitely.
                    store.upsert(
                        vhalErrorSample(
                            normalizer = normalizer,
                            spec = active.spec,
                            propertyId = active.propertyId,
                            source = active.source,
                            uncertaintyMillis = 0L,
                            message = "VHAL callback error zone=$zone"
                        )
                    )
                }
            }
            pm.registerCallback(callback, active.propertyId, active.spec.preferredSampleRate)
            callbacks.add(active.propertyId to callback)
            true
        } catch (e: Exception) {
            Log.w(TAG, "Callback unavailable for ${active.propertyId.toHexPropertyId()}", e)
            false
        }
    }

    /**
     * A callback that carries a non-available status.
     *
     * The first refusal of a run is reported in full, because it is what turns
     * a measurement into a missing value. The repeats are dropped: the store
     * already holds the error sample, and re-writing it copies the whole
     * snapshot to every listener to say nothing new. A signal that keeps
     * refusing is unsubscribed and tried again later.
     */
    private fun onUnavailableCallback(active: ActiveSignalSpec, status: Int) {
        val signalId = active.spec.signalId
        when (unavailable.onUnavailable(signalId)) {
            UnavailableAction.IGNORE -> return
            UnavailableAction.REPORT -> {
                Log.w(TAG, "VHAL status $status not available for ${active.propertyId.toHexPropertyId()} ($signalId)")
                store.upsert(
                    vhalErrorSample(
                        normalizer = normalizer,
                        spec = active.spec,
                        propertyId = active.propertyId,
                        source = active.source,
                        uncertaintyMillis = 0L,
                        message = "VHAL status=$status unavailable"
                    )
                )
            }
            UnavailableAction.MUTE -> {
                Log.w(TAG, "VHAL $signalId (${active.propertyId.toHexPropertyId()}) answered unavailable ${VhalUnavailablePolicy.DEFAULT_REFUSALS_BEFORE_MUTE} times; unsubscribing for ${UNAVAILABLE_RETRY_MILLIS / 1000}s")
                muteAndRetry(active)
            }
        }
    }

    /**
     * Drops the subscription of a signal that only refuses, and re-registers it
     * after a backoff. The stored error sample is left alone: the signal is
     * still unavailable, and that remains the honest answer while it is muted.
     */
    private fun muteAndRetry(active: ActiveSignalSpec) {
        worker?.post {
            if (!running) return@post
            unregisterCallback(active.propertyId)
            worker?.postDelayed({
                if (!running) return@postDelayed
                val pm = propertyManager ?: return@postDelayed
                unavailable.reset(active.spec.signalId)
                if (!registerCallback(pm, active)) {
                    Log.w(TAG, "Retry of ${active.spec.signalId} could not re-register its callback")
                }
            }, UNAVAILABLE_RETRY_MILLIS)
        }
    }

    private fun unregisterCallback(propertyId: Int) {
        val pm = propertyManager ?: return
        val registered = callbacks.filter { it.first == propertyId }
        registered.forEach { (id, callback) ->
            try {
                pm.unregisterCallback(callback, id)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to unregister callback for ${id.toHexPropertyId()}", e)
            }
        }
        callbacks.removeAll(registered)
    }

    // Momentary key events revert to 0 within milliseconds. Latch the last
    // non-zero press so it stays visible in the UI for HOLD_MILLIS, and drop
    // the trailing 0 release (the timer handles reverting to idle). A sustained
    // long-press that keeps re-emitting non-zero simply refreshes the timer.
    private fun handleKeyEvent(active: ActiveSignalSpec, raw: Any?, sourceTimestampNanos: Long) {
        val intValue = when (raw) {
            is Number -> raw.toInt()
            else -> raw?.toString()?.toIntOrNull() ?: 0
        }
        val signalId = active.spec.signalId
        if (intValue != 0) {
            val generation = (keyEventGeneration[signalId] ?: 0L) + 1L
            keyEventGeneration[signalId] = generation
            store.upsert(
                normalizer.normalize(
                    spec = active.spec,
                    rawValue = intValue,
                    rawSource = SignalSource.VHAL_CALLBACK,
                    propertyId = active.propertyId,
                    sourceTimestampNanos = sourceTimestampNanos,
                    uncertaintyMillis = 0L,
                    details = "keydown latched raw=$intValue"
                )
            )
            worker?.postDelayed({
                if (keyEventGeneration[signalId] == generation) {
                    store.upsert(
                        normalizer.normalize(
                            spec = active.spec,
                            rawValue = 0,
                            rawSource = SignalSource.VHAL_CALLBACK,
                            propertyId = active.propertyId,
                            sourceTimestampNanos = null,
                            uncertaintyMillis = 0L,
                            details = "latch idle"
                        )
                    )
                }
            }, KEY_EVENT_HOLD_MILLIS)
        }
        // intValue == 0 (release) is intentionally swallowed: the pending revert
        // handles returning to idle without clobbering the visible press.
    }

    private fun schedulePolling(pm: CarPropertyManager, active: ActiveSignalSpec) {
        val task = object : Runnable {
            override fun run() {
                if (!running) return
                readProperty(pm, active, SignalSource.VHAL_POLLING)?.let(store::upsert)
                worker?.postDelayed(this, active.spec.pollingIntervalMillis)
            }
        }
        worker?.postDelayed(task, active.spec.pollingIntervalMillis)
    }

    private fun readProperty(
        pm: CarPropertyManager,
        active: ActiveSignalSpec,
        source: SignalSource
    ): SignalSample? {
        return try {
            val config = findConfig(pm, active.propertyId)
            val rawRead = if (config != null) {
                @Suppress("UNCHECKED_CAST")
                val carValue = pm.getProperty(config.propertyType as Class<Any>, active.propertyId, active.spec.areaId)
                if (!vhalStatusIsAvailable(carValue.status)) {
                    return vhalErrorSample(
                        normalizer = normalizer,
                        spec = active.spec,
                        propertyId = active.propertyId,
                        source = source,
                        uncertaintyMillis = active.spec.pollingIntervalMillis,
                        message = "VHAL status=${carValue.status} unavailable"
                    )
                }
                RawPropertyRead(carValue.value, carValue.timestamp)
            } else {
                readPropertyFallback(pm, active.propertyId, active.spec.areaId)
            }
            val raw = if (active.spec.adaptEcarxValue && active.ecarxRef != null) {
                ecarxSignalProvider.adaptValue(active.ecarxRef, rawRead?.value)
            } else {
                rawRead?.value
            }
            normalizer.normalize(
                spec = active.spec,
                rawValue = raw,
                rawSource = source,
                propertyId = active.propertyId,
                sourceTimestampNanos = rawRead?.sourceTimestampNanos,
                uncertaintyMillis = active.spec.pollingIntervalMillis,
                details = "poll"
            )
        } catch (e: Exception) {
            normalizer.errorSample(active.spec, active.propertyId, source, active.spec.pollingIntervalMillis, e)
        }
    }

    private fun readPropertyFallback(
        pm: CarPropertyManager,
        propertyId: Int,
        areaId: Int
    ): RawPropertyRead? {
        return try {
            RawPropertyRead(pm.getFloatProperty(propertyId, areaId), null)
        } catch (_: Exception) {
            try {
                RawPropertyRead(pm.getIntProperty(propertyId, areaId), null)
            } catch (_: Exception) {
                null
            }
        }
    }

    private fun loadConfigCache(pm: CarPropertyManager) {
        configByPropertyId = try {
            pm.propertyList.associateBy { it.propertyId }
        } catch (e: Throwable) {
            Log.w(TAG, "Failed to read property list", e)
            emptyMap()
        }
    }

    private fun findConfig(pm: CarPropertyManager, propertyId: Int): CarPropertyConfig<*>? {
        if (configByPropertyId.isEmpty()) loadConfigCache(pm)
        return configByPropertyId[propertyId]
    }

    private fun unregisterCallbacks() {
        val pm = propertyManager ?: return
        callbacks.forEach { (_, callback) ->
            try {
                pm.unregisterCallback(callback)
            } catch (_: Exception) {
            }
        }
        callbacks.clear()
    }

    private data class ActiveSignalSpec(
        val spec: SignalSpec,
        val propertyId: Int,
        val source: SignalSource,
        val ecarxRef: EcarxSignalProvider.WrappedPropertyRef? = null
    )

    private data class RawPropertyRead(
        val value: Any?,
        val sourceTimestampNanos: Long?
    )

    companion object {
        private const val TAG = "VhalSubscriptionManager"
        // How long a momentary key press stays latched/visible before reverting
        // to idle. Long enough to read on a debug screen, short enough to see
        // repeated presses distinctly.
        private const val KEY_EVENT_HOLD_MILLIS = 3_000L

        /**
         * The worker that registers the subscriptions and, since 2026-08-17,
         * receives them. Linux truncates at 15 characters: the old
         * "GeelyTelemetryVhal" reached `top` as "GeelyTelemetryV".
         */
        internal const val WORKER_THREAD_NAME = "vhal-callbacks"

        /**
         * How long a muted signal stays unsubscribed. Five minutes is long
         * enough that a property this car never publishes costs nothing, and
         * short enough that an ECU which wakes later is picked up within one
         * drive.
         */
        private const val UNAVAILABLE_RETRY_MILLIS = 5 * 60 * 1000L
    }
}
