package com.timhss.capyenergy.telemetry.pairing

import com.timhss.capyenergy.telemetry.FakeSettingsContext
import com.timhss.capyenergy.telemetry.TelemetryFacade
import com.timhss.capyenergy.telemetry.TelemetrySettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The stuck-REGISTRADO fix: a registered-but-unclaimed car shows "registered"
 * only inside the 5-minute claim window (the pairing-code TTL); past it the
 * facade drops the orphan token via `resetRegistration()` and falls through
 * to idle, which renders the "new code" retry button.
 *
 * `TelemetryFacade` needs a full `TelemetryGraph` (Room), so these tests pin
 * the pure boundary decision plus the settings round-trip the facade relies
 * on, following the coordinator tests' style (real persistence, no mocks).
 */
class TelemetryFacadeRegisteredClaimTest {

    private lateinit var ctx: FakeSettingsContext
    private lateinit var settings: TelemetrySettings

    @Before
    fun setUp() {
        ctx = FakeSettingsContext()
        settings = TelemetrySettings(ctx)
    }

    @Test
    fun `claim window matches the five minute pairing-code TTL`() {
        assertEquals(5 * 60 * 1_000L, TelemetryFacade.REGISTERED_CLAIM_WINDOW_MILLIS)
    }

    @Test
    fun `just registered still shows registered`() {
        val now = 1_000_000_000L
        assertTrue(TelemetryFacade.registeredClaimLive(now, now))
        assertTrue(
            TelemetryFacade.registeredClaimLive(
                now,
                now + TelemetryFacade.REGISTERED_CLAIM_WINDOW_MILLIS - 1
            )
        )
    }

    @Test
    fun `registered five or more minutes ago falls through to retry`() {
        val now = 1_000_000_000L
        assertFalse(
            TelemetryFacade.registeredClaimLive(
                now,
                now + TelemetryFacade.REGISTERED_CLAIM_WINDOW_MILLIS
            )
        )
        assertFalse(
            TelemetryFacade.registeredClaimLive(
                now,
                now + TelemetryFacade.REGISTERED_CLAIM_WINDOW_MILLIS + 1
            )
        )
    }

    @Test
    fun `missing timestamp reads as expired so pre-field installs reset`() {
        assertFalse(TelemetryFacade.registeredClaimLive(null, 1_000_000_000L))
    }

    @Test
    fun `resetRegistration clears the stuck token back to unpaired`() {
        settings.register(token = "tok-orphan", vehicleId = "VIN-1", atUtcMillis = 1_000L)
        assertEquals(TelemetrySettings.PAIRING_STATUS_REGISTERED, settings.pairingStatus())

        settings.resetRegistration()

        assertEquals(TelemetrySettings.PAIRING_STATUS_UNPAIRED, settings.pairingStatus())
        assertNull(settings.carToken())
        assertNull(settings.registeredAtUtcMillis())
    }
}
