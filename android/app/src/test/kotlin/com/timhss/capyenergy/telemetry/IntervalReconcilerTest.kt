package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.IntervalEntity
import com.timhss.capyenergy.telemetry.db.SessionEntity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class IntervalReconcilerTest {

    @Test
    fun `empty list returns empty`() {
        val session = createSession(1_787_101_249_693L) // 2026-08-18 22:00:49 UTC-3
        val result = IntervalReconciler.reconcile(session, emptyList())
        assertTrue(result.isEmpty())
    }

    @Test
    fun `consistent intervals remain untouched`() {
        val sessionStart = 1_787_101_249_693L // 2026-08-18 22:00:49
        val session = createSession(sessionStart)
        val alignedStart = 1_787_101_200_000L // 22:00:00

        val intervals = listOf(
            createInterval(session.id, alignedStart, tractionWh = 10.0, distanceKm = 0.5),
            createInterval(session.id, alignedStart + 60_000L, tractionWh = 20.0, distanceKm = 0.8),
            createInterval(session.id, alignedStart + 120_000L, tractionWh = 30.0, distanceKm = 1.0)
        )

        val result = IntervalReconciler.reconcile(session, intervals)
        assertEquals(intervals, result)
    }

    @Test
    fun `re-anchors pre-jump interval from 2025 to reconciled 2026 session start`() {
        val sessionStart = 1_787_101_249_693L // 2026-08-18 22:00:49
        val session = createSession(sessionStart)
        val alignedStart = 1_787_101_200_000L // 2026-08-18 22:00:00

        val preJump2025 = 1_748_048_880_000L // 2025-05-23 22:08:00
        val postJump1 = 1_787_101_260_000L   // 2026-08-18 22:01:00
        val postJump2 = 1_787_101_320_000L   // 2026-08-18 22:02:00

        val intervals = listOf(
            createInterval(session.id, preJump2025, tractionWh = 17.5, distanceKm = 0.05, coveredSeconds = 44.3),
            createInterval(session.id, postJump1, tractionWh = 31.9, distanceKm = 0.135, coveredSeconds = 25.8),
            createInterval(session.id, postJump2, tractionWh = 134.8, distanceKm = 0.677, coveredSeconds = 60.0)
        )

        val result = IntervalReconciler.reconcile(session, intervals)

        assertEquals(3, result.size)
        // First bucket should now be at 2026-08-18 22:00:00
        assertEquals(alignedStart, result[0].startUtcMillis)
        assertEquals(17.5, result[0].tractionWh, 1e-3)
        assertEquals(0.05, result[0].distanceKm, 1e-3)
        assertEquals(44.3, result[0].coveredSeconds, 1e-3)

        // Subsequent buckets follow
        assertEquals(postJump1, result[1].startUtcMillis)
        assertEquals(31.9, result[1].tractionWh, 1e-3)

        assertEquals(postJump2, result[2].startUtcMillis)
        assertEquals(134.8, result[2].tractionWh, 1e-3)
    }

    @Test
    fun `re-anchors multiple pre-jump intervals and merges colliding buckets`() {
        val sessionStart = 1_787_101_200_000L // 22:00:00
        val session = createSession(sessionStart)

        val preJump1 = 1_748_048_880_000L // 2025-05-23 22:08:00 -> maps to 22:00:00
        val preJump2 = 1_748_048_940_000L // 2025-05-23 22:09:00 -> maps to 22:01:00
        val postJump1 = 1_787_101_260_000L // 2026-08-18 22:01:00 (collides with remapped preJump2)
        val postJump2 = 1_787_101_320_000L // 2026-08-18 22:02:00

        val intervals = listOf(
            createInterval(session.id, preJump1, tractionWh = 10.0, distanceKm = 0.1, coveredSeconds = 60.0),
            createInterval(session.id, preJump2, tractionWh = 5.0, distanceKm = 0.05, coveredSeconds = 20.0),
            createInterval(session.id, postJump1, tractionWh = 15.0, distanceKm = 0.2, coveredSeconds = 40.0),
            createInterval(session.id, postJump2, tractionWh = 25.0, distanceKm = 0.5, coveredSeconds = 60.0)
        )

        val result = IntervalReconciler.reconcile(session, intervals)

        assertEquals(3, result.size)
        // 22:00:00 bucket
        assertEquals(sessionStart, result[0].startUtcMillis)
        assertEquals(10.0, result[0].tractionWh, 1e-3)
        assertEquals(0.1, result[0].distanceKm, 1e-3)

        // 22:01:00 bucket (merged preJump2 + postJump1)
        assertEquals(postJump1, result[1].startUtcMillis)
        assertEquals(20.0, result[1].tractionWh, 1e-3) // 5.0 + 15.0
        assertEquals(0.25, result[1].distanceKm, 1e-3) // 0.05 + 0.2
        assertEquals(60.0, result[1].coveredSeconds, 1e-3) // 20.0 + 40.0

        // 22:02:00 bucket
        assertEquals(postJump2, result[2].startUtcMillis)
        assertEquals(25.0, result[2].tractionWh, 1e-3)
    }

    @Test
    fun `reconciling colliding intervals merges startSoc and endSoc correctly`() {
        val sessionStart = 1_787_101_200_000L
        val session = createSession(sessionStart)

        val preJump = 1_748_048_880_000L // maps to 22:00:00
        val postJump = 1_787_101_200_000L // 22:00:00 (collides)

        val intervals = listOf(
            createInterval(session.id, preJump, tractionWh = 5.0, startSoc = 80.0, endSoc = 79.5),
            createInterval(session.id, postJump, tractionWh = 10.0, startSoc = 79.5, endSoc = 79.0)
        )

        val result = IntervalReconciler.reconcile(session, intervals)
        assertEquals(1, result.size)
        assertEquals(80.0, result[0].startSoc!!, 1e-6)
        assertEquals(79.0, result[0].endSoc!!, 1e-6)
    }

    @Test
    fun `reconciling colliding intervals merges startVoltage and endVoltage correctly`() {
        val sessionStart = 1_787_101_200_000L
        val session = createSession(sessionStart)

        val preJump = 1_748_048_880_000L // maps to 22:00:00
        val postJump = 1_787_101_200_000L // 22:00:00 (collides)

        val intervals = listOf(
            createInterval(session.id, preJump, tractionWh = 5.0, startVoltage = 380.0, endVoltage = 382.0),
            createInterval(session.id, postJump, tractionWh = 10.0, startVoltage = 382.0, endVoltage = 385.0)
        )

        val result = IntervalReconciler.reconcile(session, intervals)
        assertEquals(1, result.size)
        assertEquals(380.0, result[0].startVoltage!!, 1e-6)
        assertEquals(385.0, result[0].endVoltage!!, 1e-6)
    }

    private fun createSession(startedAtUtcMillis: Long): SessionEntity = SessionEntity(
        id = "trip-test-123",
        vehicleId = "veh-1",
        kind = "TRIP",
        status = "ENDED",
        startedAtUtcMillis = startedAtUtcMillis,
        startedAtElapsedNanos = 100_000_000_000L,
        endedAtUtcMillis = startedAtUtcMillis + 18 * 60_000L,
        endedAtElapsedNanos = 100_000_000_000L + 18 * 60_000L * 1_000_000L,
        createdAtUtcMillis = startedAtUtcMillis,
        updatedAtUtcMillis = startedAtUtcMillis + 18 * 60_000L
    )

    private fun createInterval(
        sessionId: String,
        startUtcMillis: Long,
        tractionWh: Double = 0.0,
        regenWh: Double = 0.0,
        auxiliaryWh: Double = 0.0,
        climateWh: Double = 0.0,
        deliveredWh: Double = 0.0,
        distanceKm: Double = 0.0,
        coveredSeconds: Double = 60.0,
        startSoc: Double? = null,
        endSoc: Double? = null,
        startVoltage: Double? = null,
        endVoltage: Double? = null
    ): IntervalEntity = IntervalEntity(
        sessionId = sessionId,
        startUtcMillis = startUtcMillis,
        widthMillis = 60_000L,
        tractionWh = tractionWh,
        regenWh = regenWh,
        auxiliaryWh = auxiliaryWh,
        climateWh = climateWh,
        deliveredWh = deliveredWh,
        distanceKm = distanceKm,
        coveredSeconds = coveredSeconds,
        climateCoveredSeconds = 0.0,
        speedCoveredSeconds = coveredSeconds,
        deliveredCoveredSeconds = 0.0,
        startSoc = startSoc,
        endSoc = endSoc,
        startVoltage = startVoltage,
        endVoltage = endVoltage,
        updatedAtUtcMillis = startUtcMillis
    )
}
