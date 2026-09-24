package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.ClockAnchorStore.Anchor
import com.timhss.capyenergy.telemetry.db.IntervalEntity

/**
 * Time authority T5, step 2: the unlock-and-backfill engine.
 *
 * The head unit boots on the MCU's default wall clock and only syncs seconds
 * later (the captain: "viagem nenhuma dura segundos"). Minutes recorded
 * before the truth arrives carry the boot-default stamp; the monotonic pair
 * `(startElapsedNanos, startBootCount)` recorded with them (T2) is the exact
 * axis the truth re-anchors. Per plan section 1, within one boot the
 * correction is exact arithmetic, never estimation:
 *
 *     wall'(row) = anchorWall + (rowElapsed − anchorElapsed)
 *
 * floored to the minute bucket. Rows written on the trusted offset already
 * are left alone; rows whose boot differs from the anchor's are never
 * re-anchored with a foreign reference, because `elapsedRealtimeNanos`
 * restarts on reboot and a cross-boot subtraction lies (plan section 2).
 *
 * Pure Kotlin: the caller feeds rows from storage and hands the results
 * back to a transaction; the engine never touches the database or the
 * clock, so the JVM rig exercises every rule without Android.
 */

data class ReplacedIntervalKey(
    val sessionId: String,
    /** The OLD wrong stamp that must leave the cloud when the corrected row lands. */
    val oldStartUtcMillis: Long,
    /** The corrected stamp the row now carries. */
    val correctedStartUtcMillis: Long,
)

/**
 * One correction pass: the rewritten rows plus, for every OLD key that died,
 * the exact pairing old→corrected. The cloud re-upload (T9) deletes only
 * these keys, after the corrected rows land — never a blanket, never the
 * corrected key.
 */
data class ClockUnlockOutcome(
    val rows: List<IntervalEntity>,
    val replacedKeys: List<ReplacedIntervalKey>,
)
object ClockUnlockBackfillEngine {

    /**
     * Resolves the [candidates] of the anchor's own boot onto the trusted
     * instant. Returns one rewritten row per resolved candidate (with a new
     * `startUtcMillis` key when the rewrite moves minutes), in candidate
     * order. The caller persists them and drops the replaced old keys.
     *
     * [anchorBootCount] is the boot the anchor's elapsed axis belongs to.
     * When null, the boot comes from the rows themselves — the sweep runs
     * inside one session close, so the candidate list is one boot; a
     * mixed-boot list with no explicit boot is refused, because re-anchoring
     * a row with a foreign boot's reference lies once the monotonic axis
     * restarted (plan section 2).
     */
    fun clockUnlock(
        candidates: List<IntervalEntity>,
        anchor: Anchor?,
        anchorBootCount: Long? = null
    ): List<IntervalEntity> = clockUnlockWithKeys(candidates, anchor, anchorBootCount).rows

    /**
     * T9: [clockUnlock] plus the replaced-keys ledger. Same resolution rule;
     * the caller persists the rows and queues the keys.
     */
    fun clockUnlockWithKeys(
        candidates: List<IntervalEntity>,
        anchor: Anchor?,
        anchorBootCount: Long? = null
    ): ClockUnlockOutcome {
        if (anchor == null) return ClockUnlockOutcome(emptyList(), emptyList())
        val boots = candidates.mapNotNull { it.startBootCount?.toLong() }.toSet()
        val boot = anchorBootCount ?: when (boots.size) {
            1 -> boots.first()
            else -> return ClockUnlockOutcome(emptyList(), emptyList())
        }
        val replaced = mutableListOf<ReplacedIntervalKey>()
        val resolved = candidates.mapNotNull { row ->
            val elapsedNanos = row.startElapsedNanos ?: return@mapNotNull null
            if (row.startBootCount?.toLong() != boot) return@mapNotNull null
            val resolvedMillis =
                anchor.wallMillis + (elapsedNanos - anchor.elapsedNanos) / NANOS_PER_MILLISECOND
            val aligned = EnergyBucketAccumulator.alignToBucket(resolvedMillis)
            // A row already on the trusted minute and already marked known needs no rewrite.
            if (aligned == row.startUtcMillis && row.timeState == STATE_KNOWN) return@mapNotNull null
            // Only a row whose minute MOVED replaces a cloud key. A row
            // resolved onto its own bucket rewrites in place: same key, no
            // deletion, no marker to confuse the re-upload.
            if (aligned != row.startUtcMillis) {
                replaced += ReplacedIntervalKey(row.sessionId, row.startUtcMillis, aligned)
            }
            row.copy(
                startUtcMillis = aligned,
                timeState = STATE_KNOWN,
                dirty = true,
                updatedAtUtcMillis = row.updatedAtUtcMillis,
                correctedFromUtcMillis = row.startUtcMillis.takeIf { it != aligned }
            )
        }
        val merged = mergeCollisions(resolved, replaced)
        return ClockUnlockOutcome(merged, replaced)
    }

