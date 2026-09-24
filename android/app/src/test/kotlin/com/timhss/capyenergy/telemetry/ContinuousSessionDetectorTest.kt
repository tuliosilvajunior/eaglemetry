package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey
import com.timhss.capyenergy.telemetry.db.SessionEntity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * CONTINUOUS records one minute for every minute the collector is awake,
 * gated on nothing. See issue 199/205.
 */
class ContinuousSessionDetectorTest {

    private class FakeContinuousSessionStore : ContinuousSessionStore {
        var openSession: SessionEntity? = null
        var createdCount = 0
        var closedCount = 0
        var lastCloseReason: String? = null
        var lastClosedId: String? = null

        override fun latestOpenContinuousSession(): SessionEntity? =
            openSession?.takeIf { it.status == "ACTIVE" }

        override fun createContinuousSession(startedAt: SignalTimestamp): String {
            createdCount++
            val id = "continuous-$createdCount"
            openSession = SessionEntity(
                id = id,
                vehicleId = "test-vehicle",
                kind = "CONTINUOUS",
                status = "ACTIVE",
                startedAtUtcMillis = startedAt.receivedAtUtcMillis,
                startedAtElapsedNanos = startedAt.receivedAtElapsedNanos,
                createdAtUtcMillis = startedAt.receivedAtUtcMillis,
                updatedAtUtcMillis = startedAt.receivedAtUtcMillis,
                updatedAtElapsedNanos = startedAt.receivedAtElapsedNanos
            )
            return id
        }

        override fun closeContinuousSession(id: String, endedAt: SignalTimestamp, reason: String) {
            closedCount++
            lastCloseReason = reason
            lastClosedId = id
            val current = openSession
            if (current != null && current.id == id) {
                openSession = current.copy(
                    endedAtUtcMillis = endedAt.receivedAtUtcMillis,
                    endedAtElapsedNanos = endedAt.receivedAtElapsedNanos,
                    endReason = reason,
                    status = "ENDED",
                    updatedAtUtcMillis = endedAt.receivedAtUtcMillis,
                    updatedAtElapsedNanos = endedAt.receivedAtElapsedNanos
                )
            }
        }
    }

    /** No gear/speed/SOC on it: the detector reads none of that. */
    private fun sample(seconds: Long): SignalSample = SignalSample(
        signalId = SignalKey.HV_BATTERY_SOC,
        value = 50f,
        unit = "",
        quality = SignalQuality.MEASURED,
        source = SignalSource.VHAL_POLLING,
        propertyId = 0,
        propertyIdHex = "0x00000000",
        areaId = 0,
        timestamp = SignalTimestamp(
            receivedAtUtcMillis = 1_700_000_000_000L + seconds * 1_000L,
            receivedAtElapsedNanos = seconds * 1_000_000_000L,
            sourceTimestampNanos = null,
            accuracy = TimestampAccuracy.POLLED,
            uncertaintyMillis = 0L
        ),
        details = "test"
    )

    @Test
    fun `opens on the first frame once the mode is on`() {
        val store = FakeContinuousSessionStore()
        val detector = ContinuousSessionDetector(store, enabledProvider = { true })

        assertNull(detector.activeFrameSession())

        detector.onSignalUpdated(sample(0), emptyMap())

        assertEquals(1, store.createdCount)
        assertNotNull(detector.activeFrameSession())
        assertEquals("CONTINUOUS", detector.activeFrameSession()?.type)
    }

    @Test
    fun `mode off opens nothing`() {
        val store = FakeContinuousSessionStore()
        val detector = ContinuousSessionDetector(store, enabledProvider = { false })

        detector.onSignalUpdated(sample(0), emptyMap())
        detector.onSignalUpdated(sample(60), emptyMap())

        assertEquals(0, store.createdCount)
        assertEquals(0, store.closedCount)
        assertNull(detector.activeFrameSession())
    }

    @Test
    fun `no gate on gear, speed, motion, trip or charge -- every frame counts`() {
        val store = FakeContinuousSessionStore()
        val detector = ContinuousSessionDetector(store, enabledProvider = { true })

        // A snapshot that would fail every other detector's gate: moving fast,
        // in Drive, nothing parked, nothing charging. The map is not even
        // read, but this documents that nothing here would matter if it were.
        val movingSnapshot = mapOf(
            SignalKey.GEAR to sample(0),
            SignalKey.VEHICLE_SPEED to sample(0)
        )
        detector.onSignalUpdated(sample(0), movingSnapshot)

        assertEquals(1, store.createdCount)
        assertNotNull(detector.activeFrameSession())
    }

    @Test
    fun `turning the mode off mid-run closes the open session`() {
        val store = FakeContinuousSessionStore()
        var enabled = true
        val detector = ContinuousSessionDetector(store, enabledProvider = { enabled })

        detector.onSignalUpdated(sample(0), emptyMap())
        assertEquals(1, store.createdCount)

        enabled = false
        detector.onSignalUpdated(sample(1), emptyMap())

        assertEquals(1, store.closedCount)
        assertEquals("MODE_DISABLED", store.lastCloseReason)
        assertNull(detector.activeFrameSession())
    }

