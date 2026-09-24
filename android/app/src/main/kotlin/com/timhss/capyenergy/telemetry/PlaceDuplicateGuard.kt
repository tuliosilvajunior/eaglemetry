package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.InsightPlaceEntity
import com.timhss.capyenergy.telemetry.PositionDeadbandEvaluator.Companion.haversineDistanceMeters
import kotlin.math.roundToInt

/**
 * The near-duplicate rule every replica enforces on a place write.
 *
 * Two live places that share one normalized name (trim + lowercase) and sit
 * within [NEAR_DISTANCE_M] of each other are the same place recorded twice.
 * Creation refuses the second row; the merge flow is the way out. Pure on
 * purpose: the unit test runs without Room, and the phone source applies the
 * same numbers so both sides refuse with the same words.
 */
object PlaceDuplicateGuard {
    const val NEAR_DISTANCE_M = 500.0

    fun normalized(name: String): String = name.trim().lowercase()

    /**
     * The live row whose write would land on top of an existing place, or
     * null when the write is safe. [live] holds the replica's live rows; the
     * row being updated is excluded by [id]. An unnamed candidate never
     * collides: there is no name to match against.
     */
    fun findConflict(
        id: String?,
        name: String,
        latitude: Double,
        longitude: Double,
        live: List<InsightPlaceEntity>
    ): Conflict? {
        val candidate = normalized(name)
        if (candidate.isEmpty()) return null
        for (row in live) {
            if (row.isDeleted) continue
            if (!id.isNullOrBlank() && row.id == id) continue
            if (normalized(row.name) != candidate) continue
            val d = haversineDistanceMeters(latitude, longitude, row.latitude, row.longitude)
            if (d < NEAR_DISTANCE_M) return Conflict(row = row, distanceM = d)
        }
        return null
    }

    /** The line the UI shows for a refused write: distance plus two ways out. */
    fun conflictMessage(name: String, distanceM: Double): String =
        "Ja existe '${name.trim()}' a ${distanceM.roundToInt()} m — use raio maior ou mescle"

    data class Conflict(val row: InsightPlaceEntity, val distanceM: Double)
}