    /**
     * When two pending rows map to the same corrected minute, merge by
     * summation per plan section 5.1 (the combine contract).
     */
    private fun mergeCollisions(
        rows: List<IntervalEntity>,
        replaced: MutableList<ReplacedIntervalKey>
    ): List<IntervalEntity> {
        if (rows.size <= 1) return rows
        val grouped = LinkedHashMap<Pair<String, Long>, IntervalEntity>()
        for (row in rows) {
            val key = Pair(row.sessionId, row.startUtcMillis)
            val existing = grouped[key]
            if (existing == null) {
                grouped[key] = row
            } else {
                // The ledger already names both old keys (one per candidate,
                // registered during resolution). Nothing is removed here: the
                // second old row must survive or it would orphan in the cloud.
                // The merged row keeps the FIRST old stamp as its marker.
                grouped[key] = existing.copy(
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
                    timeState = STATE_KNOWN,
                    dirty = true,
                    correctedFromUtcMillis = existing.correctedFromUtcMillis ?: row.correctedFromUtcMillis,
                    updatedAtUtcMillis = maxOf(existing.updatedAtUtcMillis, row.updatedAtUtcMillis)
                )
            }
        }
        return grouped.values.toList()
    }

    /**
     * Marks the rows whose boot never saw a trusted anchor: the time is
     * wrong and nothing can fix it here, so the state names it and the rows
     * are PRESERVED (the captain's no-silent-loss rule). Not deletion, not a
     * guess — a label. True for rows it marked, false when the boot did see
     * a trusted anchor (nothing is uncorrectable then).
     */
    fun markUncorrectable(rows: List<IntervalEntity>): List<IntervalEntity> =
        rows.map { it.copy(timeState = STATE_UNCORRECTABLE) }

    /**
     * Time authority T6: the stamp a session is born with. A boot with a
     * learned anchor writes `known`; a boot still waiting for truth writes
     * `pending` — the detector sees the wrong clock but can do nothing but
     * wait, so consumers read this instead of re-deriving.
     */
    fun sessionBirthState(anchorLearned: Boolean): String =
        if (anchorLearned) STATE_KNOWN else STATE_PENDING

    /**
     * The stamp a session closes with. A close that lands after the boot
     * learned its anchor promotes to `known` (the stamps are trustworthy
     * now); a close before truth keeps whatever the session had, except
     * `unknown` — a pre-authority row closing on an untrusted boot is
     * pending, not grandfathered. `known` never steps back to `pending`.
     */
    fun sessionCloseState(current: String, anchorLearned: Boolean): String =
        when {
            anchorLearned || current == STATE_KNOWN -> STATE_KNOWN
            current == STATE_UNCORRECTABLE -> STATE_UNCORRECTABLE
            else -> STATE_PENDING
        }

    const val STATE_PENDING = "pending"
    const val STATE_KNOWN = "known"
    const val STATE_UNCORRECTABLE = "uncorrectable"

    private const val NANOS_PER_MILLISECOND = 1_000_000L
}
