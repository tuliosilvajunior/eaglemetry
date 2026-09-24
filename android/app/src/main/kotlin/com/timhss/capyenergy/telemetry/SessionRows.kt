package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.SessionEntity

/**
 * One list row: the stored session, plus what is only true right now.
 */
data class TripSessionRow(
    val session: SessionEntity,
    /** Reconciled across reboots, never end minus start on the wall clock. */
    val durationMillis: Long?,
    val endSoc: Float?,
    val endOdometerKm: Float?,
    val updatedAtUtcMillis: Long,
)

data class ChargeSessionRow(
    val session: SessionEntity,
    val durationMillis: Long?,
    val endSoc: Float?,
    val endOdometerKm: Float?,
    val endAmbientTempC: Float?,
    /** Integrated from DC power, which is the trustworthy signal while charging. */
    val estimatedEnergyKwh: Double?,
    val updatedAtUtcMillis: Long,
)

/** A page of rows with the counters the list header shows. */
data class TripSessionPage(
    val sessions: List<TripSessionRow>,
    val totalCount: Long,
    val limit: Int,
    val tripWritesThisRun: Long,
)

data class ChargeSessionPage(
    val sessions: List<ChargeSessionRow>,
    val totalCount: Long,
    val limit: Int,
    val chargeWritesThisRun: Long,
)

/**
 * A run of charges the detector split but a driver would call one session.
 *
 * The breaks travel with it so the reader can judge the suggestion rather than
 * trust it: a merge deletes rows, and the evidence for it belongs on screen.
 */
data class ChargeMergeCandidateRow(
    val sessionIds: List<String>,
    val sessions: List<ChargeSessionRow>,
    val breaks: List<ChargeMergeBreakRow>,
    val startUtcMillis: Long,
    val endUtcMillis: Long,
    val durationMillis: Long,
    val totalFrames: Long,
    val startSoc: Float?,
    val endSoc: Float?,
    val startOdometerKm: Float?,
    val endOdometerKm: Float?,
)

data class ChargeMergeBreakRow(
    val previousSessionId: String,
    val nextSessionId: String,
    val gapMillis: Long,
    val socDelta: Float?,
    val odometerDeltaKm: Float?,
)

data class ChargeMergeCandidatePage(
    val candidates: List<ChargeMergeCandidateRow>,
    val totalCount: Int,
    val limit: Int,
)

data class ChargeMergeOutcome(
    val ok: Boolean,
    val error: String?,
    val mergedSessionId: String?,
    val mergedCount: Int,
    val framesReassigned: Int,
    val deletedSessions: Int,
)

/** The row as it stands after a price was written, not the price requested. */
data class ChargeCostUpdate(
    val ok: Boolean,
    val updatedRows: Int,
    val session: ChargeSessionRow?,
)

/**
 * What the "price the unpriced charges" action did.
 *
 * [costPerKwh] and [currency] are what was written, so the screen reports the
 * rate that landed rather than the one it asked for. [updatedRows] is zero
 * both when nothing needed a price and when the write failed; [ok] separates
 * them.
 */
data class DefaultChargeCostApplication(
    val ok: Boolean,
    val updatedRows: Int,
    val costPerKwh: Double?,
    val currency: String,
    val error: String?,
    /**
     * The start of the oldest charge this action priced, or null when it
     * priced none. The cycle ledger is rebuilt from there, and it can only be
     * read before the write, because afterwards no unpriced row points at it.
     */
    val oldestPricedStartUtcMillis: Long? = null,
)
