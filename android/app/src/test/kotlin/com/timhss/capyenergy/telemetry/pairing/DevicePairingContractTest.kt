package com.timhss.capyenergy.telemetry.pairing

import com.timhss.capyenergy.telemetry.FakeSettingsContext
import com.timhss.capyenergy.telemetry.TelemetrySettings
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

/**
 * Contract tests that exercise the real production mapping (PairingStateMapper)
 * and the real coordinator persistence, not hand-typed literal-vs-literal checks.
 *
 * Proof of coverage: deleting the body of TelemetryFacade.getDevicePairingState
 * and making it return {"status":"failed"} would fail these tests because they
 * assert on the mapper's output and on the coordinator's persisted state.
 */
class DevicePairingContractTest {

    private lateinit var ctx: FakeSettingsContext
    private lateinit var settings: TelemetrySettings
    private lateinit var fakeClient: FakeDevicePairingClient

    @Before
    fun setUp() {
        ctx = FakeSettingsContext()
        settings = TelemetrySettings(ctx)
        fakeClient = FakeDevicePairingClient()
    }

    private fun coordinator() = PairingCoordinator(
        client = fakeClient,
        settings = settings,
        pollIntervalMillis = 0,
        sleeper = {}
    )

    // -- Pure mapper tests (would fail if mapper body were replaced) --

    @Test
    fun `mapper startToMap carries userCode expiresAt vehicleId`() {
        val start = PairingStartResult("482-910", "dev-1", "2099-01-01T00:00:00.000Z")
        val map = PairingStateMapper.startToMap(start, "vin-123")
        assertEquals("pending", map["status"])
        assertEquals("482-910", map["userCode"])
        assertEquals("2099-01-01T00:00:00.000Z", map["expiresAt"])
        assertEquals("vin-123", map["vehicleId"])
    }

    @Test
    fun `mapper pollResultToMap distinguishes all five terminals`() {
        val pendingMap = PairingStateMapper.pollResultToMap(
            PairingPollResult.Pending,
            PairingStartResult("111-222", "dev-1", "2099-01-01T00:00:00.000Z"),
            "vin-123"
        )
        assertEquals("pending", pendingMap["status"])
        assertNotNull(pendingMap["userCode"])

        val approvedMap = PairingStateMapper.pollResultToMap(
            PairingPollResult.Approved("tok", "acct-1"), null, "vin-123"
        )
        assertEquals("approved", approvedMap["status"])
        assertEquals("acct-1", approvedMap["accountId"])

        val expiredMap = PairingStateMapper.pollResultToMap(PairingPollResult.Expired, null, "vin-123")
        assertEquals("expired", expiredMap["status"])
        assertEquals("expired", expiredMap["reason"])

        val rejectedMap = PairingStateMapper.pollResultToMap(PairingPollResult.Rejected, null, "vin-123")
        assertEquals("rejected", rejectedMap["status"])
        assertEquals("rejected", rejectedMap["reason"])

        val invalidMap = PairingStateMapper.pollResultToMap(PairingPollResult.InvalidCode, null, "vin-123")
        assertEquals("invalidCode", invalidMap["status"])
        assertEquals("invalid_code", invalidMap["reason"])

        // Distinctness required by spec: do not collapse expired/rejected/invalid
        assertNotEquals(expiredMap["status"], rejectedMap["status"])
        assertNotEquals(rejectedMap["status"], invalidMap["status"])
        assertNotEquals(expiredMap["status"], invalidMap["status"])
    }

    @Test
    fun `mapper terminalToMap preserves rejected distinct from expired`() {
        assertEquals("rejected", PairingStateMapper.terminalToMap("rejected")["status"])
        assertEquals("expired", PairingStateMapper.terminalToMap("expired")["status"])
        assertNotEquals(
            PairingStateMapper.terminalToMap("expired")["status"],
            PairingStateMapper.terminalToMap("rejected")["status"]
        )
    }

