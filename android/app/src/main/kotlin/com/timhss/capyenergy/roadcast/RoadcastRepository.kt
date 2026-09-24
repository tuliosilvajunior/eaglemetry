package com.timhss.capyenergy.roadcast

import android.os.SystemClock
import com.timhss.capyenergy.concurrent.namedSingleThreadExecutor
import com.timhss.capyenergy.profile.SignalKey
import com.timhss.capyenergy.profile.SignalTransport
import com.timhss.capyenergy.profile.VehicleProfile
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Kotlin's single source of truth for the Roadcast connection and negotiated
 * schema. Consumers observe [state]; they never own a JNI client, resolve a
 * schema index, or perform reconnection themselves.
 *
 * This first slice publishes connection/schema truth only. A following slice
 * will add a single batched live-sample stream for Kotlin signal consumers.
 */
class RoadcastRepository(
    private val connect: () -> Result<RoadcastSession> = { RoadcastClient.connect() },
    private val nowElapsedNanos: () -> Long = SystemClock::elapsedRealtimeNanos,
    dispatcher: CoroutineDispatcher = namedSingleThreadExecutor("roadcast-pump").asCoroutineDispatcher(),
) : SignalTransport {
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val lifecycleLock = Any()
    private var pumpJob: Job? = null
    private var client: RoadcastSession? = null
    private val subscriptionIds = AtomicLong()
    private val subscriptions = LinkedHashMap<Long, SubscriptionRecord>()
    private val wakeups = Channel<Unit>(Channel.CONFLATED)

    private val _state = MutableStateFlow<RoadcastState>(RoadcastState.Stopped)
    val state: StateFlow<RoadcastState> = _state.asStateFlow()

    override val transportName: String = "roadcast"

    /** The bus answers whatever the profile binds to a bus signal. */
    override fun answers(profile: VehicleProfile): Set<SignalKey> = profile.busSignals.keys

    /**
     * The daemon is connected and its last sample is recent.
     *
     * A connection alone is not delivery: the client stays open while the bus
     * is silent, and reporting that as delivery would make a quiet vehicle look
     * like a working one.
     */
    override fun isDelivering(): Boolean = client?.isAlive() == true

    override fun start() {
        synchronized(lifecycleLock) {
            if (pumpJob?.isActive == true) return
            pumpJob = scope.launch {
                while (isActive) {
                    refreshOnce()
                    withTimeoutOrNull(nextPollDelayMillis()) { wakeups.receive() }
                }
            }
        }
    }

    /** Stops all Kotlin access before the foreground service tears down. */
    override fun stop() {
        val job = synchronized(lifecycleLock) {
            pumpJob.also { pumpJob = null }
        } ?: return

        runBlocking {
            job.cancelAndJoin()
        }
        disconnect()
        _state.value = RoadcastState.Stopped
    }

    fun statusMap(): Map<String, Any?> = state.value.toStatusMap()

    /**
     * Registers a live watchlist. The repository unions every active watchlist
     * and performs one JNI batch read, even when multiple domain features use it.
     */
    fun subscribe(
        signals: Set<String>,
        cadence: RoadcastCadence = RoadcastCadence.tenHz,
    ): RoadcastSubscription {
        require(signals.isNotEmpty()) { "Roadcast subscription requires at least one signal" }
        val id = subscriptionIds.incrementAndGet()
        val flow = MutableStateFlow<RoadcastSnapshotState>(RoadcastSnapshotState.Waiting)
        synchronized(subscriptions) {
            subscriptions[id] = SubscriptionRecord(
                signals = signals.toSet(),
                cadence = cadence,
                state = flow,
            )
        }
        wakeups.trySend(Unit)
        return RoadcastSubscription(
            state = flow.asStateFlow(),
            closeAction = {
                synchronized(subscriptions) { subscriptions.remove(id) }
                wakeups.trySend(Unit)
            },
            setCadenceAction = { cadence ->
                val changed = synchronized(subscriptions) {
                    val record = subscriptions[id] ?: return@RoadcastSubscription
                    if (record.cadence.intervalNanos == cadence.intervalNanos) {
                        false
                    } else {
                        record.cadence = cadence
                        record.nextDueElapsedNanos = 0L
                        true
                    }
                }
                if (changed) wakeups.trySend(Unit)
            },
        )
    }

    /** Visible to JVM tests; production callers use [start] and [state]. */
    internal fun refreshOnce() {
        val active = ensureClient() ?: return
        val currentStatus = active.status()
        if (currentStatus == null || !active.isAlive()) {
            publishUnavailable("Roadcast stopped publishing; reconnecting")
            disconnect()
            return
        }

        val schema = when (val current = _state.value) {
            is RoadcastState.Ready -> current.schema
            is RoadcastState.Unavailable -> current.lastKnownSchema
            else -> emptyList()
        }
        if (schema.isEmpty()) {
            publishUnavailable("Roadcast schema was unavailable after connection")
            disconnect()
            return
        }
        _state.value = RoadcastState.Ready(schema, currentStatus)
        publishSamples(active, schema, currentStatus)
    }

    private fun ensureClient(): RoadcastSession? {
        client?.let { return it }
        _state.value = RoadcastState.Connecting

        val connected = connect().getOrElse { error ->
            publishUnavailable("Roadcast client failed to connect: ${error.message}")
            return null
        }
        val negotiatedSchema = runCatching { connected.schema() }.getOrElse { error ->
            connected.close()
            publishUnavailable("Roadcast schema negotiation failed: ${error.message}")
            return null
        }
        val currentStatus = connected.status()
        if (currentStatus == null || negotiatedSchema.size != currentStatus.signalCount) {
            connected.close()
            publishUnavailable("Roadcast returned an incomplete schema")
            return null
        }

        client = connected
        _state.value = RoadcastState.Ready(negotiatedSchema, currentStatus)
        return connected
    }

    private fun publishUnavailable(reason: String) {
        val previous = _state.value
        _state.value = RoadcastState.Unavailable(
            reason = reason,
            lastKnownSchema = previous.schemaOrEmpty(),
            lastKnownStatus = previous.statusOrNull(),
        )
        synchronized(subscriptions) {
            subscriptions.values.forEach { it.state.value = RoadcastSnapshotState.Unavailable(reason) }
        }
    }

    private fun publishSamples(
        active: RoadcastSession,
        schema: List<RoadcastSchemaEntry>,
        status: RoadcastClientStatus,
    ) {
        if (synchronized(subscriptions) { subscriptions.isEmpty() }) return
        val now = nowElapsedNanos()
        val due = synchronized(subscriptions) {
            subscriptions.values.filter { subscription ->
                now >= subscription.nextDueElapsedNanos
            }.onEach { subscription ->
                subscription.nextDueElapsedNanos = now + subscription.cadence.intervalNanos
            }
        }
        val requested = due.flatMapTo(linkedSetOf()) { it.signals }
        if (requested.isEmpty()) return

        val byName = schema.associateBy { it.name }
        val entries = requested.mapNotNull { byName[it] }.distinctBy { it.index }
        if (entries.isEmpty()) return

        val reading = RoadcastReading(entries.size)
        val result = active.read(entries.map { it.index }.toIntArray(), reading)
        if (result < 0) {
            publishUnavailable("Roadcast read failed ($result)")
            disconnect()
            return
        }

        val samples = buildMap {
            entries.forEachIndexed { position, entry ->
                put(entry.name, RoadcastSample(
                    raw = reading.rawAt(position),
                    physical = reading.valueAt(position),
                    valid = reading.isValidAt(position),
                    calibrated = reading.isCalibratedAt(position),
                    lastChangeNanos = reading.lastChangeNsAt(position),
                ))
            }
        }
        val snapshot = RoadcastSnapshot(
            sampleSequence = status.sampleSequence,
            receivedAtElapsedNanos = nowElapsedNanos(),
            sampleAgeNanos = active.sampleAgeNs(),
            samples = samples,
            missingSignals = requested - samples.keys,
        )
        due.forEach { it.state.value = RoadcastSnapshotState.Ready(snapshot) }
    }

    private fun disconnect() {
        client?.close()
        client = null
    }

    private fun nextPollDelayMillis(): Long {
        if (client == null) return RECONNECT_INTERVAL_MILLIS
        val now = nowElapsedNanos()
        val nextDue = synchronized(subscriptions) {
            subscriptions.values.minOfOrNull { it.nextDueElapsedNanos }
        } ?: return STATUS_INTERVAL_MILLIS
        return ((nextDue - now) / NANOS_PER_MILLI).coerceIn(1L, STATUS_INTERVAL_MILLIS)
    }

    companion object {
        private const val RECONNECT_INTERVAL_MILLIS = 500L
        private const val STATUS_INTERVAL_MILLIS = 500L
        private const val NANOS_PER_MILLI = 1_000_000L
    }
}

