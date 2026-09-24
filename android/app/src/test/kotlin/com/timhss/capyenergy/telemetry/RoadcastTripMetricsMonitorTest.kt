package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.roadcast.RoadcastCadence
import com.timhss.capyenergy.roadcast.RoadcastClientStatus
import com.timhss.capyenergy.roadcast.RoadcastReading
import com.timhss.capyenergy.roadcast.RoadcastRepository
import com.timhss.capyenergy.roadcast.RoadcastSchemaEntry
import com.timhss.capyenergy.roadcast.RoadcastSession
import org.junit.Assert.assertEquals
import org.junit.Test

class RoadcastTripMetricsMonitorTest {
    @Test
    fun idleCadenceIsOneHzUntilASessionOpens() {
        var sessionActive = false
        var now = 0L
        val schema = listOf(schemaEntry())
        val session = FakeRoadcastSession(status(signalCount = schema.size), schema)
        val repository = RoadcastRepository(
            connect = { Result.success(session) },
            nowElapsedNanos = { now },
        )
        val monitor = RoadcastTripMetricsMonitor(
            repository,
            sessionActive = { sessionActive },
        )
        monitor.start()
        try {
            repository.refreshOnce()
            assertEquals(RoadcastCadence.oneHz, monitor.cadence)
            assertEquals(1, session.readCount)

            now += 20_000_000L
            repository.refreshOnce()
            assertEquals(1, session.readCount)

            sessionActive = true
            monitor.syncCadence()
            assertEquals(RoadcastCadence.sixtyHz, monitor.cadence)
            repository.refreshOnce()
            assertEquals(2, session.readCount)
        } finally {
            monitor.stop()
            repository.stop()
        }
    }

    @Test
    fun aClosedSessionDropsBackToOneHz() {
        var sessionActive = true
        val schema = listOf(schemaEntry())
        val session = FakeRoadcastSession(status(signalCount = schema.size), schema)
        val repository = RoadcastRepository(connect = { Result.success(session) })
        val monitor = RoadcastTripMetricsMonitor(
            repository,
            sessionActive = { sessionActive },
        )
        monitor.start()
        try {
            assertEquals(RoadcastCadence.sixtyHz, monitor.cadence)
            sessionActive = false
            monitor.syncCadence()
            assertEquals(RoadcastCadence.oneHz, monitor.cadence)
        } finally {
            monitor.stop()
            repository.stop()
        }
    }

    @Test
    fun startWithAnOpenSessionBeginsAtSixtyHz() {
        val schema = listOf(schemaEntry())
        val session = FakeRoadcastSession(status(signalCount = schema.size), schema)
        val repository = RoadcastRepository(connect = { Result.success(session) })
        val monitor = RoadcastTripMetricsMonitor(
            repository,
            sessionActive = { true },
        )
        monitor.start()
        try {
            assertEquals(RoadcastCadence.sixtyHz, monitor.cadence)
        } finally {
            monitor.stop()
            repository.stop()
        }
    }

    @Test
    fun aSyncWithNoSubscriptionDoesNotRecordTheCadence() {
        val schema = listOf(schemaEntry())
        val session = FakeRoadcastSession(status(signalCount = schema.size), schema)
        val repository = RoadcastRepository(connect = { Result.success(session) })
        val monitor = RoadcastTripMetricsMonitor(repository, sessionActive = { true })

        // Before start there is nothing to apply the rate to. Recording the
        // want anyway would make every later call return early, and the trip
        // would integrate at the idle rate for its whole length.
        monitor.syncCadence()
        assertEquals(RoadcastCadence.oneHz, monitor.cadence)

        monitor.start()
        try {
            assertEquals(RoadcastCadence.sixtyHz, monitor.cadence)
        } finally {
            monitor.stop()
            repository.stop()
        }
    }

    private fun status(signalCount: Int) = RoadcastClientStatus(
        hz = 60,
        frameCount = 1,
        signalCount = signalCount,
        schemaVersion = 1,
        schemaHash = 1L,
        sampleSequence = 1L,
        droppedBatches = 0L,
        coalescedSamples = 0L,
        resynchronizations = 0L,
        effectiveHzMillihz = 60_000,
        sourceState = 1,
        connected = true,
    )

    private fun schemaEntry() = RoadcastSchemaEntry(
        stableId = 1L,
        index = 0,
        invalidSignalIndex = null,
        canId = 0x315,
        kind = 2,
        source = 1,
        width = 12,
        flags = 0x02,
        scale = 0.1,
        offset = -204.0,
        name = RoadcastTripMetricsProvider.DRIVE_POWER,
        unit = "kW",
    )

    private class FakeRoadcastSession(
        private val status: RoadcastClientStatus,
        private val schema: List<RoadcastSchemaEntry>,
    ) : RoadcastSession {
        var readCount = 0

        override fun status(): RoadcastClientStatus = status
        override fun schema(): List<RoadcastSchemaEntry> = schema
        override fun sampleAgeNs(): Long = 10_000_000L
        override fun isAlive(maxAgeMs: Long): Boolean = true
        override fun read(indices: IntArray, output: RoadcastReading): Int {
            readCount += 1
            indices.indices.forEach { index ->
                output.raw[index] = 2040L
                output.physical[index] = 0.0
                output.flags[index] = 0x03.toByte()
            }
            return 0
        }
        override fun close() {}
    }
}