    @Test
    fun `stop closes the session the collector stopping ends`() {
        val store = FakeContinuousSessionStore()
        val detector = ContinuousSessionDetector(store, enabledProvider = { true })
        detector.onSignalUpdated(sample(0), emptyMap())

        detector.stop()

        assertEquals(1, store.closedCount)
        assertEquals("COLLECTOR_STOPPED", store.lastCloseReason)
        assertNull(detector.activeFrameSession())
    }

    @Test
    fun `stop without an open session does nothing`() {
        val store = FakeContinuousSessionStore()
        val detector = ContinuousSessionDetector(store, enabledProvider = { true })

        detector.stop()

        assertEquals(0, store.closedCount)
    }

    @Test
    fun `a session reaching the 24h ceiling is closed and a new one opens`() {
        val store = FakeContinuousSessionStore()
        val detector = ContinuousSessionDetector(store, enabledProvider = { true })

        detector.onSignalUpdated(sample(0), emptyMap())
        assertEquals(1, store.createdCount)

        val justUnderCeilingSeconds = 24 * 3600 - 1
        detector.onSignalUpdated(sample(justUnderCeilingSeconds.toLong()), emptyMap())
        assertEquals(0, store.closedCount)
        assertEquals(1, store.createdCount)

        val atCeilingSeconds = 24 * 3600
        detector.onSignalUpdated(sample(atCeilingSeconds.toLong()), emptyMap())

        assertEquals(1, store.closedCount)
        assertEquals("ROTATION_CEILING", store.lastCloseReason)
        assertEquals(2, store.createdCount)
        assertNotNull("a fresh session must be open, not a gap", detector.activeFrameSession())
    }

    @Test
    fun `restore closes a young open session without adopting it`() {
        val store = FakeContinuousSessionStore()
        // Left open two minutes ago: well under the 24h stale threshold.
        store.openSession = SessionEntity(
            id = "continuous-orphan",
            vehicleId = "test-vehicle",
            kind = "CONTINUOUS",
            status = "ACTIVE",
            startedAtUtcMillis = System.currentTimeMillis() - 5 * 60_000L,
            startedAtElapsedNanos = 0L,
            createdAtUtcMillis = System.currentTimeMillis() - 5 * 60_000L,
            updatedAtUtcMillis = System.currentTimeMillis() - 2 * 60_000L,
            updatedAtElapsedNanos = 0L
        )
        val detector = ContinuousSessionDetector(store, enabledProvider = { true })

        detector.restoreIfNeeded()

        assertEquals(1, store.closedCount)
        assertEquals("continuous-orphan", store.lastClosedId)
        assertEquals("COLLECTOR_RESTARTED", store.lastCloseReason)
        // Not adopted: the detector holds no session of its own yet. The next
        // frame opens a brand new one.
        assertNull(detector.activeFrameSession())

        detector.onSignalUpdated(sample(0), emptyMap())
        assertEquals(1, store.createdCount)
        assertTrue(detector.activeFrameSession()?.id != "continuous-orphan")
    }

    @Test
    fun `restore closes a stale open session at its last update, not adopted`() {
        val store = FakeContinuousSessionStore()
        val now = System.currentTimeMillis()
        val lastUpdate = now - 25 * 3600 * 1000L // 25h ago: past the 24h threshold
        store.openSession = SessionEntity(
            id = "continuous-stale",
            vehicleId = "test-vehicle",
            kind = "CONTINUOUS",
            status = "ACTIVE",
            startedAtUtcMillis = lastUpdate - 60_000L,
            startedAtElapsedNanos = 0L,
            createdAtUtcMillis = lastUpdate - 60_000L,
            updatedAtUtcMillis = lastUpdate,
            updatedAtElapsedNanos = 0L
        )
        val detector = ContinuousSessionDetector(store, enabledProvider = { true })

        detector.restoreIfNeeded()

        assertEquals(1, store.closedCount)
        assertEquals("STALE_RECOVERY", store.lastCloseReason)
        assertEquals(lastUpdate, store.openSession?.endedAtUtcMillis)
        assertNull(detector.activeFrameSession())
    }

    @Test
    fun `restore with nothing open does nothing`() {
        val store = FakeContinuousSessionStore()
        val detector = ContinuousSessionDetector(store, enabledProvider = { true })

        detector.restoreIfNeeded()

        assertEquals(0, store.closedCount)
        assertNull(detector.activeFrameSession())
    }

    @Test
    fun `restore only ever runs once`() {
        val store = FakeContinuousSessionStore()
        store.openSession = SessionEntity(
            id = "continuous-orphan",
            vehicleId = "test-vehicle",
            kind = "CONTINUOUS",
            status = "ACTIVE",
            startedAtUtcMillis = 0L,
            startedAtElapsedNanos = 0L,
            createdAtUtcMillis = 0L,
            updatedAtUtcMillis = 0L,
            updatedAtElapsedNanos = 0L
        )
        val detector = ContinuousSessionDetector(store, enabledProvider = { true })

        detector.restoreIfNeeded()
        assertEquals(1, store.closedCount)

        // A second open row appears (as if another restore path re-read one);
        // the already-restored detector must not react to it again.
        store.openSession = store.openSession?.copy(id = "continuous-second")
        detector.restoreIfNeeded()

        assertEquals(1, store.closedCount)
    }
}
