package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.pairing.FakeDevicePairingClient
import com.timhss.capyenergy.telemetry.pairing.RegisterResult
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The B1 identity race at the boot boundary (issue #236 P2-T6).
 *
 * A car that cannot read its VIN at t=0 registers under android_id; the VIN
 * arrives moments later and the identity upgrades. The token bound to
 * android_id can never upload VIN-keyed rows. The recovery is re-registration
 * under the VIN once it lands — and the driver must do it WITHOUT waiting for
 * the next boot.
 *
 * The runtime passes an injected clock and reads the vehicle id through the
 * provider, so this test drives the same boundary the production wiring does:
 * a test double that flips its answer when the "VIN read" happens at a given
 * timestamp.
 */
class BootVehicleKeyRaceTest {

    private lateinit var ctx: FakeSettingsContext
    private lateinit var settings: TelemetrySettings
    private lateinit var fakeClient: FakeDevicePairingClient

    @Before
    fun setUp() {
        ctx = FakeSettingsContext()
        settings = TelemetrySettings(ctx)
        fakeClient = FakeDevicePairingClient()
    }

    private class ClockAndVehicle {
        var now = 0L
        var androidIdMinted = false
        var vinAvailableAt = Long.MAX_VALUE

        fun currentId(): String {
            if (now >= vinAvailableAt) return "VIN-REAL"
            return if (androidIdMinted) "ANDROID-ID-1" else "unassigned"
        }
    }

    @Test
    fun `token minted under android id is re-keyed under the VIN when it lands`() {
        val clock = ClockAndVehicle().apply { androidIdMinted = true; vinAvailableAt = 60_000L }
        val registerCalls = mutableListOf<String>()
        val retries = mutableListOf<Long>()

        val coordinator = com.timhss.capyenergy.telemetry.pairing.PairingCoordinator(
            client = fakeClient,
            settings = settings,
            pollIntervalMillis = 0,
            sleeper = {},
        )
        val driver = BootRegistrationDriver(
            coordinator = coordinator,
            settings = settings,
            vehicleIdProvider = { clock.currentId() },
            nowMillis = { clock.now },
            scheduleRetry = { retries.add(it) },
            baseRetryDelayMillis = 500L,
            maxRetryDelayMillis = 2_000L,
            maxRetryStates = 3,
        )

        // Boot at t=500: VIN not readable yet, minted under android id.
        clock.now = 500L
        fakeClient.enqueueRegister(RegisterResult("tok-android"))
        driver.run()
        assertEquals(listOf("ANDROID-ID-1"), registerCalls.plus(fakeClient.registerCalls))
        assertEquals("ANDROID-ID-1", settings.registeredVehicleId())
        assertEquals(TelemetrySettings.PAIRING_STATUS_REGISTERED, settings.pairingStatus())
        fakeClient.registerCalls.clear()

        // t=60s: the VIN upgrade lands and re-keys under the VIN.
        clock.now = 60_000L
        fakeClient.enqueueRegister(RegisterResult("tok-vin"))
        driver.run()
        assertEquals(listOf("VIN-REAL"), registerCalls.plus(fakeClient.registerCalls))
        assertEquals("VIN-REAL", settings.registeredVehicleId())
        assertEquals("tok-vin", settings.carToken())
        assertTrue(retries.isEmpty())
    }
}