class RoadcastCadence private constructor(val intervalNanos: Long) {
    override fun equals(other: Any?): Boolean =
        other is RoadcastCadence && other.intervalNanos == intervalNanos

    override fun hashCode(): Int = intervalNanos.hashCode()

    companion object {
        val oneHz = hz(1)
        val tenHz = hz(10)
        val sixtyHz = hz(60)

        fun hz(value: Int): RoadcastCadence {
            require(value in 1..60) { "Roadcast cadence must be between 1 and 60 Hz" }
            return RoadcastCadence(1_000_000_000L / value)
        }
    }
}

private data class SubscriptionRecord(
    val signals: Set<String>,
    var cadence: RoadcastCadence,
    val state: MutableStateFlow<RoadcastSnapshotState>,
    var nextDueElapsedNanos: Long = 0L,
)

data class RoadcastSample(
    val raw: Long,
    val physical: Double,
    val valid: Boolean,
    val calibrated: Boolean,
    val lastChangeNanos: Long,
)

data class RoadcastSnapshot(
    val sampleSequence: Long,
    val receivedAtElapsedNanos: Long,
    val sampleAgeNanos: Long,
    val samples: Map<String, RoadcastSample>,
    val missingSignals: Set<String>,
) {
    fun sample(name: String): RoadcastSample? = samples[name]
}

