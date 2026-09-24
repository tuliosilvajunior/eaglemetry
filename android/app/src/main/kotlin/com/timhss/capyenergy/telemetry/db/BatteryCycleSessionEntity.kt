package com.timhss.capyenergy.telemetry.db

import androidx.room.Entity
import androidx.room.Index

/**
 * One session's part in one battery cycle, as the fold attributed it.
 *
 * This table exists because the membership cannot be recovered from the
 * timestamps. A trip that crosses the 100 % mark is split between two cycles in
 * proportion to the SOC on each side of the boundary, so the same session
 * belongs to both, and by how much is a fact only `BatteryCycleLedger` knows.
 *
 * The row also outlives the session it names. Retention deletes sessions and a
 * cycle survives them, so [sessionId]
 * can point at a row that is gone. That is why the window is copied here: a
 * reader can still say when the session happened and that it was deleted,
 * instead of showing a shorter list as if it were the whole one.
 *
 * Written and deleted with the cycles, in the same transaction, so the two
 * cannot disagree about what a cycle is made of.
 */
@Entity(
    tableName = "battery_cycle_sessions",
    primaryKeys = ["cycleOrdinal", "sessionKind", "sessionId"],
    indices = [Index(value = ["cycleOrdinal"]), Index(value = ["sessionId"])]
)
data class BatteryCycleSessionEntity(
    val cycleOrdinal: Long,
    /** `TRIP`, `CHARGE` or `PARKED` — `BatteryCycleLedger.EventKind`. */
    val sessionKind: String,
    val sessionId: String,
    /** How much of the session this cycle took, 0 to 1. Below 1 only for a
     * trip split across a cycle boundary. */
    val share: Double,
    val startUtcMillis: Long,
    val endUtcMillis: Long
)