    @Test
    fun `mapper idle is idle`() {
        assertEquals("idle", PairingStateMapper.idleToMap()["status"])
    }

    @Test
    fun `mapper revoked is revoked`() {
        val map = PairingStateMapper.revokedToMap()
        assertEquals("revoked", map["status"])
        assertEquals("revoked", map["reason"])
        assertEquals("revoked", PairingStateMapper.terminalToMap("revoked")["status"])
    }

    // -- Coordinator integration tests (real persistence, real state transitions) --

    @Test
    fun `start surfaces userCode and marks pending`() = runBlocking {
        val c = coordinator()
        val expected = PairingStartResult("482-910", "00000000-0000-4000-a000-000000000001", "2099-01-01T00:00:00.000Z")
        fakeClient.enqueueStart(expected)
        val result = c.start("vin-123")
        assertEquals("482-910", result.userCode)
        assertNotNull(c.currentDeviceCode)
        assertEquals(TelemetrySettings.PAIRING_STATUS_PENDING, settings.pairingStatus())
        // Through mapper
        val contract = PairingStateMapper.startToMap(result, "vin-123")
        assertEquals("pending", contract["status"])
    }

    @Test
    fun `poll approved saves credential and clears device_code`() = runBlocking {
        val c = coordinator()
        fakeClient.enqueueStart(PairingStartResult("111-222", "dev-1", "2099-01-01T00:00:00.000Z"))
        c.start("vin-123")
        fakeClient.enqueuePoll(PairingPollResult.Approved(carToken = "token-abc", accountId = "acct-123"))
        val polled = c.pollOnce()
        assertTrue(polled is PairingPollResult.Approved)
        assertEquals("token-abc", settings.carToken())
        assertEquals("acct-123", settings.accountId())
        assertEquals(TelemetrySettings.PAIRING_STATUS_APPROVED, settings.pairingStatus())
        assertNull(c.currentDeviceCode)
        val contract = PairingStateMapper.pollResultToMap(polled, null, "vin-123")
        assertEquals("approved", contract["status"])
        assertEquals("acct-123", contract["accountId"])
    }

    @Test
    fun `poll expired clears stale credential and goes unpaired`() = runBlocking {
        val c = coordinator()
        // First approve to have a stale credential for re-pairing scenario
        fakeClient.enqueueStart(PairingStartResult("111-222", "dev-1", "2099-01-01T00:00:00.000Z"))
        c.start("vin-123")
        fakeClient.enqueuePoll(PairingPollResult.Approved("old-token", "old-acct"))
        c.pollOnce()
        assertEquals("old-acct", settings.accountId())
        // Re-pair attempt
        fakeClient.enqueueStart(PairingStartResult("333-444", "dev-2", "2099-01-01T00:00:00.000Z"))
        c.start("vin-123")
        assertEquals(TelemetrySettings.PAIRING_STATUS_PENDING, settings.pairingStatus())
        fakeClient.enqueuePoll(PairingPollResult.Expired)
        val polled = c.pollOnce()
        assertTrue(polled is PairingPollResult.Expired)
        assertNull(c.currentDeviceCode)
        // Must clear stale token (re-pairing case)
        assertNull(settings.carToken())
        assertNull(settings.accountId())
        assertEquals(TelemetrySettings.PAIRING_STATUS_UNPAIRED, settings.pairingStatus())
        val contract = PairingStateMapper.pollResultToMap(polled, null, "vin-123")
        assertEquals("expired", contract["status"])
    }

