package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.ClockAnchorStore.Anchor
import com.timhss.capyenergy.telemetry.db.IntervalDao
import com.timhss.capyenergy.telemetry.db.IntervalEntity
import com.timhss.capyenergy.telemetry.db.IntervalReplacedKeyDao
import com.timhss.capyenergy.telemetry.db.IntervalReplacedKeyEntity
import com.timhss.capyenergy.telemetry.db.SessionDao

/**
 * Time authority T5, step 3: the joint between storage and the engine. Runs
 * at every session close: with the boot's learned anchor it rewrites the
 * boot's pending minutes onto the trusted instants (the captain's D-44
 * backfill); without one it writes nothing, never deletes and never guesses
 *
 * A re-anchored row is a new key when its minute moved, so the sweep writes
 * the resolved rows and deletes exactly the old keys it replaced, inside
 * the caller's transaction.
 */
class ClockBackfillSweeper(
    private val intervalDao: IntervalDao,
    private val replacedKeyDao: IntervalReplacedKeyDao? = null,
    private val sessionDao: SessionDao? = null,
    private val currentBootCountProvider: () -> Long? = { null },
    private val nowUtcMillisProvider: () -> Long = { System.currentTimeMillis() }
) {

    /**
     * Sweeps one session's boot on close. Returns the count of rows the
     * trusted anchor rewrote. A boot without a learned anchor is swept
     * again by a later close — the sweep is idempotent (plan section 5.1).
     */
    fun sweepOnClose(sessionId: String, sessionBootCount: Int?): Int {
        val boot = sessionBootCount?.toLong() ?: return 0
        return sweepBoot(boot)
    }

    /**
     * G1: the same sweep without a session close. Runs when the boot's
     * anchor is learned after a truthless close left pendings behind, so
     * the minutes resolve with no later close. Same guards, same writes,
     * plus the closed `pending` sessions of this boot are promoted with
     * their edge stamps re-anchored by the same arithmetic. Idempotent:
     * a second run finds no pendings and rewrites nothing.
     */
    fun sweepBoot(boot: Long): Int {
        val currentBoot = currentBootCountProvider()
        if (currentBoot != null && currentBoot != boot) return 0
        if (!ClockAnchorStore.isLearned()) return 0
        val anchor = ClockAnchorStore.anchor() ?: return 0
        promoteClosedPendingSessions(boot, anchor)
        val candidates = intervalDao.pendingsForBoot(boot)
        val outcome = ClockUnlockBackfillEngine.clockUnlockWithKeys(candidates, anchor, boot)
        val resolved = outcome.rows
        if (resolved.isEmpty()) return 0
        val candidateKeys = candidates.filter { it.startBootCount?.toLong() == boot }
            .map { Pair(it.sessionId, it.startUtcMillis) }
            .toSet()
        val resolvedKeys = resolved.map { Pair(it.sessionId, it.startUtcMillis) }.toSet()
        val staleKeys = candidateKeys - resolvedKeys
        for (row in staleKeys) {
            intervalDao.deleteKey(row.first, row.second)
        }
        val mergedResolved = resolved.map { row ->
            val existing = intervalDao.findById(row.sessionId, row.startUtcMillis)
            if (existing != null && Pair(existing.sessionId, existing.startUtcMillis) !in staleKeys &&
                existing.startElapsedNanos != row.startElapsedNanos
            ) {
                existing.copy(
                    tractionWh = existing.tractionWh + row.tractionWh,
                    regenWh = existing.regenWh + row.regenWh,
                    auxiliaryWh = existing.auxiliaryWh + row.auxiliaryWh,
                    climateWh = existing.climateWh + row.climateWh,
                    deliveredWh = existing.deliveredWh + row.deliveredWh,
                    distanceKm = existing.distanceKm + row.distanceKm,
                    coveredSeconds = existing.coveredSeconds + row.coveredSeconds,
                    climateCoveredSeconds = existing.climateCoveredSeconds + row.climateCoveredSeconds,
                    speedCoveredSeconds = existing.speedCoveredSeconds + row.speedCoveredSeconds,
                    deliveredCoveredSeconds = existing.deliveredCoveredSeconds + row.deliveredCoveredSeconds,
                    startSoc = existing.startSoc ?: row.startSoc,
                    endSoc = row.endSoc ?: existing.endSoc,
                    startVoltage = existing.startVoltage ?: row.startVoltage,
                    endVoltage = row.endVoltage ?: existing.endVoltage,
                    startElapsedNanos = minOf(
                        existing.startElapsedNanos ?: Long.MAX_VALUE,
                        row.startElapsedNanos ?: Long.MAX_VALUE
                    ).takeIf { it != Long.MAX_VALUE },
                    timeState = ClockUnlockBackfillEngine.STATE_KNOWN,
                    dirty = true,
                    correctedFromUtcMillis = existing.correctedFromUtcMillis ?: row.correctedFromUtcMillis,
                    updatedAtUtcMillis = maxOf(existing.updatedAtUtcMillis, row.updatedAtUtcMillis)
                )
            } else {
                row
            }
        }
        // T9: every old key the sweep replaced is queued for the cloud
        // re-upload — exact keys, one per rewritten row, two when a
        // collision merged minutes. The queue is written with the new rows
        // in the same sweep pass; the uploader drains it AFTER the corrected
        // insert succeeds (insert first, delete after).
        if (outcome.replacedKeys.isNotEmpty()) {
            replacedKeyDao?.upsertAll(
                outcome.replacedKeys.map {
                    IntervalReplacedKeyEntity(
                        sessionId = it.sessionId,
                        startUtcMillis = it.oldStartUtcMillis,
                        replacedByUtcMillis = it.correctedStartUtcMillis
                    )
                }
            )
        }
        intervalDao.upsertAll(mergedResolved)
        return mergedResolved.size
    }

    /**
     * Promotes the boot's already-closed `pending` sessions once truth
     * landed: every edge stamp on this boot re-anchors by the same exact
     * arithmetic the intervals use
     * (`wall = anchorWall + (elapsed - anchorElapsed)`), the state moves to
     * `known` via the same [ClockUnlockBackfillEngine.sessionCloseState]
     * the close path uses, and the row is re-marked dirty so the corrected
     * stamps upload. Active sessions keep their live stamps; their close
     * promotes them. Cross-boot sessions are skipped: an edge on another
     * boot has no anchor here. Idempotent: a promoted session is `known`
     * and never matches again.
     */
    private fun promoteClosedPendingSessions(boot: Long, anchor: Anchor) {
        val sessions = sessionDao ?: return
        val now = nowUtcMillisProvider()
        val closed = sessions.findByKind("TRIP") + sessions.findByKind("CHARGE") +
            sessions.findByKind("PARKED") + sessions.findByKind("CONTINUOUS")
        for (session in closed) {
            if (session.timeState != ClockUnlockBackfillEngine.STATE_PENDING) continue
            if (session.status == SessionFinalizer.FINALIZATION_PENDING) continue
            val endWall = session.endedAtUtcMillis ?: continue
            if (session.startedAtBootCount?.toLong() != boot) continue
            if (session.startedAtBootCount != session.endedAtBootCount) continue
            val start = reanchor(session.startedAtUtcMillis, session.startedAtElapsedNanos, session.startedAtBootCount, boot, anchor) ?: continue
            val end = reanchor(endWall, session.endedAtElapsedNanos, session.endedAtBootCount, boot, anchor) ?: continue
            sessions.upsert(
                session.copy(
                    startedAtUtcMillis = start,
                    endedAtUtcMillis = end,
                    movementStartedAtUtcMillis = reanchorEdge(session.movementStartedAtUtcMillis, session.movementStartedAtElapsedNanos, session.movementStartedAtBootCount, boot, anchor),
                    chargeStartedAtUtcMillis = reanchorEdge(session.chargeStartedAtUtcMillis, session.chargeStartedAtElapsedNanos, session.chargeStartedAtBootCount, boot, anchor),
                    chargeEndedAtUtcMillis = reanchorEdge(session.chargeEndedAtUtcMillis, session.chargeEndedAtElapsedNanos, session.chargeEndedAtBootCount, boot, anchor),
                    plugDisconnectedAtUtcMillis = reanchorEdge(session.plugDisconnectedAtUtcMillis, session.plugDisconnectedAtElapsedNanos, session.plugDisconnectedAtBootCount, boot, anchor),
                    timeState = ClockUnlockBackfillEngine.sessionCloseState(
                        session.timeState,
                        anchorLearned = true
                    ),
                    dirty = true,
                    updatedAtUtcMillis = now
                )
            )
        }
    }

    private fun reanchorEdge(wall: Long?, elapsed: Long?, edgeBoot: Int?, boot: Long, anchor: Anchor): Long? {
        if (wall == null) return null
        return reanchor(wall, elapsed, edgeBoot, boot, anchor) ?: wall
    }

    private fun reanchor(wall: Long, elapsed: Long?, edgeBoot: Int?, boot: Long, anchor: Anchor): Long? {
        if (edgeBoot?.toLong() != boot || elapsed == null || elapsed <= 0L) return null
        return anchor.wallMillis + (elapsed - anchor.elapsedNanos) / 1_000_000L
    }
}
