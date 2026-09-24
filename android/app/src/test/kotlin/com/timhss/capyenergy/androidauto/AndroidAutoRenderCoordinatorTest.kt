package com.timhss.capyenergy.androidauto

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidAutoRenderCoordinatorTest {

    /**
     * The fake asserts R2 on its own: a second attach with different geometry
     * and no intervening detach is the attack that corrupts the other host's
     * glViewport. If a test trips this check, fix the coordinator — never relax
     * the fake.
     */
    private class RecordingGateway(
        private val attachSucceeds: Boolean = true,
        private val detachSucceeds: Boolean = true,
    ) : AndroidAutoRenderGateway {

        val calls = mutableListOf<String>()
        private var liveWidth: Int? = null

        override fun attach(width: Int, height: Int): Boolean {
            val live = liveWidth
            check(live == null || live == width) {
                "attach($width) while already attached at $live without a detach — violates R2"
            }
            calls += "attach:${width}x$height"
            if (attachSucceeds) liveWidth = width
            return attachSucceeds
        }

        override fun detach(): Boolean {
            calls += "detach"
            liveWidth = null
            return detachSucceeds
        }
    }

    private fun makeFixture(
        attachSucceeds: Boolean = true,
        detachSucceeds: Boolean = true,
    ): RecordingGateway = RecordingGateway(attachSucceeds, detachSucceeds)

    private fun readyAll(coordinator: AndroidAutoRenderCoordinator) {
        coordinator.setDartActive(true)
        coordinator.setBufferSize(1920, 1080)
        coordinator.setSurfaceReady(true)
        coordinator.setServiceConnected(true)
        coordinator.setActivityResumed(true)
    }

    // Case 1: five inputs one at a time, all true at the end. Exactly one
    // detach-then-attach pair, detach first (R2).
    @Test
    fun activatesWithExactlyOneDetachThenAttachPair() {
        val gateway = makeFixture()
        val coordinator = AndroidAutoRenderCoordinator(gateway)
        readyAll(coordinator)
        assertEquals(listOf("detach", "attach:1920x1080"), gateway.calls)
        assertTrue(coordinator.attached)
        assertEquals(1, coordinator.attachCount)
    }

    // Case 2: repeating a setter with an unchanged value adds no calls.
    @Test
    fun unchangedSetterIsShortCircuited() {
        val gateway = makeFixture()
        val coordinator = AndroidAutoRenderCoordinator(gateway)
        readyAll(coordinator)
        val before = gateway.calls.size
        coordinator.setDartActive(true)
        coordinator.setActivityResumed(true)
        coordinator.setSurfaceReady(true)
        coordinator.setBufferSize(1920, 1080)
        coordinator.setServiceConnected(true)
        assertEquals(before, gateway.calls.size)
    }

    // Case 3: refresh() while attached records only an attach — no detach (R3).
    // It must NOT bump attachCount: that counter reports ownership transitions,
    // and validation.md T5/T6 read it to tell one takeover from a repeating one.
    @Test
    fun refreshWhileAttachedAttachesWithoutDetaching() {
        val gateway = makeFixture()
        val coordinator = AndroidAutoRenderCoordinator(gateway)
        readyAll(coordinator)
        gateway.calls.clear()
        coordinator.refresh()
        assertEquals(listOf("attach:1920x1080"), gateway.calls)
        assertEquals(1, coordinator.attachCount)
    }

    // Case 3b: a burst of refreshes (watchdog + heartbeat + manual Reconnect)
    // still leaves attachCount at the single takeover that owns them.
    @Test
    fun refreshBurstDoesNotInflateAttachCount() {
        val gateway = makeFixture()
        val coordinator = AndroidAutoRenderCoordinator(gateway)
        readyAll(coordinator)
        repeat(20) { coordinator.refresh() }
        assertEquals(1, coordinator.attachCount)
        assertTrue(coordinator.attached)
    }

    // Case 4: refresh() while not attached does nothing.
    @Test
    fun refreshWhileNotAttachedIsNoOp() {
        val gateway = makeFixture()
        val coordinator = AndroidAutoRenderCoordinator(gateway)
        coordinator.refresh()
        assertTrue(gateway.calls.isEmpty())
        assertFalse(coordinator.attached)
    }

    // Case 5: activity paused while attached -> detach only, attached=false (R4).
    @Test
    fun activityPausedReleases() {
        val gateway = makeFixture()
        val coordinator = AndroidAutoRenderCoordinator(gateway)
        readyAll(coordinator)
        coordinator.setActivityResumed(false)
        assertEquals("detach", gateway.calls.last())
        assertFalse(coordinator.attached)
    }

    // Case 6: dart deactivate while attached -> detach only.
    @Test
    fun dartDeactivateReleases() {
        val gateway = makeFixture()
        val coordinator = AndroidAutoRenderCoordinator(gateway)
        readyAll(coordinator)
        coordinator.setDartActive(false)
        assertEquals("detach", gateway.calls.last())
        assertFalse(coordinator.attached)
    }

    // Case 7: service disconnect while attached -> detach only.
    @Test
    fun serviceDisconnectReleases() {
        val gateway = makeFixture()
        val coordinator = AndroidAutoRenderCoordinator(gateway)
        readyAll(coordinator)
        coordinator.setServiceConnected(false)
        assertEquals("detach", gateway.calls.last())
        assertFalse(coordinator.attached)
    }

    // Case 8: surface released while attached -> detach only (R8 ordering).
    @Test
    fun surfaceReleasedReleases() {
        val gateway = makeFixture()
        val coordinator = AndroidAutoRenderCoordinator(gateway)
        readyAll(coordinator)
        coordinator.setSurfaceReady(false)
        assertEquals("detach", gateway.calls.last())
        assertFalse(coordinator.attached)
    }

    // Case 9: zero buffer while attached -> detach only.
    @Test
    fun zeroBufferReleases() {
        val gateway = makeFixture()
        val coordinator = AndroidAutoRenderCoordinator(gateway)
        readyAll(coordinator)
        coordinator.setBufferSize(0, 0)
        assertEquals("detach", gateway.calls.last())
        assertFalse(coordinator.attached)
    }

    // Case 10: attach failure leaves attached=false + ATTACH_FAILED, and the
    // retry is a takeover (detach -> attach), never a bare attach.
    @Test
    fun failedAttachRetriesAsTakeOver() {
        val gateway = makeFixture(attachSucceeds = false)
        val coordinator = AndroidAutoRenderCoordinator(gateway)
        readyAll(coordinator)
        assertFalse(coordinator.attached)
        assertEquals("ATTACH_FAILED", coordinator.lastError)
        assertEquals(listOf("detach", "attach:1920x1080"), gateway.calls)
    }

    // Case 11: failed detach on release still drops ownership, DETACH_FAILED.
    @Test
    fun failedDetachStillReleasesOwnership() {
        val gateway = makeFixture(detachSucceeds = false)
        val coordinator = AndroidAutoRenderCoordinator(gateway)
        readyAll(coordinator)
        coordinator.setActivityResumed(false)
        assertFalse(coordinator.attached)
        assertEquals("DETACH_FAILED", coordinator.lastError)
    }

    // Case 12: 10x resume/pause ping-pong — the automated stand-in for
    // hardware step T4. Every transition into "attached" must be a clean
    // detach→attach takeover (R2): an attach call is never directly preceded
    // by another attach (which would be a bare second attach).
    @Test
    fun tenPingPongCyclesStayClean() {
        val gateway = makeFixture()
        val coordinator = AndroidAutoRenderCoordinator(gateway)
        readyAll(coordinator)
        val attachesBefore = coordinator.attachCount // the initial takeover = 1
        for (i in 0 until 10) {
            coordinator.setActivityResumed(false) // RELEASE: detach
            coordinator.setActivityResumed(true) // TAKE_OVER: detach, attach
        }
        coordinator.setActivityResumed(false) // final RELEASE: detach
        assertEquals(attachesBefore + 10, coordinator.attachCount)
        val indexed = gateway.calls.withIndex().toList()
        for ((idx, call) in indexed) {
            if (!call.startsWith("attach")) continue
            assertTrue("attach at index $idx must be preceded by a detach", idx > 0)
            assertEquals("detach", indexed[idx - 1].value)
        }
    }

    // Case 13: interleaved refresh() inside the ping-pong never produces a
    // bare second attach with no live attachment (R2 check in the fake would
    // throw on any offending attach).
    @Test
    fun refreshInterleavedInPingPongNeverTripsR2() {
        val gateway = makeFixture()
        val coordinator = AndroidAutoRenderCoordinator(gateway)
        readyAll(coordinator)
        for (i in 0 until 10) {
            coordinator.setActivityResumed(false)
            coordinator.refresh() // no-op while released
            coordinator.setActivityResumed(true)
            coordinator.refresh() // same-surface re-attach while live
        }
        assertTrue(
            gateway.calls.all { it.startsWith("detach") || it.startsWith("attach:1920x1080") },
        )
    }

    // Case 14: onChanged fires on every action, not on NONE.
    @Test
    fun onChangedFiresOnlyOnRealActions() {
        val gateway = makeFixture()
        var changed = 0
        val coordinator = AndroidAutoRenderCoordinator(gateway, onChanged = { changed += 1 })
        coordinator.setDartActive(true) // inputs change but NONE -> no report
        assertEquals(0, changed)
        coordinator.setBufferSize(1920, 1080) // still NONE (not renderable yet)
        assertEquals(0, changed)
        readyAll(coordinator) // takeover fires exactly once on the last input
        assertEquals(1, changed)
        coordinator.setDartActive(true) // unchanged -> short-circuit, no report
        coordinator.setActivityResumed(true)
        coordinator.refresh() // a real action -> reports again
        assertEquals(2, changed)
    }
}
