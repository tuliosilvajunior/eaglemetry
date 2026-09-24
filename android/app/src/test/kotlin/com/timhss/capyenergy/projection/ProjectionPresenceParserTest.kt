package com.timhss.capyenergy.projection

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * *
 * The cases that matter are the ones that must change nothing: both OEM apps
 * send many other `notification` values on the same action, and treating any of
 * them as an edge would report a phone that is not there — or worse, report a
 * live one as gone.
 */
class ProjectionPresenceParserTest {

    @Test
    fun `recognizes both broadcast actions and nothing else`() {
        assertEquals(
            ProjectionPresenceParser.Protocol.CARPLAY,
            ProjectionPresenceParser.protocolOf("com.njda.carplay.broadcast"),
        )
        assertEquals(
            ProjectionPresenceParser.Protocol.ANDROID_AUTO,
            ProjectionPresenceParser.protocolOf("com.njda.aauto.broadcast"),
        )
        assertNull(ProjectionPresenceParser.protocolOf("com.njda.carplay.other"))
        assertNull(ProjectionPresenceParser.protocolOf(null))
    }

    @Test
    fun `reads the two connection edges`() {
        assertEquals(
            PresenceState.CONNECTED,
            ProjectionPresenceParser.stateFromNotification("connected"),
        )
        assertEquals(
            PresenceState.DISCONNECTED,
            ProjectionPresenceParser.stateFromNotification("disconnected"),
        )
    }

    @Test
    fun `leaves the state alone for every other notification`() {
        // Real values both apps send on the same action.
        val others = listOf(
            "poweron_request",
            "alert_active",
            "alert_inactive",
            "media_active",
            "media_inactive",
            "",
            "CONNECTED",
        )
        for (value in others) {
            assertNull(value, ProjectionPresenceParser.stateFromNotification(value))
        }
    }

    @Test
    fun `a missing extra is not a disconnection`() {
        assertNull(ProjectionPresenceParser.stateFromNotification(null))
    }

    @Test
    fun `a non-zero reply is a connected phone`() {
        assertEquals(PresenceState.CONNECTED, ProjectionPresenceParser.stateFromReply(1))
        assertEquals(PresenceState.DISCONNECTED, ProjectionPresenceParser.stateFromReply(0))
    }

    @Test
    fun `a read that did not happen is unknown, never disconnected`() {
        assertEquals(PresenceState.UNKNOWN, ProjectionPresenceParser.stateFromReply(null))
    }

    @Test
    fun `wire names match the Dart parser`() {
        assertEquals("connected", PresenceState.CONNECTED.wireName())
        assertEquals("disconnected", PresenceState.DISCONNECTED.wireName())
        assertEquals("unknown", PresenceState.UNKNOWN.wireName())
    }
}
