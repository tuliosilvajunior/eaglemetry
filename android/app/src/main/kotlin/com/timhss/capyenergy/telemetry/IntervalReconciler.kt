package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.IntervalEntity
import com.timhss.capyenergy.telemetry.db.SessionEntity

/**
 * Reconciles interval start timestamps if a clock jump occurred during a session.
 *
 * Inside a single boot without reboot, elapsedRealtimeNanos is monotonic. If the session's
 * startedAtUtcMillis was reconciled to the true time reference by [SessionTimeReconciler],
 * intervals written prior to the time sync may carry timestamps from an uncalibrated clock
 * (such as the default 2025-05-23 MCU firmware timestamp).
 *
 * This shifts pre-jump intervals to the reconciled session start timeline and merges
 * any colliding bucket intervals.
 */
object IntervalReconciler {
    private const val DRIFT_TOLERANCE_MILLIS = 60_000L

    fun reconcile(
        session: SessionEntity,
        intervals: List<IntervalEntity>,
        now: Long = System.currentTimeMillis()
    ): List<IntervalEntity> {
        if (intervals.isEmpty()) return emptyList()
        val sessionStart = session.startedAtUtcMillis
        val alignedSessionStart = EnergyBucketAccumulator.alignToBucket(sessionStart)

        // Identify pre-jump intervals whose timestamps significantly predate the reconciled start
        val preJump = intervals.filter { it.startUtcMillis < alignedSessionStart - DRIFT_TOLERANCE_MILLIS }
        if (preJump.isEmpty()) {
            return intervals
        }

        val postJump = intervals.filter { it.startUtcMillis >= alignedSessionStart - DRIFT_TOLERANCE_MILLIS }

        // Sort pre-jump intervals chronologically
        val sortedPreJump = preJump.sortedBy { it.startUtcMillis }
        val firstPreJumpStart = sortedPreJump.first().startUtcMillis

        // Remap pre-jump intervals to begin at alignedSessionStart
        val remappedPreJump = sortedPreJump.map { interval ->
            val offsetFromFirst = interval.startUtcMillis - firstPreJumpStart
            val newStart = alignedSessionStart + offsetFromFirst
            interval.copy(startUtcMillis = newStart, updatedAtUtcMillis = now)
        }

        // Merge remapped pre-jump intervals with post-jump intervals if any startUtcMillis collide
        val allReconciled = HashMap<Long, IntervalEntity>()

        for (interval in postJump) {
            allReconciled[interval.startUtcMillis] = interval
        }

        for (interval in remappedPreJump) {
            val existing = allReconciled[interval.startUtcMillis]
            if (existing == null) {
                allReconciled[interval.startUtcMillis] = interval
            } else {
                allReconciled[interval.startUtcMillis] = existing.copy(
                    tractionWh = existing.tractionWh + interval.tractionWh,
                    regenWh = existing.regenWh + interval.regenWh,
                    auxiliaryWh = existing.auxiliaryWh + interval.auxiliaryWh,
                    climateWh = existing.climateWh + interval.climateWh,
                    deliveredWh = existing.deliveredWh + interval.deliveredWh,
                    distanceKm = existing.distanceKm + interval.distanceKm,
                    coveredSeconds = existing.coveredSeconds + interval.coveredSeconds,
                    climateCoveredSeconds = existing.climateCoveredSeconds + interval.climateCoveredSeconds,
                    speedCoveredSeconds = existing.speedCoveredSeconds + interval.speedCoveredSeconds,
                    deliveredCoveredSeconds = existing.deliveredCoveredSeconds + interval.deliveredCoveredSeconds,
                    startSoc = interval.startSoc ?: existing.startSoc,
                    endSoc = existing.endSoc ?: interval.endSoc,
                    startVoltage = interval.startVoltage ?: existing.startVoltage,
                    endVoltage = existing.endVoltage ?: interval.endVoltage,
                    updatedAtUtcMillis = now
                )
            }
        }

        return allReconciled.values.sortedBy { it.startUtcMillis }
    }
}
