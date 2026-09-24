package com.timhss.capyenergy.telemetry

import android.content.Context
import com.timhss.capyenergy.concurrent.namedSingleThreadExecutor
import com.timhss.capyenergy.telemetry.db.BatteryCycleEntity
import com.timhss.capyenergy.telemetry.db.BatteryCycleSessionEntity
import com.timhss.capyenergy.telemetry.db.TelemetryDatabase
import java.util.concurrent.Callable

/**
 * Keeps `battery_cycles` in step with the sessions.
 *
 * The rules live in `BatteryCycleLedger`. This class holds none of them:
 * `BatteryCycleEvents` turns rows into events and `BatteryCycleLedger` folds
 * them. What lives here is when to fold, how much to fold, and what to do when
 * the sessions behind a cycle are gone.
 *
 * The cycles are stored, not folded on demand, because retention deletes the
 * sessions and a cycle must outlive them.
 */
class BatteryCycleRepository(
    context: Context,
    private val capacityWhProvider: () -> Double? = { null },
    private val clock: () -> Long = System::currentTimeMillis,
    private val accountIdProvider: () -> String? = { null },
) {
    private val database = TelemetryDatabase.get(context.applicationContext)
    private val cycleDao = database.batteryCycleDao()
    private val cycleSessionDao = database.batteryCycleSessionDao()
    private val sessionDao = database.sessionDao()
    private val costDao = database.sessionCostDao()
    private val dbExecutor = namedSingleThreadExecutor("cycles-db")

    /** The cycles for the list, newest first. Refreshes before it reads. */
    fun cycles(limit: Int = DEFAULT_LIMIT): BatteryCyclePage {
        val effectiveLimit = limit.coerceIn(1, MAX_LIMIT)
        return dbExecutor.submit(Callable {
            rebuild(cycleDao.newestRebuildable())
            freezeCyclesWithoutSessions()
            BatteryCyclePage(
                cycles = cycleDao.latest(effectiveLimit).map { it.toRow() },
                totalCount = cycleDao.count(),
                limit = effectiveLimit
            )
        }).get()
    }

    /**
     * What one cycle is made of, oldest session first.
     *
     * It does not refresh first. The membership is written with the cycle, so
     * asking for the sessions of a cycle the reader is already looking at
     * cannot need a fold. An empty answer for a frozen cycle is the truth: the
     * sessions were deleted before this table existed.
     */
    fun sessions(ordinal: Long): List<BatteryCycleSessionRow> =
        dbExecutor.submit(Callable {
            cycleSessionDao.forCycle(ordinal).map { it.toRow() }
        }).get()

    /** Brings the open cycle up to date without reading the list. */
    fun refresh() {
        dbExecutor.submit {
            rebuild(cycleDao.newestRebuildable())
            freezeCyclesWithoutSessions()
        }.get()
    }

    /**
     * Rebuilds the cycles that a late pricing edit changed.
     *
     * Pricing a charge changes the pack blend from that charge forward, so
     * every cycle that ends at or after it is wrong. Any cycle is a valid
     * resume point, so the tail is rebuilt from the oldest affected cycle
     * rather than from the beginning. A frozen cycle is not rebuilt: its
     * sessions are gone, and it keeps the cost it closed with.
     */
    fun invalidateFrom(utcMillis: Long) {
        dbExecutor.submit {
            val target = cycleDao.oldestRebuildableEndingAtOrAfter(utcMillis)
            if (target != null) rebuild(target)
            freezeCyclesWithoutSessions()
        }.get()
    }

    /**
     * Folds forward from [resumeRow], replacing it and everything after it.
     *
     * The resume row is rebuilt rather than continued. It stores only the blend
     * it opened with, so reproducing it is what carries the blend into the
     * cycles that follow. This bounds the work to one cycle plus whatever is
     * new.
     */
    private fun rebuild(resumeRow: BatteryCycleEntity?) {
        val existingMaxOrdinal = cycleDao.maxOrdinal()
        val from = resumeRow?.startUtcMillis ?: 0L
        val sessions = sessionDao.closedFrom(from)
        val costs = costDao.forSessions(sessions.map { it.id }).associateBy { it.sessionId }
        val events = BatteryCycleEvents.build(
            sessions = sessions,
            capacityFallbackWh = capacityWhProvider(),
            costs = costs
        )
        if (events.isEmpty()) return

        val resume = when {
            resumeRow != null -> BatteryCycleLedger.Resume(
                pricedFraction = resumeRow.openingPricedFraction,
                blendedPrice = resumeRow.openingBlendedPrice,
                isPartial = resumeRow.isPartial
            )
            // Cycles exist but every one is frozen, so their sessions are gone.
            // The blend goes with them and the pack starts unpriced again. The
            // record already holds its first cycle, so what opens here is not
            // the partial one; only a fold with no resume at all may say that.
            existingMaxOrdinal != null -> BatteryCycleLedger.Resume()
            else -> null
        }
        val folded = BatteryCycleLedger.fold(events, resume)
        if (folded.isEmpty()) return

        // A frozen cycle may sit before the resume point, so the first ordinal
        // continues the record rather than starting at 1.
        val firstOrdinal = resumeRow?.ordinal ?: ((existingMaxOrdinal ?: 0L) + 1L)

        val now = clock()

        // The fold derives a cycle from whichever sessions it consumed, but
        // the account that writes it is the pairing active at fold time. A
        // rebuild replaces cycles and their membership in one transaction, so
        // the whole group shares one stamp; unowned rows are adopted, owned
        // rows keep their account (the `account_id IS NULL` rule).
        val stampAccountId = accountIdProvider()
        val rows = folded.mapIndexed { index, cycle ->
            cycle.toEntity(
                ordinal = firstOrdinal + index,
                createdAtUtcMillis = if (index == 0) {
                    resumeRow?.createdAtUtcMillis ?: now
                } else {
                    now
                },
                updatedAtUtcMillis = now,
                accountId = stampAccountId
            )
        }
        val members = folded.flatMapIndexed { index, cycle ->
            val ordinal = firstOrdinal + index
            cycle.members.map { member ->
                BatteryCycleSessionEntity(
                    cycleOrdinal = ordinal,
                    sessionKind = member.kind.name,
                    sessionId = member.sessionId,
                    share = member.share,
                    startUtcMillis = member.startUtcMillis,
                    endUtcMillis = member.endUtcMillis
                )
            }
        }
        // One transaction: a process that dies between the delete and the
        // insert would otherwise lose cycles whose sessions retention may
        // already have deleted, and those cannot be folded again. The
        // membership goes in the same one, so a cycle and the list of what it
        // is made of cannot disagree.
        database.runInTransaction(
            Runnable {
                cycleDao.deleteFrom(firstOrdinal)
                cycleSessionDao.deleteFrom(firstOrdinal)
                cycleDao.upsertAll(rows)
                cycleSessionDao.upsertAll(members)
            }
        )
    }

    /**
     * Freezes every cycle whose sessions retention has deleted.
     *
     * A frozen cycle can no longer be rebuilt, so the app must be able to tell
     * its cost is final. Freezing is decided against the oldest session that
     * survives: a cycle that ended before it has nothing left to fold.
     */
    private fun freezeCyclesWithoutSessions() {
        val oldestSession = sessionDao.oldestStartUtcMillisAll() ?: return

        val stale = cycleDao.newestClosedEndingBefore(oldestSession) ?: return
        cycleDao.freezeUpTo(stale.ordinal, clock())
    }

    /**
     * The capacity the fold may use, or null when none is trustworthy.
     *
     * This applies the plausibility guard but never the nameplate fallback.
     * A cycle with no capacity reports its energy as unknown, which is the rule
     * in `BatteryCycleLedger`; substituting the nameplate would print a
     * number the car did not support.
     */
    private fun BatteryCycleLedger.Cycle.toEntity(
        ordinal: Long,
        createdAtUtcMillis: Long,
        updatedAtUtcMillis: Long,
        accountId: String?,
    ) = BatteryCycleEntity(
        ordinal = ordinal,
        startUtcMillis = startUtcMillis,
        endUtcMillis = endUtcMillis,
        dischargePercent = dischargePercent,
        distanceKm = distanceKm,
        tripEnergyKwh = tripEnergyKwh,
        parkedEnergyKwh = parkedEnergyKwh,
        parkedSocPercent = parkedSocPercent,
        cost = cost,
        costCurrency = costCurrency,
        pricedEnergyKwh = pricedEnergyKwh,
        unpricedEnergyKwh = unpricedEnergyKwh,
        energyIncomplete = energyIncomplete,
        mixedCurrency = mixedCurrency,
        isOpen = isOpen,
        isPartial = isPartial,
        openingPricedFraction = openingPricedFraction,
        openingBlendedPrice = openingBlendedPrice,
        frozenAtUtcMillis = null,
        createdAtUtcMillis = createdAtUtcMillis,
        updatedAtUtcMillis = updatedAtUtcMillis,
        accountId = accountId,
    )

    companion object {
        const val DEFAULT_LIMIT = 200

        /**
         * A cycle is months of driving, so a page this deep is already the whole
         * record. The cap is here because the limit arrives from Flutter.
         */
        const val MAX_LIMIT = 1000
    }
}
