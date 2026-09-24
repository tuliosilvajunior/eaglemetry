package com.timhss.capyenergy.telemetry.sync

import com.timhss.capyenergy.telemetry.VehicleIdAliasStore
import com.timhss.capyenergy.telemetry.db.BatteryCycleDao
import com.timhss.capyenergy.telemetry.db.InsightPlaceDao
import com.timhss.capyenergy.telemetry.db.IntervalDao
import com.timhss.capyenergy.telemetry.db.JourneyDao
import com.timhss.capyenergy.telemetry.db.PreferenceDao
import com.timhss.capyenergy.telemetry.db.PreferenceProposalDao
import com.timhss.capyenergy.telemetry.db.SessionCostDao
import com.timhss.capyenergy.telemetry.db.SessionDao
import com.timhss.capyenergy.telemetry.db.SessionEntity
import com.timhss.capyenergy.telemetry.db.TelemetryEventDao
import com.timhss.capyenergy.telemetry.db.TelemetryFrameDao
import com.timhss.capyenergy.telemetry.db.TrackDao

/**
 * Paged sync batch envelope conforming to protocol version 2.
 */
data class SyncBatch(
    val protocolVersion: Int,
    val streamType: String,
    val items: List<Map<String, Any?>>,
    val nextCursor: String?,
    val hasMore: Boolean,
    val generatedAtUtcMillis: Long,
    val remaining: Long
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "protocolVersion" to protocolVersion,
        "streamType" to streamType,
        "items" to items,
        "nextCursor" to nextCursor,
        "hasMore" to hasMore,
        "generatedAtUtcMillis" to generatedAtUtcMillis,
        "remaining" to remaining
    )
}

data class SyncStreamCount(
    val streamType: String,
    val total: Long,
    val remaining: Long
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "streamType" to streamType,
        "total" to total,
        "remaining" to remaining
    )
}

sealed class SyncPackException(message: String) : IllegalArgumentException(message)

class SyncCursorNotFoundException(val streamType: String, val cursor: String) :
    SyncPackException("Cursor not found for $streamType: '$cursor'")

class SyncSessionNotClosedException(val sessionId: String) :
    SyncPackException("Session not found or not closed for frames sync: '$sessionId'")

class SyncCursorCorruptException(val streamType: String, val cursor: String, detail: String) :
    SyncPackException("Corrupt cursor for $streamType '$cursor': $detail")

