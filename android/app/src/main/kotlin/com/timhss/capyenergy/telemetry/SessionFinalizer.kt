package com.timhss.capyenergy.telemetry

import android.util.Log
import com.timhss.capyenergy.telemetry.db.SessionEntity
import com.timhss.capyenergy.telemetry.db.TelemetryDatabase

/**
 * Terminal status and rollup, committed together.
 */
class SessionFinalizer(
    private val database: TelemetryDatabase,
    private val capacityWhProvider: () -> Double? = { null },
    private val beforeCommit: () -> Unit = {},
    private val nowUtcMillisProvider: () -> Long = { System.currentTimeMillis() },
    private val currentBootCountProvider: () -> Long? = { null },
    private val anchorLearnedProvider: () -> Boolean = { ClockAnchorStore.isLearned() },
    private val onCrossBootBand: (ClockCrossBootBand.Band) -> Unit = { }
) {
    /**
     * Seams a unit drive can override: the neighbours read from a detached
     * DAO. A reader that returns no placed neighbours is the honest
     * no-evidence answer, so the default reads the real table.
     */
    var placedNeighboursReader: (unplacedSessionId: String) -> List<ClockCrossBootBand.PlacedSpan> =
        { unplacedSessionId -> defaultPlacedNeighbours(unplacedSessionId) }
    private val sessionDao = database.sessionDao()
    private val intervalDao = database.intervalDao()
    private val segmentDao = database.tripSegmentDao()
    private val trackDao = database.trackDao()
    private val clockSweeper = ClockBackfillSweeper(
        intervalDao,
        replacedKeyDao = database.intervalReplacedKeyDao(),
        sessionDao = sessionDao,
        currentBootCountProvider = currentBootCountProvider,
    )
    private val signatureLedger = ClockBadSignatureLedger(
        database.clockBadSignatureDao(),
        intervalDao,
        nowUtcMillisProvider
    )

    fun finalizeTrip(
        pending: SessionEntity,
        terminalStatus: String = TRIP_TERMINAL_STATUS
    ) {
        finalize(pending, terminalStatus)
    }

    fun finalizeCharge(
        pending: SessionEntity,
        terminalStatus: String = recoveredChargeTerminalStatus(pending)
    ) {
        finalize(pending, terminalStatus)
    }

    fun finalize(
        pending: SessionEntity,
        terminalStatus: String = defaultTerminalStatus(pending)
    ) {
        require(pending.status == FINALIZATION_PENDING)
        val rawIntervals = intervalDao.forSession(pending.id)
        val intervals = IntervalReconciler.reconcile(pending, rawIntervals)
        val rollup = intervals.rollup()
        val sweep = SessionSampleSweep { }
        val terminal = pending.copy(status = terminalStatus)
        val folded = SessionAggregateCalculator.applyFold(
            session = terminal,
            rollup = rollup,
            sweep = sweep
        )
        val segmentation = if (pending.kind == "TRIP") TripSegmenter.cut(sweep) else null
        val closedTrack = closeTrack(pending)
        val stamped = if (closedTrack == null) {
            folded
        } else {
            folded.copy(
                climbM = closedTrack.climbM,
                descentM = closedTrack.descentM,
                fixCount = closedTrack.fixCount
            )
        }

        database.runInTransaction {
            if (intervals != rawIntervals) {
                intervalDao.deleteBySessionIds(listOf(pending.id))
                intervalDao.upsertAll(intervals)
            }
            sessionDao.upsert(stamped)
            // The close rewrites the route once (simplified); the account stamp
            // must survive that rewrite. The rewritten row keeps the owner it
            // already had; only an unowned route is adopted by the session's
            // account (the `account_id IS NULL` rule).
            if (closedTrack != null) {
                val account = closedTrack.track.accountId ?: pending.accountId
                trackDao.upsert(closedTrack.track.copy(accountId = account))
            }
            if (segmentation != null) {
                segmentDao.replaceForSession(
                    pending.id,
                    segmentation.segments.map { TripSegmenter.toEntity(it, pending.id, pending.accountId) }
                )
            }
        }
        // The close re-anchors the session's own state: the detector sees a
        // wrong clock but can only wait for truth, so a close that lands
        // after the boot learned its anchor promotes the session to known
        // (and re-marks it dirty — a pending session may already have
        // uploaded under wrong stamps, and the corrected stamps must go up).
        // A close before truth leaves the state alone: the next close
        // re-runs the sweep, and retention never ages the pending row first.
        val closeState = ClockUnlockBackfillEngine.sessionCloseState(
            stamped.timeState,
            anchorLearnedProvider()
        )
        if (closeState != stamped.timeState) {
            sessionDao.upsert(
                stamped.copy(
                    timeState = closeState,
                    dirty = true,
                    updatedAtUtcMillis = nowUtcMillisProvider()
                )
            )
        }
        // The close sweeps the boot's still-pending minutes: when a truth
        // source already landed, every wrong minute re-anchors by exact
        // arithmetic (the captain's D-44). Without truth nothing is written
        // — the sweep is idempotent and a later close repeats it.
        runCatching {
            clockSweeper.sweepOnClose(pending.id, pending.startedAtBootCount)
        }.onFailure {
            Log.w(TAG, "clock backfill sweep failed for session ${pending.id}", it)
        }
        // The cross-boot corner (T8): a boot whose stamps stayed wrong can
        // still be BOUNDED if the placed-neighbour sweep below finds two
        // trusted sessions around it. The band verdict runs after the
        // backfill sweep so the sweep's corrections cannot be narrowed by
        // the band; the band only ever widens knowledge about a still-
        // uncorrectable boot (plan section 5.3: the interval answer, not a
        // point).
        runCatching {
            val placed = placedNeighboursReader(pending.id)
            if (placed.isNotEmpty()) {
                val unplaced = ClockCrossBootBand.UnplacedSession(
                    sessionId = pending.id,
                    bootCount = pending.startedAtBootCount?.toLong(),
                    elapsedDurationMillis = monotonicDurationMillis(pending),
                    startOdometerKm = pending.startOdometerKm?.toDouble(),
                    endOdometerKm = pending.endOdometerKm?.toDouble(),
                    startSocPercent = pending.startSocPercent,
                    endSocPercent = pending.endSocPercent
                )
                val band = ClockCrossBootBand.place(unplaced, placed)
                onCrossBootBand(band)
            }
        }.onFailure {
            Log.w(TAG, "cross-boot band placement failed for session ${pending.id}", it)
        }
        // The close also feeds the boot through the detector: stamps the
        // structural arms PROVED default join the evidence ledger, so the
        // next boot that opens on the same value is pending from the first
        // minute — learned from data, never written as a constant.
        runCatching {
            pending.startedAtBootCount?.let { signatureLedger.learnFromBoot(it.toLong()) }
        }.onFailure {
            Log.w(TAG, "clock signature learning failed for boot ${pending.id}", it)
        }
    }

    /**
     * Simplifies the drive once, at close, and reads the three Session numbers
     * off the raw points.
     *
     * The row is taken from the database rather than from the recorder that
     * built it. The minute tick has already written every point raw, so the
     * stored row is the whole drive, and reading it here means a close after a
     * process restart produces the same path as a close that never lost the
     * recorder. It also puts the simplification and the rollup in one
     * transaction.
     *
     * Simplification happens exactly once. `climbM` and `descentM` are summed
     * before it, because dropping a point drops the metres between it and its
     * neighbours; a reader deriving the climb from the stored path afterwards
     * would get a smaller number than the drive measured.
     *
     * Returns null when the session has no route, which is every charge and
     * every trip that never got a fix. Nothing is written then, so a Session
     * holds one Track row or none, never an empty one.
     */
    private fun closeTrack(pending: SessionEntity): TrackClose? {
        val stored = trackDao.forSession(pending.id) ?: return null
        return try {
            val raw = TrackCodec.decode(stored.toRow())
            if (raw.isEmpty()) {
                null
            } else {
                TrackRecorder.close(pending.id, raw, nowUtcMillisProvider())
            }
        } catch (e: Exception) {
            // The stored route stays as it is. A path this build cannot read
            // is not a path it may rewrite, and the rest of the close is
            // unaffected.
            Log.w(TAG, "Unreadable track for ${pending.id}; leaving it raw", e)
            null
        }
    }

    private fun defaultTerminalStatus(session: SessionEntity): String = when (session.kind) {
        "TRIP" -> TRIP_TERMINAL_STATUS
        "CHARGE" -> recoveredChargeTerminalStatus(session)
        else -> "ENDED"
    }

    private fun recoveredChargeTerminalStatus(session: SessionEntity): String {
        return if (session.chargeEndReason == ChargeEndReason.APP_RESTART_RECOVERY.name) {
            "ENDED"
        } else {
            "DISCONNECTED"
        }
    }

    /**
     * Time authority T8: the sessions whose stamps the sweeper trusts, read
     * from the STORED table (not the live estimate). A placed neighbour is a
     * closed session on a boot whose anchor was learned: `timeState = known`.
     * The unplaced session's own row is excluded by rule, never by identity
     * comparison alone — a legacy session may still be unknown, and the
     * unknown's stamps must never become a bracketing edge.
     */
    private fun defaultPlacedNeighbours(
        unplacedSessionId: String
    ): List<ClockCrossBootBand.PlacedSpan> {
        val unplaced = sessionDao.findById(unplacedSessionId) ?: return emptyList()
        return sessionDao.latestAll(Int.MAX_VALUE).asSequence()
            .filter { it.id != unplaced.id }
            .filter { it.timeState == ClockUnlockBackfillEngine.STATE_KNOWN }
            .filter { it.status != FINALIZATION_PENDING }
            .filter { resolvedEndMillis(it) > it.startedAtUtcMillis }
            .map { session ->
                ClockCrossBootBand.PlacedSpan(
                    sessionId = session.id,
                    startUtcMillis = session.startedAtUtcMillis,
                    endUtcMillis = resolvedEndMillis(session),
                    startOdometerKm = session.startOdometerKm?.toDouble(),
                    endOdometerKm = session.endOdometerKm?.toDouble(),
                    startSocPercent = session.startSocPercent,
                    endSocPercent = session.endSocPercent
                )
            }.toList()
    }

    private fun resolvedEndMillis(session: SessionEntity): Long =
        session.endedAtUtcMillis ?: session.updatedAtUtcMillis

    /**
     * The session's monotonic length when both edges carry the pair on one
     * boot (exact on the elapsed axis). Without the pair the wall-stamp
     * difference is the last honest ceiling the row still carries: wrong on
     * a jumped clock, but an OVER-estimate only widens the searched window
     * - it can never place the session inside a gap it does not fit.
     */
    private fun monotonicDurationMillis(session: SessionEntity): Long {
        val start = session.startedAtElapsedNanos
        val end = session.endedAtElapsedNanos ?: session.updatedAtElapsedNanos
        val sameBoot = session.startedAtBootCount != null &&
            session.startedAtBootCount == session.endedAtBootCount
        return if (end != null && end >= start && sameBoot) {
            (end - start) / 1_000_000L
        } else {
            // Without a monotonic pair on both edges there is no exact
            // duration; the wall stamp difference is the last honest ceiling
            // the session itself carries — wrong on a jumped clock, but the
            // OVER-estimate locks the session in after the neighbours, never
            // inside a gap it cannot fit.
            maxOf(
                0L,
                resolvedEndMillis(session) - session.startedAtUtcMillis
            )
        }
    }


    companion object {
        const val FINALIZATION_PENDING = "FINALIZATION_PENDING"
        private const val TRIP_TERMINAL_STATUS = "ENDED"
        private const val TAG = "SessionFinalizer"
    }
}