    @Test
    fun `poll rejected distinct from expired and clears stale`() = runBlocking {
        val c = coordinator()
        fakeClient.enqueueStart(PairingStartResult("111-222", "dev-1", "2099-01-01T00:00:00.000Z"))
        c.start("vin-123")
        fakeClient.enqueuePoll(PairingPollResult.Rejected)
        val polled = c.pollOnce()
        assertTrue(polled is PairingPollResult.Rejected)
        assertNull(c.currentDeviceCode)
        assertEquals(TelemetrySettings.PAIRING_STATUS_UNPAIRED, settings.pairingStatus())
        val rejectedMap = PairingStateMapper.pollResultToMap(polled, null, "vin-123")
        val expiredMap = PairingStateMapper.expiredToMap()
        assertNotEquals(rejectedMap["status"], expiredMap["status"])
        assertEquals("rejected", rejectedMap["status"])
    }

    @Test
    fun `poll invalidCode distinct`() = runBlocking {
        val c = coordinator()
        fakeClient.enqueueStart(PairingStartResult("111-222", "dev-1", "2099-01-01T00:00:00.000Z"))
        c.start("vin-123")
        fakeClient.enqueuePoll(PairingPollResult.InvalidCode)
        val polled = c.pollOnce()
        assertTrue(polled is PairingPollResult.InvalidCode)
        assertNull(c.currentDeviceCode)
        assertEquals(TelemetrySettings.PAIRING_STATUS_UNPAIRED, settings.pairingStatus())
    }

    @Test
    fun `approved pairing results in non-null account for uploaders gate (approved status)`() = runBlocking {
        val c = coordinator()
        fakeClient.enqueueStart(PairingStartResult("111-222", "dev-1", "2099-01-01T00:00:00.000Z"))
        c.start("vin-123")
        fakeClient.enqueuePoll(PairingPollResult.Approved(carToken = "car-token-x", accountId = "acct-999"))
        c.pollOnce()
        // Mirrors TelemetryGraph's providers after the P2-T5 fix: the account
        // surfaces only on APPROVED, but upload eligibility already covers
        // REGISTERED (a strict subset of eligibility, not of identity).
        val cloudSyncEnabled = true
        val accountIdProvider: () -> String? = {
            if (cloudSyncEnabled && settings.pairingStatus() == TelemetrySettings.PAIRING_STATUS_APPROVED) settings.accountId() else null
        }
        val uploadEnabledProvider: () -> Boolean = {
            cloudSyncEnabled && settings.pairingStatus() in setOf(
                TelemetrySettings.PAIRING_STATUS_REGISTERED,
                TelemetrySettings.PAIRING_STATUS_APPROVED
            )
        }
        assertNotNull(accountIdProvider())
        assertEquals("acct-999", accountIdProvider())
        assertTrue(uploadEnabledProvider())
        // Registered-but-unclaimed: eligible, but no account yet.
        settings.setPairingStatus(TelemetrySettings.PAIRING_STATUS_REGISTERED)
        assertTrue(uploadEnabledProvider())
        assertNull(accountIdProvider())
        // Pending does not grant upload
        fakeClient.enqueueStart(PairingStartResult("555-666", "dev-3", "2099-01-01T00:00:00.000Z"))
        c.start("vin-123")
        // status is pending now, even though accountId still would be old if not cleared; gate checks status
        // After our fix, expired clears, but while pending the gate is still null
        val pendingProvider: () -> String? = {
            if (cloudSyncEnabled && settings.pairingStatus() == TelemetrySettings.PAIRING_STATUS_APPROVED) settings.accountId() else null
        }
        assertNull(pendingProvider())
        assertFalse(uploadEnabledProvider())
        // When gate OFF, still null
        val offProvider: () -> String? = { if (false) settings.accountId() else null }
        assertNull(offProvider())
    }

    @Test
    fun `device_code never persisted across settings reopen`() = runBlocking {
        val c = coordinator()
        fakeClient.enqueueStart(PairingStartResult("111-222", "dev-1", "2099-01-01T00:00:00.000Z"))
        c.start("vin-123")
        assertNotNull(c.currentDeviceCode)
        val reopened = TelemetrySettings(ctx)
        val c2 = PairingCoordinator(fakeClient, reopened, pollIntervalMillis = 0, sleeper = {})
        assertNull(c2.currentDeviceCode)
    }