class SyncBatchPacker(
    private val sessionDao: SessionDao,
    private val intervalDao: IntervalDao,
    private val telemetryFrameDao: TelemetryFrameDao? = null,
    private val batteryCycleDao: BatteryCycleDao,
    private val telemetryEventDao: TelemetryEventDao? = null,
    private val insightPlaceDao: InsightPlaceDao? = null,
    private val sessionCostDao: SessionCostDao? = null,
    private val preferenceDao: PreferenceDao? = null,
    private val preferenceProposalDao: PreferenceProposalDao? = null,
    private val journeyDao: JourneyDao? = null,
    private val trackDao: TrackDao? = null,
    private val aliases: VehicleIdAliasStore? = null,
    private val eventsStreamEnabled: Boolean = EVENTS_STREAM_ENABLED,
    private val nowUtcMillisProvider: () -> Long = { System.currentTimeMillis() }
) {
    companion object {
        const val PROTOCOL_VERSION = 2
        const val DEFAULT_LIMIT = 1000
        const val MIN_LIMIT = 1
        const val MAX_LIMIT = 1000

        /**
         * Issue 226 transport gate. While `false`, the events stream answers
         * empty batches and reports zero pending, so companions drain their
         * pull loop without receiving rows. The pull/ack protocol, cursor
         * shape, and `TelemetryEventDao` all stay live: flipping this back
         * resumes the stream from the last confirmed id.
         */
        const val EVENTS_STREAM_ENABLED = false
    }

    fun packBatch(
        streamWireName: String,
        after: String? = null,
        limit: Int = DEFAULT_LIMIT
    ): SyncBatch {
        val stream = SyncStreamType.fromWireName(streamWireName)
            ?: throw IllegalArgumentException("Unknown sync stream: $streamWireName")

        val effectiveLimit = limit.coerceIn(MIN_LIMIT, MAX_LIMIT)
        val now = nowUtcMillisProvider()

        return when (stream) {
            SyncStreamType.SESSIONS -> packSessions(after, effectiveLimit, now)
            SyncStreamType.INTERVALS -> packIntervals(after, effectiveLimit, now)
            SyncStreamType.BATTERY_CYCLES -> packBatteryCycles(after, effectiveLimit, now)
            SyncStreamType.TELEMETRY_FRAMES -> packTelemetryFrames(after, effectiveLimit, now)
            SyncStreamType.EVENTS -> eventsBatch(after, effectiveLimit, now)
            SyncStreamType.PLACES -> packPlaces(after, effectiveLimit, now)
            SyncStreamType.SESSION_COSTS -> packSessionCosts(after, effectiveLimit, now)
            SyncStreamType.PREFERENCES -> packPreferences(after, effectiveLimit, now)
            SyncStreamType.PREFERENCE_PROPOSALS -> packPreferenceProposals(after, effectiveLimit, now)
            SyncStreamType.JOURNEYS -> packJourneys(after, effectiveLimit, now)
            SyncStreamType.TRACKS -> packTracks(after, effectiveLimit, now)
        }
    }

    fun countStream(streamWireName: String, after: String?): SyncStreamCount {
        val stream = SyncStreamType.fromWireName(streamWireName)
            ?: throw IllegalArgumentException("Unknown sync stream: $streamWireName")

        return when (stream) {
            SyncStreamType.SESSIONS -> {
                val row = after?.takeIf { it.isNotBlank() }?.let { sessionDao.findById(it.trim()) }
                SyncStreamCount(
                    streamType = stream.wireName,
                    total = sessionDao.syncPendingCount(0L, ""),
                    remaining = sessionDao.syncPendingCount(
                        afterStartedAtUtcMillis = row?.startedAtUtcMillis ?: 0L,
                        afterId = row?.id ?: ""
                    )
                )
            }
            SyncStreamType.BATTERY_CYCLES -> {
                // The packing path throws on a non-integer cursor; the count
                // must say the same thing or a corrupt cursor would read as a
                // full backlog here and as a 400 there. An ordinal that
                // parses but no longer exists is a stale cursor from a
                // reinstalled car: like the other streams the count starts
                // from the front, and the pull itself raises the
                // not-found condition that drives cursor recovery.
                val parsed = after?.trim()?.toLongOrNull()
                    ?: if (after.isNullOrBlank()) 0L
                    else throw SyncCursorCorruptException(
                        SyncStreamType.BATTERY_CYCLES.wireName,
                        after,
                        "ordinal is not an integer"
                    )
                val row = parsed.takeIf { it > 0L }?.let { batteryCycleDao.findById(it) }
                SyncStreamCount(
                    streamType = stream.wireName,
                    total = batteryCycleDao.syncPendingCount(0L),
                    remaining = batteryCycleDao.syncPendingCount(
                        afterOrdinal = row?.ordinal ?: 0L
                    )
                )
            }
            SyncStreamType.INTERVALS -> {
                var afterStartUtcMillis = 0L
                var afterSessionId = ""
                if (!after.isNullOrBlank()) {
                    val parts = after.trim().split(":")
                    if (parts.size == 2) {
                        afterSessionId = parts[0].trim()
                        afterStartUtcMillis = parts[1].trim().toLongOrNull() ?: 0L
                    }
                }
                SyncStreamCount(
                    streamType = stream.wireName,
                    total = intervalDao.syncPendingCount(0L, ""),
                    remaining = intervalDao.syncPendingCount(afterStartUtcMillis, afterSessionId)
                )
            }
            SyncStreamType.EVENTS -> eventsCount(stream, after)
            SyncStreamType.PLACES -> {
                val parts = splitUpdatedAtCursor(after, SyncStreamType.PLACES.wireName)
                SyncStreamCount(
                    streamType = stream.wireName,
                    total = insightPlaceDao?.syncPendingCount(0L, "") ?: 0L,
                    remaining = insightPlaceDao?.syncPendingCount(
                        afterUpdatedAtUtcMillis = parts?.first ?: 0L,
                        afterId = parts?.second ?: ""
                    ) ?: 0L
                )
            }
            SyncStreamType.SESSION_COSTS -> {
                val parts = splitUpdatedAtCursor(after, SyncStreamType.SESSION_COSTS.wireName)
                SyncStreamCount(
                    streamType = stream.wireName,
                    total = sessionCostDao?.syncPendingCount(0L, "") ?: 0L,
                    remaining = sessionCostDao?.syncPendingCount(
                        afterUpdatedAtUtcMillis = parts?.first ?: 0L,
                        afterSessionId = parts?.second ?: ""
                    ) ?: 0L
                )
            }
            SyncStreamType.PREFERENCES -> {
                val parts = splitPreferenceCursor(after)
                SyncStreamCount(
                    streamType = stream.wireName,
                    total = preferenceDao?.syncPendingCount(0L, "", "") ?: 0L,
                    remaining = preferenceDao?.syncPendingCount(
                        afterUpdatedAtUtcMillis = parts?.updatedAtUtcMillis ?: 0L,
                        afterScope = parts?.scope ?: "",
                        afterKey = parts?.key ?: ""
                    ) ?: 0L
                )
            }
            SyncStreamType.PREFERENCE_PROPOSALS -> {
                val parts = splitUpdatedAtCursor(after, SyncStreamType.PREFERENCE_PROPOSALS.wireName)
                SyncStreamCount(
                    streamType = stream.wireName,
                    total = preferenceProposalDao?.syncPendingCount(0L, "") ?: 0L,
                    remaining = preferenceProposalDao?.syncPendingCount(
                        afterUpdatedAtUtcMillis = parts?.first ?: 0L,
                        afterId = parts?.second ?: ""
                    ) ?: 0L
                )
            }
            SyncStreamType.JOURNEYS -> {
                val parts = splitUpdatedAtCursor(after, SyncStreamType.JOURNEYS.wireName)
                SyncStreamCount(
                    streamType = stream.wireName,
                    total = journeyDao?.syncPendingCount(0L, "") ?: 0L,
                    remaining = journeyDao?.syncPendingCount(
                        afterUpdatedAtUtcMillis = parts?.first ?: 0L,
                        afterId = parts?.second ?: ""
                    ) ?: 0L
                )
            }
            SyncStreamType.TRACKS -> {
                val parts = splitUpdatedAtCursor(after, SyncStreamType.TRACKS.wireName)
                SyncStreamCount(
                    streamType = stream.wireName,
                    total = trackDao?.syncPendingCount(0L, "") ?: 0L,
                    remaining = trackDao?.syncPendingCount(
                        afterUpdatedAtUtcMillis = parts?.first ?: 0L,
                        afterSessionId = parts?.second ?: ""
                    ) ?: 0L
                )
            }
            SyncStreamType.TELEMETRY_FRAMES -> throw IllegalArgumentException(
                "${stream.wireName} is counted in sessions by the phone, not in items by the car"
            )
        }
    }

    val countedStreams: List<SyncStreamType>
        get() = listOf(
            SyncStreamType.SESSIONS,
            SyncStreamType.INTERVALS,
            SyncStreamType.BATTERY_CYCLES,
            SyncStreamType.EVENTS,
            SyncStreamType.TRACKS,
            SyncStreamType.PLACES,
            SyncStreamType.SESSION_COSTS,
            SyncStreamType.PREFERENCES,
            SyncStreamType.PREFERENCE_PROPOSALS,
            SyncStreamType.JOURNEYS
        )

    private fun packSessions(after: String?, limit: Int, now: Long): SyncBatch {
        var afterStartedAt = 0L
        var afterId = ""

        if (!after.isNullOrBlank()) {
            val cursorId = after.trim()
            val record = sessionDao.findById(cursorId)
                ?: throw SyncCursorNotFoundException(SyncStreamType.SESSIONS.wireName, cursorId)
            afterStartedAt = record.startedAtUtcMillis
            afterId = record.id
        }

        val rows = sessionDao.syncPage(
            afterStartedAtUtcMillis = afterStartedAt,
            afterId = afterId,
            limit = limit + 1
        )

        val hasMore = rows.size > limit
        val batchRows = if (hasMore) rows.subList(0, limit) else rows
        // The session row's cost keys are frozen on the wire, and the cost
        // lives in the annotation table since slice 6. Compose it here so the
        // phone's replica carries what the car's row carries.
        val costs = sessionCostDao?.forSessions(batchRows.map { it.id })
            ?.associateBy { it.sessionId }
            .orEmpty()
        val items = batchRows.map { session ->
            val resolved = resolveVehicleId(session)
            val cost = costs[session.id]
            if (cost == null) {
                resolved.toMap()
            } else {
                resolved.copy(
                    costPerKwh = cost.costPerKwh,
                    paidAmount = cost.paidAmount,
                    costCurrency = cost.costCurrency
                ).toMap()
            }
        }
        val nextCursor = batchRows.lastOrNull()?.id ?: after

        return SyncBatch(
            protocolVersion = PROTOCOL_VERSION,
            streamType = SyncStreamType.SESSIONS.wireName,
            items = items,
            nextCursor = nextCursor,
            hasMore = hasMore,
            generatedAtUtcMillis = now,
            remaining = sessionDao.syncPendingCount(
                afterStartedAtUtcMillis = batchRows.lastOrNull()?.startedAtUtcMillis ?: afterStartedAt,
                afterId = nextCursor ?: afterId
            )
        )
    }

    /**
     * Rows recorded before a vehicle-id upgrade keep the retired id in their
     * `vehicle_id` column; history is never rewritten. The alias store maps
     * the retired id to the canonical one, so one physical car leaves the car
     * under a single id and never splits into two vehicles in the cloud.
     */
    private fun resolveVehicleId(session: SessionEntity): SessionEntity {
        val canonical = aliases?.canonicalFor(session.vehicleId) ?: return session
        return session.copy(vehicleId = canonical)
    }

    private fun packTelemetryFrames(after: String?, limit: Int, now: Long): SyncBatch {
        if (after.isNullOrBlank()) {
            throw SyncCursorCorruptException(
                SyncStreamType.TELEMETRY_FRAMES.wireName,
                after.orEmpty(),
                "telemetryFrames requires an after parameter specifying sessionId"
            )
        }

        val raw = after.trim()
        val parts = raw.split(":")
        val sessionId = parts[0].trim()
        if (sessionId.isBlank()) {
            throw SyncCursorCorruptException(
                SyncStreamType.TELEMETRY_FRAMES.wireName,
                raw,
                "sessionId is blank"
            )
        }

        val afterWallTime: Long
        val afterId: Long

        when (parts.size) {
            1 -> {
                afterWallTime = 0L
                afterId = 0L
            }
            3 -> {
                afterWallTime = parts[1].toLongOrNull()
                    ?: throw SyncCursorCorruptException(
                        SyncStreamType.TELEMETRY_FRAMES.wireName,
                        raw,
                        "invalid wallTimeUtcMillis '${parts[1]}'"
                    )
                afterId = parts[2].toLongOrNull()
                    ?: throw SyncCursorCorruptException(
                        SyncStreamType.TELEMETRY_FRAMES.wireName,
                        raw,
                        "invalid frame id '${parts[2]}'"
                    )
            }
            else -> {
                throw SyncCursorCorruptException(
                    SyncStreamType.TELEMETRY_FRAMES.wireName,
                    raw,
                    "expected 'sessionId' or 'sessionId:wallTimeUtcMillis:id'"
                )
            }
        }

        val isClosed = sessionDao.findById(sessionId)?.let {
            it.endedAtUtcMillis != null && it.status != "FINALIZATION_PENDING"
        } ?: false

        if (!isClosed) {
            throw SyncSessionNotClosedException(sessionId)
        }

        val rows = telemetryFrameDao?.framesSyncPage(
            sessionId = sessionId,
            afterWallTimeUtcMillis = afterWallTime,
            afterId = afterId,
            limit = limit + 1
        ) ?: emptyList()

        val hasMore = rows.size > limit
        val batchRows = if (hasMore) rows.subList(0, limit) else rows
        val items = batchRows.map { it.toMap() }
        val lastRow = batchRows.lastOrNull()
        val nextCursor = if (lastRow != null) {
            "$sessionId:${lastRow.wallTimeUtcMillis}:${lastRow.id}"
        } else {
            after
        }

        return SyncBatch(
            protocolVersion = PROTOCOL_VERSION,
            streamType = SyncStreamType.TELEMETRY_FRAMES.wireName,
            items = items,
            nextCursor = nextCursor,
            hasMore = hasMore,
            generatedAtUtcMillis = now,
            remaining = telemetryFrameDao?.framesSyncPendingCount(
                sessionId = sessionId,
                afterWallTimeUtcMillis = lastRow?.wallTimeUtcMillis ?: afterWallTime,
                afterId = lastRow?.id ?: afterId
            ) ?: 0
        )
    }

    private fun packBatteryCycles(after: String?, limit: Int, now: Long): SyncBatch {
        var afterOrdinal = 0L

        if (!after.isNullOrBlank()) {
            val cursor = after.trim()
            afterOrdinal = cursor.toLongOrNull()
                ?: throw SyncCursorCorruptException(
                    SyncStreamType.BATTERY_CYCLES.wireName,
                    cursor,
                    "ordinal is not an integer"
                )
            // The ordinal is a position in a rebuilt ledger, not an identity:
            // after a reinstall it restarts at 1, so a stale phone cursor no
            // longer names a row. Every other stream answers such a cursor
            // with SyncCursorNotFoundException, which the transport turns
            // into HTTP 410 and drives cursor recovery. Without this check
            // the phone would silently receive empty pages forever.
            if (batteryCycleDao.findById(afterOrdinal) == null) {
                throw SyncCursorNotFoundException(SyncStreamType.BATTERY_CYCLES.wireName, cursor)
            }
        }

        val rows = batteryCycleDao.syncPage(
            afterOrdinal = afterOrdinal,
            limit = limit + 1
        )

        val hasMore = rows.size > limit
        val batchRows = if (hasMore) rows.subList(0, limit) else rows
        val items = batchRows.map { it.toExportRow() }
        val nextCursor = batchRows.lastOrNull()?.ordinal?.toString() ?: after

        return SyncBatch(
            protocolVersion = PROTOCOL_VERSION,
            streamType = SyncStreamType.BATTERY_CYCLES.wireName,
            items = items,
            nextCursor = nextCursor,
            hasMore = hasMore,
            generatedAtUtcMillis = now,
            remaining = batteryCycleDao.syncPendingCount(
                afterOrdinal = batchRows.lastOrNull()?.ordinal ?: afterOrdinal
            )
        )
    }

    private fun packIntervals(after: String?, limit: Int, now: Long): SyncBatch {
        var afterStartUtcMillis = 0L
        var afterSessionId = ""

        if (!after.isNullOrBlank()) {
            val cursor = after.trim()
            val parts = cursor.split(":")
            if (parts.size != 2) {
                throw SyncCursorCorruptException(
                    SyncStreamType.INTERVALS.wireName,
                    cursor,
                    "expected 'sessionId:startUtcMillis'"
                )
            }
            val sessionId = parts[0].trim()
            val startUtcMillis = parts[1].trim().toLongOrNull()
                ?: throw SyncCursorCorruptException(
                    SyncStreamType.INTERVALS.wireName,
                    cursor,
                    "invalid startUtcMillis '${parts[1]}'"
                )
            val record = intervalDao.findById(sessionId, startUtcMillis)
                ?: throw SyncCursorNotFoundException(SyncStreamType.INTERVALS.wireName, cursor)
            afterStartUtcMillis = record.startUtcMillis
            afterSessionId = record.sessionId
        }

        val rows = intervalDao.syncPage(
            afterStartUtcMillis = afterStartUtcMillis,
            afterSessionId = afterSessionId,
            limit = limit + 1
        )

        val hasMore = rows.size > limit
        val batchRows = if (hasMore) rows.subList(0, limit) else rows
        val items = batchRows.map { it.toMap() }
        val lastRow = batchRows.lastOrNull()
        val nextCursor = if (lastRow != null) {
            "${lastRow.sessionId}:${lastRow.startUtcMillis}"
        } else {
            after
        }

        return SyncBatch(
            protocolVersion = PROTOCOL_VERSION,
            streamType = SyncStreamType.INTERVALS.wireName,
            items = items,
            nextCursor = nextCursor,
            hasMore = hasMore,
            generatedAtUtcMillis = now,
            remaining = intervalDao.syncPendingCount(
                afterStartUtcMillis = lastRow?.startUtcMillis ?: afterStartUtcMillis,
                afterSessionId = lastRow?.sessionId ?: afterSessionId
            )
        )
    }

    /**
     * Issue 226: the empty answer the events stream gives while
     * [eventsStreamEnabled] is false. The caller's cursor is echoed back
     * untouched, so a companion resuming later picks up exactly where it
     * stopped.
     */
    private fun emptyEventsBatch(after: String?, now: Long) = SyncBatch(
        protocolVersion = PROTOCOL_VERSION,
        streamType = SyncStreamType.EVENTS.wireName,
        items = emptyList(),
        nextCursor = after,
        hasMore = false,
        generatedAtUtcMillis = now,
        remaining = 0L
    )

    /**
     * Issue 226: the events stream answers through exactly one gate. Both
     * the pull and the inventory call sites land here, so the disabled
     * state, its zero answer, and the cursor semantics live in one place.
     */
    private fun eventsBatch(after: String?, limit: Int, now: Long): SyncBatch =
        if (eventsStreamEnabled) {
            packEvents(after, limit, now)
        } else {
            emptyEventsBatch(after, now)
        }

    private fun eventsCount(stream: SyncStreamType, after: String?): SyncStreamCount =
        if (eventsStreamEnabled) {
            SyncStreamCount(
                streamType = stream.wireName,
                total = telemetryEventDao?.syncPendingCount(0L) ?: 0L,
                remaining = telemetryEventDao?.syncPendingCount(
                    afterId = after?.trim()?.toLongOrNull() ?: 0L
                ) ?: 0L
            )
        } else {
            SyncStreamCount(streamType = stream.wireName, total = 0L, remaining = 0L)
        }

    private fun packEvents(after: String?, limit: Int, now: Long): SyncBatch {

        val eventDao = telemetryEventDao
            ?: throw IllegalStateException("TelemetryEventDao is required to pack events")

        var afterId = 0L
        if (!after.isNullOrBlank()) {
            val cursor = after.trim()
            afterId = cursor.toLongOrNull()
                ?: throw SyncCursorCorruptException(
                    SyncStreamType.EVENTS.wireName,
                    cursor,
                    "event id is not an integer"
                )
            if (eventDao.findById(afterId) == null) {
                throw SyncCursorNotFoundException(SyncStreamType.EVENTS.wireName, cursor)
            }
        }

        val rows = eventDao.syncPage(
            afterId = afterId,
            limit = limit + 1
        )

        val hasMore = rows.size > limit
        val batchRows = if (hasMore) rows.subList(0, limit) else rows
        val items = batchRows.map { it.toMap() }
        val nextCursor = batchRows.lastOrNull()?.id?.toString() ?: after

        return SyncBatch(
            protocolVersion = PROTOCOL_VERSION,
            streamType = SyncStreamType.EVENTS.wireName,
            items = items,
            nextCursor = nextCursor,
            hasMore = hasMore,
            generatedAtUtcMillis = now,
            remaining = eventDao.syncPendingCount(
                afterId = batchRows.lastOrNull()?.id ?: afterId
            )
        )
    }

    private fun packPlaces(after: String?, limit: Int, now: Long): SyncBatch {
        val dao = insightPlaceDao
            ?: throw IllegalStateException("InsightPlaceDao is required to pack places")

        var afterUpdatedAtUtcMillis = 0L
        var afterId = ""
        if (!after.isNullOrBlank()) {
            val parts = splitUpdatedAtCursor(after, SyncStreamType.PLACES.wireName)
                ?: throw SyncCursorCorruptException(
                    SyncStreamType.PLACES.wireName,
                    after,
                    "expected 'updatedAtUtcMillis:id'"
                )
            afterUpdatedAtUtcMillis = parts.first
            afterId = parts.second
            if (dao.findById(afterId) == null) {
                throw SyncCursorNotFoundException(SyncStreamType.PLACES.wireName, after)
            }
        }

        val rows = dao.syncPage(afterUpdatedAtUtcMillis, afterId, limit + 1)
        val hasMore = rows.size > limit
        val batchRows = if (hasMore) rows.subList(0, limit) else rows
        val items = batchRows.map { it.toMap() }
        val lastRow = batchRows.lastOrNull()
        val nextCursor = if (lastRow != null) {
            "${lastRow.updatedAtUtcMillis}:${lastRow.id}"
        } else {
            after
        }

        return SyncBatch(
            protocolVersion = PROTOCOL_VERSION,
            streamType = SyncStreamType.PLACES.wireName,
            items = items,
            nextCursor = nextCursor,
            hasMore = hasMore,
            generatedAtUtcMillis = now,
            remaining = dao.syncPendingCount(
                afterUpdatedAtUtcMillis = lastRow?.updatedAtUtcMillis ?: afterUpdatedAtUtcMillis,
                afterId = lastRow?.id ?: afterId
            )
        )
    }

    private fun packJourneys(after: String?, limit: Int, now: Long): SyncBatch {
        val dao = journeyDao
            ?: throw IllegalStateException("JourneyDao is required to pack journeys")

        var afterUpdatedAtUtcMillis = 0L
        var afterId = ""
        if (!after.isNullOrBlank()) {
            val parts = splitUpdatedAtCursor(after, SyncStreamType.JOURNEYS.wireName)
                ?: throw SyncCursorCorruptException(
                    SyncStreamType.JOURNEYS.wireName,
                    after,
                    "expected 'updatedAtUtcMillis:id'"
                )
            afterUpdatedAtUtcMillis = parts.first
            afterId = parts.second
            if (dao.findById(afterId) == null) {
                throw SyncCursorNotFoundException(SyncStreamType.JOURNEYS.wireName, after)
            }
        }

        val rows = dao.syncPage(afterUpdatedAtUtcMillis, afterId, limit + 1)
        val hasMore = rows.size > limit
        val batchRows = if (hasMore) rows.subList(0, limit) else rows
        val items = batchRows.map { it.toMap() }
        val lastRow = batchRows.lastOrNull()
        val nextCursor = if (lastRow != null) {
            "${lastRow.updatedAtUtcMillis}:${lastRow.id}"
        } else {
            after
        }

        return SyncBatch(
            protocolVersion = PROTOCOL_VERSION,
            streamType = SyncStreamType.JOURNEYS.wireName,
            items = items,
            nextCursor = nextCursor,
            hasMore = hasMore,
            generatedAtUtcMillis = now,
            remaining = dao.syncPendingCount(
                afterUpdatedAtUtcMillis = lastRow?.updatedAtUtcMillis ?: afterUpdatedAtUtcMillis,
                afterId = lastRow?.id ?: afterId
            )
        )
    }

    /**
     * One page of routes, oldest write first.
     *
     * The cursor is `updatedAtUtcMillis:sessionId`, the position of the last
     * row the phone confirmed. It is a position and not a row: a route the
     * retention has since deleted still names where the reading stopped, so a
     * missing row is not a corrupt cursor here and does not throw. Refusing it
     * would send every route on the car again to recover from one deletion.
     *
     * A row rewritten after it was confirmed carries a later stamp, so it
     * sorts after the cursor and is offered again. That is how the simplified
     * path written at close replaces the raw one the phone took during the
     * drive: it is the same primary key, arriving a second time.
     */
    private fun packTracks(after: String?, limit: Int, now: Long): SyncBatch {
        val dao = trackDao
            ?: throw IllegalStateException("TrackDao is required to pack tracks")

        var afterUpdatedAtUtcMillis = 0L
        var afterSessionId = ""
        if (!after.isNullOrBlank()) {
            val parts = splitUpdatedAtCursor(after, SyncStreamType.TRACKS.wireName)
                ?: throw SyncCursorCorruptException(
                    SyncStreamType.TRACKS.wireName,
                    after,
                    "expected 'updatedAtUtcMillis:sessionId'"
                )
            afterUpdatedAtUtcMillis = parts.first
            afterSessionId = parts.second
        }

        val rows = dao.syncPage(afterUpdatedAtUtcMillis, afterSessionId, limit + 1)
        val hasMore = rows.size > limit
        val batchRows = if (hasMore) rows.subList(0, limit) else rows
        val items = batchRows.map { it.toMap() }
        val lastRow = batchRows.lastOrNull()
        val nextCursor = if (lastRow != null) {
            "${lastRow.updatedAtUtcMillis}:${lastRow.sessionId}"
        } else {
            after
        }

        return SyncBatch(
            protocolVersion = PROTOCOL_VERSION,
            streamType = SyncStreamType.TRACKS.wireName,
            items = items,
            nextCursor = nextCursor,
            hasMore = hasMore,
            generatedAtUtcMillis = now,
            remaining = dao.syncPendingCount(
                afterUpdatedAtUtcMillis = lastRow?.updatedAtUtcMillis ?: afterUpdatedAtUtcMillis,
                afterSessionId = lastRow?.sessionId ?: afterSessionId
            )
        )
    }

    private fun packSessionCosts(after: String?, limit: Int, now: Long): SyncBatch {
        val dao = sessionCostDao
            ?: throw IllegalStateException("SessionCostDao is required to pack session costs")

        var afterUpdatedAtUtcMillis = 0L
        var afterSessionId = ""
        if (!after.isNullOrBlank()) {
            val parts = splitUpdatedAtCursor(after, SyncStreamType.SESSION_COSTS.wireName)
                ?: throw SyncCursorCorruptException(
                    SyncStreamType.SESSION_COSTS.wireName,
                    after,
                    "expected 'updatedAtUtcMillis:sessionId'"
                )
            afterUpdatedAtUtcMillis = parts.first
            afterSessionId = parts.second
            if (dao.findById(afterSessionId) == null) {
                throw SyncCursorNotFoundException(SyncStreamType.SESSION_COSTS.wireName, after)
            }
        }

        val rows = dao.syncPage(afterUpdatedAtUtcMillis, afterSessionId, limit + 1)
        val hasMore = rows.size > limit
        val batchRows = if (hasMore) rows.subList(0, limit) else rows
        val items = batchRows.map { it.toMap() }
        val lastRow = batchRows.lastOrNull()
        val nextCursor = if (lastRow != null) {
            "${lastRow.updatedAtUtcMillis}:${lastRow.sessionId}"
        } else {
            after
        }

        return SyncBatch(
            protocolVersion = PROTOCOL_VERSION,
            streamType = SyncStreamType.SESSION_COSTS.wireName,
            items = items,
            nextCursor = nextCursor,
            hasMore = hasMore,
            generatedAtUtcMillis = now,
            remaining = dao.syncPendingCount(
                afterUpdatedAtUtcMillis = lastRow?.updatedAtUtcMillis ?: afterUpdatedAtUtcMillis,
                afterSessionId = lastRow?.sessionId ?: afterSessionId
            )
        )
    }

    private fun packPreferences(after: String?, limit: Int, now: Long): SyncBatch {
        val dao = preferenceDao
            ?: throw IllegalStateException("PreferenceDao is required to pack preferences")

        var afterUpdatedAtUtcMillis = 0L
        var afterScope = ""
        var afterKey = ""
        if (!after.isNullOrBlank()) {
            val cursor = splitPreferenceCursor(after)
                ?: throw SyncCursorCorruptException(
                    SyncStreamType.PREFERENCES.wireName,
                    after,
                    "expected 'updatedAtUtcMillis:scope:key'"
                )
            afterUpdatedAtUtcMillis = cursor.updatedAtUtcMillis
            afterScope = cursor.scope
            afterKey = cursor.key
            if (dao.findById(afterScope, afterKey) == null) {
                throw SyncCursorNotFoundException(SyncStreamType.PREFERENCES.wireName, after)
            }
        }

        val rows = dao.syncPage(afterUpdatedAtUtcMillis, afterScope, afterKey, limit + 1)
        val hasMore = rows.size > limit
        val batchRows = if (hasMore) rows.subList(0, limit) else rows
        val items = batchRows.map { it.toMap() }
        val lastRow = batchRows.lastOrNull()
        val nextCursor = if (lastRow != null) {
            "${lastRow.updatedAtUtcMillis}:${lastRow.scope}:${lastRow.key}"
        } else {
            after
        }

        return SyncBatch(
            protocolVersion = PROTOCOL_VERSION,
            streamType = SyncStreamType.PREFERENCES.wireName,
            items = items,
            nextCursor = nextCursor,
            hasMore = hasMore,
            generatedAtUtcMillis = now,
            remaining = dao.syncPendingCount(
                afterUpdatedAtUtcMillis = lastRow?.updatedAtUtcMillis ?: afterUpdatedAtUtcMillis,
                afterScope = lastRow?.scope ?: afterScope,
                afterKey = lastRow?.key ?: afterKey
            )
        )
    }

    private fun packPreferenceProposals(after: String?, limit: Int, now: Long): SyncBatch {
        val dao = preferenceProposalDao
            ?: throw IllegalStateException("PreferenceProposalDao is required to pack preference proposals")

        var afterUpdatedAtUtcMillis = 0L
        var afterId = ""
        if (!after.isNullOrBlank()) {
            val parts = splitUpdatedAtCursor(after, SyncStreamType.PREFERENCE_PROPOSALS.wireName)
                ?: throw SyncCursorCorruptException(
                    SyncStreamType.PREFERENCE_PROPOSALS.wireName,
                    after,
                    "expected 'updatedAtUtcMillis:id'"
                )
            afterUpdatedAtUtcMillis = parts.first
            afterId = parts.second
            if (dao.findById(afterId) == null) {
                throw SyncCursorNotFoundException(SyncStreamType.PREFERENCE_PROPOSALS.wireName, after)
            }
        }

        val rows = dao.syncPage(afterUpdatedAtUtcMillis, afterId, limit + 1)
        val hasMore = rows.size > limit
        val batchRows = if (hasMore) rows.subList(0, limit) else rows
        val items = batchRows.map { it.toMap() }
        val lastRow = batchRows.lastOrNull()
        val nextCursor = if (lastRow != null) {
            "${lastRow.updatedAtUtcMillis}:${lastRow.id}"
        } else {
            after
        }

        return SyncBatch(
            protocolVersion = PROTOCOL_VERSION,
            streamType = SyncStreamType.PREFERENCE_PROPOSALS.wireName,
            items = items,
            nextCursor = nextCursor,
            hasMore = hasMore,
            generatedAtUtcMillis = now,
            remaining = dao.syncPendingCount(
                afterUpdatedAtUtcMillis = lastRow?.updatedAtUtcMillis ?: afterUpdatedAtUtcMillis,
                afterId = lastRow?.id ?: afterId
            )
        )
    }

    /** Splits a `updatedAtUtcMillis:id` cursor. */
    private fun splitUpdatedAtCursor(after: String?, stream: String): Pair<Long, String>? {
        if (after.isNullOrBlank()) return null
        val parts = after.trim().split(":")
        if (parts.size != 2) return null
        val updatedAtUtcMillis = parts[0].trim().toLongOrNull() ?: return null
        val id = parts[1].trim()
        if (id.isEmpty()) return null
        return updatedAtUtcMillis to id
    }

    /** Splits a `updatedAtUtcMillis:scope:key` cursor. */
    private fun splitPreferenceCursor(after: String?): PreferenceCursor? {
        if (after.isNullOrBlank()) return null
        val parts = after.trim().split(":")
        if (parts.size != 3) return null
        val updatedAtUtcMillis = parts[0].trim().toLongOrNull() ?: return null
        val scope = parts[1].trim()
        val key = parts[2].trim()
        if (scope.isEmpty() || key.isEmpty()) return null
        return PreferenceCursor(updatedAtUtcMillis, scope, key)
    }

    private data class PreferenceCursor(
        val updatedAtUtcMillis: Long,
        val scope: String,
        val key: String
    )
}
