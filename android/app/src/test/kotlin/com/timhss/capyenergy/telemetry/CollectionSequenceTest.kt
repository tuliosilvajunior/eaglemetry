package com.timhss.capyenergy.telemetry

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the start and stop order for telemetry collection.
 *
 * The order used to be spelled out inline in a 759-line class, where the only
 * statement of the Roadcast pairing was a comment. It was wrong for four days:
 * between 2026-07-29 and 2026-08-02 the watchlist was registered without the
 * repository that drives the poll loop, and every CAN column of every persisted
 * frame stayed null. Nothing failed; the frames were simply empty.
 */
class CollectionSequenceTest {
    @Test
    fun `start opens the Roadcast repository before the metrics monitor that reads it`() {
        val participants = RecordingParticipants()
        CollectionSequence(participants).start()

        val repositoryIndex = participants.calls.indexOf("startRoadcastRepository")
        val monitorIndex = participants.calls.indexOf("startRoadcastTripMetrics")

        assertTrue("the repository must start", repositoryIndex >= 0)
        assertTrue("the metrics monitor must start", monitorIndex >= 0)
        assertTrue(
            "the monitor polls the repository, so it cannot start first",
            repositoryIndex < monitorIndex
        )
    }

    @Test
    fun `start runs the whole sequence in order`() {
        val participants = RecordingParticipants(gpsEnabled = true)
        CollectionSequence(participants).start()

        assertEquals(
            listOf(
                "markCollectionStarted",
                "startRangeRefresh",
                "startVhalSubscriptions",
                "startRoadcastRepository",
                "startRoadcastTripMetrics",
                "startParkedSessionDetector",
                "startContinuousSessionDetector",
                "startLocation",
                "startCollectorTick",
                "runStartupMaintenance",
                "ensureRoadcastDaemon",
                "startBleServer",
            ),
            participants.calls
        )
    }

    @Test
    fun `stop reverses every start and leaves the daemon alone`() {
        val participants = RecordingParticipants(gpsEnabled = true)
        val sequence = CollectionSequence(participants)
        sequence.start()
        participants.calls.clear()

        sequence.stop()

        assertEquals(
            listOf(
                "markCollectionStopped",
                "stopBleServer",
                "stopRangeRefresh",
                "stopCollectorTick",
                "stopVhalSubscriptions",
                "stopRoadcastTripMetrics",
                "stopParkedSessionDetector",
                "stopContinuousSessionDetector",
                "restoreKeyserver",
                "stopLocation",
                "stopRoadcastRepository",
            ),
            participants.calls
        )
    }

    @Test
    fun `every start has a matching stop`() {
        // A participant started and never stopped keeps a thread, a subscription
        // or a socket alive after the user asked collection to end.
        val participants = RecordingParticipants(gpsEnabled = true)
        val sequence = CollectionSequence(participants)

        sequence.start()
        val started = participants.calls
            .filter { it.startsWith("start") }
            .map { it.removePrefix("start") }
        participants.calls.clear()

        sequence.stop()
        val stopped = participants.calls
            .filter { it.startsWith("stop") }
            .map { it.removePrefix("stop") }

        assertEquals(started.toSet(), stopped.toSet())
    }

    @Test
    fun `location starts only when GPS is enabled`() {
        val disabled = RecordingParticipants(gpsEnabled = false)
        val sequence = CollectionSequence(disabled)
        sequence.start()
        assertFalse(disabled.calls.contains("startLocation"))

        disabled.calls.clear()
        sequence.stop()
        // Stop releases it either way. The setting can be turned off while
        // collection runs, and setGpsEnabled(false) stops the provider directly,
        // so an unconditional release is the only shape that cannot leak.
        assertTrue(disabled.calls.contains("stopLocation"))
    }

    @Test
    fun `a second start does nothing`() {
        val participants = RecordingParticipants()
        val sequence = CollectionSequence(participants)

        sequence.start()
        val afterFirst = participants.calls.toList()
        sequence.start()

        assertEquals(afterFirst, participants.calls)
        assertTrue(sequence.running)
    }

    @Test
    fun `a stop without a start does nothing`() {
        val participants = RecordingParticipants()
        val sequence = CollectionSequence(participants)

        sequence.stop()

        assertEquals(emptyList<String>(), participants.calls)
        assertFalse(sequence.running)
    }

    @Test
    fun `a restart runs the sequence again`() {
        val participants = RecordingParticipants()
        val sequence = CollectionSequence(participants)

        sequence.start()
        sequence.stop()
        participants.calls.clear()
        sequence.start()

        assertTrue(sequence.running)
        assertTrue(participants.calls.contains("startRoadcastRepository"))
        assertTrue(participants.calls.contains("startRoadcastTripMetrics"))
        assertTrue(participants.calls.contains("startParkedSessionDetector"))
        assertTrue(participants.calls.contains("startBleServer"))
    }

    private class RecordingParticipants(
        private val gpsEnabled: Boolean = false,
    ) : CollectionParticipants {
        val calls = mutableListOf<String>()

        override var collectionRunning: Boolean = false

        private fun record(name: String) {
            calls += name
        }

        override fun markCollectionStarted() = record("markCollectionStarted")
        override fun markCollectionStopped() = record("markCollectionStopped")
        override fun startRangeRefresh() = record("startRangeRefresh")
        override fun stopRangeRefresh() = record("stopRangeRefresh")
        override fun startVhalSubscriptions() = record("startVhalSubscriptions")
        override fun stopVhalSubscriptions() = record("stopVhalSubscriptions")
        override fun startRoadcastRepository() = record("startRoadcastRepository")
        override fun stopRoadcastRepository() = record("stopRoadcastRepository")
        override fun startRoadcastTripMetrics() = record("startRoadcastTripMetrics")
        override fun stopRoadcastTripMetrics() = record("stopRoadcastTripMetrics")
        override fun startParkedSessionDetector() = record("startParkedSessionDetector")
        override fun stopParkedSessionDetector() = record("stopParkedSessionDetector")
        override fun startContinuousSessionDetector() = record("startContinuousSessionDetector")
        override fun stopContinuousSessionDetector() = record("stopContinuousSessionDetector")
        override fun gpsEnabled(): Boolean = gpsEnabled
        override fun startLocation() = record("startLocation")
        override fun stopLocation() = record("stopLocation")
        override fun startCollectorTick() = record("startCollectorTick")
        override fun stopCollectorTick() = record("stopCollectorTick")
        override fun runStartupMaintenance() = record("runStartupMaintenance")
        override fun ensureRoadcastDaemon() = record("ensureRoadcastDaemon")
        override fun startBleServer() = record("startBleServer")
        override fun stopBleServer() = record("stopBleServer")
        override fun restoreKeyserver() = record("restoreKeyserver")
    }
}
