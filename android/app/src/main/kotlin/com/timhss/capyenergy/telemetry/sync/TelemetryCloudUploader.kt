package com.timhss.capyenergy.telemetry.sync

import com.timhss.capyenergy.telemetry.ClockUnlockBackfillEngine
import com.timhss.capyenergy.telemetry.ReplacedIntervalKey
import com.timhss.capyenergy.telemetry.db.BatteryCycleDao
import com.timhss.capyenergy.telemetry.db.IntervalDao
import com.timhss.capyenergy.telemetry.db.IntervalReplacedKeyDao
import com.timhss.capyenergy.telemetry.db.SessionDao
import com.timhss.capyenergy.telemetry.db.TelemetryEventDao
import com.timhss.capyenergy.telemetry.db.TrackDao
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.async
import kotlinx.coroutines.supervisorScope

/**
 * Where a cloud row goes.
 *
 * The uploader knows the table, the natural key and the order of the
 * streams. It does not know the provider. That keeps the rule the companion
 * already follows: **one file knows it is Supabase**, and a provider error
 * never reaches a screen as server text.
 */
interface CloudSink {
    /**
     * Writes [rows] into [table].
     *
     * [conflictColumns] names the key that makes a replay a no-op. When
     * [merge] is false a row already present is left as-is; when true the
     * row is replaced, which is what a session that closed after its first
     * upload needs.
     */
    suspend fun upsert(
        table: String,
        rows: List<Map<String, Any?>>,
        conflictColumns: List<String>,
        merge: Boolean
    )

    /**
     * Removes from [table] exactly the rows named by [keys], scoped to
     * [vehicleId]. The cloud's own RLS refuses any key that does not belong
     * to the device token's vehicle and account (the T9 cross-account
     * guard) — this method never filters beyond what the caller names.
     *
     * [keys] are the natural-key triples minus the vehicle: the corrected
     * re-upload deletes only the OLD wrong stamps the sweeper rewrote, never
     * the corrected ones and never a blanket.
     */
    suspend fun delete(
        table: String,
        vehicleId: String,
        keys: List<Triple<String, String, Long>>
    )

    /**
     * Which of [ids] this account owns.
     *
     * The read is scoped by the cloud's own RLS, so an id that belongs to
     * somebody else comes back absent.
     */
    suspend fun ownedVehicles(ids: Set<String>): Set<String> = ids
}

/**
 * What one cloud upload run moved.
 */
data class TelemetryCloudUploadReport(
    val perStream: Map<String, Int> = emptyMap()
) {
    val total: Int get() = perStream.values.sum()
    val movedNothing: Boolean get() = total == 0
}

/**
 * A cloud upload that the sink refused.
 *
 * [retryable] is true for network and provider errors that a later run may
 * recover from. A non-retryable fault (authentication, schema) should not be
 * retried without intervention.
 */
class TelemetryCloudUploadException(
    val table: String,
    cause: Throwable,
    val retryable: Boolean = true
) : Exception("Cloud upload failed for $table: ${cause.message}", cause) {
    companion object {
        /**
         * True for transient faults a retry may recover from; false for
         * permanent faults that a retry will repeat.
         *
         * Permanent: 401/403 auth revocation, constraint text, or a
         * non-retryable [HttpCloudSinkException.statusCode]. The structured
         * status wins over message text: the message embeds the request URL
         * and body, where 409/422-shaped digits occur naturally.
         * Transient: network, timeout, 408/429, 5xx.
         */
        fun isRetryable(error: Throwable): Boolean {
            var s: Throwable? = error
            while (s != null) {
                if (s is HttpCloudSinkException) {
                    return s.statusCode == 408 || s.statusCode == 429 || s.statusCode >= 500
                }
                s = s.cause
            }
            var cur: Throwable? = error
            while (cur != null) {
                val msg = (cur.message ?: "").lowercase()
                if (msg.contains("401") || msg.contains("403")) return false
                if (msg.contains("constraint") || msg.contains("violates") ) return false
                // SQLite / Postgrest constraint messages often carry these
                if (msg.contains("unique constraint") || msg.contains("foreign key")) return false
                cur = cur.cause
            }
            // Class-name heuristic for timeouts that may carry no 5xx text.
            var c: Throwable? = error
            while (c != null) {
                val name = c.javaClass.simpleName.lowercase()
                if (name.contains("timeout") || name.contains("interrupted")) return true
                c = c.cause
            }
            return true
        }
    }
}
/**
 * Queries `dirty = 1` rows from Room DAOs, formats them under natural keys,
 * and dispatches chunked batches to a [CloudSink].
 *
 * Ordering: sessions first (foreign key root), then intervals, tracks,
 * telemetry events, and battery cycles. A run that stops halfway leaves a
 * shorter history, never a broken one.
 *
 * Each stream is sent in configurable chunks (default 100 rows per request)
 * to prevent oversized payloads over a mobile connection. A failed chunk is
 * not cleared, so a retry repeats it — safe because every write is keyed.
 *
 * Formatting follows `MeasurementIngestionSchemaTest`: `toExportRow()` maps
 * are snake_cased and augmented with `vehicle_id` + `account_id`. The
 * `dirty` and `rowId` fields are never exported.
 */
