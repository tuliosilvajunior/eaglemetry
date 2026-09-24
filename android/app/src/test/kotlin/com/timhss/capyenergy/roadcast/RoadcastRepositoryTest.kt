package com.timhss.capyenergy.roadcast

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RoadcastRepositoryTest {
    @Test
    fun publishesReadyStateFromOneNegotiatedSchema() {
        val schema = listOf(schemaEntry())
        val session = FakeRoadcastSession(
            status = status(signalCount = schema.size),
            schema = schema,
        )
        val repository = RoadcastRepository(connect = { Result.success(session) })

        repository.refreshOnce()

        val state = repository.state.value as RoadcastState.Ready
        assertEquals(schema, state.schema)
        assertEquals(1, repository.statusMap()["signalCount"])
        assertTrue(repository.statusMap()["attached"] as Boolean)
    }

    @Test
    fun preservesLastKnownSchemaWhenRoadcastBecomesUnavailable() {
        val schema = listOf(schemaEntry())
        val session = FakeRoadcastSession(
            status = status(signalCount = schema.size),
            schema = schema,
        )
        val repository = RoadcastRepository(connect = { Result.success(session) })
        repository.refreshOnce()
        session.alive = false

        repository.refreshOnce()

        val state = repository.state.value as RoadcastState.Unavailable
        assertEquals(schema, state.lastKnownSchema)
        assertTrue(session.closed)
        assertFalse(repository.statusMap()["attached"] as Boolean)
    }

    @Test
    fun unionsProviderWatchlistsIntoOneAtomicSnapshot() {
        val schema = listOf(schemaEntry(name = "battery"), schemaEntry(name = "key", index = 1))
        val session = FakeRoadcastSession(
            status = status(signalCount = schema.size),
            schema = schema,
        )
        val repository = RoadcastRepository(
            connect = { Result.success(session) },
            nowElapsedNanos = { 123L },
        )
        val battery = repository.subscribe(setOf("battery"))
        val key = repository.subscribe(setOf("key"))

        repository.refreshOnce()

        assertEquals(1, session.readCount)
        val snapshot = (battery.state.value as RoadcastSnapshotState.Ready).snapshot
        assertEquals(setOf("battery", "key"), snapshot.samples.keys)
        assertEquals(snapshot, (key.state.value as RoadcastSnapshotState.Ready).snapshot)
        battery.close()
        key.close()
    }

    @Test
    fun publishesOnlyToSubscriptionsWhoseCadenceIsDue() {
        var now = 0L
        val schema = listOf(schemaEntry(name = "fast"), schemaEntry(name = "slow", index = 1))
        val session = FakeRoadcastSession(status(signalCount = schema.size), schema)
        val repository = RoadcastRepository(
            connect = { Result.success(session) },
            nowElapsedNanos = { now },
        )
        val fast = repository.subscribe(setOf("fast"), RoadcastCadence.sixtyHz)
        val slow = repository.subscribe(setOf("slow"), RoadcastCadence.oneHz)
        repository.refreshOnce()
        val slowFirst = (slow.state.value as RoadcastSnapshotState.Ready).snapshot

        now += 20_000_000L
        repository.refreshOnce()

        assertEquals(2, session.readCount)
        assertEquals(slowFirst, (slow.state.value as RoadcastSnapshotState.Ready).snapshot)
        fast.close()
        slow.close()
    }

    @Test
    fun raisingCadenceMakesTheNextRefreshDueAtOnce() {
        var now = 0L
        val schema = listOf(schemaEntry(name = "power"))
        val session = FakeRoadcastSession(status(signalCount = schema.size), schema)
        val repository = RoadcastRepository(
            connect = { Result.success(session) },
            nowElapsedNanos = { now },
        )
        val subscription = repository.subscribe(setOf("power"), RoadcastCadence.oneHz)
        repository.refreshOnce()
        assertEquals(1, session.readCount)

        now += 20_000_000L
        repository.refreshOnce()
        assertEquals(1, session.readCount)

        subscription.setCadence(RoadcastCadence.sixtyHz)
        repository.refreshOnce()
        assertEquals(2, session.readCount)

        subscription.close()
    }

    /**
     * A subscriber must get data from [RoadcastRepository.start] alone.
     *
     * Every other test here drives the loop by hand with `refreshOnce()`, which
     * is why nothing caught the runtime forgetting to call `start()` at all:
     * `subscribe()` registered the watchlist, no pump consumed it, and each
     * subscription waited forever. On the car that read as four days of trip
     * frames with every CAN column null, while the Dart FFI path — a separate
     * client — kept the live screen updating.
     */
    @Test
    fun startAlonePublishesToSubscribersWithoutAManualRefresh() {
        val schema = listOf(schemaEntry())
        val session = FakeRoadcastSession(status(signalCount = schema.size), schema)
        val repository = RoadcastRepository(
            connect = { Result.success(session) },
            nowElapsedNanos = { System.nanoTime() },
        )
        val subscription = repository.subscribe(setOf("VCU_DrvPwrAct"))

        repository.start()
        try {
            val deadline = System.nanoTime() + 5_000_000_000L
            while (subscription.state.value !is RoadcastSnapshotState.Ready &&
                System.nanoTime() < deadline
            ) {
                Thread.sleep(10L)
            }
            assertTrue(
                "start() did not connect and publish; the poll loop never ran",
                subscription.state.value is RoadcastSnapshotState.Ready
            )
        } finally {
            subscription.close()
            repository.stop()
        }
    }

    private fun status(signalCount: Int) = RoadcastClientStatus(
        hz = 60,
        frameCount = 111,
        signalCount = signalCount,
        schemaVersion = 1,
        schemaHash = 42L,
        sampleSequence = 12L,
        droppedBatches = 0L,
        coalescedSamples = 0L,
        resynchronizations = 0L,
        effectiveHzMillihz = 60_000,
        sourceState = 1,
        connected = true,
    )

    private fun schemaEntry(name: String = "VCU_DrvPwrAct", index: Int = 0) = RoadcastSchemaEntry(
        stableId = 1L,
        index = index,
        invalidSignalIndex = null,
        canId = 0x315,
        kind = 2,
        source = 1,
        width = 12,
        flags = 0x02,
        scale = 0.1,
        offset = -204.8,
        name = name,
        unit = "kW",
    )

    private class FakeRoadcastSession(
        private val status: RoadcastClientStatus,
        private val schema: List<RoadcastSchemaEntry>,
    ) : RoadcastSession {
        var alive = true
        var closed = false
        var readCount = 0

        override fun status(): RoadcastClientStatus = status
        override fun schema(): List<RoadcastSchemaEntry> = schema
        override fun sampleAgeNs(): Long = 10_000_000L
        override fun isAlive(maxAgeMs: Long): Boolean = alive
        override fun read(indices: IntArray, output: RoadcastReading): Int {
            readCount += 1
            indices.indices.forEach { index ->
                output.raw[index] = index.toLong()
                output.physical[index] = index.toDouble()
                output.flags[index] = 0x03.toByte()
            }
            return 0
        }
        override fun close() {
            closed = true
        }
    }
}
