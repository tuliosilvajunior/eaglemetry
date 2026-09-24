package com.timhss.capyenergy.telemetry

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Time authority T6: the session stamp decisions, pure and exhaustive.
 *
 * Birth and close each consult the boot's anchor exactly once. The matrix
 * below is the whole contract: a boot waiting for truth stamps `pending`
 * (consumers keep working and say so), a boot with truth stamps `known`,
 * and `known` never steps back.
 */
class SessionTimeStateTest {

    @Test
    fun `birth on an unlearned boot is pending`() {
        assertEquals("pending", ClockUnlockBackfillEngine.sessionBirthState(false))
    }

    @Test
    fun `birth on a learned boot is known`() {
        assertEquals("known", ClockUnlockBackfillEngine.sessionBirthState(true))
    }

    @Test
    fun `close after truth promotes every prior state to known`() {
        for (prior in listOf("pending", "unknown", "uncorrectable", "known")) {
            assertEquals(
                "close with anchor resolves $prior",
                "known",
                ClockUnlockBackfillEngine.sessionCloseState(prior, true)
            )
        }
    }

    @Test
    fun `close before truth keeps pending and never invents known`() {
        assertEquals("pending", ClockUnlockBackfillEngine.sessionCloseState("pending", false))
        assertEquals("known", ClockUnlockBackfillEngine.sessionCloseState("known", false))
    }

    @Test
    fun `close before truth moves pre-authority unknown to pending`() {
        // A pre-T6 row closing on an untrusted boot joins the contract as
        // pending: its stamps were written with no authority behind them.
        assertEquals("pending", ClockUnlockBackfillEngine.sessionCloseState("unknown", false))
    }

    @Test
    fun `close before truth keeps uncorrectable without stranding as pending`() {
        // An uncorrectable session was already judged uncorrectable: demoting it
        // to pending would hold it in the uploader forever because no sweep
        // revisits it. It must remain uncorrectable.
        assertEquals(
            "uncorrectable",
            ClockUnlockBackfillEngine.sessionCloseState("uncorrectable", false)
        )
    }
}