sealed interface RoadcastSnapshotState {
    data object Waiting : RoadcastSnapshotState
    data class Ready(val snapshot: RoadcastSnapshot) : RoadcastSnapshotState
    data class Unavailable(val reason: String) : RoadcastSnapshotState
}

class RoadcastSubscription internal constructor(
    val state: StateFlow<RoadcastSnapshotState>,
    private val closeAction: () -> Unit,
    private val setCadenceAction: (RoadcastCadence) -> Unit = {},
) : AutoCloseable {
    override fun close() = closeAction()

    /**
     * Changes how often this watchlist is read. A faster cadence is due at
     * once, so a trip that just armed does not wait out the idle interval.
     */
    fun setCadence(cadence: RoadcastCadence) = setCadenceAction(cadence)
}

sealed interface RoadcastState {
    data object Stopped : RoadcastState
    data object Connecting : RoadcastState

    data class Ready(
        val schema: List<RoadcastSchemaEntry>,
        val status: RoadcastClientStatus,
    ) : RoadcastState

    data class Unavailable(
        val reason: String,
        val lastKnownSchema: List<RoadcastSchemaEntry> = emptyList(),
        val lastKnownStatus: RoadcastClientStatus? = null,
    ) : RoadcastState
}

private fun RoadcastState.schemaOrEmpty(): List<RoadcastSchemaEntry> = when (this) {
    is RoadcastState.Ready -> schema
    is RoadcastState.Unavailable -> lastKnownSchema
    RoadcastState.Connecting,
    RoadcastState.Stopped -> emptyList()
}

private fun RoadcastState.statusOrNull(): RoadcastClientStatus? = when (this) {
    is RoadcastState.Ready -> status
    is RoadcastState.Unavailable -> lastKnownStatus
    RoadcastState.Connecting,
    RoadcastState.Stopped -> null
}

private fun RoadcastState.toStatusMap(): Map<String, Any?> {
    val status = statusOrNull()
    val schema = schemaOrEmpty()
    val error = (this as? RoadcastState.Unavailable)?.reason
    return mapOf(
        "source" to "ROADCAST",
        "attached" to (this is RoadcastState.Ready),
        "schemaLoaded" to schema.isNotEmpty(),
        "schemaSignalCount" to schema.size,
        "calibratedSignalCount" to schema.count { it.calibrated },
        "signalCount" to (status?.signalCount ?: 0),
        "frameCount" to (status?.frameCount ?: 0),
        "hz" to (status?.hz ?: 0),
        "schemaVersion" to (status?.schemaVersion ?: 0),
        "schemaHash" to (status?.schemaHash ?: 0L),
        "sampleSequence" to (status?.sampleSequence ?: 0L),
        "droppedBatches" to (status?.droppedBatches ?: 0L),
        "coalescedSamples" to (status?.coalescedSamples ?: 0L),
        "resynchronizations" to (status?.resynchronizations ?: 0L),
        "error" to error,
    )
}
