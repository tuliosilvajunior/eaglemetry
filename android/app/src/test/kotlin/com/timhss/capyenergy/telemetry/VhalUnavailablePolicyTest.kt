package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey

import com.timhss.capyenergy.concurrent.MAX_THREAD_NAME_LENGTH
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class VhalUnavailablePolicyTest {

    @Test
    fun `the first refusal is reported and the repeats are not`() {
        val policy = VhalUnavailablePolicy(refusalsBeforeMute = 4)
        assertEquals(UnavailableAction.REPORT, policy.onUnavailable(SignalKey.OUTSIDE_TEMPERATURE))
        assertEquals(UnavailableAction.IGNORE, policy.onUnavailable(SignalKey.OUTSIDE_TEMPERATURE))
        assertEquals(UnavailableAction.IGNORE, policy.onUnavailable(SignalKey.OUTSIDE_TEMPERATURE))
    }

    @Test
    fun `a signal that keeps refusing is muted once`() {
        val policy = VhalUnavailablePolicy(refusalsBeforeMute = 3)
        val actions = (1..5).map { policy.onUnavailable(SignalKey.OUTSIDE_TEMPERATURE) }
        assertEquals(
            listOf(
                UnavailableAction.REPORT,
                UnavailableAction.IGNORE,
                UnavailableAction.MUTE,
                UnavailableAction.IGNORE,
                UnavailableAction.IGNORE
            ),
            actions
        )
    }

    @Test
    fun `a usable value ends the run, so the next refusal is reported again`() {
        val policy = VhalUnavailablePolicy(refusalsBeforeMute = 3)
        policy.onUnavailable(SignalKey.OUTSIDE_TEMPERATURE)
        policy.onUnavailable(SignalKey.OUTSIDE_TEMPERATURE)
        policy.onAvailable(SignalKey.OUTSIDE_TEMPERATURE)
        assertEquals(UnavailableAction.REPORT, policy.onUnavailable(SignalKey.OUTSIDE_TEMPERATURE))
    }

    @Test
    fun `signals are counted apart`() {
        // One dead property must not mute a healthy neighbour, which is what a
        // single shared counter would do.
        val policy = VhalUnavailablePolicy(refusalsBeforeMute = 2)
        assertEquals(UnavailableAction.REPORT, policy.onUnavailable(SignalKey.OUTSIDE_TEMPERATURE))
        assertEquals(UnavailableAction.REPORT, policy.onUnavailable(SignalKey.HV_BATTERY_VOLTAGE))
        assertEquals(UnavailableAction.MUTE, policy.onUnavailable(SignalKey.OUTSIDE_TEMPERATURE))
        assertEquals(UnavailableAction.MUTE, policy.onUnavailable(SignalKey.HV_BATTERY_VOLTAGE))
    }

    @Test
    fun `a retried subscription starts a fresh run`() {
        // Without the reset, the retry would mute on its very first callback
        // and never report why.
        val policy = VhalUnavailablePolicy(refusalsBeforeMute = 2)
        policy.onUnavailable(SignalKey.OUTSIDE_TEMPERATURE)
        policy.onUnavailable(SignalKey.OUTSIDE_TEMPERATURE)
        policy.reset(SignalKey.OUTSIDE_TEMPERATURE)
        assertEquals(UnavailableAction.REPORT, policy.onUnavailable(SignalKey.OUTSIDE_TEMPERATURE))
    }

    @Test
    fun `the callback worker keeps a name Linux does not cut`() {
        assertTrue(VhalSubscriptionManager.WORKER_THREAD_NAME.length <= MAX_THREAD_NAME_LENGTH)
    }
}