class TelemetryCloudUploader(
    private val sessionDao: SessionDao,
    private val intervalDao: IntervalDao,
    private val trackDao: TrackDao,
    private val telemetryEventDao: TelemetryEventDao,
    private val batteryCycleDao: BatteryCycleDao,
    private val intervalReplacedKeyDao: IntervalReplacedKeyDao? = null,
    private val sink: CloudSink,
    private val vehicleIdProvider: () -> String?,
    private val accountIdProvider: () -> String?,
    private val aliases: com.timhss.capyenergy.telemetry.VehicleIdAliasStore? = null,
    // Upload eligibility (cloud gate + registered-or-approved status), decided
    // by the caller. A null account is NOT a stop: a registered-but-unclaimed
    // car uploads with account_id = null (Phase 1 RLS accepts unclaimed rows).
    private val uploadEnabledProvider: () -> Boolean = { true },
    private val chunkSize: Int = 1000,
    private val replacedKeyPageSize: Int = 1000
) {

    companion object {
        /**
         * Most ids one `WHERE … IN (:ids)` statement may bind.
         *
         * SQLite before 3.32 (Android 9 on the head unit) refuses more than 999
         * host variables. An upload chunk may be larger than that, so the dirty
         * marks are cleared in slices of this size, never one statement per
         * chunk.
         */
        const val MAX_BIND_VARIABLES = 500

        const val SESSION_TABLE = "session"
        const val INTERVAL_TABLE = "interval"
        const val TRACK_TABLE = "track"
        const val EVENT_TABLE = "telemetry_events"
        const val CYCLE_TABLE = "battery_cycles"

        val SESSION_CONFLICT = listOf("vehicle_id", "id")
        val INTERVAL_CONFLICT = listOf("vehicle_id", "session_id", "start_utc_millis")
        val TRACK_CONFLICT = listOf("vehicle_id", "session_id")
        val EVENT_CONFLICT = listOf(
            "vehicle_id",
            "occurred_at_utc_millis",
            "occurred_at_elapsed_nanos",
            "type",
            "signal_id"
        )
        val CYCLE_CONFLICT = listOf("vehicle_id", "start_utc_millis")

        private const val UNASSIGNED = "unassigned"

        fun snakeCase(name: String): String =
            name.replace(Regex("(?<!^)(?=[A-Z])"), "_").lowercase()

        fun snakeCaseMap(export: Map<String, Any?>): MutableMap<String, Any?> {
            val out = mutableMapOf<String, Any?>()
            for ((k, v) in export) {
                out[snakeCase(k)] = v
            }
            return out
        }
    }
    /**
     * Re-marks every local measurement stream dirty so the next [upload]
     * re-sends history under the currently paired account.
     *
     * Promotes any ended pending sessions and intervals to `uncorrectable` so
     * sessions from previous boots that never received a clock anchor are not
     * permanently stranded.
     * All five streams are marked: marking sessions alone would leave a partial
     * history (sessions without their intervals, tracks, events, or cycles).
     */
    fun promoteEndedPending(): Int {
        val s = sessionDao.promoteEndedPendingToUncorrectable()
        val i = intervalDao.promoteEndedPendingToUncorrectable()
        return s + i
    }

    fun markHistoryDirty(): Map<String, Int> {
        promoteEndedPending()
        return mapOf(
            SESSION_TABLE to sessionDao.markAllDirty(),
            INTERVAL_TABLE to intervalDao.markAllDirty(),
            TRACK_TABLE to trackDao.markAllDirty(),
            EVENT_TABLE to telemetryEventDao.markAllDirty(),
            CYCLE_TABLE to batteryCycleDao.markAllDirty(),
        )
    }

    /**
     * Uploads every dirty row that can be scoped to a vehicle.
     *
     * The dirty mark is cleared only after the sink accepts the chunk, so a
     * failure repeats the chunk rather than skipping it.
     *
     * Pre-claim uploads (issue #236 Phase 2): when the car is registered but
     * not yet claimed, [accountIdProvider] answers null and every row is
     * written with `account_id = null`; the cloud trigger stamps the column
     * from the device token. [uploadEnabledProvider] is the only on/off
     * switch — never the account.
     */
    suspend fun upload(): TelemetryCloudUploadReport {
        if (!uploadEnabledProvider()) return TelemetryCloudUploadReport()
        val accountId = accountIdProvider()
        // vehicleId is resolved per-row for intervals/tracks via session lookup;
        // the global provider is only needed for cycles and as fallback.
        // Alias-canonicalize every vehicle id before it leaves the car: a row
        // recorded under a retired id (android_id) must upload under the
        // canonical VIN, or the RLS policy (vehicle_id = token's vehicle_id)
        // refuses it — the B1 stranded state.
        val globalVehicleId = vehicleIdProvider()
            ?.takeIf { it.isNotBlank() && it != UNASSIGNED }
            ?.let { aliases?.canonicalFor(it)?.takeIf { a -> a.isNotBlank() } ?: it }

        fun canonical(id: String): String {
            if (id.isBlank() || id == UNASSIGNED) return globalVehicleId ?: id
            val found = aliases?.canonicalFor(id)?.takeIf { it.isNotBlank() }
            if (found != null) return found
            if (globalVehicleId != null && globalVehicleId != id) {
                aliases?.record(id, globalVehicleId, System.currentTimeMillis())
                return globalVehicleId
            }
            return id
        }

        val perStream = ConcurrentHashMap<String, Int>()

        // --- Level 1: Sessions (foreign key root, runs first sequentially) ------
        uploadSessions(accountId, ::canonical, perStream)

        // --- Level 2: Child streams (run concurrently) -------------------------
        // The streams are independent: a refused event chunk must not cancel
        // the interval upload beside it. Each stream runs to its own end; the
        // first failure is rethrown after all of them finish, with the others
        // attached as suppressed.
        val failures = supervisorScope {
            listOf(
                async { uploadIntervalsAndDeletes(accountId, ::canonical, perStream) },
                async { uploadTracks(accountId, ::canonical, perStream) },
                async { uploadTelemetryEvents(accountId, globalVehicleId, ::canonical, perStream) },
                async { uploadBatteryCycles(accountId, globalVehicleId, perStream) },
            ).mapNotNull { stream -> runCatching { stream.await() }.exceptionOrNull() }
        }
        if (failures.isNotEmpty()) {
            val first = failures.first()
            failures.drop(1).forEach(first::addSuppressed)
            throw first
        }

        return TelemetryCloudUploadReport(perStream)
    }

    /** Clears dirty marks in slices that stay under SQLite's bind limit. */
    private fun <K> clearInSlices(keys: List<K>, clear: (List<K>) -> Int) {
        keys.chunked(MAX_BIND_VARIABLES).forEach { clear(it) }
    }

    private suspend fun uploadSessions(
        accountId: String?,
        canonical: (String) -> String,
        perStream: ConcurrentHashMap<String, Int>
    ) {
        val sessions = sessionDao.dirtySessions(Int.MAX_VALUE)
            .filter { it.vehicleId != UNASSIGNED && it.vehicleId.isNotBlank() }
        if (sessions.isEmpty()) return
        for (chunk in sessions.chunked(chunkSize)) {
            val sinkRows = chunk.map { entity ->
                val row = snakeCaseMap(entity.toExportRow())
                row["vehicle_id"] = canonical(entity.vehicleId)
                row["account_id"] = accountId
                row
            }
            try {
                sink.upsert(SESSION_TABLE, sinkRows, SESSION_CONFLICT, merge = true)
            } catch (e: Exception) {
                throw TelemetryCloudUploadException(SESSION_TABLE, e, retryable = TelemetryCloudUploadException.isRetryable(e))
            }
            clearInSlices(chunk.map { it.id }, sessionDao::clearDirty)
            perStream.merge(SESSION_TABLE, sinkRows.size, Int::plus)
        }
    }

    private suspend fun uploadIntervalsAndDeletes(
        accountId: String?,
        canonical: (String) -> String,
        perStream: ConcurrentHashMap<String, Int>
    ) {
        val intervals = intervalDao.dirtyIntervals(Int.MAX_VALUE)
        if (intervals.isNotEmpty()) {
            val scoped = intervals.mapNotNull { interval ->
                val session = sessionDao.findById(interval.sessionId)
                if (session == null) {
                    intervalDao.clearDirty(interval.sessionId, interval.startUtcMillis)
                    null
                } else if (session.vehicleId == UNASSIGNED || session.vehicleId.isBlank() || session.timeState == "pending") {
                    null
                } else {
                    interval to session.vehicleId
                }
            }
            for (chunk in scoped.chunked(chunkSize)) {
                val sinkRows = chunk.map { (interval, vehicleId) ->
                    val row = snakeCaseMap(interval.toExportRow())
                    row["vehicle_id"] = canonical(vehicleId)
                    row["account_id"] = accountId
                    row
                }
                try {
                    sink.upsert(INTERVAL_TABLE, sinkRows, INTERVAL_CONFLICT, merge = true)
                } catch (e: Exception) {
                    throw TelemetryCloudUploadException(INTERVAL_TABLE, e, retryable = TelemetryCloudUploadException.isRetryable(e))
                }
                val keys = chunk.map { (interval, _) -> "${interval.sessionId}:${interval.startUtcMillis}" }
                clearInSlices(keys, intervalDao::clearDirtyByKeys)
                perStream.merge(INTERVAL_TABLE, sinkRows.size, Int::plus)
            }
        }

        // --- Corrected re-upload (T9): delete only the keys the sweeper
        // rewrote, AFTER the corrected rows landed above. The order is the
        // safety: a failure between the two leaves a duplicate (ugly,
        // recoverable), never an absence (the captain's rule). The queue
        // drains in pages; a refused delete keeps its key for the next pass.
        val replacedDao = intervalReplacedKeyDao
        if (replacedDao != null) {
            while (true) {
                val pending = replacedDao.pending(replacedKeyPageSize)
                if (pending.isEmpty()) break
                val toDeleteByVehicle = mutableMapOf<String, MutableList<Triple<String, String, Long>>>()
                var pendingSessionKeyCount = 0

                for (key in pending) {
                    val session = sessionDao.findById(key.sessionId)
                    if (session == null) {
                        // The parent session already left the local store:
                        // its cloud rows are gone too, nothing to delete.
                        replacedDao.deleteKey(key.sessionId, key.startUtcMillis)
                        continue
                    }
                    val vehicle = session.vehicleId
                    if (vehicle == UNASSIGNED || vehicle.isBlank()) {
                        replacedDao.deleteKey(key.sessionId, key.startUtcMillis)
                        continue
                    }
                    if (session.timeState == "pending") {
                        pendingSessionKeyCount++
                        continue
                    }
                    val canonicalVehicle = canonical(vehicle)
                    toDeleteByVehicle.getOrPut(canonicalVehicle) { mutableListOf() }
                        .add(Triple(vehicle, key.sessionId, key.startUtcMillis))
                }

                if (toDeleteByVehicle.isEmpty()) {
                    if (pendingSessionKeyCount == pending.size) {
                        // All pending keys belong to pending sessions; avoid an infinite loop.
                        break
                    }
                    continue
                }

                for ((canonicalVehicle, triples) in toDeleteByVehicle) {
                    try {
                        sink.delete(
                            INTERVAL_TABLE,
                            canonicalVehicle,
                            triples
                        )
                    } catch (e: Exception) {
                        throw TelemetryCloudUploadException(
                            INTERVAL_TABLE,
                            e,
                            retryable = TelemetryCloudUploadException.isRetryable(e)
                        )
                    }
                    for ((_, sessionId, startUtcMillis) in triples) {
                        replacedDao.deleteKey(sessionId, startUtcMillis)
                    }
                    perStream.merge(INTERVAL_TABLE, triples.size, Int::plus)
                }
            }
        }
    }

    private suspend fun uploadTracks(
        accountId: String?,
        canonical: (String) -> String,
        perStream: ConcurrentHashMap<String, Int>
    ) {
        val tracks = trackDao.dirtyTracks(Int.MAX_VALUE)
        if (tracks.isEmpty()) return
        val scoped = tracks.mapNotNull { track ->
            val session = sessionDao.findById(track.sessionId)
            if (session == null) {
                trackDao.clearDirty(listOf(track.sessionId))
                null
            } else if (session.vehicleId == UNASSIGNED || session.vehicleId.isBlank() || session.timeState == "pending") {
                null
            } else {
                track to session.vehicleId
            }
        }
        for (chunk in scoped.chunked(chunkSize)) {
            val sinkRows = chunk.map { (track, vehicleId) ->
                val row = snakeCaseMap(track.toExportRow())
                row["vehicle_id"] = canonical(vehicleId)
                row["account_id"] = accountId
                row
            }
            try {
                sink.upsert(TRACK_TABLE, sinkRows, TRACK_CONFLICT, merge = true)
            } catch (e: Exception) {
                throw TelemetryCloudUploadException(TRACK_TABLE, e, retryable = TelemetryCloudUploadException.isRetryable(e))
            }
            clearInSlices(chunk.map { (track, _) -> track.sessionId }, trackDao::clearDirty)
            perStream.merge(TRACK_TABLE, sinkRows.size, Int::plus)
        }
    }

    private suspend fun uploadTelemetryEvents(
        accountId: String?,
        globalVehicleId: String?,
        canonical: (String) -> String,
        perStream: ConcurrentHashMap<String, Int>
    ) {
        val events = telemetryEventDao.dirtyEvents(Int.MAX_VALUE)
        if (events.isEmpty()) return
        val scoped = events.mapNotNull { event ->
            val sid = event.sessionId
            if (sid == null) {
                val vehicleId = globalVehicleId
                if (vehicleId == null || vehicleId == UNASSIGNED || vehicleId.isBlank()) null
                else event to vehicleId
            } else {
                val session = sessionDao.findById(sid)
                if (session == null) {
                    telemetryEventDao.clearDirty(listOf(event.id))
                    null
                } else if (session.vehicleId == UNASSIGNED || session.vehicleId.isBlank() || session.timeState == "pending") {
                    null
                } else {
                    event to session.vehicleId
                }
            }
        }
        for (chunk in scoped.chunked(chunkSize)) {
            val sinkRows = chunk.map { (event, vehicleId) ->
                // Drop local autoincrement id from cloud key; keep natural key cols.
                val filtered = event.toMap().filterKeys { it != "id" }
                val row = snakeCaseMap(filtered)
                row["vehicle_id"] = canonical(vehicleId)
                row["account_id"] = accountId
                // Cloud key cannot hold null signal_id.
                if (row["signal_id"] == null) row["signal_id"] = ""
                row
            }
            try {
                sink.upsert(EVENT_TABLE, sinkRows, EVENT_CONFLICT, merge = false)
            } catch (e: Exception) {
                throw TelemetryCloudUploadException(EVENT_TABLE, e, retryable = TelemetryCloudUploadException.isRetryable(e))
            }
            clearInSlices(chunk.map { (event, _) -> event.id }, telemetryEventDao::clearDirty)
            perStream.merge(EVENT_TABLE, sinkRows.size, Int::plus)
        }
    }

    private suspend fun uploadBatteryCycles(
        accountId: String?,
        globalVehicleId: String?,
        perStream: ConcurrentHashMap<String, Int>
    ) {
        val cycles = batteryCycleDao.dirtyCycles(Int.MAX_VALUE)
        if (cycles.isEmpty()) return
        val vehicleId = globalVehicleId
        if (vehicleId != null && vehicleId != UNASSIGNED && vehicleId.isNotBlank()) {
            for (chunk in cycles.chunked(chunkSize)) {
                val sinkRows = chunk.map { cycle ->
                    val row = snakeCaseMap(cycle.toExportRow())
                    row["vehicle_id"] = vehicleId
                    row["account_id"] = accountId
                    row
                }
                try {
                    sink.upsert(CYCLE_TABLE, sinkRows, CYCLE_CONFLICT, merge = true)
                } catch (e: Exception) {
                    throw TelemetryCloudUploadException(CYCLE_TABLE, e, retryable = TelemetryCloudUploadException.isRetryable(e))
                }
                clearInSlices(chunk.map { it.ordinal }, batteryCycleDao::clearDirty)
                perStream.merge(CYCLE_TABLE, sinkRows.size, Int::plus)
            }
        }
    }
}