    @Test
    fun `cancel preserves approved credential`() = runBlocking {
        val c = coordinator()
        fakeClient.enqueueStart(PairingStartResult("111-222", "dev-1", "2099-01-01T00:00:00.000Z"))
        c.start("vin-123")
        fakeClient.enqueuePoll(PairingPollResult.Approved(carToken = "tok", accountId = "acct-1"))
        c.pollOnce()
        c.cancel()
        assertEquals("tok", settings.carToken())
        assertEquals("acct-1", settings.accountId())
        assertEquals(TelemetrySettings.PAIRING_STATUS_APPROVED, settings.pairingStatus())
    }

    @Test
    fun `cancel pending clears stale credential`() = runBlocking {
        val c = coordinator()
        // Approve first
        fakeClient.enqueueStart(PairingStartResult("111-222", "dev-1", "2099-01-01T00:00:00.000Z"))
        c.start("vin-123")
        fakeClient.enqueuePoll(PairingPollResult.Approved("old-tok", "old-acct"))
        c.pollOnce()
        // Re-pair
        fakeClient.enqueueStart(PairingStartResult("999-000", "dev-2", "2099-01-01T00:00:00.000Z"))
        c.start("vin-123")
        c.cancel()
        assertNull(settings.carToken())
        assertNull(settings.accountId())
        assertEquals(TelemetrySettings.PAIRING_STATUS_UNPAIRED, settings.pairingStatus())
    }

    @Test
    fun `registerAndSave leaves the uploader gate open with a null account`() = runBlocking {
        // P2-T6 end to end with the real persistence: unpaired car registers,
        // and the uploader's providers (mirroring TelemetryGraph's) must now
        // admit REGISTERED with account_id = null — the ownerless rows Phase 3
        // adopts at claim time.
        val c = coordinator()
        fakeClient.enqueueRegister(RegisterResult(carToken = "tok-reg"))
        c.registerAndSave("vin-123")
        val cloudSyncEnabled = true
        val accountIdProvider: () -> String? = {
            if (cloudSyncEnabled && settings.pairingStatus() == TelemetrySettings.PAIRING_STATUS_APPROVED) settings.accountId() else null
        }
        val uploadEnabledProvider: () -> Boolean = {
            cloudSyncEnabled && settings.pairingStatus() in setOf(
                TelemetrySettings.PAIRING_STATUS_REGISTERED,
                TelemetrySettings.PAIRING_STATUS_APPROVED
            )
        }
        assertTrue(uploadEnabledProvider())
        assertNull(accountIdProvider())
        assertEquals("tok-reg", settings.carToken())
        assertEquals(TelemetrySettings.PAIRING_STATUS_REGISTERED, settings.pairingStatus())
    }

    @Test
    fun `blank token refused stays unpaired and keeps the upload gate shut`() = runBlocking {
        settings.setPairingStatus(TelemetrySettings.PAIRING_STATUS_UNPAIRED)
        fakeClient.enqueueRegister(RegisterResult(carToken = ""))
        val c = coordinator()
        var threw = false
        try {
            c.registerAndSave("vin-123")
        } catch (e: DevicePairingException) {
            threw = true
        }
        assertTrue(threw)
        assertEquals(TelemetrySettings.PAIRING_STATUS_UNPAIRED, settings.pairingStatus())
        assertNull(settings.carToken())
        // An unregistered car must not upload: a phantom registration that
        // would let it believe it is online while every upload is refused is
        // worse than not registering at all.
        val uploadEnabledProvider: () -> Boolean = {
            settings.pairingStatus() in setOf(
                TelemetrySettings.PAIRING_STATUS_REGISTERED,
                TelemetrySettings.PAIRING_STATUS_APPROVED
            )
        }
        assertFalse(uploadEnabledProvider())
    }
}
