package com.timhss.capyenergy.telemetry

import android.content.Context
import com.timhss.capyenergy.telemetry.db.SessionEntity
import com.timhss.capyenergy.telemetry.db.TelemetryDatabase

class RangeEfficiencyRepository(
    private val tripLoader: (startUtcMillis: Long, endUtcMillis: Long) -> List<SessionEntity>,
    private val nowMillis: () -> Long = System::currentTimeMillis
) {
    constructor(context: Context) : this(
        tripLoader = { start, end ->
            TelemetryDatabase.get(context.applicationContext)
                .sessionDao()
                .inWindow(kind = "TRIP", startUtcMillis = start, endUtcMillis = end)
        },
        nowMillis = System::currentTimeMillis
    )

    fun snapshot(): RangeEfficiencySnapshot {
        val now = nowMillis()
        return compute(
            loadWindow = { days ->
                val start = now - days * DAY_MILLIS
                tripLoader(start, now)
            },
            nowMillis = now
        )
    }

    companion object {
        internal const val MIN_EFFICIENCY_KM_PER_KWH = 0.5
        internal const val MAX_EFFICIENCY_KM_PER_KWH = 20.0
        internal const val MIN_DISTANCE_KM = 1.0
        internal const val DAY_MILLIS = 24L * 60L * 60L * 1_000L
        internal const val FINALIZATION_PENDING = "FINALIZATION_PENDING"
        internal val WINDOW_CANDIDATES = listOf(7, 30)

        internal fun compute(
            loadWindow: (days: Int) -> List<SessionEntity>,
            nowMillis: Long
        ): RangeEfficiencySnapshot {
            for (days in WINDOW_CANDIDATES) {
                val trips = loadWindow(days)
                if (trips.isEmpty()) continue
                val candidate = computeWindow(trips, days, nowMillis)
                if (candidate.efficiencyKmPerKwh != null) return candidate
            }
            return RangeEfficiencySnapshot(updatedAtUtcMillis = nowMillis)
        }

        internal fun computeWindow(
            trips: List<SessionEntity>,
            windowDays: Int,
            updatedAtUtcMillis: Long
        ): RangeEfficiencySnapshot {
            var totalDistance = 0.0
            var totalNetKwh = 0.0
            var qualifying = 0
            for (trip in trips) {
                if (trip.status == FINALIZATION_PENDING) continue
                // G3: a pending session's wall stamps are not yet trustworthy.
                // It waits for the sweep and enters automatically, under its
                // corrected stamp, once it turns known.
                if (trip.timeState == ClockUnlockBackfillEngine.STATE_PENDING) continue
                val energy = trip.tripEnergyBreakdown()?.netKwh ?: continue
                if (!energy.isFinite() || energy <= 0.0) continue
                val distance = trip.odometerDistanceKm()
                    ?.takeIf { it.isFinite() && it > 0.0 }
                    ?: trip.rollupDistanceKm
                        ?.takeIf { it.isFinite() && it > 0.0 }
                if (distance == null) {
                    continue
                }
                totalDistance += distance
                totalNetKwh += energy
                qualifying += 1
            }
            val efficiency = if (
                qualifying >= 1 &&
                totalDistance >= MIN_DISTANCE_KM &&
                totalNetKwh > 0.0
            ) {
                val ratio = totalDistance / totalNetKwh
                if (ratio.isFinite() && ratio >= MIN_EFFICIENCY_KM_PER_KWH && ratio <= MAX_EFFICIENCY_KM_PER_KWH) {
                    ratio
                } else null
            } else {
                null
            }
            return RangeEfficiencySnapshot(
                windowDays = if (efficiency != null) windowDays else null,
                tripCount = if (efficiency != null) qualifying else 0,
                distanceKm = totalDistance.takeIf { efficiency != null && it > 0.0 },
                netEnergyKwh = totalNetKwh.takeIf { efficiency != null && it > 0.0 },
                efficiencyKmPerKwh = efficiency,
                updatedAtUtcMillis = updatedAtUtcMillis
            )
        }

        internal fun SessionEntity.odometerDistanceKm(): Double? {
            val start = startOdometerKm ?: return null
            val end = endOdometerKm ?: return null
            val distance = (end - start).toDouble()
            return distance.takeIf { it >= 0.0 }
        }
    }
}

data class RangeEfficiencySnapshot(
    val windowDays: Int? = null,
    val tripCount: Int = 0,
    val distanceKm: Double? = null,
    val netEnergyKwh: Double? = null,
    val efficiencyKmPerKwh: Double? = null,
    val updatedAtUtcMillis: Long = 0L
)
