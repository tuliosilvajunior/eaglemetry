package com.timhss.capyenergy.telemetry

import android.content.Context
import com.timhss.capyenergy.BuildConfig
import com.timhss.capyenergy.telemetry.db.TelemetryDatabase
import com.timhss.capyenergy.telemetry.sync.SyncStreamType
import java.util.concurrent.atomic.AtomicLong

class TelemetryRetentionManager(
    context: Context,
    private val capacityWhProvider: () -> Double? = { null },
    private val nowUtcMillisProvider: () -> Long = { System.currentTimeMillis() }
) {
    private val appContext = context.applicationContext
    private val database = TelemetryDatabase.get(appContext)

    private val writeExecutor = TelemetryWriteCoordinator.executor
    private val prefs = appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val attempts = AtomicLong(0L)
    private val failures = AtomicLong(0L)

    @Volatile
    private var running = false

    @Volatile
    private var lastHealth: Map<String, Any?> = emptyMap()

    @Volatile
    private var activeSessionProvider: () -> Boolean = { false }

    fun setActiveSessionProvider(provider: () -> Boolean) {
        activeSessionProvider = provider
    }

    fun runRetention(force: Boolean = false): Map<String, Any?> {
        val startedAt = nowUtcMillisProvider()
        val startedNanos = System.nanoTime()
        attempts.incrementAndGet()
        running = true
        return try {
            runRetentionInternal(force).also { result ->
                lastHealth = mapOf(
                    "lastStartedUtcMillis" to startedAt,
                    "lastCompletedUtcMillis" to nowUtcMillisProvider(),
                    "lastDurationMillis" to elapsedMillis(startedNanos),
                    "lastResult" to result,
                    "lastError" to null
                )
            }
        } catch (error: Throwable) {
            failures.incrementAndGet()
            lastHealth = mapOf(
                "lastStartedUtcMillis" to startedAt,
                "lastCompletedUtcMillis" to nowUtcMillisProvider(),
                "lastDurationMillis" to elapsedMillis(startedNanos),
                "lastResult" to null,
                "lastError" to "${error.javaClass.simpleName}: ${error.message}".take(500)
            )
            throw error
        } finally {
            running = false
        }
    }

    fun statusMap(): Map<String, Any?> = mapOf(
        "running" to running,
        "attemptsThisRun" to attempts.get(),
        "failuresThisRun" to failures.get(),
        "configuredRetentionDays" to retentionDays(),
        "configuredContinuousRetentionDays" to continuousRetentionDays()
    ) + lastHealth

    private fun runRetentionInternal(force: Boolean): Map<String, Any?> {
        val now = nowUtcMillisProvider()
        if (activeSessionProvider()) {
            return mapOf(
                "ok" to true,
                "skipped" to true,
                "reason" to "active_session",
                "retentionDays" to retentionDays(),
                "timestampMillis" to now
            )
        }
        val lastRun = prefs.getLong(KEY_LAST_RUN_UTC_MILLIS, 0L)
        if (!force && now - lastRun < RETENTION_RUN_COOLDOWN_MILLIS) {
            return mapOf(
                "ok" to true,
                "skipped" to true,
                "reason" to "cooldown",
                "lastRunUtcMillis" to lastRun,
                "retentionDays" to retentionDays(),
                "timestampMillis" to now
            )
        }

        val retentionDays = retentionDays()
        val cutoffUtcMillis = now - retentionDays * DAY_MILLIS
        val aggregatesUpserted = backfillAggregates(now)

        val orphanEventsDeleted = deleteInChunks("retention_delete_orphan_events") {
            database.telemetryEventDao().deleteOrphanSessionEventsChunk(DELETE_CHUNK_SIZE)
        }
        val eventsDeleted = deleteEventsRespectingSync(cutoffUtcMillis)
        val parkedSessionsDeleted = deleteParkedRespectingSync(cutoffUtcMillis)
        val continuousCutoffUtcMillis = now - continuousRetentionDays() * DAY_MILLIS
        val continuousSessionsDeleted = deleteContinuousRespectingSync(continuousCutoffUtcMillis)
        // Orphan rows name a session that no longer exists, so they are GC
        // (ungated on the pending-upload mark), not age retention.
        // Finding 9: chunked, after the session deletes above orphaned their
        // intervals. One unchunked deleteOrphans() of months of continuous
        // minutes holds the write lock for seconds and stalls frame writes.
        val orphanIntervalsDeleted = deleteInChunks("retention_delete_orphan_intervals") {
            database.intervalDao().deleteOrphansChunk(DELETE_CHUNK_SIZE)
        }
        val orphanTripSegmentsDeleted = database.tripSegmentDao().deleteOrphans()
        // A route outlives its Session otherwise. One row per Session, so this
        // is one delete and not a chunked sweep.
        val orphanTracksDeleted = database.trackDao().deleteOrphans()

        val eligibleForNoLongerReducible = database.sessionDao().sessionsEligibleForNoLongerReducible()
        for (sessionId in eligibleForNoLongerReducible) {
            database.sessionDao().markNoLongerReducible(sessionId, now)
        }

        if (activeSessionProvider()) {
            return mapOf(
                "ok" to true,
                "skipped" to true,
                "reason" to "active_session_started",
                "retentionDays" to retentionDays,
                "aggregatesUpserted" to aggregatesUpserted,
                "orphanEventsDeleted" to orphanEventsDeleted,
                "telemetryEventsDeleted" to eventsDeleted,
                "parkedSessionsDeleted" to parkedSessionsDeleted,
                "continuousSessionsDeleted" to continuousSessionsDeleted,
                "orphanIntervalsDeleted" to orphanIntervalsDeleted,
                "orphanTracksDeleted" to orphanTracksDeleted,
                "timestampMillis" to nowUtcMillisProvider()
            )
        }
        prefs.edit().putLong(KEY_LAST_RUN_UTC_MILLIS, now).apply()

        return mapOf(
            "ok" to true,
            "skipped" to false,
            "retentionDays" to retentionDays,
            "cutoffUtcMillis" to cutoffUtcMillis,
            "aggregatesUpserted" to aggregatesUpserted,
            "orphanEventsDeleted" to orphanEventsDeleted,
            "telemetryEventsDeleted" to eventsDeleted,
            "parkedSessionsDeleted" to parkedSessionsDeleted,
            "continuousSessionsDeleted" to continuousSessionsDeleted,
            "orphanEnergyBucketsDeleted" to orphanIntervalsDeleted,
            "orphanTripSegmentsDeleted" to orphanTripSegmentsDeleted,
            "orphanTracksDeleted" to orphanTracksDeleted,
            "sessionsAwaitingAggregate" to 0,
            "sessionsAwaitingAggregateIds" to emptyList<String>(),
            "lastRunUtcMillis" to now,
            "timestampMillis" to now
        )
    }

    fun backfillAggregates(now: Long = nowUtcMillisProvider()): Int {
        var count = 0
        val sessionDao = database.sessionDao()
        val finalizer = SessionFinalizer(database, capacityWhProvider)
        for (session in sessionDao.unfinalizedClosed()) {
            if (activeSessionProvider()) break
            val ok = runCatching {
                finalizer.finalize(session.copy(status = SessionFinalizer.FINALIZATION_PENDING), terminalStatus = session.status)
            }.isSuccess
            if (ok) count++
        }
        return count
    }

    /**
     * Deletes events older than cutoff, holding back anything after the slowest
     * confirmed device's cursor floor.
     */
    private fun deleteEventsRespectingSync(cutoffUtcMillis: Long): Int {
        val eventDao = database.telemetryEventDao()
        val confirmedIds = database.syncCursorDao()
            .confirmedRecordIdsForStream(SyncStreamType.EVENTS.wireName)
        if (confirmedIds.isEmpty()) {
            return deleteInChunks("retention_delete_events") {
                eventDao.deleteOlderThanChunk(cutoffUtcMillis, DELETE_CHUNK_SIZE)
            }
        }

        val floorId = confirmedIds
            .mapNotNull { it.toLongOrNull() }
            .minOrNull()
            ?: return deleteInChunks("retention_delete_events") {
                eventDao.deleteOlderThanChunk(cutoffUtcMillis, DELETE_CHUNK_SIZE)
            }

        return deleteInChunks("retention_delete_events_confirmed") {
            eventDao.deleteOlderThanConfirmedChunk(cutoffUtcMillis, floorId, DELETE_CHUNK_SIZE)
        }
    }

    /**
     * The parked purge, under rule 2.7: a session no device has confirmed is not
     * deleted, whatever its age.
     *
     * A parked session is the one whole row retention removes by age, and
     * `SESSIONS` is a sync stream, so the row can leave the car before a phone
     * ever saw it. The floor is the least advanced device's confirmed position.
     *
     * **No cursor means no restriction.** A car nobody pairs a phone to must
     * still clean itself up; blocking on an acknowledgement that will never come
     * would grow the database without bound. The floor only exists once a device
     * has actually confirmed something, which is the only moment the car learns
     * that anyone is reading.
     *
     * A cursor pointing at a session that is already gone is ignored: that phone
     * gets `SyncCursorNotFound` on its next pull, resets and re-reads, so it
     * constrains nothing here.
     */
    private fun deleteParkedRespectingSync(cutoffUtcMillis: Long): Int {
        val sessionDao = database.sessionDao()
        val confirmedIds = database.syncCursorDao()
            .confirmedRecordIdsForStream(SyncStreamType.SESSIONS.wireName)
        if (confirmedIds.isEmpty()) {
            return sessionDao.deleteOlderThan(cutoffUtcMillis)
        }

        val floor = confirmedIds
            .mapNotNull { sessionDao.findById(it)?.startedAtUtcMillis }
            .minOrNull()
            ?: return sessionDao.deleteOlderThan(cutoffUtcMillis)

        return sessionDao.deleteOlderThanConfirmed(cutoffUtcMillis, floor)
    }

    /**
     * Finding 4: continuous sessions are local/cloud-only and excluded from
     * companion sync streams, so no companion cursor may hold them back.
     * Finding 1: when the backstop below is active, the `dirty = 0` gate is
     * bypassed as well, else an unpaired vehicle grows without bound.
     */
    private fun deleteContinuousRespectingSync(cutoffUtcMillis: Long): Int {
        val sessionDao = database.sessionDao()
        return if (continuousBackstopActive()) {
            sessionDao.deleteContinuousOlderThanIgnoringDirty(cutoffUtcMillis)
        } else {
            sessionDao.deleteContinuousOlderThan(cutoffUtcMillis)
        }
    }

    /**
     * Finding 1 backstop: every continuous session is born `dirty = 1` and
     * only the cloud uploader clears it, so a vehicle without cloud upload
     * would never delete anything. When cloud upload is off/unconfigured,
     * or the session count exceeds 2x the retention window (default 180
     * days, so 360 sessions), delete by age alone.
     */
    private fun continuousBackstopActive(): Boolean {
        if (!BuildConfig.CLOUD_SYNC_ENABLED) return true
        if (BuildConfig.SUPABASE_URL.isBlank() || BuildConfig.SUPABASE_ANON_KEY.isBlank()) return true
        return database.sessionDao().countByKind("CONTINUOUS") > continuousRetentionDays() * 2
    }

    private fun retentionDays(): Long {
        return prefs.getLong(KEY_RAW_RETENTION_DAYS, DEFAULT_RAW_RETENTION_DAYS)
            .coerceIn(MIN_RAW_RETENTION_DAYS, MAX_RAW_RETENTION_DAYS)
    }

    /**
     * How long `CONTINUOUS` minutes are kept, separate from [retentionDays]:
     * keeping raw frames short and continuous history long is a choice the
     * owner can make, not one setting doing both jobs.
     */
    private fun continuousRetentionDays(): Long {
        return prefs.getLong(KEY_CONTINUOUS_RETENTION_DAYS, DEFAULT_CONTINUOUS_RETENTION_DAYS)
            .coerceIn(MIN_CONTINUOUS_RETENTION_DAYS, MAX_CONTINUOUS_RETENTION_DAYS)
    }

    fun setContinuousRetentionDays(days: Long) {
        prefs.edit()
            .putLong(
                KEY_CONTINUOUS_RETENTION_DAYS,
                days.coerceIn(MIN_CONTINUOUS_RETENTION_DAYS, MAX_CONTINUOUS_RETENTION_DAYS)
            )
            .apply()
    }

    private fun elapsedMillis(startedNanos: Long): Long =
        (System.nanoTime() - startedNanos).coerceAtLeast(0L) / 1_000_000L

    private fun deleteInChunks(operation: String, deleteChunk: () -> Int): Int {
        var total = 0
        while (!activeSessionProvider()) {
            val deleted = writeExecutor.call(operation, trackAsWrite = true) { deleteChunk() }
            total += deleted
            if (deleted < DELETE_CHUNK_SIZE) break
        }
        return total
    }

    companion object {
        private const val PREFS_NAME = "telemetry_retention"
        private const val KEY_RAW_RETENTION_DAYS = "raw_retention_days"
        private const val KEY_CONTINUOUS_RETENTION_DAYS = "continuous_retention_days"
        private const val KEY_LAST_RUN_UTC_MILLIS = "last_run_utc_millis"
        private const val DEFAULT_RAW_RETENTION_DAYS = 30L
        private const val MIN_RAW_RETENTION_DAYS = 1L
        private const val MAX_RAW_RETENTION_DAYS = 3650L
        // Longer than the raw retention default on purpose: the timeline is
        // meant to answer "since power on" over a much longer span than raw
        // frames need to, at a fraction of the storage cost per day.
        private const val DEFAULT_CONTINUOUS_RETENTION_DAYS = 180L
        private const val MIN_CONTINUOUS_RETENTION_DAYS = 1L
        private const val MAX_CONTINUOUS_RETENTION_DAYS = 3650L
        private const val DAY_MILLIS = 86_400_000L
        private const val RETENTION_RUN_COOLDOWN_MILLIS = DAY_MILLIS
        private const val DELETE_CHUNK_SIZE = 2_000
        private const val BLOCKED_SESSION_REPORT_LIMIT = 20
    }
}
