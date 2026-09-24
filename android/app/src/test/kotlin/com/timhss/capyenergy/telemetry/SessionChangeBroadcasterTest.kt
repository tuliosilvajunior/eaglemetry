package com.timhss.capyenergy.telemetry

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What the lists rely on to stop polling.
 *
 * A missed or misattributed event leaves a screen showing data that has been
 * replaced, with nothing to correct it until the fallback tick — which is
 * exactly the case this exists to make rare.
 */
class SessionChangeBroadcasterTest {

    @Test
    fun `a trip write is not a charge write`() {
        val broadcaster = SessionChangeBroadcaster()
        val seen = mutableListOf<SessionChange>()
        broadcaster.addListener(seen::add)

        broadcaster.tripsChanged()

        assertEquals(1, seen.size)
        assertTrue(seen.single().trips)
        assertFalse(
            "the charging list must not re-read for a trip write",
            seen.single().charges,
        )
    }

    @Test
    fun `a merge touches both lists`() {
        val broadcaster = SessionChangeBroadcaster()
        val seen = mutableListOf<SessionChange>()
        broadcaster.addListener(seen::add)

        // A merge rewrites charges and reassigns their frames, so a trip list
        // showing those frames' session has something new to read too.
        broadcaster.sessionsChanged()

        assertTrue(seen.single().trips)
        assertTrue(seen.single().charges)
    }

    @Test
    fun `the revision rises once per change, so a gap is visible`() {
        val broadcaster = SessionChangeBroadcaster()
        val seen = mutableListOf<Long>()
        broadcaster.addListener { seen.add(it.revision) }

        broadcaster.tripsChanged()
        broadcaster.chargesChanged()
        broadcaster.sessionsChanged()

        assertEquals(listOf(1L, 2L, 3L), seen)
        assertEquals(3L, broadcaster.currentRevision())
    }

    @Test
    fun `a removed listener stops hearing`() {
        val broadcaster = SessionChangeBroadcaster()
        val seen = mutableListOf<SessionChange>()
        val listener: (SessionChange) -> Unit = seen::add
        broadcaster.addListener(listener)

        broadcaster.tripsChanged()
        broadcaster.removeListener(listener)
        broadcaster.tripsChanged()

        // The sink belongs to a Flutter engine that may be gone; delivering to
        // it after cancel is the leak this guards.
        assertEquals(1, seen.size)
    }

    @Test
    fun `one broken listener does not silence the others`() {
        val broadcaster = SessionChangeBroadcaster()
        val seen = mutableListOf<SessionChange>()
        broadcaster.addListener { throw IllegalStateException("dead sink") }
        broadcaster.addListener(seen::add)

        broadcaster.tripsChanged()

        assertEquals(1, seen.size)
    }

    @Test
    fun `a write reported as neither is not an event`() {
        val broadcaster = SessionChangeBroadcaster()
        var count = 0
        broadcaster.addListener { count++ }

        broadcaster.tripsChanged()
        val afterFirst = broadcaster.currentRevision()
        broadcaster.chargesChanged()

        assertEquals(1L, afterFirst)
        assertEquals(2, count)
        assertEquals(2L, broadcaster.currentRevision())
    }
}
