package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.pairing.DevicePairingException
import com.timhss.capyenergy.telemetry.pairing.FakeDevicePairingClient
import com.timhss.capyenergy.telemetry.pairing.RegisterResult
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Boot-time pre-claim registration driver (issue #236 P2-T6 / B1).
 *
 * The driver is the whole registration decision surface: when a boot mints a
 * token, when it is skipped (already registered under the current id, or the
 * id not minted yet), the re-key when the identity upgrades, the bounded
 * backoff after a failure, and the blank-token refusal. The runtime's only
 * job is to call [run] from startup and the upload tick.
 *
 * These tests fail if the production callsites are removed: the fake client
 * records every `register` call, and the injected scheduler records every
 * retry delay, so a deleted wiring shows up as zero calls instead of a green
 * source-presence assertion.
 */
class BootRegistrationDriverTest {

    private lateinit var ctx: FakeSettingsContext
    private lateinit var settings: TelemetrySettings
    private lateinit var fakeClient: FakeDevicePairingClient
    private lateinit var coordinator: com.timhss.capyenergy.telemetry.pairing.PairingCoordinator
    private val retries = mutableListOf<Long>()
    private var vehicleId = "VIN-CAR"
    private var now = 1_000L

    @Before
    fun setUp() {
        ctx = FakeSettingsContext()
        settings = TelemetrySettings(ctx)
        fakeClient = FakeDevicePairingClient()
        coordinator = com.timhss.capyenergy.telemetry.pairing.PairingCoordinator(
            client = fakeClient,
            settings = settings,
            pollIntervalMillis = 0,
            sleeper = {},
        )
        retries.clear()
        vehicleId = "VIN-CAR"
        now = 1_000L
    }

    private fun driver(
        baseRetryDelayMillis: Long = 500L,
        maxRetryDelayMillis: Long = 2_000L,
        maxRetryStates: Int = 3,
    ) = BootRegistrationDriver(
        coordinator = coordinator,
        settings = settings,
        vehicleIdProvider = { vehicleId },
        nowMillis = { now },
        scheduleRetry = { retries.add(it) },
        baseRetryDelayMillis = baseRetryDelayMillis,
        maxRetryDelayMillis = maxRetryDelayMillis,
        maxRetryStates = maxRetryStates,
    )

    @Test
    fun `fresh car registers once and the token is persisted`() {
        val d = driver()
        d.run()
        assertEquals(listOf("VIN-CAR"), fakeClient.registerCalls)
        assertEquals("test-car-token", settings.carToken())
        assertEquals(TelemetrySettings.PAIRING_STATUS_REGISTERED, settings.pairingStatus())
        assertEquals("VIN-CAR", settings.registeredVehicleId())
        assertTrue(retries.isEmpty())
    }

    @Test
    fun `already registered under current id does not re-register`() {
        settings.register("tok", "VIN-CAR")
        val d = driver()
        d.run()
        assertTrue(fakeClient.registerCalls.isEmpty())
    }

    @Test
    fun `registered car whose id was retired re-registers under the current id`() {
        // B1: minted under android_id, identity upgraded to VIN.
        settings.register("tok", "android-id-1")
        val d = driver()
        d.run()
        assertEquals(listOf("VIN-CAR"), fakeClient.registerCalls)
        assertEquals("VIN-CAR", settings.registeredVehicleId())
    }

    @Test
    fun `unminted vehicle id skips without registering`() {
        vehicleId = "unassigned"
        val d = driver()
        d.run()
        assertTrue(fakeClient.registerCalls.isEmpty())
        assertTrue(retries.isEmpty())
    }
    @Test
    fun `network failure schedules a retry with backoff and notifies`() {
        repeat(6) { fakeClient.enqueueRegisterError(DevicePairingException("network down")) }
        val d = driver(baseRetryDelayMillis = 500L, maxRetryDelayMillis = 2_000L, maxRetryStates = 3)
        var exhausted: Throwable? = null
        d.onRetriesExhausted = { exhausted = it }
        d.run() // fails, schedule 500
        d.run() // fails, schedule 1000
        d.run() // fails, schedule 2000
        d.run() // fails, exhausted
        assertEquals(listOf(500L, 1_000L, 2_000L), retries)
        assertTrue(exhausted is DevicePairingException)
        // Never persisted a phantom registered state.
        assertEquals(TelemetrySettings.PAIRING_STATUS_UNPAIRED, settings.pairingStatus())
    }

    @Test
    fun `backoff is bounded by maxRetryDelayMillis`() {
        repeat(6) { fakeClient.enqueueRegisterError(DevicePairingException("network down")) }
        val d = driver(baseRetryDelayMillis = 500L, maxRetryDelayMillis = 1_500L, maxRetryStates = 4)
        d.run(); d.run(); d.run(); d.run(); d.run()
        assertEquals(listOf(500L, 1_000L, 1_500L, 1_500L), retries)
    }

    @Test
    fun `blank token refusal drops the credential instead of retrying`() {
        fakeClient.enqueueRegister(RegisterResult(carToken = "  "))
        val d = driver()
        var refused: Throwable? = null
        d.onRefused = { refused = it }
        d.run()
        assertTrue(retries.isEmpty())
        assertTrue(refused is DevicePairingException)
        // Unpaired, no token: the next boot tries honestly again.
        assertEquals(TelemetrySettings.PAIRING_STATUS_UNPAIRED, settings.pairingStatus())
        assertNull(settings.carToken())
    }

    @Test
    fun `success resets the attempt counter and other cars stay untouched`() {
        fakeClient.enqueueRegisterError(DevicePairingException("network down"))
        val d = driver()
        d.run() // fail #1
        d.onRegistered = { }
        fakeClient.enqueueRegister(RegisterResult("tok-ok"))
        d.run() // success
        assertEquals(TelemetrySettings.PAIRING_STATUS_REGISTERED, settings.pairingStatus())
        assertEquals("tok-ok", settings.carToken())

        // 1 failure schedules base; success clears the retry state.
        assertEquals(1, retries.size)
        retries.clear()

        // After success the car is registered under the current id, so a
        // later run is a no-op at the gate — no new credentials, no retries.
        d.run()
        assertEquals(2, fakeClient.registerCalls.size)
        assertTrue(retries.isEmpty())
        assertTrue(
            "registered id must stay stable after success",
            settings.registeredVehicleId() == "VIN-CAR"
        )
    }

    @Test
    fun `approved car is left completely alone`() {
        settings.setPairingStatus(TelemetrySettings.PAIRING_STATUS_APPROVED)
        settings.setCarToken("tok-approved")
        settings.setAccountId("acct")
        val d = driver()
        d.run()
        assertTrue(fakeClient.registerCalls.isEmpty())
        assertEquals("tok-approved", settings.carToken())
        assertEquals("acct", settings.accountId())
    }

    @Test
    fun `pending car is left alone mid-claim`() {
        settings.setPairingStatus(TelemetrySettings.PAIRING_STATUS_PENDING)
        val d = driver()
        d.run()
        assertTrue(fakeClient.registerCalls.isEmpty())
    }

    @Test
    fun `revoked car holds its token and does not re-register`() {
        // Revocation is a separate Phase 4 flow; boot registration must not
        // mint a fresh token over a revoked one.
        settings.setPairingStatus(TelemetrySettings.PAIRING_STATUS_REVOKED)
        settings.setCarToken("tok-revoked")
        val d = driver()
        d.run()
        assertTrue(fakeClient.registerCalls.isEmpty())
        assertEquals(TelemetrySettings.PAIRING_STATUS_REVOKED, settings.pairingStatus())
    }
}