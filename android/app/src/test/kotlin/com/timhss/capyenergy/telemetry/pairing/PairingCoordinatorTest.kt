package com.timhss.capyenergy.telemetry.pairing

import com.timhss.capyenergy.telemetry.FakeSettingsContext
import com.timhss.capyenergy.telemetry.TelemetrySettings
import org.junit.Assert.assertFalse
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class PairingCoordinatorTest {

    private lateinit var settings: TelemetrySettings
    private lateinit var ctx: FakeSettingsContext
    private lateinit var fakeClient: FakeDevicePairingClient

    @Before
    fun setUp() {
        ctx = FakeSettingsContext()
        settings = TelemetrySettings(ctx)
        fakeClient = FakeDevicePairingClient()
    }

    private fun coordinator(pollIntervalMillis: Long = 0L) = PairingCoordinator(
        client = fakeClient,
        settings = settings,
        pollIntervalMillis = pollIntervalMillis,
        sleeper = {} // no delay in tests
    )

    @Test
    fun `start stores device_code in memory and marks pending`() = runBlocking {
        val startResult = PairingStartResult("482-910", "00000000-0000-4000-a000-000000000001", "2099-01-01T00:00:00.000Z")
        fakeClient.enqueueStart(startResult)
        val c = coordinator()
        val result = c.start("VIN-1")
        assertEquals(startResult, result)
        assertEquals("00000000-0000-4000-a000-000000000001", c.currentDeviceCode)
        assertEquals(TelemetrySettings.PAIRING_STATUS_PENDING, settings.pairingStatus())
        // device_code never persisted
        assertNull(settings.carToken())
        assertNull(settings.accountId())
        // Reopened settings still pending but no token
        val reopened = TelemetrySettings(ctx)
        assertEquals(TelemetrySettings.PAIRING_STATUS_PENDING, reopened.pairingStatus())
        assertNull(reopened.carToken())
    }

    @Test
    fun `pending remains pending and keeps device_code`() = runBlocking {
        fakeClient.enqueueStart(PairingStartResult("111-222", "code-pending", "2099-01-01T00:00:00.000Z"))
        fakeClient.enqueuePoll(PairingPollResult.Pending)
        val c = coordinator()
        c.start("VIN-1")
        val result = c.pollOnce()
        assertTrue(result is PairingPollResult.Pending)
        assertEquals("code-pending", c.currentDeviceCode)
        assertEquals(TelemetrySettings.PAIRING_STATUS_PENDING, settings.pairingStatus())
        assertNull(settings.carToken())
    }

    @Test
    fun `pending to approved saves token and clears device_code`() = runBlocking {
        fakeClient.enqueueStart(PairingStartResult("111-222", "code-approve", "2099-01-01T00:00:00.000Z"))
        fakeClient.enqueuePoll(PairingPollResult.Pending)
        fakeClient.enqueuePoll(PairingPollResult.Approved("tok123", "acct123"))
        val c = coordinator()
        c.start("VIN-1")
        c.pollOnce() // pending
        val approved = c.pollOnce()
        assertTrue(approved is PairingPollResult.Approved)
        assertEquals("tok123", (approved as PairingPollResult.Approved).carToken)
        assertNull(c.currentDeviceCode)
        assertEquals(TelemetrySettings.PAIRING_STATUS_APPROVED, settings.pairingStatus())
        assertEquals("tok123", settings.carToken())
        assertEquals("acct123", settings.accountId())
        // Reopen persists
        val reopened = TelemetrySettings(ctx)
        assertEquals("tok123", reopened.carToken())
        assertEquals("acct123", reopened.accountId())
    }

    @Test
    fun `pending to expired clears pending and goes unpaired`() = runBlocking {
        fakeClient.enqueueStart(PairingStartResult("111-222", "code-expire", "2099-01-01T00:00:00.000Z"))
        fakeClient.enqueuePoll(PairingPollResult.Expired)
        val c = coordinator()
        c.start("VIN-1")
        val result = c.pollOnce()
        assertTrue(result is PairingPollResult.Expired)
        assertNull(c.currentDeviceCode)
        assertEquals(TelemetrySettings.PAIRING_STATUS_UNPAIRED, settings.pairingStatus())
        assertNull(settings.carToken())
        assertNull(settings.accountId())
    }

    @Test
    fun `invalid code clears and goes unpaired`() = runBlocking {
        fakeClient.enqueueStart(PairingStartResult("111-222", "bad-code", "2099-01-01T00:00:00.000Z"))
        fakeClient.enqueuePoll(PairingPollResult.InvalidCode)
        val c = coordinator()
        c.start("VIN-1")
        val result = c.pollOnce()
        assertTrue(result is PairingPollResult.InvalidCode)
        assertNull(c.currentDeviceCode)
        assertEquals(TelemetrySettings.PAIRING_STATUS_UNPAIRED, settings.pairingStatus())
    }

    @Test
    fun `pollUntilDone pending then approved`() = runBlocking {
        fakeClient.enqueueStart(PairingStartResult("111-222", "code-loop", "2099-01-01T00:00:00.000Z"))
        fakeClient.enqueuePoll(PairingPollResult.Pending)
        fakeClient.enqueuePoll(PairingPollResult.Pending)
        fakeClient.enqueuePoll(PairingPollResult.Approved("tok999", "acct999"))
        val c = coordinator(pollIntervalMillis = 0)
        c.start("VIN-1")
        val terminal = c.pollUntilDone()
        assertTrue(terminal is PairingPollResult.Approved)
        assertEquals("tok999", settings.carToken())
        assertEquals(TelemetrySettings.PAIRING_STATUS_APPROVED, settings.pairingStatus())
        assertNull(c.currentDeviceCode)
        assertEquals(3, fakeClient.pollCalls.size)
    }

    @Test
    fun `pollUntilDone pending then expired`() = runBlocking {
        fakeClient.enqueueStart(PairingStartResult("111-222", "code-loop2", "2099-01-01T00:00:00.000Z"))
        fakeClient.enqueuePoll(PairingPollResult.Pending)
        fakeClient.enqueuePoll(PairingPollResult.Expired)
        val c = coordinator(pollIntervalMillis = 0)
        c.start("VIN-1")
        val terminal = c.pollUntilDone()
        assertTrue(terminal is PairingPollResult.Expired)
        assertEquals(TelemetrySettings.PAIRING_STATUS_UNPAIRED, settings.pairingStatus())
        assertNull(c.currentDeviceCode)
    }

    @Test
    fun `cancel stops polling and clears device_code`() = runBlocking {
        fakeClient.enqueueStart(PairingStartResult("111-222", "code-cancel", "2099-01-01T00:00:00.000Z"))
        val c = coordinator()
        c.start("VIN-1")
        assertNotNull(c.currentDeviceCode)
        c.cancel()
        assertNull(c.currentDeviceCode)
        assertEquals(TelemetrySettings.PAIRING_STATUS_UNPAIRED, settings.pairingStatus())
    }

    @Test
    fun `pollUntilDone respects caller cancel`() = runBlocking {
        fakeClient.enqueueStart(PairingStartResult("111-222", "code-cancel-loop", "2099-01-01T00:00:00.000Z"))
        // Enqueue infinite pending — but we cancel after first poll
        repeat(10) { fakeClient.enqueuePoll(PairingPollResult.Pending) }
        val c = coordinator(pollIntervalMillis = 0)
        c.start("VIN-1")
        var calls = 0
        val result = c.pollUntilDone(isCancelled = {
            calls++
            calls > 1 // cancel after first iteration
        })
        assertNull(result) // cancelled returns null
        assertNull(c.currentDeviceCode)
    }

    @Test
    fun `pollOnce without start throws`() = runBlocking {
        val c = coordinator()
        var threw = false
        try {
            c.pollOnce()
        } catch (e: IllegalStateException) {
            threw = true
        }
        assertTrue(threw)
    }

    @Test
    fun `pollUntilDone without start throws`() = runBlocking {
        val c = coordinator()
        var threw = false
        try {
            c.pollUntilDone()
        } catch (e: IllegalStateException) {
            threw = true
        }
        assertTrue(threw)
    }

    @Test
    fun `cancel does not clear approved credential`() = runBlocking {
        fakeClient.enqueueStart(PairingStartResult("111-222", "code-approve-then-cancel", "2099-01-01T00:00:00.000Z"))
        fakeClient.enqueuePoll(PairingPollResult.Approved("tok-keep", "acct-keep"))
        val c = coordinator()
        c.start("VIN-1")
        c.pollOnce() // approved
        assertEquals(TelemetrySettings.PAIRING_STATUS_APPROVED, settings.pairingStatus())
        c.cancel() // should not wipe approved
        assertEquals(TelemetrySettings.PAIRING_STATUS_APPROVED, settings.pairingStatus())
        assertEquals("tok-keep", settings.carToken())
    }

    @Test
    fun `device_code never persisted across settings reopen`() = runBlocking {
        fakeClient.enqueueStart(PairingStartResult("999-888", "secret-device-code", "2099-01-01T00:00:00.000Z"))
        val c = coordinator()
        c.start("VIN-1")
        // Simulate app restart: new settings instance same backing store
        val reopened = TelemetrySettings(ctx)
        // Reopened has pending status but no token and crucially no device_code
        assertEquals(TelemetrySettings.PAIRING_STATUS_PENDING, reopened.pairingStatus())
        assertNull(reopened.carToken())
        // The new coordinator has no device_code — polling secret is memory-only
        val c2 = PairingCoordinator(fakeClient, reopened, pollIntervalMillis = 0, sleeper = {})
        assertNull(c2.currentDeviceCode)
    }

    @Test
    fun `start isCancelled flag reset on new start`() = runBlocking {
        fakeClient.enqueueStart(PairingStartResult("111-222", "code-1", "2099-01-01T00:00:00.000Z"))
        fakeClient.enqueueStart(PairingStartResult("333-444", "code-2", "2099-01-01T00:00:00.000Z"))
        val c = coordinator()
        c.start("VIN-1")
        c.cancel()
        assertNull(c.currentDeviceCode)
        // Next start should succeed despite prior cancel
        val result2 = c.start("VIN-2")
        assertEquals("code-2", result2.deviceCode)
        assertEquals("code-2", c.currentDeviceCode)
        assertEquals(TelemetrySettings.PAIRING_STATUS_PENDING, settings.pairingStatus())
    }

    @Test
    fun `approved fires hook with changed account on first pairing`() = runBlocking {
        fakeClient.enqueueStart(PairingStartResult("111-222", "code-first", "2099-01-01T00:00:00.000Z"))
        fakeClient.enqueuePoll(PairingPollResult.Approved("tok-1", "acct-1"))
        val c = coordinator()
        val calls = mutableListOf<Pair<Boolean, String>>()
        c.onApprovedHook = { approved, changed -> calls.add(changed to approved.accountId) }
        c.start("VIN-1")
        c.pollOnce()
        assertEquals(listOf(true to "acct-1"), calls)
    }

    @Test
    fun `approved reports unchanged account on re-pairing to same account`() = runBlocking {
        settings.setAccountId("acct-same")
        settings.setCarToken("tok-old")
        settings.setPairingStatus(TelemetrySettings.PAIRING_STATUS_APPROVED)
        fakeClient.enqueueStart(PairingStartResult("111-222", "code-same", "2099-01-01T00:00:00.000Z"))
        fakeClient.enqueuePoll(PairingPollResult.Approved("tok-new", "acct-same"))
        val c = coordinator()
        val calls = mutableListOf<Boolean>()
        c.onApprovedHook = { _, changed -> calls.add(changed) }
        c.start("VIN-1")
        c.pollOnce()
        assertEquals(listOf(false), calls)
        assertEquals("tok-new", settings.carToken())
    }

    @Test
    fun `pending and terminal failures do not fire hook`() = runBlocking {
        fakeClient.enqueueStart(PairingStartResult("111-222", "code-quiet", "2099-01-01T00:00:00.000Z"))
        fakeClient.enqueuePoll(PairingPollResult.Pending)
        fakeClient.enqueuePoll(PairingPollResult.Expired)
        val c = coordinator()
        var calls = 0
        c.onApprovedHook = { _, _ -> calls++ }
        c.start("VIN-1")
        c.pollOnce()
        c.pollOnce()
        assertEquals(0, calls)
    }

    @Test
    fun `throwing hook does not roll back saved credential`() = runBlocking {
        fakeClient.enqueueStart(PairingStartResult("111-222", "code-throw", "2099-01-01T00:00:00.000Z"))
        fakeClient.enqueuePoll(PairingPollResult.Approved("tok-safe", "acct-safe"))
        val c = coordinator()
        c.onApprovedHook = { _, _ -> throw RuntimeException("hook boom") }
        c.start("VIN-1")
        c.pollOnce()
        assertEquals(TelemetrySettings.PAIRING_STATUS_APPROVED, settings.pairingStatus())
        assertEquals("tok-safe", settings.carToken())
        assertEquals("acct-safe", settings.accountId())
    }

    // --- Pre-claim registration (issue #236 P2-T6) ---------------------------

    @Test
    fun `unpaired car with no token should register`() {
        assertTrue(coordinator().shouldRegister("vin-1"))
    }

    @Test
    fun `unpaired car holding a token must not re-register`() {
        settings.setCarToken("tok-x")
        assertFalse(coordinator().shouldRegister("vin-1"))
    }

    @Test
    fun `approved pending and revoked cars do not register`() {
        settings.setPairingStatus(TelemetrySettings.PAIRING_STATUS_APPROVED)
        assertFalse(coordinator().shouldRegister("vin-1"))
        settings.setPairingStatus(TelemetrySettings.PAIRING_STATUS_PENDING)
        assertFalse(coordinator().shouldRegister("vin-1"))
        settings.setPairingStatus(TelemetrySettings.PAIRING_STATUS_REVOKED)
        assertFalse(coordinator().shouldRegister("vin-1"))
    }

    @Test
    fun `registered car matching current id does not re-register`() {
        settings.setPairingStatus(TelemetrySettings.PAIRING_STATUS_REGISTERED)
        settings.register("tok-x", "vin-1")
        assertFalse(coordinator().shouldRegister("vin-1"))
    }

    @Test
    fun `registered car whose token was minted under a retired id re-registers`() {
        // B1: token minted under android_id, identity upgraded to VIN later.
        settings.register("tok-x", "android-id-1")
        assertTrue(coordinator().shouldRegister("VIN-1"))
    }

    @Test
    fun `registered car with no recorded registration id re-registers`() {
        // Install registered before registered_vehicle_id existed — recovery.
        settings.setPairingStatus(TelemetrySettings.PAIRING_STATUS_REGISTERED)
        settings.setCarToken("tok-x")
        assertTrue(coordinator().shouldRegister("VIN-1"))
    }

    @Test
    fun `registerAndSave persists token as registered and leaves account null`() = runBlocking {
        fakeClient.enqueueRegister(
            RegisterResult(carToken = "tok-abc")
        )
        val token = coordinator().registerAndSave("vin-1")
        assertEquals("tok-abc", token)
        assertEquals(listOf("vin-1"), fakeClient.registerCalls)
        assertEquals("tok-abc", settings.carToken())
        assertNull(settings.accountId())
        assertEquals(TelemetrySettings.PAIRING_STATUS_REGISTERED, settings.pairingStatus())
        assertEquals("vin-1", settings.registeredVehicleId())
    }

    @Test
    fun `registerAndSave clears a stale account`() = runBlocking {
        settings.setAccountId("old-acct")
        fakeClient.enqueueRegister(RegisterResult(carToken = "tok-x"))
        coordinator().registerAndSave("vin-1")
        assertNull(settings.accountId())
    }

    @Test
    fun `registerAndSave refuses a blank token and persists nothing`() = runBlocking {
        fakeClient.enqueueRegister(RegisterResult(carToken = "   "))
        var threw = false
        try {
            coordinator().registerAndSave("vin-1")
        } catch (e: DevicePairingException) {
            threw = true
            assertTrue(e.message!!.contains("blank car_token"))
        }
        assertTrue(threw)
        assertNull(settings.carToken())
        assertNull(settings.accountId())
        assertEquals(TelemetrySettings.PAIRING_STATUS_UNPAIRED, settings.pairingStatus())
    }

    @Test
    fun `registerAndSave failure persists nothing and leaves unpaired`() = runBlocking {
        fakeClient.enqueueRegisterError(DevicePairingException("network down"))
        var threw = false
        try {
            coordinator().registerAndSave("vin-1")
        } catch (e: DevicePairingException) {
            threw = true
        }
        assertTrue(threw)
        assertNull(settings.carToken())
        assertEquals(TelemetrySettings.PAIRING_STATUS_UNPAIRED, settings.pairingStatus())
    }
}
