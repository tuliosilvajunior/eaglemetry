package com.timhss.capyenergy.telemetry

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

class TelemetrySettingsPairingTest {

    private lateinit var settings: TelemetrySettings
    private lateinit var ctx: FakeSettingsContext

    @Before
    fun setUp() {
        ctx = FakeSettingsContext()
        settings = TelemetrySettings(ctx)
    }

    @Test
    fun `pairing defaults to unpaired with no token`() {
        assertEquals(TelemetrySettings.PAIRING_STATUS_UNPAIRED, settings.pairingStatus())
        assertNull(settings.carToken())
        assertNull(settings.accountId())
    }

    @Test
    fun `set pairing status pending persists`() {
        settings.setPairingStatus(TelemetrySettings.PAIRING_STATUS_PENDING)
        assertEquals(TelemetrySettings.PAIRING_STATUS_PENDING, settings.pairingStatus())
        // Reopen sees same value
        val reopened = TelemetrySettings(ctx)
        assertEquals(TelemetrySettings.PAIRING_STATUS_PENDING, reopened.pairingStatus())
    }

    @Test
    fun `set pairing status approved persists`() {
        settings.setPairingStatus(TelemetrySettings.PAIRING_STATUS_APPROVED)
        assertEquals(TelemetrySettings.PAIRING_STATUS_APPROVED, settings.pairingStatus())
    }

    @Test
    fun `invalid pairing status falls back to unpaired`() {
        settings.setPairingStatus("garbage")
        assertEquals(TelemetrySettings.PAIRING_STATUS_UNPAIRED, settings.pairingStatus())
    }

    @Test
    fun `null pairing status resets to unpaired`() {
        settings.setPairingStatus(TelemetrySettings.PAIRING_STATUS_PENDING)
        settings.setPairingStatus(null)
        assertEquals(TelemetrySettings.PAIRING_STATUS_UNPAIRED, settings.pairingStatus())
    }

    @Test
    fun `blank pairing status resets to unpaired`() {
        settings.setPairingStatus("   ")
        assertEquals(TelemetrySettings.PAIRING_STATUS_UNPAIRED, settings.pairingStatus())
    }

    @Test
    fun `car token round trips`() {
        settings.setCarToken("tok_abc123")
        assertEquals("tok_abc123", settings.carToken())
        val reopened = TelemetrySettings(ctx)
        assertEquals("tok_abc123", reopened.carToken())
    }

    @Test
    fun `blank car token clears`() {
        settings.setCarToken("tok")
        settings.setCarToken("   ")
        assertNull(settings.carToken())
    }

    @Test
    fun `null car token clears`() {
        settings.setCarToken("tok")
        settings.setCarToken(null)
        assertNull(settings.carToken())
    }

    @Test
    fun `account id round trips`() {
        settings.setAccountId("00000000-0000-4000-a000-000000000001")
        assertEquals("00000000-0000-4000-a000-000000000001", settings.accountId())
    }

    @Test
    fun `clearPairing resets all three fields`() {
        settings.setPairingStatus(TelemetrySettings.PAIRING_STATUS_APPROVED)
        settings.setCarToken("tok")
        settings.setAccountId("acct")
        settings.clearPairing()
        assertEquals(TelemetrySettings.PAIRING_STATUS_UNPAIRED, settings.pairingStatus())
        assertNull(settings.carToken())
        assertNull(settings.accountId())
        val reopened = TelemetrySettings(ctx)
        assertEquals(TelemetrySettings.PAIRING_STATUS_UNPAIRED, reopened.pairingStatus())
        assertNull(reopened.carToken())
        assertNull(reopened.accountId())
    }

    @Test
    fun `set pairing status registered persists`() {
        settings.setPairingStatus(TelemetrySettings.PAIRING_STATUS_REGISTERED)
        assertEquals(TelemetrySettings.PAIRING_STATUS_REGISTERED, settings.pairingStatus())
    }

    @Test
    fun `set pairing status revoked persists`() {
        settings.setPairingStatus(TelemetrySettings.PAIRING_STATUS_REVOKED)
        assertEquals(TelemetrySettings.PAIRING_STATUS_REVOKED, settings.pairingStatus())
    }

    @Test
    fun `markRevoked sets revoked and keeps tokens`() {
        settings.setPairingStatus(TelemetrySettings.PAIRING_STATUS_REGISTERED)
        settings.setCarToken("tok")
        settings.setAccountId("acct")
        settings.markRevoked()
        assertEquals(TelemetrySettings.PAIRING_STATUS_REVOKED, settings.pairingStatus())
        assertEquals("tok", settings.carToken())
        assertEquals("acct", settings.accountId())
    }

    @Test
    fun `pairing fields are independent of vehicle id`() {
        settings.setVehicleId("VIN-1")
        settings.setPairingStatus(TelemetrySettings.PAIRING_STATUS_PENDING)
        settings.setCarToken("tok")
        settings.setAccountId("acct")
        assertEquals("VIN-1", settings.vehicleId())
        assertEquals(TelemetrySettings.PAIRING_STATUS_PENDING, settings.pairingStatus())
        assertEquals("tok", settings.carToken())
    }
}
