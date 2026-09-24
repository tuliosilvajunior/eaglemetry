package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.GeelyProfile
import com.timhss.capyenergy.profile.SignalKey
import com.timhss.capyenergy.telemetry.db.TelemetryEventDao
import com.timhss.capyenergy.profile.VehicleProfile

import android.content.Context
import android.util.Log
import com.timhss.capyenergy.telemetry.db.TelemetryDatabase
import com.timhss.capyenergy.telemetry.db.TelemetryEventEntity
import java.io.File
import java.util.ArrayDeque
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONObject

class EventRepository(
    context: Context,
    private val eventFileEnabledProvider: () -> Boolean = { false },
    /**
     * The session a signal event lands in, or null when none is open.
     *
     * A session event carried its id from the start; a signal event never
     * did, so `telemetry_events.sessionId` was null on every one of them and a
     * trip's event list could only ever show the four lifecycle rows. The
     * default keeps a test that only exercises the event policy free of a
     * session store.
     */
    private val profile: VehicleProfile = GeelyProfile,
    /**
     * Issue 226 test seams. The database write and the write queue are
     * injectable so the persistence gate can be tested at the database seam
     * on the JVM, where Room and the coordinator's executor cannot run.
     * Production passes neither and gets the singletons.
     */
    private val accountIdProvider: () -> String? = { null },
    private val eventDaoOverride: TelemetryEventDao? = null,
    private val writeExecutorOverride: ObservedWriteExecutor? = null,
) : SignalStateStore.Listener, TripEventSink, ChargeEventSink {

    /**
     * Assigned by [TelemetryGraph] once the detectors exist.
     *
     * It is set after construction rather than passed in because this
     * repository is built before the detectors that answer it — the graph
     * declares it early, and the session detectors hold it as their event
     * sink.
     */
    var activeSessionProvider: () -> ActiveFrameSession? = { null }
    private val appContext = context.applicationContext
    private val eventFile = File(context.applicationContext.filesDir, EVENT_FILE_NAME)
    private val eventDao = eventDaoOverride ?: TelemetryDatabase.get(appContext).telemetryEventDao()
    private val writeExecutor = writeExecutorOverride ?: TelemetryWriteCoordinator.executor
    private val roomInsertedEvents = AtomicLong(0L)
    private val droppedEvents = AtomicLong(0L)
    private val vehicleActivityDetector = VehicleActivityDetector()
    private val eventPolicy = SignalEventPolicy()
    private val persistencePolicy = EventPersistencePolicy(profile)
    private val recentEvents = ArrayDeque<TelemetryEvent>()
    private val lastLoggedValues = mutableMapOf<SignalKey, Any?>()
    private val previousQualities = mutableMapOf<SignalKey, SignalQuality>()
    private var previousActivity: VehicleActivity? = null

    @Synchronized
    override fun onSignalUpdated(sample: SignalSample, snapshot: Map<SignalKey, SignalSample>) {
        val lastLoggedValue = lastLoggedValues[sample.signalId]
        val previousQuality = previousQualities[sample.signalId]
        previousQualities[sample.signalId] = sample.quality
        val shouldLog = eventPolicy.shouldLog(
            signalId = sample.signalId,
            previousQuality = previousQuality,
            quality = sample.quality,
            lastLoggedValue = lastLoggedValue,
            newValue = sample.value
        )
        if (shouldLog) {
            lastLoggedValues[sample.signalId] = sample.value
            appendEvent(signalEvent(sample, lastLoggedValue))
        }

        val activity = vehicleActivityDetector.classify(snapshot)
        if (activity != previousActivity) {
            val previous = previousActivity
            previousActivity = activity
            appendEvent(
                TelemetryEvent(
                    id = UUID.randomUUID().toString(),
                    type = TelemetryEventType.VEHICLE_ACTIVITY_CHANGED,
                    timestamp = sample.timestamp,
                    signalId = null,
                    value = activity.name,
                    previousValue = previous?.name,
                    quality = null,
                    source = sample.source,
                    details = "vehicleActivity=$activity previous=$previous"
                )
            )
        }
    }

    fun recent(limit: Int): List<TelemetryEvent> = synchronized(recentEvents) {
        val safeLimit = limit.coerceAtLeast(0)
        val snapshot = recentEvents.toList()
        snapshot.drop((snapshot.size - safeLimit).coerceAtLeast(0))
    }

    fun recentMap(limit: Int): Map<String, Any?> = mapOf(
        "events" to recent(limit).map { it.toMap() },
        "eventFile" to eventFile.absolutePath,
        "database" to appContext.getDatabasePath(DATABASE_NAME).absolutePath,
        "databaseInsertedThisRun" to roomInsertedEvents.get(),
        "droppedEventsThisRun" to droppedEvents.get()
    )

    fun statusMap(): Map<String, Any?> = mapOf(
        "databaseInsertedThisRun" to roomInsertedEvents.get(),
        "droppedEventsThisRun" to droppedEvents.get()
    )

    @Synchronized
    fun resetInMemory() {
        synchronized(recentEvents) {
            recentEvents.clear()
        }
        lastLoggedValues.clear()
        previousQualities.clear()
        previousActivity = null
        roomInsertedEvents.set(0L)
        droppedEvents.set(0L)
        deleteEventFiles()
    }

    /** Removes the debug JSONL mirror; posted to the executor to avoid racing appends. */
    fun deleteEventFiles() {
        writeExecutor.executeWrite(
            operation = "delete_debug_event_files",
            overflowPolicy = ObservedWriteExecutor.OverflowPolicy.DROP_NEWEST,
            onFailure = { Log.w(TAG, "Failed to delete telemetry event files", it) }
        ) { deleteEventFilesLocked() }
    }

    private fun deleteEventFilesLocked() {
        try {
            eventFile.delete()
        } catch (_: Exception) {
        }
        // Covers rotations beyond the current MAX_ROTATED_FILES left by older builds.
        (1..LEGACY_MAX_ROTATED_FILES).forEach { index ->
            try {
                File(eventFile.absolutePath + ".$index").delete()
            } catch (_: Exception) {
            }
        }
    }

    private fun rotateSuffixes(): List<String> = (1..MAX_ROTATED_FILES).map { ".$it" }

    override fun appendEvent(event: TelemetryEvent) {
        synchronized(recentEvents) {
            recentEvents.addLast(event)
            while (recentEvents.size > MAX_RECENT_EVENTS) {
                recentEvents.removeFirst()
            }
        }
        // Issue 226 origin filter: events below the persistence bar live only
        // in [recentEvents]. Continuous or parked-hardware signal churn
        // (odometer ticks, pedal presses, door latches) updates live state
        // and never reaches flash.
        if (!persistencePolicy.shouldPersist(event)) return
        val accepted = writeExecutor.executeWrite(
            operation = "insert_event",
            acceptedElapsedNanos = event.timestamp.receivedAtElapsedNanos,
            overflowPolicy = if (event.isCriticalPersistenceEvent()) {
                ObservedWriteExecutor.OverflowPolicy.BLOCK
            } else {
                ObservedWriteExecutor.OverflowPolicy.DROP_NEWEST
            },
            onFailure = { Log.w(TAG, "Failed to persist telemetry event", it) }
        ) {
            try {
                if (eventFileEnabledProvider()) {
                    eventFile.parentFile?.mkdirs()
                    rotateIfNeeded()
                    eventFile.appendText(event.toJson().toString() + "\n")
                } else {
                    deleteEventFilesLocked()
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to persist telemetry event", e)
            }
            // Every event carries the account that was pairing when it was
            // born — including signal events with no session. They have no
            // session to inherit an owner from, so the stamp at insert is the
            // only rule for them: an unowned event is adopted by the first
            // account that claims it, a stamped one never changes hands.
            // (gb236-p4: the design left this class open; stamping at birth
            // keeps one rule for every row instead of a second mechanism.)
            eventDao.insert(
                TelemetryEventEntity.fromEvent(event, accountIdProvider())
            )
        }
        if (!accepted) droppedEvents.incrementAndGet()
    }

    private fun rotateIfNeeded() {
        if (!eventFile.exists() || eventFile.length() <= MAX_EVENT_FILE_BYTES) return
        val suffixes = rotateSuffixes()
        File(eventFile.absolutePath + suffixes.last()).delete()
        for (index in suffixes.size - 2 downTo 0) {
            val current = File(eventFile.absolutePath + suffixes[index])
            if (current.exists()) {
                current.renameTo(File(eventFile.absolutePath + suffixes[index + 1]))
            }
        }
        eventFile.renameTo(File(eventFile.absolutePath + suffixes.first()))
    }

    private fun TelemetryEvent.isCriticalPersistenceEvent(): Boolean = when (type) {
        TelemetryEventType.SIGNAL_UPDATED -> false
        else -> true
    }

    private fun signalEvent(sample: SignalSample, previousValue: Any?): TelemetryEvent {
        val type = when (sample.quality) {
            SignalQuality.ERROR -> TelemetryEventType.SIGNAL_ERROR
            SignalQuality.UNAVAILABLE -> TelemetryEventType.SIGNAL_UNAVAILABLE
            else -> TelemetryEventType.SIGNAL_UPDATED
        }
        return TelemetryEvent(
            id = UUID.randomUUID().toString(),
            type = type,
            timestamp = sample.timestamp,
            signalId = sample.signalId,
            value = sample.value,
            previousValue = previousValue,
            quality = sample.quality,
            source = sample.source,
            details = sample.details,
            // Only a declared key joins a session. The rest is still recorded,
            // and stays out of the list a person reads by having no session.
            sessionId = if (profile.isSessionEvent(sample.signalId)) {
                activeSessionProvider()?.id
            } else {
                null
            }
        )
    }

    /**
     * Gives a session the declared events that happened before it existed.
     *
     * A trip is opened when the detector is sure, and it is back-dated to when
     * movement began. The gear change that started the drive is therefore
     * written before the session row exists, and it is exactly the event the
     * list most needs. `TelemetryEventDao.backStampSession` was written for
     * this and had no caller until now.
     *
     * Only an unstamped row is claimed, so a session never takes an event from
     * the one before it.
     */
    override fun backStampSession(sessionId: String, fromUtcMillis: Long, toUtcMillis: Long) {
        writeExecutor.executeWrite(
            operation = "back_stamp_events",
            acceptedElapsedNanos = null,
            overflowPolicy = ObservedWriteExecutor.OverflowPolicy.DROP_NEWEST,
            onFailure = { Log.w(TAG, "Failed to back-stamp events", it) }
        ) {
            val orphans = eventDao
                .orphansInWindow(fromUtcMillis, toUtcMillis)
                .filter { entity ->
                    val key = entity.signalId?.let { name ->
                        SignalKey.entries.firstOrNull { it.name == name }
                    }
                    key != null && profile.isSessionEvent(key)
                }
            if (orphans.isNotEmpty()) {
                eventDao.backStampSession(sessionId, orphans.map { it.id })
            }
        }
    }

    override fun sessionEvent(
        type: TelemetryEventType,
        timestamp: SignalTimestamp,
        value: Any?,
        previousValue: Any?,
        source: SignalSource?,
        details: String,
        sessionId: String?
    ): TelemetryEvent {
        return TelemetryEvent(
            id = UUID.randomUUID().toString(),
            type = type,
            timestamp = timestamp,
            signalId = null,
            value = value,
            previousValue = previousValue,
            quality = null,
            source = source,
            details = details,
            sessionId = sessionId
        )
    }

    fun sessionEvent(
        type: TelemetryEventType,
        timestamp: SignalTimestamp,
        value: Any?,
        source: SignalSource?,
        details: String,
        sessionId: String? = null
    ): TelemetryEvent {
        return sessionEvent(
            type = type,
            timestamp = timestamp,
            value = value,
            previousValue = null,
            source = source,
            details = details,
            sessionId = sessionId
        )
    }

    private fun TelemetryEvent.toJson(): JSONObject {
        val timestampJson = JSONObject()
            .put("receivedAtUtcMillis", timestamp.receivedAtUtcMillis)
            .put("receivedAtElapsedNanos", timestamp.receivedAtElapsedNanos)
            .put("sourceTimestampNanos", timestamp.sourceTimestampNanos)
            .put("accuracy", timestamp.accuracy.name)
            .put("uncertaintyMillis", timestamp.uncertaintyMillis)
        return JSONObject()
            .put("id", id)
            .put("type", type.name)
            .put("timestamp", timestampJson)
            .put("occurredAtUtcMillis", timestamp.receivedAtUtcMillis)
            .put("occurredAtElapsedNanos", timestamp.receivedAtElapsedNanos)
            .put("sourceTimestampNanos", timestamp.sourceTimestampNanos)
            .put("timestampAccuracy", timestamp.accuracy.name)
            .put("uncertaintyMillis", timestamp.uncertaintyMillis)
            .put("signalId", signalId?.name)
            .put("value", jsonValue(value))
            .put("previousValue", jsonValue(previousValue))
            .put("quality", quality?.name)
            .put("source", source?.name)
            .put("details", details)
            .put("sessionId", sessionId ?: JSONObject.NULL)
    }

    private fun jsonValue(value: Any?): Any = when (value) {
        null -> JSONObject.NULL
        is Number, is Boolean, is String -> value
        else -> value.toString()
    }

    companion object {
        private const val TAG = "EventRepository"
        private const val EVENT_FILE_NAME = "telemetry_events.jsonl"
        private const val DATABASE_NAME = "geely_telemetry.db"
        private const val MAX_RECENT_EVENTS = 500
        private const val MAX_EVENT_FILE_BYTES = 5L * 1024 * 1024
        private const val MAX_ROTATED_FILES = 1
        private const val LEGACY_MAX_ROTATED_FILES = 2
    }
}
