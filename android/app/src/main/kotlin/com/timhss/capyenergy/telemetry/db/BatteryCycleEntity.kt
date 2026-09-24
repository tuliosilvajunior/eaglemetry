package com.timhss.capyenergy.telemetry.db

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

/**
 * One materialized battery cycle.
 *
 * The cycles are stored rather than folded on demand because retention deletes
 * the sessions that made them and a cycle must outlive them.
 *
 * [ordinal] is the identity. It counts from 1 at the oldest cycle and never
 * changes, so a rebuild replaces rows instead of appending them.
 */
@Entity(
    tableName = "battery_cycles",
    indices = [
        Index(value = ["startUtcMillis"]),
        Index(value = ["dirty", "ordinal"])
    ]
)
data class BatteryCycleEntity(
    @PrimaryKey val ordinal: Long,
    val startUtcMillis: Long,
    val endUtcMillis: Long,
    val dischargePercent: Double,
    val distanceKm: Double,
    val tripEnergyKwh: Double,
    val parkedEnergyKwh: Double,
    val parkedSocPercent: Double,
    val cost: Double?,
    val costCurrency: String?,
    val pricedEnergyKwh: Double,
    val unpricedEnergyKwh: Double,
    val isOpen: Boolean,
    val isPartial: Boolean,
    val energyIncomplete: Boolean,
    val mixedCurrency: Boolean,
    /**
     * The pack blend when this cycle opened. It makes any cycle a valid resume
     * point, which is what bounds a refresh to one cycle and lets a late
     * pricing edit rebuild only the tail.
     */
    val openingPricedFraction: Double,
    val openingBlendedPrice: Double,
    /**
     * When the sessions of this cycle were found to be gone.
     *
     * A frozen cycle can no longer be rebuilt, so it keeps the cost it closed
     * with. The app needs this to tell a cost that is current from one that is
     * final; without it, a total would mix a rebuilt cycle with a frozen one as
     * if both answered the same pricing.
     */
    val frozenAtUtcMillis: Long?,
    val createdAtUtcMillis: Long,
    val updatedAtUtcMillis: Long,
    val dirty: Boolean = true,
    val accountId: String? = null,
) {
    /**
     * One row of the persisted record, not the Flutter wire.
     *
     * These key names are the on-disk format of the CSV/JSON export, so a
     * rename here changes a file format. The Flutter spelling is the
     * bridge's job.
     */
    fun toExportRow(): Map<String, Any?> = mapOf(
        "ordinal" to ordinal,
        "startUtcMillis" to startUtcMillis,
        "endUtcMillis" to endUtcMillis,
        "dischargePercent" to dischargePercent,
        "distanceKm" to distanceKm,
        "tripEnergyKwh" to tripEnergyKwh,
        "parkedEnergyKwh" to parkedEnergyKwh,
        "parkedSocPercent" to parkedSocPercent,
        "cost" to cost,
        "costCurrency" to costCurrency,
        "pricedEnergyKwh" to pricedEnergyKwh,
        "unpricedEnergyKwh" to unpricedEnergyKwh,
        "isOpen" to isOpen,
        "isPartial" to isPartial,
        "energyIncomplete" to energyIncomplete,
        "mixedCurrency" to mixedCurrency,
        "openingPricedFraction" to openingPricedFraction,
        "openingBlendedPrice" to openingBlendedPrice,
        "frozenAtUtcMillis" to frozenAtUtcMillis,
        "createdAtUtcMillis" to createdAtUtcMillis,
        "updatedAtUtcMillis" to updatedAtUtcMillis
    )
}
