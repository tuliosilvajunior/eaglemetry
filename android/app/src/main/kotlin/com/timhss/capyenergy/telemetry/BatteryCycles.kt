package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.BatteryCycleEntity
import com.timhss.capyenergy.telemetry.db.BatteryCycleSessionEntity

/**
 * One battery cycle, as the list shows it.
 *
 * This is the domain type the repository answers with, beside [SessionRows] and
 * [EnergySeries]. The bridge spells it for Flutter, so `battery_cycles` never
 * has to know what Flutter calls a field: those column names are the on-disk
 * format of the export, so a rename changes a file format.
 *
 * `openingPricedFraction` and `openingBlendedPrice` are absent on purpose. They
 * exist so a refresh can resume the fold at any cycle; no reader shows them,
 * and a field on the wire that nobody reads is a field two sides have to keep
 * agreeing about for nothing.
 */
data class BatteryCycleRow(
    /** The identity, counting from 1 at the oldest cycle. */
    val ordinal: Long,
    val startUtcMillis: Long,
    val endUtcMillis: Long,
    /** How full the bar is, 0 to 100. Below 100 only for the open cycle. */
    val dischargePercent: Double,
    val distanceKm: Double,
    val tripEnergyKwh: Double,
    /** Counted against the money ledger, but it never moved the boundary. */
    val parkedEnergyKwh: Double,
    val parkedSocPercent: Double,
    val cost: Double?,
    val costCurrency: String?,
    val pricedEnergyKwh: Double,
    val unpricedEnergyKwh: Double,
    val isOpen: Boolean,
    /** Collection began in the middle of this battery, so it is not a whole one. */
    val isPartial: Boolean,
    /** Some interval had no trustworthy capacity, so the energy is a floor. */
    val energyIncomplete: Boolean,
    val mixedCurrency: Boolean,
    /**
     * When the sessions behind this cycle were found to be gone.
     *
     * A frozen cycle cannot be folded again, so its cost is final rather than
     * current. The reader needs the two apart before it adds them together.
     */
    val frozenAtUtcMillis: Long?,
    val updatedAtUtcMillis: Long,
)

/**
 * One session's part in one cycle, as the list of a cycle shows it.
 *
 * [share] is below 1 only for a trip the fold split across the 100 % mark. The
 * window is the session's own, copied when the cycle was folded, so a session
 * retention has since deleted can still be named and placed in time.
 */
data class BatteryCycleSessionRow(
    val cycleOrdinal: Long,
    /** `TRIP`, `CHARGE` or `PARKED`. */
    val kind: String,
    val sessionId: String,
    val share: Double,
    val startUtcMillis: Long,
    val endUtcMillis: Long,
    /**
     * The session itself, when it still exists and has a list row.
     *
     * Filled by the read surface, not by the cycle repository: the membership
     * is stored, the session is looked up. A parked session has no list row, so
     * both stay null for one and [deleted] is the only thing to read.
     */
    val trip: TripSessionRow? = null,
    val charge: ChargeSessionRow? = null,
    /**
     * The session row is gone. Retention deleted it and the cycle outlived it.
     *
     * This is why the window above is stored beside the id: a deleted session
     * can still be placed in time and counted, and the reader can say that it
     * is no longer there instead of showing a shorter list as a whole one.
     */
    val deleted: Boolean = false
)

/** What one cycle is made of, oldest session first. */
data class BatteryCycleSessionsPage(
    val ordinal: Long,
    val sessions: List<BatteryCycleSessionRow>
)

/** A page of cycles, newest first, with the count the header shows. */
data class BatteryCyclePage(
    val cycles: List<BatteryCycleRow>,
    val totalCount: Long,
    val limit: Int,
)

internal fun BatteryCycleEntity.toRow(): BatteryCycleRow = BatteryCycleRow(
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
    isOpen = isOpen,
    isPartial = isPartial,
    energyIncomplete = energyIncomplete,
    mixedCurrency = mixedCurrency,
    frozenAtUtcMillis = frozenAtUtcMillis,
    updatedAtUtcMillis = updatedAtUtcMillis,
)

internal fun BatteryCycleSessionEntity.toRow(): BatteryCycleSessionRow = BatteryCycleSessionRow(
    cycleOrdinal = cycleOrdinal,
    kind = sessionKind,
    sessionId = sessionId,
    share = share,
    startUtcMillis = startUtcMillis,
    endUtcMillis = endUtcMillis
)
