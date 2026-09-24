package com.timhss.capyenergy.service

import com.timhss.capyenergy.service.AutoOpenLauncher.Companion.DEBOUNCE_MILLIS
import com.timhss.capyenergy.service.AutoOpenLauncher.Companion.STARTUP_SETTLE_MILLIS
import com.timhss.capyenergy.service.AutoOpenLauncher.Companion.refusalFor
import com.timhss.capyenergy.service.AutoOpenLauncher.Refusal
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The launcher takes the display from the driver, so what it refuses matters
 * more than what it accepts. Each case states which refusal it expects, because
 * the refusal is also what the log line on the car says.
 */
class AutoOpenLauncherTest {

    private val startedAt = 1_000L

    private fun refusal(
        now: Long,
        lastLaunchAt: Long? = null,
        enabled: Boolean = true,
        resting: Boolean = false
    ): Refusal? = refusalFor(
        enabled = enabled,
        resting = resting,
        now = now,
        startedAt = startedAt,
        lastLaunchAt = lastLaunchAt
    )

    @Test
    fun `a plug during the settle window opens nothing`() {
        // A car that boots with the cable in reports its first connected
        // reading as a connect. That is the engine starting, not a driver
        // plugging in.
        assertEquals(
            Refusal.SETTLE_WINDOW,
            refusal(now = startedAt + STARTUP_SETTLE_MILLIS - 1)
        )
    }

    @Test
    fun `a plug after the settle window opens the app`() {
        assertNull(refusal(now = startedAt + STARTUP_SETTLE_MILLIS + 1))
    }

    @Test
    fun `the plug and the charge start open the app once`() {
        // One arrival reports two beginnings. The second must not open a
        // second screen.
        val plug = startedAt + STARTUP_SETTLE_MILLIS + 1
        assertEquals(
            Refusal.DEBOUNCE,
            refusal(now = plug + 5_000, lastLaunchAt = plug)
        )
    }

    @Test
    fun `a bouncing contact opens the app once`() {
        val firstLaunch = startedAt + STARTUP_SETTLE_MILLIS + 1
        assertEquals(
            Refusal.DEBOUNCE,
            refusal(now = firstLaunch + DEBOUNCE_MILLIS - 1, lastLaunchAt = firstLaunch)
        )
    }

    @Test
    fun `plugging in again later opens the app again`() {
        val firstLaunch = startedAt + STARTUP_SETTLE_MILLIS + 1
        assertNull(refusal(now = firstLaunch + DEBOUNCE_MILLIS + 1, lastLaunchAt = firstLaunch))
    }

    @Test
    fun `a person resting in the car keeps the display`() {
        // Camping or nap mode. The wall box can switch on at night, and the
        // factory screen refuses on the same condition.
        assertEquals(
            Refusal.SOMEBODY_IS_RESTING,
            refusal(now = startedAt + STARTUP_SETTLE_MILLIS + 1, resting = true)
        )
    }

    @Test
    fun `the setting is refused before anything is read`() {
        // The reader's choice comes first: a car in camping mode with the
        // replacement off must report the setting, not the mode.
        assertEquals(
            Refusal.SETTING_OFF,
            refusal(
                now = startedAt + STARTUP_SETTLE_MILLIS + 1,
                enabled = false,
                resting = true
            )
        )
    }
}
